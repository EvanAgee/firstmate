#!/usr/bin/env bash
# fm-captain-queue.sh - fleet-board captain cards, answer reconcile, expiry, and auto-retire.
#
# The dashboard posts each answer as one JSON line on state/captain-replies.jsonl
# with the card's id and generation, and wakes firstmate through the home-local
# captain-queue check when that file grows past state/captain-replies.cursor.
# This script is the only writer of data/captain-queue.json. The card id and the
# reply id are the same value: the decision-hold identity
# (`bin/fm-decision-hold.sh id <origin> <key>`) when one exists, or the backlog
# captain-hold id otherwise. Do not invent a shorter second id.
#
# Captain-queue.json persists each card once in `records`. Each record's
# `state` is `open`, `parked`, or `resolved`; readers derive their views from
# that field. The writer accepts the legacy items/resolved/parked shape and
# keeps active or parked same-id rows ahead of resolved history.
# Same-state duplicates use their newest state timestamp and stable tie-breaks.
# A legacy active row paired with resolved history receives the next generation.
# A future legacy asked-at is clamped to the first canonical migration time.
# The next successful write emits the canonical records shape.
# `add` upserts an open card or reopens a resolved card without parked history.
# Idempotent open-card retries with the same ask fields preserve generation;
# changing an ask field increments it. Both preserve the original asked-at and
# backing classification, including the missing classification on legacy
# records. Reopening a resolved card also increments its generation.
# `reconcile` is the captain-reply wake action and the heartbeat board sweep.
# It reads every new reply line past the cursor and groups conflicts by id and
# generation. The latest server receipt time wins, with later log order breaking
# a tie. Earlier replies remain in the log, print `superseded:`, and advance the
# cursor. Only the winner prints `handled:`. A winner received after another
# answer was handled also prints `superseding:` and replaces the recorded answer.
# A matched winner changes the card's state to `resolved` and records a pending
# delivery until `handled:` is emitted and the cursor advances past that line.
# A reopen cannot discard this evidence. Before the first canonical write,
# consumed replies reconstruct delivered-winner evidence from the log and cursor.
# A reply without a generation is legacy generation 1. A newer conflict for an
# already delivered historical generation prints `superseding:` and `handled:`
# without changing the current card; other old-generation replies print `stale:`.
# Resolving the card is not doing the work:
# each `handled:` line is the answer firstmate still has to act on. An `orphan:`
# line matches no card; the cursor stays before it so the answer cannot be
# skipped. Reconcile never advances past an answer that was neither matched nor
# surfaced. Dashboard-reply clearing is unchanged: a matched reply still prints
# `handled:` so firstmate can verify a "Done - command ran" answer against
# reality before treating that work as done.
# After applying new replies, or when there are none, reconcile also retires
# each remaining active card recorded as backed whose backlog item is done.
# The card id is the backlog captain-hold id or the decision-hold identity, so a done item and
# a closed decision-hold are the same check: `tasks-axi show <id>` against this
# home's backlog reports state done. Cards whose item is still open, absent, or
# unreadable stay. Auto-clear prints `cleared:` lines, not `handled:`; those
# are not dashboard answers to act on. A readable backlog is checked directly
# when tasks-axi cannot answer.
# `add` records backlog_backed as true, false, or null when the backlog cannot
# be read. False, null, and legacy records without the field expire after
# UNBACKED_CARD_EXPIRY_DAYS (7) days without dropping their content.
# `park` defers a confirmed-unbacked card at any age, or migrates a
# human-verified legacy card, with a required note.
# Repeating it is a no-op for parked cards and resolved cards with parked history.
# Add, park, and reconcile take one home-scoped lock at
# state/.captain-queue.lock for the whole read-modify-write, then release it.
#
# Usage:
#   fm-captain-queue.sh add --id <id> --question <text> \
#     [--context <text>] [--project <name>] [--asked-at <iso>] \
#     [--option <text>]... [--command <text>]...
#   fm-captain-queue.sh park --id <id> --note <text>
#   fm-captain-queue.sh reconcile
#   fm-captain-queue.sh -h|--help
#
# Environment:
#   FM_HOME / FM_ROOT_OVERRIDE / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE
#   FM_CAPTAIN_QUEUE_NOW   optional ISO stamp for updated_at / asked_at / resolved_at / parked_at
#
# Requires jq.
# Exit 0 on success (including an empty reconcile).
# Exit 1 when reconcile stops on an orphan or a malformed reply.
# Exit 2 on usage or missing jq.
set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
QUEUE="$DATA/captain-queue.json"
REPLIES="$STATE/captain-replies.jsonl"
CURSOR_FILE="$STATE/captain-replies.cursor"
QUEUE_LOCK="$STATE/.captain-queue.lock"
QUEUE_LOCK_HELD=0
LOCK_LIB_LOADED=0
UNBACKED_CARD_EXPIRY_DAYS=7
UNBACKED_CARD_EXPIRY_SECONDS=$((UNBACKED_CARD_EXPIRY_DAYS * 24 * 60 * 60))
ISO_EPOCH_JQ='
def fm_iso_epoch:
  . as $stamp
  | (($stamp | fromdateiso8601?) as $epoch
      | select($epoch != null and ($epoch | todateiso8601) == $stamp)
      | $epoch)
    //
    (($stamp | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\\.(?<fraction>[0-9]+)Z$")?) as $parts
      | select($parts != null)
      | ($parts.base + "Z" | fromdateiso8601?) as $whole
      | select($whole != null and ($whole | todateiso8601) == ($parts.base + "Z"))
      | ($whole + ("0." + $parts.fraction | tonumber)))
    //
    (($stamp | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]+))?(?<sign>[+-])(?<hours>[0-9]{2}):(?<minutes>[0-9]{2})$")?) as $parts
      | select($parts != null)
      | ($parts.hours | tonumber) as $hours
      | ($parts.minutes | tonumber) as $minutes
      | select($hours <= 23 and $minutes <= 59)
      | ($parts.base + "Z" | fromdateiso8601?) as $local
      | select($local != null and ($local | todateiso8601) == ($parts.base + "Z"))
      | (if ($parts.fraction // "") == ""
         then 0
         else ("0." + $parts.fraction | tonumber)
         end) as $fraction
      | (($hours * 60 + $minutes) * 60) as $offset
      | ($local + $fraction + (if $parts.sign == "+" then -$offset else $offset end)))
    // empty;
