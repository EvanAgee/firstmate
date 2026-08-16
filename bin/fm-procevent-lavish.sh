#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html> [--decisions-origin <origin-id>]
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh answers <result-file>
#   fm-procevent-lavish.sh close-decisions <result-file>
#   fm-procevent-lavish.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# ANSWER-TIME DECISION CLOSURE. A Lavish review is the channel a captain answers
# durable decision holds through, and the deck's own structured `question` slug is
# already the hold's decision key. `--decisions-origin` records that binding at arm
# time, and from then on the act that CAPTURES the captain's answer is the act that
# CLOSES its hold - the same answerer-closes property bin/fm-send.sh --resolve-key
# gives the live status-log ledger. Without the flag nothing here touches a hold, so
# an unbound deck behaves exactly as it always did.
#
# `answers` prints one `key<TAB>answer<TAB>label` line per structured choice the
# captain submitted. Only rows tagged `choice` are read: a freeform captain message
# is prose that may contain anything, and must never be able to forge a decision key.
# `close-decisions` maps each of those keys to `<bound-origin>-decision-<key>` and
# closes it through `bin/fm-decision-hold.sh answer`, which owns every safety rule
# that close obeys. It can only ever touch holds of the ONE bound origin, it is
# idempotent because the decision text it writes is a pure function of the captured
# result, and it skips - never forces - a key whose hold is absent, already closed,
# or still blocking routed work, leaving that one for `resolve` exactly as today.
# `autohandle` is the runner's own entry into `close-decisions`. It deliberately
# NEVER reports full handling: recording the captain's answer is transcription, but
# ACTING on it is firstmate's judgement, so the result stays unacknowledged and its
# `check` wake still reaches the handler exactly as before.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BINDING_DIR="$STATE/lavish-decisions"
BINDING_SCHEMA=fm-lavish-decisions.v1

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The decision origin this source's captain answers belong to, or empty when the
# deck was armed without one. An unreadable or wrong-schema binding is a hard
# error rather than a silent "no origin": closing nothing is the safe direction
# only when it is a deliberate choice, never when it is a corrupted record.
read_binding_origin() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || die "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || die "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  case "$origin" in
    ''|*[!A-Za-z0-9._-]*) die "decision binding has an invalid origin id: $path" ;;
  esac
  printf '%s\n' "$origin"
}

write_binding_origin() {  # <source-id> <origin-id>
  local id=$1 origin=$2 tmp dest
  (umask 077; mkdir -p "$BINDING_DIR") || die "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || die "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$id")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || die "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    die "cannot record the decision binding for $id"
  fi
}

cmd_arm() {
  local artifact=${1-} id real origin=''
  [ -n "$artifact" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decisions-origin) shift; origin=${1-} ;;
      *) usage ;;
    esac
    shift
  done
  if [ -n "$origin" ]; then
    case "$origin" in
      *[!A-Za-z0-9._-]*) die "--decisions-origin must be a privacy-safe slug: $origin" ;;
    esac
  fi
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # Bind BEFORE registering: a source that can start producing answers must never
  # exist without the binding that tells this adapter where those answers belong.
  [ -z "$origin" ] || write_binding_origin "$id" "$origin"
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- lavish-axi poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
  [ -z "$origin" ] || printf 'decisions-origin: %s\n' "$origin"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  rm -f -- "$(binding_path "$id")"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

# Print `key<TAB>answer<TAB>label` for every structured choice the captain
# submitted in a captured result. The published response frames queued feedback as
# a `prompts[N]{field,...}:` header followed by exactly N indented CSV rows whose
# quoted fields carry JSON-style escapes, so this reads the declared field ORDER
# rather than assuming a fixed column, and takes only rows whose `tag` field is
# `choice`. A freeform `message` row is captain prose and is deliberately never a
# source of decision keys. A row that does not carry both a slug-shaped `question`
# and an `answer` inside its `Context data:` block is skipped, so a deck that does
# not key its forms by decision key simply yields nothing.
cmd_answers() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  perl -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    my %seen;
    my @out;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "choice";
      my $prompt = $f{prompt};
      next unless defined $prompt && $prompt =~ /Context data:\s*(\{.*\})/s;
      my $ctx = $1;
      next unless $ctx =~ /"question"\s*:\s*"((?:[^"\\]|\\.)*)"/;
      my $key = $1;
      next unless $ctx =~ /"answer"\s*:\s*"((?:[^"\\]|\\.)*)"/;
      my $answer = $1;
      $_ =~ s/\\(.)/$1/g for ($key, $answer);
      next unless $key =~ /\A[A-Za-z0-9._-]{1,64}\z/;
      next unless length $answer && length($answer) <= 512;
      my $label = defined $f{text} ? $f{text} : "";
      s/[\x00-\x1f\x7f]/ /g for ($answer, $label);
      $label = substr($label, 0, 512);
      # A re-answered form appears again later in the queue; the last submission wins.
      if (defined $seen{$key}) { $out[$seen{$key}] = undef }
      $seen{$key} = scalar @out;
      push @out, "$key\t$answer\t$label";
    }
    print "$_\n" for grep { defined } @out;
  ' "$file"
}

