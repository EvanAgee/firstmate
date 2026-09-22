#!/usr/bin/env bash
# C5 behavior carried from the fork's ship-brief tests onto the root scaffold.
# shellcheck disable=SC2016 # Backticks in expected brief text are literal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

home=$(fm_test_tmproot fm-brief-c5)
mkdir -p "$home/data" "$home/state"

brief() { # <id> <mode-or-kind> [extra flag]
  local id=$1 mode=$2
  shift 2
  case "$mode" in
    scout) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample --scout "$@" >/dev/null || return $? ;;
    secondmate) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects "$@" >/dev/null || return $? ;;
    *) FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" sample --mode "$mode" "$@" >/dev/null || return $? ;;
  esac
  printf '%s/data/%s/brief.md\n' "$home" "$id"
}

assert_has() { # <file> <literal text>
  grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"
}

assert_lacks() { # <file> <literal text>
  if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi
}

for mode in no-mistakes direct-PR local-only; do
  file=$(brief "ship-$mode" "$mode") || fail "$mode scaffold failed"
  assert_has "$file" '# Session skills'
  assert_has "$file" 'On a raw launch, load caveman and ponytail yourself before starting.'
  assert_has "$file" "This brief's test requirements win over ponytail's test rule."
  assert_has "$file" '# Working directory'
  assert_has "$file" 'Do not put `cd <dir>` in a compound command such as `cd <dir> && grep ...`.'
  assert_has "$file" 'Never run the 1Password CLI'
  assert_has "$file" 'Do not spawn subagents, background agents, or sub-workers'
  assert_has "$file" 'Run `npx unslop` on every changed file'
  assert_has "$file" 'Every `needs-decision:` and `blocked:` line MUST carry `[key=<slug>]`'
  assert_has "$file" 'Recording a decision is not acting on it'
  assert_has "$file" 'the work it unblocks still has to be done in the same turn'
  assert_has "$file" 'reusing the exact key you opened it with'
  assert_has "$file" 'broken environment inside your own worktree is yours to fix'
  assert_has "$file" 'Never write a real blocker as a `working:` line'
  assert_has "$file" 'For any change a user can see, walk it before reporting done'
  assert_has "$file" 'the path the issue describes and the two paths beside it'
  assert_has "$file" 'A done without that section is not done'
  assert_has "$file" 'After CI is green and before reporting any PR done, check its review comments'
  assert_has "$file" 'node ~/Sites/agent-workflow-kit/scripts/upload-artifact.mjs'
  assert_has "$file" 'open the PR page and verify every image displays'
  assert_has "$file" 'editing the PR body alone does not re-run them'
  assert_lacks "$file" '# Matt-flow'
done

file=$(brief ship-matt no-mistakes --matt-flow) || fail 'Matt-flow scaffold failed'
assert_has "$file" '# Matt-flow'
assert_has "$file" 'Enter at the installed `tdd` skill: write the failing test first, then make it pass.'
assert_has "$file" 'matt-flow-tdd-missing'
assert_has "$file" 'Stop the flow after `tdd`'
assert_has "$file" 'do not run `code-review`'
assert_has "$file" 'run /no-mistakes to validate and ship a PR'
assert_has "$file" 'While a validation gate is open, the turn is not finished'
assert_has "$file" '.agents/skills/review-loop-stop/SKILL.md'
assert_has "$file" 'bin/fm-review-loop-stop.sh'
assert_has "$file" 'carry it verbatim in `--intent`'
assert_has "$file" 'checks green at {pipeline head}'
assert_has "$file" 'Reporting done does not end your ownership of this PR'
assert_has "$file" 'Never merge the PR and never arm auto-merge'
assert_has "$file" 'Drive late reviewer feedback back through no-mistakes'
assert_has "$file" 'If the monitor has ended, rerun /no-mistakes.'
assert_lacks "$file" 'Firstmate will then instruct you to run /no-mistakes'
assert_lacks "$file" 'fix and push on your `fm/ship-matt` branch'

for mode in direct-PR local-only; do
  file=$(brief "matt-$mode" "$mode" --matt-flow) || fail "$mode Matt-flow scaffold failed"
  assert_has "$file" 'Continue from `tdd` to the installed `code-review` skill'
  assert_lacks "$file" 'Stop the flow after `tdd`'
  assert_has "$file" 'For any change a user can see, walk it before reporting done'
done

file=$(brief ship-direct direct-PR) || fail 'direct-PR scaffold failed'
assert_has "$file" 'Handle late reviewer feedback directly'
assert_has "$file" 'Stay on watch after reporting done.'
assert_has "$file" 'Reporting done does not end your ownership of this PR'
assert_has "$file" 'Never merge the PR and never arm auto-merge'
assert_lacks "$file" 'Drive late reviewer feedback back through no-mistakes'

file=$(brief ship-local local-only) || fail 'local-only scaffold failed'
assert_has "$file" 'as a signed-in user on a local build'
assert_has "$file" 'in the body of your final commit message'
assert_has "$file" 'walked {the path you walked}'
assert_lacks "$file" 'Stay on watch after reporting done.'
assert_lacks "$file" 'carry it verbatim in `--intent`'

file=$(brief scout scout) || fail 'scout scaffold failed'
assert_has "$file" '# Session skills'
assert_has "$file" '# Working directory'
assert_has "$file" 'Never run the 1Password CLI'
assert_has "$file" 'Every `needs-decision:` and `blocked:` line MUST carry `[key=<slug>]`'
assert_lacks "$file" '## What I walked'

file=$(brief secondmate secondmate) || fail 'secondmate scaffold failed'
assert_lacks "$file" '# Session skills'
assert_lacks "$file" '# Working directory'

for kind in scout secondmate; do
  if brief "invalid-$kind" "$kind" --matt-flow >/dev/null 2>&1; then
    fail "--matt-flow accepted for $kind"
  fi
done

pass 'C5 brief rules and mode-specific delivery work on the root scaffold'
