#!/usr/bin/env bash
# fm-captain-queue.sh - fleet-board captain cards and dashboard-answer reconcile.
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
# `reconcile` is the captain-reply wake action. It reads every new reply line
# past the cursor, matches by id, moves a matched card out of the active `items`
# set into `resolved` (answer preserved), and advances the cursor past that
# line. Removing the card is not doing the work: each `handled:` line is the
# answer firstmate still has to act on. An `orphan:` line matches no card; the
# cursor stays before it so the answer cannot be skipped. Reconcile never
# advances past an answer that was neither matched nor surfaced.
# add and reconcile take one home-scoped lock at state/.captain-queue.lock for
# the whole queue-and-cursor read-modify-write, then release it.
#
# Usage:
#   fm-captain-queue.sh add --id <id> --question <text> \
#     [--context <text>] [--project <name>] [--asked-at <iso>] \
#     [--option <text>]... [--command <text>]...
#   fm-captain-queue.sh reconcile
#   fm-captain-queue.sh -h|--help
#
# Environment:
#   FM_HOME / FM_ROOT_OVERRIDE / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE
#   FM_CAPTAIN_QUEUE_NOW   optional ISO stamp for updated_at / asked_at / resolved_at
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
  if [ -n "${FM_CAPTAIN_QUEUE_NOW:-}" ]; then
    printf '%s\n' "$FM_CAPTAIN_QUEUE_NOW"
  else
    date -u +%Y-%m-%dT%H:%M:%SZ
  fi
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
          resolved: ((.resolved // []) | map(select(type == "object")))
        }
      else
        error("captain-queue.json is not an object")
      end
    ' "$QUEUE"
  else
    printf '%s\n' '{"updated_at":"","items":[],"resolved":[]}'
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

  local queue options_json commands_json next_num item
  acquire_queue_lock
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
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
      status: "open",
      project: $project
    }')
  queue=$(printf '%s\n' "$queue" | jq -c --arg id "$id" --argjson item "$item" '
    if any(.items[]; .id == $id) then
      .items = [.items[] | if .id == $id then
        $item + {num: .num}
      else . end]
    else
      .items += [$item]
    end
  ')
  printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
  release_queue_lock
  printf 'added: %s\n' "$id"
}

# Apply one matched reply: move the active card into resolved, keep the answer.
apply_handled() {  # <queue-json> <id> <answer> <stamp> -> new queue on stdout
  local queue=$1 id=$2 answer=$3 stamp=$4
  printf '%s\n' "$queue" | jq -c \
    --arg id "$id" \
    --arg answer "$answer" \
    --arg stamp "$stamp" '
      . as $q
      | ($q.items | map(select(.id == $id)) | .[0]) as $card
      | $q
      | .items = (.items | map(select(.id != $id)))
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

cmd_reconcile() {
  local cursor total queue line n id answer stamp
  acquire_queue_lock
  cursor=$(read_cursor)
  queue=$(read_queue) || die 1 "captain-queue.json is unreadable"
  if [ ! -f "$REPLIES" ]; then
    release_queue_lock
    exit 0
  fi
  total=$(wc -l < "$REPLIES" | tr -d ' ')
  [ -n "$total" ] || total=0
  if [ "$total" -le "$cursor" ]; then
    release_queue_lock
    exit 0
  fi

  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [ "$n" -gt "$cursor" ] || continue
    if [ -z "$line" ]; then
      printf 'orphan: [id=] malformed reply line %s\n' "$n"
      exit 1
    fi
    if ! printf '%s\n' "$line" | jq -e 'type == "object" and (.id | type == "string") and (.id | length > 0) and (.answer | type == "string")' >/dev/null 2>&1; then
      printf 'orphan: [id=] malformed reply line %s\n' "$n"
      exit 1
    fi
    id=$(printf '%s\n' "$line" | jq -r '.id')
    answer=$(printf '%s\n' "$line" | jq -r '.answer')
    if printf '%s\n' "$queue" | jq -e --arg id "$id" 'any(.items[]; .id == $id)' >/dev/null; then
      stamp=$(now_stamp)
      queue=$(apply_handled "$queue" "$id" "$answer" "$stamp") || die 1 "failed to resolve $id"
      printf '%s\n' "$queue" | write_queue || die 1 "failed to write captain-queue.json"
      write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
      cursor=$n
      printf 'handled: [id=%s] %s\n' "$id" "$answer"
    elif printf '%s\n' "$queue" | jq -e --arg id "$id" --arg answer "$answer" \
        'any(.resolved[]; .id == $id and .answer == $answer)' >/dev/null; then
      # Crash window: the card already moved, the cursor did not. Same answer
      # means this line was applied; advance without dropping a new answer.
      write_cursor "$n" || die 1 "failed to write captain-replies.cursor"
      cursor=$n
      printf 'handled: [id=%s] %s\n' "$id" "$answer"
    else
      printf 'orphan: [id=%s] %s\n' "$id" "$answer"
      exit 1
    fi
  done < "$REPLIES"
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