# The captain decision text recorded on the hold. It is a pure function of the
# captured result, which is what makes a replayed capture an idempotent no-op
# rather than a rejected "different captain decision".
decision_text() {  # <source-id> <sequence> <key> <answer> <label>
  printf 'Captain answered this decision in a Lavish review.\n'
  printf 'Captured result: %s sequence %s\n' "$1" "$2"
  printf 'Decision key: %s\n' "$3"
  printf 'Answer: %s\n' "$4"
  [ -z "$5" ] || printf 'Answer as shown to the captain: %s\n' "$5"
}

# Close every captain hold this captured result answers. One line per key:
# `closed:` when the hold is now durably resolved, `skipped:` with the reason
# otherwise. Skipping is never a failure of this command - a hold that is absent,
# closed outside this path, or still blocking routed work is exactly the case
# fm-decision-hold refuses to force, and it stays open for the handler.
cmd_close_decisions() {
  local file=${1-} sid seq origin key answer label hold tmp closed=0 skipped=0 err
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  sid=$(fm_procevent_result_source_id "$file")
  seq=$(fm_procevent_result_sequence "$file")
  fm_procevent_source_id_valid "$sid" || die "result path does not name a valid source: $file"
  case "$seq" in ''|*[!0-9]*) die "result path does not name a sequence: $file" ;; esac
  origin=$(read_binding_origin "$sid") || exit 1
  if [ -z "$origin" ]; then
    printf 'no-decisions-origin: %s\n' "$sid"
    return 1
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-lavish-decision.XXXXXX") || die "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-lavish-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; die "cannot stage the captain decision diagnostics"; }
  while IFS=$'\t' read -r key answer label; do
    [ -n "$key" ] || continue
    hold="$origin-decision-$key"
    decision_text "$sid" "$seq" "$key" "$answer" "$label" > "$tmp" \
      || die "cannot stage the captain decision for $hold"
    if FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-decision-hold.sh" answer "$origin" "$key" \
      --decision-file "$tmp" >/dev/null 2>"$err"; then
      printf 'closed: %s\n' "$hold"
      closed=$((closed + 1))
    else
      printf 'skipped: %s (%s)\n' "$hold" "$(tr -d '\n' < "$err" | sed 's/^fm-decision-hold: //')"
      skipped=$((skipped + 1))
    fi
  done < <(cmd_answers "$file")
  rm -f -- "$tmp" "$err"
  printf 'decisions: closed=%s skipped=%s origin=%s\n' "$closed" "$skipped" "$origin"
  [ "$skipped" -eq 0 ]
}

# The runner's entry into cmd_close_decisions. It applies the captain's answers
# and then ALWAYS reports incomplete handling, because acknowledging the result
# here would retire the `check` wake firstmate needs in order to act on those
# answers. See the answer-time-closure note in the header.
cmd_autohandle() {
  local sid=${1-} seq=${2-} file=${3-}
  [ "$#" -eq 3 ] || usage
  fm_procevent_source_id_valid "$sid" || die "source id must be path-safe: $sid"
  case "$seq" in ''|*[!0-9]*) die "sequence must be a nonnegative integer: $seq" ;; esac
  [ "$(fm_procevent_result_source_id "$file")" = "$sid" ] \
    && [ "$(fm_procevent_result_sequence "$file")" = "$seq" ] \
    || die "result file does not belong to $sid sequence $seq: $file"
  cmd_close_decisions "$file" >/dev/null 2>&1 || true
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  answers)   shift; cmd_answers "$@" ;;
  close-decisions) shift; cmd_close_decisions "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
