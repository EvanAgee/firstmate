#!/usr/bin/env bash
# fm-captain-queue.sh - fleet-board captain cards, answer reconcile, expiry, and auto-retire.
#
# The dashboard posts each answer as one JSON line on state/captain-replies.jsonl
# with the card's own id, and wakes firstmate through the home-local
# captain-queue check when that file grows past state/captain-replies.cursor.
# This script is the only writer of data/captain-queue.json. The card id and the
# reply id are the same value: the decision-hold identity
# (`bin/fm-decision-hold.sh id <origin> <key>`) when one exists, or the backlog
# captain-hold id otherwise. Do not invent a shorter second id.
#
# `add` upserts one active card under that id.
# `reconcile` is the captain-reply wake action and the heartbeat board sweep.
# It reads every new reply line past the cursor, matches by id, moves a matched
# card out of the active `items` set into `resolved` (answer preserved), and
# advances the cursor past that line. Removing the card is not doing the work:
# each `handled:` line is the answer firstmate still has to act on. An
# `orphan:` line matches no card; the cursor stays before it so the answer
# cannot be skipped. Reconcile never advances past an answer that was neither
# matched nor surfaced. Dashboard-reply clearing is unchanged: a matched reply
# still prints `handled:` so firstmate can verify a "Done - command ran"
# answer against reality before treating that work as done.
# After applying new replies, or when there are none, reconcile also retires
# each remaining active card whose backing backlog item is done. The card id is
# the backlog captain-hold id or the decision-hold identity, so a done item and
# a closed decision-hold are the same check: `tasks-axi show <id>` against this
# home's backlog reports state done. Cards whose item is still open, absent, or
# unreadable stay. Auto-clear prints `cleared:` lines, not `handled:`; those
# are not dashboard answers to act on. A missing backlog file or tasks-axi
# skips the sweep rather than guessing.
# `add` records whether a card has a backing backlog item. An unbacked card
# expires after UNBACKED_CARD_EXPIRY_DAYS (7) days. Reconcile moves expired
# cards from `items` to `parked` without dropping their original content.
# `park` moves one human-verified active card to `parked` with a required note.
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
  jq -nr --arg stamp "$1" '
    def canonical_z:
      ($stamp | fromdateiso8601?) as $epoch
      | select($epoch != null and ($epoch | todateiso8601) == $stamp)
      | ($epoch | todateiso8601);
    def canonical_offset:
      ($stamp | capture("^(?<base>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<sign>[+-])(?<hours>[0-9]{2}):(?<minutes>[0-9]{2})$")?) as $parts
      | select($parts != null)
      | ($parts.hours | tonumber) as $hours
      | ($parts.minutes | tonumber) as $minutes
      | select($hours <= 23 and $minutes <= 59)
      | ($parts.base + "Z" | fromdateiso8601?) as $local
      | select($local != null and ($local | todateiso8601) == ($parts.base + "Z"))
      | (($hours * 60 + $minutes) * 60) as $offset
      | ($local + (if $parts.sign == "+" then -$offset else $offset end) | todateiso8601);
    canonical_z // canonical_offset // empty
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
  if [ -f "$QUEUE" ]; then
    jq -c '
      if type == "object" then
        {
          updated_at: (.updated_at // ""),
          items: ((.items // []) | map(select(type == "object"))),
          resolved: ((.resolved // []) | map(select(type == "object"))),
          parked: ((.parked // []) | map(select(type == "object")))
        }
      else
        error("captain-queue.json is not an object")
      end
    ' "$QUEUE"
  else
    printf '%s\n' '{"updated_at":"","items":[],"resolved":[],"parked":[]}'
  fi
}

write_queue() {  # stdin: queue object
  local stamp json
  stamp=$(now_stamp)
  json=$(jq -c --arg stamp "$stamp" '.updated_at = $stamp') || return 1
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

write_cursor() {  # <n>
  printf '%s\n' "$1" | atomic_write "$CURSOR_FILE"
}

cmd_add() {
  local id="" question="" context="" project="" asked_at=""
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
  [ -n "$asked_at" ] || asked_at=$(now_stamp)
  asked_at=$(normalize_iso_stamp "$asked_at")
  [ -n "$asked_at" ] || die 2 "add --asked-at must be an ISO timestamp with a timezone"

  local queue options_json commands_json next_num item backlog_backed
  acquire_queue_lock
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
  if printf '%s\n' "$queue" | jq -e --arg id "$id" 'any(.parked[]; .id == $id)' >/dev/null; then
    die 1 "card already parked: $id"
  fi
  backlog_backed=$(backlog_backing_state "$id")
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
  next_num=$(printf '%s\n' "$queue" | jq -r '.items | map(.num) | max // 0')
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
      status: "open",
      project: $project
    }')
  queue=$(printf '%s\n' "$queue" | jq -c --arg id "$id" --argjson item "$item" '
    if any(.items[]; .id == $id) then
      .items = [.items[] | if .id == $id then
        if has("backlog_backed") and
            ((.backlog_backed | type) == "boolean" or .backlog_backed == null) then
          $item + {
            num: .num,
            asked_at: (.asked_at // $item.asked_at),
            backlog_backed: (
              if (.backlog_backed | type) == "boolean" then
                .backlog_backed
              else
                $item.backlog_backed
              end
            )
          }
        else
          $item + {num: .num}
        end
      else . end]
    else
      .items += [$item]
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
      . as $q
      | ($q.items | map(select(.id == $id)) | .[0]) as $card
      | $q
      | .items = (.items | map(select(.id != $id)))
      | .parked = (
          (.parked // [])
          + [
            $card
            + {
                status: "parked",
                parked_at: $stamp,
                parked_reason: $reason,
                parked_note: $note
              }
          ]
        )
    '
}

cmd_park() {
  local id="" note="" queue stamp
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
  if printf '%s\n' "$queue" | jq -e --arg id "$id" 'any(.parked[]; .id == $id)' >/dev/null; then
    release_queue_lock
    printf 'parked: [id=%s] already-parked\n' "$id"
    return 0
  fi
  if ! printf '%s\n' "$queue" | jq -e --arg id "$id" 'any(.items[]; .id == $id)' >/dev/null; then
    die 1 "active card not found: $id"
  fi
  stamp=$(now_stamp)
  queue=$(apply_parked "$queue" "$id" "$stamp" "manual" "$note") \
    || die 1 "failed to park $id"
  printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
  release_queue_lock
  printf 'parked: [id=%s] manual\n' "$id"
}

# Print true when the backlog contains <id>, false when absence is verified,
# or null when the lookup could not answer.
backlog_backing_state() {  # <id>
  local id=$1 show
  [ -n "$id" ] || { printf 'null\n'; return 0; }
  [ -f "$DATA/backlog.md" ] || { printf 'false\n'; return 0; }
  [ -r "$DATA/backlog.md" ] || { printf 'null\n'; return 0; }
  command -v tasks-axi >/dev/null 2>&1 || { printf 'null\n'; return 0; }
  if show=$(tasks-axi show "$id" --file "$DATA/backlog.md" 2>&1); then
    printf 'true\n'
  elif printf '%s\n' "$show" | grep -qx 'code: NOT_FOUND'; then
    printf 'false\n'
  else
    printf 'null\n'
  fi
}

# Apply one matched reply: move the active or parked card into resolved.
apply_handled() {  # <queue-json> <id> <answer> <stamp> -> new queue on stdout
  local queue=$1 id=$2 answer=$3 stamp=$4
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --arg answer "$answer" \
    --arg stamp "$stamp" '
      . as $q
      | (($q.items + ($q.parked // [])) | map(select(.id == $id)) | .[0]) as $card
      | $q
      | .items = (.items | map(select(.id != $id)))
      | .parked = ((.parked // []) | map(select(.id != $id)))
      | .resolved = (
          (.resolved // [])
          + [
            $card
            + {
                status: "resolved",
                answer: $answer,
                resolved_at: $stamp
              }
          ]
        )
    '
}

# True when this home's backlog records <id> as done. Absent, unreadable, or
# still-open items return false so a card cannot clear on a guess.
backlog_item_done() {  # <id>
  local id=$1 show state
  [ -n "$id" ] || return 1
  [ -f "$DATA/backlog.md" ] || return 1
  command -v tasks-axi >/dev/null 2>&1 || return 1
  show=$(tasks-axi show "$id" --file "$DATA/backlog.md" 2>/dev/null) || return 1
  state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
  [ "$state" = "done" ]
}

# Retire remaining active cards whose backing backlog item is done.
# Mutates the caller's `queue`. Prints `cleared:` lines, never `handled:`.
clear_closed_cards() {
  local id stamp ids
  ids=$(printf '%s\n' "$queue" | jq -r '.items[]? | select(.backlog_backed == true) | .id // empty') || return 0
  [ -n "$ids" ] || return 0
  [ -f "$DATA/backlog.md" ] || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    backlog_item_done "$id" || continue
    stamp=$(now_stamp)
    queue=$(apply_handled "$queue" "$id" "backlog-done" "$stamp") || die 1 "failed to auto-clear $id"
    printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
    printf 'cleared: [id=%s] backlog-done\n' "$id"
  done <<EOF
$ids
EOF
}

refresh_unknown_backing_states() {
  local id ids state changed=0
  ids=$(printf '%s\n' "$queue" | jq -r '
    .items[]? | select(has("backlog_backed") and .backlog_backed == null) | .id // empty
  ') || return 0
  [ -n "$ids" ] || return 0
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    state=$(backlog_backing_state "$id")
    [ "$state" != null ] || continue
    queue=$(printf '%s\n' "$queue" | jq -c \
      --arg id "$id" --argjson state "$state" '
        .items = [.items[] | if .id == $id then .backlog_backed = $state else . end]
      ') || die 1 "failed to record backlog backing for $id"
    changed=1
  done <<EOF
$ids
EOF
  if [ "$changed" -eq 1 ]; then
    printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
  fi
}

# Move active cards created without a backlog item to parked after seven days.
# A missing or malformed timestamp stays active rather than expiring on a guess.
park_expired_cards() {
  local id stamp ids
  stamp=$(now_stamp)
  ids=$(printf '%s\n' "$queue" | jq -r '.items[]? | select(.backlog_backed == false) | .id // empty') || return 0
  [ -n "$ids" ] || return 0
  while IFS= read -r id || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    if ! printf '%s\n' "$queue" | jq -e \
        --arg id "$id" \
        --arg stamp "$stamp" \
        --argjson expiry "$UNBACKED_CARD_EXPIRY_SECONDS" '
          ($stamp | fromdateiso8601?) as $now
          | (.items[] | select(.id == $id) | .asked_at | fromdateiso8601?) as $asked
          | $now != null and $asked != null and ($now - $asked >= $expiry)
        ' >/dev/null; then
      continue
    fi
    queue=$(apply_parked "$queue" "$id" "$stamp" "expired-unbacked" \
      "Expired after $UNBACKED_CARD_EXPIRY_DAYS days without a backing backlog item") \
      || die 1 "failed to park $id"
    printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
    printf 'parked: [id=%s] expired-unbacked\n' "$id"
  done <<EOF
$ids
EOF
}

cmd_reconcile() {
  local cursor queue line n id answer stamp
  local orphan=0 orphan_id="" orphan_answer=""
  acquire_queue_lock
  cursor=$(read_cursor)
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"

  if [ -f "$REPLIES" ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ "$n" -gt "$cursor" ] || continue
      if [ -z "$line" ]; then
        orphan=1
        orphan_id=
        orphan_answer="malformed reply line $n"
        break
      fi
      if ! printf '%s\n' "$line" | jq -e 'type == "object" and (.id | type == "string") and (.id | length > 0) and (.answer | type == "string")' >/dev/null 2>&1; then
        orphan=1
        orphan_id=
        orphan_answer="malformed reply line $n"
        break
      fi
      id=$(printf '%s\n' "$line" | jq -r '.id')
      answer=$(printf '%s\n' "$line" | jq -r '.answer')
      if printf '%s\n' "$queue" | jq -e --arg id "$id" \
          'any(.items[]; .id == $id) or any(.parked[]; .id == $id)' >/dev/null; then
        stamp=$(now_stamp)
        queue=$(apply_handled "$queue" "$id" "$answer" "$stamp") || die 1 "failed to resolve $id"
        printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
        printf 'handled: [id=%s] %s\n' "$id" "$answer"
      elif printf '%s\n' "$queue" | jq -e --arg id "$id" --arg answer "$answer" \
          'any(.resolved[]; .id == $id and (.answer == $answer or .answer == "backlog-done"))' >/dev/null; then
        # Crash window: the card already moved, the cursor did not. Same answer
        # means this line was applied; advance without dropping a new answer.
        write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
        cursor=$n
        printf 'handled: [id=%s] %s\n' "$id" "$answer"
      else
        orphan=1
        orphan_id=$id
        orphan_answer=$answer
        break
      fi
    done < "$REPLIES"
  fi

  refresh_unknown_backing_states
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