'
REPLY_LOG_JQ='
def fm_reply_receipt_ms:
  if has("at") | not then -1
  elif (.at | type) != "string" then null
  elif (.at | test("\\.[0-9]{3}Z$")) then
    (.at | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\\.(?<ms>[0-9]{3})Z$")) as $parts
    | ([($parts.base + "Z" | fm_iso_epoch)][0] // null) as $epoch
    | if $epoch == null then null
      else ($epoch * 1000) + ($parts.ms | tonumber)
      end
  else
    ([.at | fm_iso_epoch][0] // null) as $epoch
    | if $epoch == null then null else $epoch * 1000 end
  end;
def fm_classified_replies($raw):
  $raw
  | split("\n")
  | to_entries
  | if length > 0 and .[-1].value == "" then .[:-1] else . end
  | map({line: (.key + 1), raw: .value})
  | map(
      . as $line
      | (try (.raw | fromjson) catch null) as $record
      | (if ($record | type) == "object" then ($record | fm_reply_receipt_ms) else null end) as $receipt
      | (if ($record | type) != "object" then false
         else
           (($record.id | type) == "string" and ($record.id | length) > 0)
           and (($record.answer | type) == "string")
           and ((($record | has("generation")) | not)
             or (($record.generation | type) == "number"
               and $record.generation > 0
               and ($record.generation | floor) == $record.generation))
           and ((($record | has("at")) | not) or $receipt != null)
         end) as $valid
      | . + {
          valid: $valid,
          id: (if $valid then $record.id else "" end),
          generation: (if $valid then ($record.generation // 1) else 0 end),
          answer: (if $valid then $record.answer else "" end),
          receipt_ms: (if $valid then $receipt else null end)
        }
    );
'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  local code=$1
  shift
  printf 'fm-captain-queue: %s\n' "$*" >&2
  exit "$code"
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die 2 "jq is required"
}

load_lock_lib() {
  if [ "$LOCK_LIB_LOADED" = 0 ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    LOCK_LIB_LOADED=1
  fi
}

acquire_queue_lock() {
  load_lock_lib
  mkdir -p "$STATE"
  fm_lock_acquire_wait "$QUEUE_LOCK" || die 1 "cannot lock captain queue"
  QUEUE_LOCK_HELD=1
}

release_queue_lock() {
  if [ "$QUEUE_LOCK_HELD" = 1 ]; then
    fm_lock_release "$QUEUE_LOCK" || true
    QUEUE_LOCK_HELD=0
  fi
}

trap release_queue_lock EXIT

now_stamp() {
  local stamp
  if [ -n "${FM_CAPTAIN_QUEUE_NOW:-}" ]; then
    stamp=$(normalize_iso_stamp "$FM_CAPTAIN_QUEUE_NOW")
    [ -n "$stamp" ] \
      || die 2 "FM_CAPTAIN_QUEUE_NOW must be an ISO timestamp with a timezone"
    printf '%s\n' "$stamp"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
}

normalize_iso_stamp() {  # <stamp>
  jq -nr --arg stamp "$1" "$ISO_EPOCH_JQ"'
    $stamp | fm_iso_epoch | todateiso8601
  '
}

id_ok() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
  else
    jq -n --args '$ARGS.positional' -- "$@"
  fi
}

atomic_write() {  # <dest>  (stdin is the new contents)
  local dest=$1 dir tmp
  dir=$(dirname -- "$dest")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.fm-captain-queue.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest"
}

read_queue() {
  local migration_stamp
  migration_stamp=$(now_stamp)
  if [ -f "$QUEUE" ]; then
    jq -c --arg migration_stamp "$migration_stamp" "$ISO_EPOCH_JQ"'
      def objects: map(select(type == "object"));
      def with_state($state): . + {state: $state} | del(.status);
      def with_generation:
        . + {generation:
          (if ((.generation | type) == "number"
              and .generation > 0
              and (.generation | floor) == .generation)
          then .generation else 1 end)};
      def valid_state: . == "open" or . == "parked" or . == "resolved";
      def valid_id: (.id | type) == "string" and (.id | length) > 0;
      def valid_pending_reply_delivery:
        type == "object"
        and ((.line | type) == "number" and .line > 0 and (.line | floor) == .line)
        and ((.generation | type) == "number"
          and .generation > 0
          and (.generation | floor) == .generation)
        and ((.id | type) == "string" and (.id | length) > 0)
        and (.answer | type) == "string"
        and ((has("kind") | not) or .kind == "handled" or .kind == "superseding");
      def valid_delivered_reply_winner:
        type == "object"
        and ((.line | type) == "number" and .line > 0 and (.line | floor) == .line)
        and ((.generation | type) == "number"
          and .generation > 0
          and (.generation | floor) == .generation)
        and ((.id | type) == "string" and (.id | length) > 0)
        and (.answer | type) == "string"
        and (.kind == "handled" or .kind == "superseding");
      def state_touch_epoch:
        (if .state == "resolved" then (.resolved_at // .parked_at // .asked_at)
        elif .state == "parked" then (.parked_at // .asked_at)
        else .asked_at
        end)
        | if type == "string" then fm_iso_epoch // -1 else -1 end;
      def legacy_state_rank:
        if .state == "parked" then 2
        elif .state == "open" then 1
        else 0
        end;
      def latest_legacy_records:
        . as $records
        | (($records
            | map(select(valid_id))
            | sort_by(.id)
            | group_by(.id)
            | map(
                . as $group
                | ($group | max_by([
                    legacy_state_rank,
                    state_touch_epoch,
                    (.num // 0),
                    (.__fm_legacy_order // 0)
                  ])) as $selected
                | ([$group[]
                    | select(.state == "resolved")
                    | if ((.generation | type) == "number"
                        and .generation > 0
                        and (.generation | floor) == .generation)
                      then .generation else 1 end] | max // 0) as $resolved_generation
                | if $selected.state != "resolved" and $resolved_generation > 0 then
                    $selected
                    + {generation: ([$selected.generation // 1, $resolved_generation + 1] | max)}
                    + {__fm_legacy_resolved_answers: [$group[]
                        | select(.state == "resolved" and (.answer | type) == "string")
                        | {
                            generation: (if ((.generation | type) == "number"
                                and .generation > 0
                                and (.generation | floor) == .generation)
                              then .generation else 1 end),
                            answer: .answer
                          }]}
                  else $selected
                  end
              ))
          + ($records | map(select(valid_id | not))))
        | sort_by([.num // 0, .id // ""])
        | map(del(.__fm_legacy_order));
      if type != "object" then
        error("captain-queue.json is not an object")
      else
        (if has("records") then
          if (.records | type) != "array" then
            error("captain-queue.json records is not an array")
          else
            (.records | objects | map(
              if (.state | valid_state) then del(.status)
              else error("captain-queue.json record has an invalid state")
              end
            ))
          end
        else
          ((((.resolved // []) | objects | map(with_state("resolved")))
          + ((.items // []) | objects | map(with_state("open")))
          + ((.parked // []) | objects | map(with_state("parked"))))
          | map(
              ([.asked_at | fm_iso_epoch][0] // null) as $asked_epoch
              | ([$migration_stamp | fm_iso_epoch][0] // null) as $migration_epoch
              | if $asked_epoch != null
                  and $migration_epoch != null
                  and $asked_epoch > $migration_epoch
              then .asked_at = $migration_stamp
              else .
              end)
          | to_entries
          | map(.value + {__fm_legacy_order: .key})
          | latest_legacy_records)
        end | map(with_generation)) as $records
        | (.pending_reply_deliveries // []) as $pending
        | (if ($pending | type) != "array" then
            error("captain-queue.json pending_reply_deliveries is not an array")
          elif any($pending[]; valid_pending_reply_delivery | not) then
            error("captain-queue.json has an invalid pending reply delivery")
          else $pending
          end) as $pending_reply_deliveries
        | (.delivered_reply_winners // []) as $delivered
        | (if ($delivered | type) != "array" then
            error("captain-queue.json delivered_reply_winners is not an array")
          elif any($delivered[]; valid_delivered_reply_winner | not) then
            error("captain-queue.json has an invalid delivered reply winner")
          else $delivered
          end) as $delivered_reply_winners
        | ([$records[] | .id | select(type == "string" and length > 0)]
          | group_by(.) | map(select(length > 1)) | .[0][0] // "") as $duplicate
        | if $duplicate != "" then
            error("captain-queue.json has duplicate card id: " + $duplicate)
          else
            {
              updated_at: (.updated_at // ""),
              records: $records,
              pending_reply_deliveries: $pending_reply_deliveries,
              delivered_reply_winners: $delivered_reply_winners,
              reply_delivery_tracking: (.reply_delivery_tracking == true),
              __fm_needs_canonical_write: (has("records") | not)
            }
          end
      end
    ' "$QUEUE"
  else
    printf '%s\n' '{"updated_at":"","records":[],"pending_reply_deliveries":[],"delivered_reply_winners":[],"reply_delivery_tracking":false,"__fm_needs_canonical_write":false}'
  fi
}

write_queue() {  # stdin: queue object
  local stamp json
  stamp=$(now_stamp)
  json=$(jq -c --arg stamp "$stamp" '{
    updated_at: $stamp,
    records: [(.records // [])[] | del(.__fm_legacy_resolved_answers)],
    pending_reply_deliveries: (.pending_reply_deliveries // []),
    delivered_reply_winners: (.delivered_reply_winners // []),
    reply_delivery_tracking: true
  }') || return 1
  printf '%s\n' "$json" | jq '.' | atomic_write "$QUEUE"
}

read_cursor() {
  local seen=0
  if [ -f "$CURSOR_FILE" ]; then
    seen=$(tr -cd '0-9' < "$CURSOR_FILE")
    [ -n "$seen" ] || seen=0
  fi
  printf '%s\n' "$seen"
}

migrate_reply_delivery_tracking() {  # <queue-json> <cursor>
  local queue=$1 cursor=$2 replies_file=$REPLIES
  if [ "$(printf '%s\n' "$queue" | jq -r '.reply_delivery_tracking')" = true ]; then
    printf '%s\n' "$queue"
    return 0
  fi
  [ -f "$replies_file" ] || replies_file=/dev/null
  printf '%s\n' "$queue" | jq -c \
    --rawfile raw "$replies_file" \
    --argjson cursor "$cursor" \
    "$ISO_EPOCH_JQ$REPLY_LOG_JQ"'
      . as $queue
      | (fm_classified_replies($raw)
        | map(select(.valid and .line <= $cursor))) as $consumed
      | ([$queue.records[] as $record
          | $consumed[]
          | . as $entry
          | select(.id == $record.id)
          | select(
              if $record.state == "resolved" then
                .generation == $record.generation
              elif .generation < $record.generation then
                any($record.__fm_legacy_resolved_answers[]?;
                  .generation == $entry.generation
                  and (.answer == $entry.answer or .answer == "backlog-done"))
                or (
                  ([$record.asked_at | fm_iso_epoch][0] // null) as $asked_epoch
                  |
                  .receipt_ms >= 0
                  and $asked_epoch != null
                  and .receipt_ms <= ($asked_epoch * 1000)
                )
              else false
              end)
        ]
        | sort_by([.id, .generation])
        | group_by([.id, .generation])
        | map(max_by([.receipt_ms, .line]))
        | map(. as $winner
            | ([$queue.records[] | select(.id == $winner.id)][0]) as $record
            | select($record.state != "resolved"
              or $record.answer == "backlog-done"
              or $record.answer == $winner.answer)
            | {
                line: .line,
                id: .id,
                generation: .generation,
                answer: .answer,
                kind: "handled"
              })) as $reconstructed
      | $queue
      | .delivered_reply_winners = (
          ((.delivered_reply_winners // []) + $reconstructed)
          | sort_by([.id, .generation])
          | group_by([.id, .generation])
          | map(max_by(.line))
        )
      | .reply_delivery_tracking = true
    '
}

write_cursor() {  # <n>
  printf '%s\n' "$1" | atomic_write "$CURSOR_FILE"
}

cmd_add() {
  local id="" question="" context="" project="" asked_at="" add_stamp
  local -a options=() commands=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)
        [ "$#" -ge 2 ] || die 2 "add --id needs a value"
        id=$2
        shift 2
        ;;
      --question)
        [ "$#" -ge 2 ] || die 2 "add --question needs a value"
        question=$2
        shift 2
        ;;
      --context)
        [ "$#" -ge 2 ] || die 2 "add --context needs a value"
        context=$2
        shift 2
        ;;
      --project)
        [ "$#" -ge 2 ] || die 2 "add --project needs a value"
        project=$2
        shift 2
        ;;
      --asked-at)
        [ "$#" -ge 2 ] || die 2 "add --asked-at needs a value"
        asked_at=$2
        shift 2
        ;;
      --option)
        [ "$#" -ge 2 ] || die 2 "add --option needs a value"
        options+=("$2")
        shift 2
        ;;
      --command)
        [ "$#" -ge 2 ] || die 2 "add --command needs a value"
        commands+=("$2")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die 2 "unknown add flag: $1"
        ;;
    esac
  done
  [ -n "$id" ] || die 2 "add requires --id"
  id_ok "$id" || die 2 "id must be a hold identity slug"
  [ -n "$question" ] || die 2 "add requires --question"
  add_stamp=$(now_stamp)
  [ -n "$asked_at" ] || asked_at=$add_stamp
  asked_at=$(normalize_iso_stamp "$asked_at")
  [ -n "$asked_at" ] || die 2 "add --asked-at must be an ISO timestamp with a timezone"
  jq -ne --arg asked "$asked_at" --arg added "$add_stamp" \
    '($asked | fromdateiso8601) <= ($added | fromdateiso8601)' >/dev/null \
    || die 2 "add --asked-at cannot be later than the add time"

  local queue options_json commands_json next_num item backlog_backed cursor
  acquire_queue_lock
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
  cursor=$(read_cursor)
  queue=$(migrate_reply_delivery_tracking "$queue" "$cursor") \
    || die 1 "failed to migrate reply delivery tracking"
  if printf '%s\n' "$queue" | jq -e --arg id "$id" '
      any(.records[];
        .id == $id
        and (.state == "parked"
          or (has("parked_at") or has("parked_reason") or has("parked_note")))
      )
    ' >/dev/null; then
    die 1 "card already parked: $id"
  fi
  backlog_backed=$(add_time_backlog_backing_state "$id")
  if [ "${#options[@]}" -gt 0 ]; then
    options_json=$(json_array "${options[@]}")
  else
    options_json=$(json_array)
  fi
  if [ "${#commands[@]}" -gt 0 ]; then
    commands_json=$(json_array "${commands[@]}")
  else
    commands_json=$(json_array)
  fi
  next_num=$(printf '%s\n' "$queue" | jq -r '.records | map(.num) | max // 0')
  next_num=$((next_num + 1))
  item=$(jq -nc \
    --arg id "$id" \
    --arg question "$question" \
    --arg context "$context" \
    --arg project "$project" \
    --arg asked_at "$asked_at" \
    --argjson num "$next_num" \
    --argjson backlog_backed "$backlog_backed" \
    --argjson options "$options_json" \
    --argjson commands "$commands_json" \
    '{
      id: $id,
      num: $num,
      question: $question,
      context: $context,
      commands: $commands,
      options: $options,
      asked_at: $asked_at,
      backlog_backed: $backlog_backed,
      generation: 1,
      state: "open",
      project: $project
    }')
  queue=$(printf '%s\n' "$queue" | jq -c --arg id "$id" --argjson item "$item" '
    if any(.records[]; .id == $id and (.state == "open" or .state == "resolved")) then
      .records = [.records[] |
        if .id == $id and .state == "open" then
          . as $existing
          | $item + {
              num: $existing.num,
              asked_at: ($existing.asked_at // $item.asked_at),
              generation: ($existing.generation +
                (if [
                  $existing.question,
                  $existing.context,
                  $existing.commands,
                  $existing.options,
                  $existing.project
                ] == [
                  $item.question,
                  $item.context,
                  $item.commands,
                  $item.options,
                  $item.project
                ] then 0 else 1 end))
            }
          | if ($existing | has("backlog_backed")) then
              .backlog_backed = $existing.backlog_backed
            else
              del(.backlog_backed)
            end
        elif .id == $id and .state == "resolved" then
          $item + {num: .num, generation: (.generation + 1)}
        else
          .
        end
      ]
    else
      .records += [$item]
    end
  ')
  printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
  release_queue_lock
  printf 'added: %s\n' "$id"
}

# Apply one park transition while preserving the complete active card.
apply_parked() {  # <queue-json> <id> <stamp> <reason> <note> -> new queue on stdout
  local queue=$1 id=$2 stamp=$3 reason=$4 note=$5
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --arg stamp "$stamp" \
    --arg reason "$reason" \
    --arg note "$note" '
      .records = [.records[] |
        if .id == $id and .state == "open" then
          . + {
            state: "parked",
            parked_at: $stamp,
            parked_reason: $reason,
            parked_note: $note
          }
        else . end
      ]
    '
}

cmd_park() {
  local id="" note="" queue stamp cursor
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)
        [ "$#" -ge 2 ] || die 2 "park --id needs a value"
        id=$2
        shift 2
        ;;
      --note)
        [ "$#" -ge 2 ] || die 2 "park --note needs a value"
        note=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die 2 "unknown park flag: $1"
        ;;
    esac
  done
  [ -n "$id" ] || die 2 "park requires --id"
  id_ok "$id" || die 2 "id must be a hold identity slug"
  [ -n "$note" ] || die 2 "park requires --note"

  acquire_queue_lock
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
  cursor=$(read_cursor)
  queue=$(migrate_reply_delivery_tracking "$queue" "$cursor") \
    || die 1 "failed to migrate reply delivery tracking"
  if printf '%s\n' "$queue" | jq -e --arg id "$id" '
      any(.records[];
        .id == $id
        and (.state == "parked"
          or (.state == "resolved"
            and (has("parked_at") or has("parked_reason") or has("parked_note"))))
      )
    ' >/dev/null; then
    release_queue_lock
    printf 'parked: [id=%s] already-parked\n' "$id"
    return 0
  fi
  if ! printf '%s\n' "$queue" | jq -e --arg id "$id" \
      'any(.records[]; .id == $id and .state == "open")' >/dev/null; then
    die 1 "active card not found: $id"
  fi
  if ! printf '%s\n' "$queue" | jq -e --arg id "$id" '
      any(.records[];
        .id == $id
        and .state == "open"
        and ((has("backlog_backed") | not) or .backlog_backed == false)
      )
    ' >/dev/null; then
    die 1 "manual park requires an unbacked or legacy card: $id"
  fi
  stamp=$(now_stamp)
  queue=$(apply_parked "$queue" "$id" "$stamp" "manual" "$note") \
    || die 1 "failed to park $id"
  printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
  release_queue_lock
  printf 'parked: [id=%s] manual\n' "$id"
}

# Print the backlog state for <id>, or absent when no item exists.
backlog_item_state() {  # <id>
  local id=$1 show state
  [ -n "$id" ] || return 1
  [ -f "$DATA/backlog.md" ] || { printf 'absent\n'; return 0; }
  [ -r "$DATA/backlog.md" ] || return 1
  if command -v tasks-axi >/dev/null 2>&1; then
    if show=$(tasks-axi show "$id" --file "$DATA/backlog.md" 2>&1); then
      state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
      if [ -n "$state" ]; then
        printf '%s\n' "$state"
        return 0
      fi
    elif printf '%s\n' "$show" | grep -qx 'code: NOT_FOUND'; then
      printf 'absent\n'
      return 0
    fi
  fi
  awk -v wanted="$id" '
    function heading_state(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "Done") return "done"
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      return ""
    }
    function row_id(line, separator, candidate) {
      sub(/^[-*][[:space:]]+/, "", line)
      sub(/^\[[ xX]\][[:space:]]+/, "", line)
      separator = index(line, " - ")
      if (separator == 0) return ""
      candidate = substr(line, 1, separator - 1)
      if (candidate ~ /^\*\*[^*]+\*\*$/) {
        candidate = substr(candidate, 3, length(candidate) - 4)
      }
      return candidate
    }
    /^##[[:space:]]+/ { section = heading_state($0); next }
    /^[-*][[:space:]]+/ && row_id($0) == wanted {
      if (section == "done") print "done"
      else if (section == "") print "present"
      else print section
      found = 1
      exit
    }
    END { if (!found) print "absent" }
  ' "$DATA/backlog.md"
}

add_time_backlog_backing_state() {  # <id>
  local state
  state=$(backlog_item_state "$1") || { printf 'null\n'; return 0; }
  if [ "$state" = absent ]; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

# Apply one resolution and optionally retain its reply line for delivery.
apply_handled() {  # <queue-json> <id> <generation> <answer> <stamp> [line] -> new queue on stdout
  local queue=$1 id=$2 generation=$3 answer=$4 stamp=$5 line=${6:-}
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --argjson generation "$generation" \
    --arg answer "$answer" \
    --arg stamp "$stamp" \
    --arg line "$line" '
      .records = [.records[] |
        if .id == $id
          and .generation == $generation
          and (.state == "open" or .state == "parked") then
          . + {
            state: "resolved",
            answer: $answer,
            resolved_at: $stamp
          }
        else . end
      ]
      | if $line == "" then . else
          .pending_reply_deliveries = ((.pending_reply_deliveries // []) + [{
            line: ($line | tonumber),
            id: $id,
            generation: $generation,
            answer: $answer,
            kind: "handled"
          }])
        end
    '
}

apply_replacement_answer() {  # <queue-json> <id> <generation> <answer> <stamp> <line> <kind> -> new queue on stdout
  local queue=$1 id=$2 generation=$3 answer=$4 stamp=$5 line=$6 kind=$7
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --argjson generation "$generation" \
    --arg answer "$answer" \
    --arg stamp "$stamp" \
    --argjson line "$line" \
    --arg kind "$kind" '
      .records = [.records[] |
        if .id == $id and .generation == $generation and .state == "resolved" then
          . + {answer: $answer, resolved_at: $stamp}
        else . end
      ]
      | .pending_reply_deliveries = ((.pending_reply_deliveries // []) + [{
          line: $line,
          id: $id,
          generation: $generation,
          answer: $answer,
          kind: $kind
        }])
    '
}

record_reply_delivery() {  # <queue-json> <id> <generation> <answer> <line> <kind> -> new queue on stdout
  local queue=$1 id=$2 generation=$3 answer=$4 line=$5 kind=$6
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --argjson generation "$generation" \
    --arg answer "$answer" \
    --argjson line "$line" \
    --arg kind "$kind" '
      .pending_reply_deliveries = (
        [(.pending_reply_deliveries // [])[] | select(.line != $line)]
        + [{
          line: $line,
          id: $id,
          generation: $generation,
          answer: $answer,
          kind: $kind
        }]
      )
    '
}

drop_delivered_replies() {  # <queue-json> <cursor> -> new queue on stdout
  local queue=$1 cursor=$2
  printf '%s\n' "$queue" | jq -c --argjson cursor "$cursor" '
    .pending_reply_deliveries = [
      (.pending_reply_deliveries // [])[] | select(.line > $cursor)
    ]
  '
}

finish_reply_delivery() {  # <id> <generation> <answer> <line> <kind>
  local id=$1 generation=$2 answer=$3 line=$4 kind=$5
  if [ "$kind" = superseding ]; then
    printf 'superseding: [id=%s] [generation=%s] %s\n' "$id" "$generation" "$answer"
  fi
  printf 'handled: [id=%s] %s\n' "$id" "$answer"
  queue=$(printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --argjson generation "$generation" \
    --arg answer "$answer" \
    --argjson line "$line" \
    --arg kind "$kind" '
      .pending_reply_deliveries = [
        (.pending_reply_deliveries // [])[] | select(.line > $line)
      ]
      | .delivered_reply_winners = (
          [(.delivered_reply_winners // [])[]
            | select(.id != $id or .generation != $generation)]
          + [{
              line: $line,
              id: $id,
              generation: $generation,
              answer: $answer,
              kind: $kind
            }]
        )
      | .reply_delivery_tracking = true
    ') || die 1 "failed to record delivered reply"
  printf '%s\n' "$queue" | write_queue || die 1 "failed to clear delivered reply"
  write_cursor "$line" || die 1 "failed to write captain-replies.cursor"
  cursor=$line
}

# True when this home's backlog records <id> as done. Absent, unreadable, or
# still-open items return false so a card cannot clear on a guess.
backlog_item_done() {  # <id>
  local state
  state=$(backlog_item_state "$1") || return 1
  [ "$state" = "done" ]
}

# Retire remaining active cards whose backing backlog item is done.
# Mutates the caller's `queue`. Prints `cleared:` lines, never `handled:`.
clear_closed_cards() {
  local id generation stamp records
  records=$(printf '%s\n' "$queue" | jq -r '
    .records[]?
    | select(.state == "open")
    | select(.backlog_backed == true)
    | [.id // "", .generation]
    | @tsv
  ') || return 0
  [ -n "$records" ] || return 0
  [ -f "$DATA/backlog.md" ] || return 0
  while IFS=$'\t' read -r id generation || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    backlog_item_done "$id" || continue
    stamp=$(now_stamp)
    queue=$(apply_handled "$queue" "$id" "$generation" "backlog-done" "$stamp") || die 1 "failed to auto-clear $id"
    printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
    printf 'cleared: [id=%s] backlog-done\n' "$id"
  done <<EOF
$records
EOF
}

# Move active cards without confirmed add-time backing to parked after seven days.
# A missing or malformed timestamp stays active rather than expiring on a guess.
park_expired_cards() {
  local id stamp ids backing reason note
  stamp=$(now_stamp)
  ids=$(printf '%s\n' "$queue" | jq -r '
    .records[]?
    | select(.state == "open")
    | select((has("backlog_backed") | not)
      or .backlog_backed == false
      or .backlog_backed == null)
    | .id // empty
  ') || return 0
  [ -n "$ids" ] || return 0
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    if ! printf '%s\n' "$queue" | jq -e \
        --arg id "$id" \
        --arg stamp "$stamp" \
        --argjson expiry "$UNBACKED_CARD_EXPIRY_SECONDS" "$ISO_EPOCH_JQ"'
          ($stamp | fm_iso_epoch) as $now
          | (.records[] | select(.id == $id and .state == "open") | .asked_at | fm_iso_epoch) as $asked
          | $now - $asked >= $expiry
        ' >/dev/null; then
      continue
    fi
    backing=$(printf '%s\n' "$queue" | jq -r --arg id "$id" '
      .records[]
      | select(.id == $id and .state == "open")
      | if has("backlog_backed") then (.backlog_backed | tostring) else "legacy" end
    ')
    if [ "$backing" = false ]; then
      reason=expired-unbacked
      note="Expired after $UNBACKED_CARD_EXPIRY_DAYS days without a backing backlog item"
    elif [ "$backing" = legacy ]; then
      reason=expired-legacy-backing
      note="Expired after $UNBACKED_CARD_EXPIRY_DAYS days without verified legacy backing"
    else
      reason=expired-unknown-backing
      note="Expired after $UNBACKED_CARD_EXPIRY_DAYS days while backlog backing could not be verified"
    fi
    queue=$(apply_parked "$queue" "$id" "$stamp" "$reason" "$note") \
      || die 1 "failed to park $id"
    printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
    printf 'parked: [id=%s] %s\n' "$id" "$reason"
  done <<EOF
$ids
EOF
}

build_reply_plan() {  # <queue-json> <cursor> -> plan JSON on stdout
  local queue=$1 cursor=$2
  printf '%s\n' "$queue" | jq -c \
    --rawfile raw "$REPLIES" \
    --argjson cursor "$cursor" \
    "$ISO_EPOCH_JQ$REPLY_LOG_JQ"'
      . as $queue
      | (fm_classified_replies($raw)) as $classified
      | ($classified | map(
          select(.line > $cursor)
          | if (.valid | not) then . + {kind: "malformed"}
            else . as $entry
            | ([$queue.records[]? | select(.id == $entry.id)][0] // null) as $target
            | if $target == null or $target.generation < .generation then
                . + {kind: "orphan"}
              elif $target.generation > .generation then
                . + {kind: "stale"}
              else
                . + {kind: "current"}
              end
            end
        )) as $pending
      | ([range(0; $pending | length)
          | select($pending[.].kind == "malformed" or $pending[.].kind == "orphan")]
          | .[0] // ($pending | length)) as $stop
      | ($pending[0:$stop]) as $processable
      | {
          entries: ($processable | map(
            . as $entry
            | ([$classified[]
                | select(.valid
                  and .id == $entry.id
                  and .generation == $entry.generation)]
                | max_by([.receipt_ms, .line])) as $winner
            | . + {winner_line: $winner.line}
          )),
          blocker: (if $stop < ($pending | length) then $pending[$stop] else null end)
        }
    '
}

cmd_reconcile() {
  local cursor queue pruned plan blocker_line line entry n id generation answer stamp winner_line
  local reply_kind delivery_kind delivered_kind prior_delivered_line prior_delivered_answer replacement_kind
  local needs_migration
  local orphan=0 orphan_id="" orphan_answer=""
  acquire_queue_lock
  cursor=$(read_cursor)
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
  needs_migration=$(printf '%s\n' "$queue" | jq -r '
    (.reply_delivery_tracking != true) or (.__fm_needs_canonical_write == true)
  ')
  queue=$(migrate_reply_delivery_tracking "$queue" "$cursor") \
    || die 1 "failed to migrate reply delivery tracking"
  if [ "$needs_migration" = true ] && [ -f "$QUEUE" ]; then
    printf '%s\n' "$queue" | write_queue || die 1 "failed to persist captain queue migration"
  fi
  pruned=$(drop_delivered_replies "$queue" "$cursor") || die 1 "failed to prune delivered replies"
  if [ "$pruned" != "$queue" ]; then
    queue=$pruned
    printf '%s\n' "$queue" | write_queue || die 1 "failed to prune delivered replies"
  fi

  if [ -f "$REPLIES" ]; then
    plan=$(build_reply_plan "$queue" "$cursor") || die 1 "captain-replies.jsonl is unreadable"
    blocker_line=$(printf '%s\n' "$plan" | jq -r '.blocker.line // 0')
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ "$n" -gt "$cursor" ] || continue
      if [ "$n" -eq "$blocker_line" ]; then
        orphan=1
        if [ "$(printf '%s\n' "$plan" | jq -r '.blocker.kind')" = malformed ]; then
          orphan_id=
          orphan_answer="malformed reply line $n"
        else
          orphan_id=$(printf '%s\n' "$plan" | jq -r '.blocker.id')
          orphan_answer=$(printf '%s\n' "$plan" | jq -r '.blocker.answer')
        fi
        break
      fi
      entry=$(printf '%s\n' "$plan" | jq -c --argjson line "$n" \
        '.entries[] | select(.line == $line)')
      [ -n "$entry" ] || break
      id=$(printf '%s\n' "$entry" | jq -r '.id')
      generation=$(printf '%s\n' "$entry" | jq -r '.generation')
      answer=$(printf '%s\n' "$entry" | jq -r '.answer')
      winner_line=$(printf '%s\n' "$entry" | jq -r '.winner_line')
      reply_kind=$(printf '%s\n' "$entry" | jq -r '.kind')
      prior_delivered_line=$(printf '%s\n' "$queue" | jq -r \
        --arg id "$id" --argjson generation "$generation" '
          [.delivered_reply_winners[]?
            | select(.id == $id and .generation == $generation)
            | .line][0] // 0
        ')
      prior_delivered_answer=$(printf '%s\n' "$queue" | jq -r \
        --arg id "$id" --argjson generation "$generation" '
          [.delivered_reply_winners[]?
            | select(.id == $id and .generation == $generation)
            | .answer][0] // ""
        ')
      replacement_kind=handled
      if [ "$prior_delivered_line" -gt 0 ] && [ "$prior_delivered_answer" != "$answer" ]; then
        replacement_kind=superseding
      fi
      delivered_kind=$(printf '%s\n' "$queue" | jq -r \
        --arg id "$id" \
        --argjson generation "$generation" \
        --arg answer "$answer" \
        --argjson line "$n" '
          [.delivered_reply_winners[]?
            | select(.line == $line
              and .id == $id
              and .generation == $generation
              and .answer == $answer)
            | .kind][0] // ""
        ')
      delivery_kind=$(printf '%s\n' "$queue" | jq -r \
        --arg id "$id" \
        --argjson generation "$generation" \
        --arg answer "$answer" \
        --argjson line "$n" '
          [.pending_reply_deliveries[]?
            | select(.line == $line
              and .id == $id
              and .generation == $generation
              and .answer == $answer)
            | (.kind // "handled")][0] // ""
        ')
      if [ -n "$delivered_kind" ]; then
        if printf '%s\n' "$queue" | jq -e \
            --arg id "$id" --argjson generation "$generation" \
            'any(.records[]; .id == $id and .generation > $generation)' >/dev/null; then
          printf 'stale: [id=%s] [generation=%s] %s\n' "$id" "$generation" "$answer"
        else
          if [ "$delivered_kind" = superseding ]; then
            printf 'superseding: [id=%s] [generation=%s] %s\n' "$id" "$generation" "$answer"
          fi
          printf 'handled: [id=%s] %s\n' "$id" "$answer"
        fi
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
      elif [ "$prior_delivered_line" -gt 0 ] && [ "$prior_delivered_answer" = "$answer" ]; then
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
        queue=$(drop_delivered_replies "$queue" "$cursor") \
          || die 1 "failed to clear duplicate delivered reply"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to clear duplicate delivered reply"
      elif [ -n "$delivery_kind" ] \
          && { [ "$n" -eq "$winner_line" ] || [ "$reply_kind" = stale ]; }; then
        finish_reply_delivery "$id" "$generation" "$answer" "$n" "$delivery_kind"
      elif [ "$n" -ne "$winner_line" ]; then
        printf 'superseded: [id=%s] [generation=%s] [winner-line=%s] %s\n' \
          "$id" "$generation" "$winner_line" "$answer"
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
        queue=$(drop_delivered_replies "$queue" "$cursor") || die 1 "failed to clear superseded reply"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to clear superseded reply"
        continue
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --argjson generation "$generation" \
          'any(.records[];
            .id == $id and .generation == $generation
            and (.state == "open" or .state == "parked")
          )' >/dev/null; then
        stamp=$(now_stamp)
        queue=$(apply_handled "$queue" "$id" "$generation" "$answer" "$stamp" "$n") \
          || die 1 "failed to resolve $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
        finish_reply_delivery "$id" "$generation" "$answer" "$n" handled
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --argjson generation "$generation" --arg answer "$answer" \
          'any(.records[];
            .id == $id and .state == "resolved"
            and .generation == $generation
            and .answer == $answer
          )' >/dev/null; then
        queue=$(record_reply_delivery "$queue" "$id" "$generation" "$answer" "$n" handled) \
          || die 1 "failed to retain delivery for $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to retain delivery for $id"
        finish_reply_delivery "$id" "$generation" "$answer" "$n" handled
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --argjson generation "$generation" '
          any(.records[];
            .id == $id and .state == "resolved"
            and .generation == $generation
            and .answer == "backlog-done"
          )' >/dev/null; then
        queue=$(record_reply_delivery "$queue" "$id" "$generation" "$answer" "$n" "$replacement_kind") \
          || die 1 "failed to retain delivery for $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to retain delivery for $id"
        finish_reply_delivery "$id" "$generation" "$answer" "$n" "$replacement_kind"
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --argjson generation "$generation" \
          'any(.records[];
            .id == $id and .state == "resolved" and .generation == $generation
          )' >/dev/null; then
        stamp=$(now_stamp)
        queue=$(apply_replacement_answer \
          "$queue" "$id" "$generation" "$answer" "$stamp" "$n" "$replacement_kind") \
          || die 1 "failed to supersede $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
        finish_reply_delivery "$id" "$generation" "$answer" "$n" "$replacement_kind"
      elif [ "$replacement_kind" = superseding ] && printf '%s\n' "$queue" | jq -e \
          --arg id "$id" --argjson generation "$generation" \
          'any(.records[]; .id == $id and .generation > $generation)' >/dev/null; then
        queue=$(record_reply_delivery "$queue" "$id" "$generation" "$answer" "$n" superseding) \
          || die 1 "failed to retain historical supersession for $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to retain historical supersession for $id"
        finish_reply_delivery "$id" "$generation" "$answer" "$n" superseding
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --argjson generation "$generation" \
          'any(.records[]; .id == $id and .generation > $generation)' >/dev/null; then
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
        printf 'stale: [id=%s] [generation=%s] %s\n' "$id" "$generation" "$answer"
      else
        orphan=1
        orphan_id=$id
        orphan_answer=$answer
        break
      fi
    done < "$REPLIES"
  fi

  clear_closed_cards
  park_expired_cards
  if [ "$orphan" -eq 1 ]; then
    printf 'orphan: [id=%s] %s\n' "$orphan_id" "$orphan_answer"
    exit 1
  fi
  release_queue_lock
}

main() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    add)
      need_jq
      shift
      cmd_add "$@"
      ;;
    park)
      need_jq
      shift
      cmd_park "$@"
      ;;
    reconcile)
      need_jq
      cmd_reconcile
      ;;
    *)
      die 2 "unknown command: $1"
      ;;
  esac
}

main "$@"
