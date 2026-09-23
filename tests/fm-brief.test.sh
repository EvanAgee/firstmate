#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
# This suite checks ambient Bash syntax, guards heredoc source structure, and
# generates a brief with /bin/bash, which is Bash 5 on Ubuntu CI.
# The macos-stock-bash CI job separately parses changed shell files with Bash 3.2.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)
BRIEF_HOME="$TMP_ROOT/home"
mkdir -p "$BRIEF_HOME/data"
# shellcheck disable=SC2016 # literal backticks are the brief text under test
REVIEWER_CMD='`CLAUDE_CODE_NO_MODEL_FALLBACK=1 CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 claude -p --model opus --effort xhigh --output-format json "<axis prompt>"`'

test_script_parses() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-brief.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-brief.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-brief.sh emitted unexpected output: $out"
  pass "fm-brief.sh: bash -n succeeds"
}

test_no_heredoc_in_command_substitution() {
  local unsafe safe
  unsafe="$TMP_ROOT/heredoc-in-substitution.sh"
  safe="$TMP_ROOT/plain-heredoc.sh"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'value=$(' '  cat <<EOF' 'body' 'EOF' ')' > "$unsafe"
  # shellcheck disable=SC2016 # Literal shell fixtures must remain unexpanded.
  printf '%s\n' 'cat <<EOF' '$(' '  cat <<INNER' 'INNER' ')' 'EOF' > "$safe"
  if no_heredoc_in_command_substitution "$unsafe"; then
    fail "structural guard accepted a multiline heredoc nested in a command substitution"
  fi
  no_heredoc_in_command_substitution "$safe" \
    || fail "structural guard treated heredoc body prose as shell structure"
  no_heredoc_in_command_substitution "$ROOT/bin/fm-brief.sh" \
    || fail "fm-brief.sh wraps a heredoc in a command substitution (breaks Bash 3.2 parsing)"
  pass "fm-brief.sh: no heredoc is nested inside a command substitution (Bash 3.2 parse-safe)"
}

no_heredoc_in_command_substitution() {
  perl - "$1" <<'PERL'
use strict;
use warnings;

my $path = shift;
open my $source, '<', $path or die "$path: $!\n";
my @frames;
my @heredocs;
my $quote = '';
my $line_number = 0;

while (my $line = <$source>) {
  $line_number++;
  if (@heredocs) {
    my $candidate = $line;
    $candidate =~ s/\r?\n\z//;
    $candidate =~ s/^\t+// if $heredocs[0]{strip_tabs};
    shift @heredocs if $candidate eq $heredocs[0]{delimiter};
    next;
  }

  my $length = length $line;
  for (my $i = 0; $i < $length; $i++) {
    my $char = substr($line, $i, 1);
    if ($quote eq "'") {
      $quote = '' if $char eq "'";
      next;
    }
    if ($char eq '\\') {
      $i++;
      next;
    }
    if ($quote eq '"' && $char eq '"') {
      $quote = '';
      next;
    }
    if ($char eq "'" && $quote eq '') {
      $quote = "'";
      next;
    }
    if ($char eq '"' && $quote eq '') {
      $quote = '"';
      next;
    }
    if ($char eq '#' && $quote eq '' && ($i == 0 || substr($line, $i - 1, 1) =~ /[\s;|&()]/)) {
      last;
    }
    if ($char eq '$' && substr($line, $i + 1, 1) eq '(') {
      push @frames, { depth => 1, quote => $quote };
      $quote = '';
      $i++;
      next;
    }
    if (@frames && $quote eq '' && $char eq '(') {
      $frames[-1]{depth}++;
      next;
    }
    if (@frames && $quote eq '' && $char eq ')') {
      $frames[-1]{depth}--;
      if ($frames[-1]{depth} == 0) {
        my $frame = pop @frames;
        $quote = $frame->{quote};
      }
      next;
    }
    next unless $quote eq '' && $char eq '<' && substr($line, $i + 1, 1) eq '<';
    if (@frames) {
      print STDERR "$path:$line_number\n";
      exit 1;
    }

    my $j = $i + 2;
    my $strip_tabs = substr($line, $j, 1) eq '-';
    $j++ if $strip_tabs;
    $j++ while substr($line, $j, 1) =~ /[ \t]/;
    my $delimiter = '';
    my $delimiter_quote = '';
    for (; $j < $length; $j++) {
      my $token = substr($line, $j, 1);
      if ($delimiter_quote) {
        if ($token eq $delimiter_quote) {
          $delimiter_quote = '';
        } elsif ($token eq '\\' && $delimiter_quote eq '"') {
          $j++;
          $delimiter .= substr($line, $j, 1);
        } else {
          $delimiter .= $token;
        }
        next;
      }
      if ($token eq "'" || $token eq '"') {
        $delimiter_quote = $token;
        next;
      }
      if ($token eq '\\') {
        $j++;
        $delimiter .= substr($line, $j, 1);
        next;
      }
      last if $token =~ /[\s;|&()<>]/;
      $delimiter .= $token;
    }
    push @heredocs, { delimiter => $delimiter, strip_tabs => $strip_tabs };
    $i = $j - 1;
  }
}

exit 0;
PERL
}

test_stock_bash_generates_worker_brief() {
  local home brief out status
  home="$TMP_ROOT/stock-bash-home"
  mkdir -p "$home/data"
  out=$(FM_HOME="$home" /bin/bash "$ROOT/bin/fm-brief.sh" stock-bash-worker sample --scout 2>&1)
  status=$?
  expect_code 0 "$status" "stock Bash should generate a worker brief (got: $out)"
  brief="$home/data/stock-bash-worker/brief.md"
  assert_present "$brief" "stock Bash did not generate the worker brief"
  assert_grep '# Session skills' "$brief" "stock Bash lost the session skills section"
  pass "fm-brief.sh: stock Bash generates the worker brief"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "[--matt-flow]" "fm-brief.sh --help omitted the Matt-flow ship option"
  assert_contains "$help" "adds one thin flow trigger" "fm-brief.sh --help omitted the Matt-flow ownership boundary"
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode. fm-brief.sh no longer reads it -
# the ship mode arrives as an explicit flag - so this fixture exists to prove the
# scaffold ignores the registered posture (test_ship_mode_is_explicit_not_registry).
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id mode brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_mode in "brief-nomistakes-a1:no-mistakes" "brief-directpr-a2:direct-PR" "brief-localonly-a3:local-only"; do
    id=${id_mode%%:*}
    mode=${id_mode##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id --mode $mode should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    grep -qx "Delivery contract: mode=$mode" "$brief" \
      || fail "$id: brief did not record its machine-readable delivery contract line"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
      "$id: brief missing nonterminal working:/setup-complete gate protection"
    assert_grep "Run \`npx unslop\` on every changed file and fix all findings before any PR." "$brief" \
      "$id: brief missing the unconditional unslop gate"
    assert_no_grep "Matt-flow" "$brief" \
      "$id: ordinary ship brief unexpectedly declared Matt-flow"
    assert_no_grep "\`to-spec\`" "$brief" \
      "$id: ordinary ship brief unexpectedly mentioned a Matt-flow skill"
    assert_no_grep "\`code-review\`" "$brief" \
      "$id: ordinary ship brief unexpectedly mentioned a Matt-flow terminal phase"
    awk '
      $0 == "# Rules" { found = 1; good = (blank == 1); exit }
      { blank = ($0 == "" ? blank + 1 : 0) }
      END { exit !(found && good) }
    ' "$brief" || fail "$id: ordinary ship brief changed spacing before the Rules section"
    assert_grep "After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid." "$brief" \
      "$id: brief missing the PR review-feedback definition-of-done rule"
    assert_grep "node ~/Sites/agent-workflow-kit/scripts/upload-artifact.mjs --ref pr-<PR#> --pr <PR#> <screenshot-file>..." "$brief" \
      "$id: brief missing the Cloudflare upload command in the UI screenshot rule"
    assert_grep "Committed repo paths (for example \`docs/reference/151/foo.png\`) and local file paths do NOT render in a private-repo PR and do NOT count." "$brief" \
      "$id: brief missing the committed/local paths do-not-count clause"
    assert_grep "The \`pr-evidence\` check only confirms that the PR body contains Markdown image syntax with an HTTPS URL; it does not fetch or inspect the image, so open the PR page and verify every image displays before reporting done instead of trusting the upload command's output." "$brief" \
      "$id: brief missing the rendered-image verification rule"
    assert_grep "After embedding the URLs, push a commit (an empty one is fine) so push-triggered checks re-run against the current head; editing the PR body alone does not re-run them." "$brief" \
      "$id: brief missing the push-triggered evidence-check rerun rule"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# shellcheck disable=SC2016 # Literal backticks must reach the generated brief.
TURN_COMPLETION_RULE='Do not end your turn before the work is done. Never describe what you would do next; do it. The only turns that end are a `done:`, `failed:`, keyed `blocked:`, keyed `needs-decision:`, or `paused:` line. If you notice you have written "Next, I will", that is the signal to keep going.'
BACKGROUND_WAIT_RULE='Every wait on a background command needs a deadline. Check that the job is alive and its output is growing; if it died, fail loudly with the output and exit status.'
# shellcheck disable=SC2016 # Literal wording is the scaffold contract.
UNRELATED_FINDINGS_RULE='If while working or testing you find pre-existing bugs, performance concerns, or behaviors the task does not mention, do not fix, optimize, or extend them in this change unless the requested behavior cannot work without it. Report each one as a follow-up in your done line.'

test_worker_turn_and_scope_rules() {
  local home brief
  home="$TMP_ROOT/worker-turn-rules-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-turn-ship some-proj --mode local-only >/dev/null 2>&1 \
    || fail "ordinary ship brief failed to scaffold"
  brief="$home/data/brief-turn-ship/brief.md"
  assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
    "ordinary ship brief lost the nonterminal working line"
  grep -Fx "5. $TURN_COMPLETION_RULE" "$brief" >/dev/null \
    || fail "ordinary ship brief missing the numbered turn-completion rule"
  grep -Fx "6. $BACKGROUND_WAIT_RULE" "$brief" >/dev/null \
    || fail "ordinary ship brief missing the background-wait rule"
  grep -Fx "7. $UNRELATED_FINDINGS_RULE" "$brief" >/dev/null \
    || fail "ordinary ship brief missing the numbered unrelated-findings rule"
  assert_grep "8. If you hit the same obstacle twice" "$brief" \
    "ordinary ship brief did not renumber later rules"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-turn-matt some-proj --mode local-only --matt-flow >/dev/null 2>&1 \
    || fail "Matt-flow ship brief failed to scaffold"
  brief="$home/data/brief-turn-matt/brief.md"
  grep -Fx "5. $TURN_COMPLETION_RULE" "$brief" >/dev/null \
    || fail "Matt-flow ship brief missing the numbered turn-completion rule"
  grep -Fx "6. $BACKGROUND_WAIT_RULE" "$brief" >/dev/null \
    || fail "Matt-flow ship brief missing the background-wait rule"
  assert_no_grep "$UNRELATED_FINDINGS_RULE" "$brief" \
    "Matt-flow ship brief gained the ordinary unrelated-findings rule"
  assert_grep "7. If you hit the same obstacle twice" "$brief" \
    "Matt-flow ship brief did not renumber later rules"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-turn-scout some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  brief="$home/data/brief-turn-scout/brief.md"
  assert_grep "mid-task \`working:\` line (including setup complete) is nonterminal" "$brief" \
    "scout brief missing the nonterminal working line"
  grep -Fx "5. $TURN_COMPLETION_RULE" "$brief" >/dev/null \
    || fail "scout brief missing the numbered turn-completion rule"
  grep -Fx "6. $BACKGROUND_WAIT_RULE" "$brief" >/dev/null \
    || fail "scout brief missing the background-wait rule"
  assert_no_grep "$UNRELATED_FINDINGS_RULE" "$brief" \
    "scout brief gained the ship-only unrelated-findings rule"
  assert_grep "7. If you hit the same obstacle twice" "$brief" \
    "scout brief did not renumber later rules"

  pass "fm-brief.sh: worker turns finish the work and ordinary ships defer unrelated findings"
}

# The turn-completion rule names the four specific early stops a worker must
# not end a turn on, because a model follows a named stop better than a general
# one. Every variant that carries the rule (every ship mode, Matt-flow, scout)
# must name all four and keep the status-note placement right after them.
EARLY_STOP_LINES=(
  '   Never end a turn on any of these four early stops:'
  '   - a summary that closes by announcing the next step instead of making the tool call;'
  '   - an offer to carry on unless someone prefers otherwise;'
  '   - a list of decisions that, by your own account, block nothing;'
  '   - a report sent because the turn was long or a milestone landed.'
  '   A status note goes in the same message as your next tool call, never as the last word of a turn.'
)

test_turn_rule_names_the_four_early_stops() {
  local home brief variant id args expected
  home="$TMP_ROOT/early-stops-home"
  mkdir -p "$home/data"
  expected="$TMP_ROOT/early-stops-expected"
  printf '%s\n' "${EARLY_STOP_LINES[@]}" > "$expected"

  for variant in "no-mistakes:--mode no-mistakes" "direct-PR:--mode direct-PR" "local-only:--mode local-only" \
    "matt:--mode local-only --matt-flow" "scout:--scout"; do
    id="early-stops-${variant%%:*}"
    args=${variant#*:}
    # shellcheck disable=SC2086 # args is a deliberate flag list.
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj $args >/dev/null 2>&1 \
      || fail "$id: brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    grep -Fx "5. $TURN_COMPLETION_RULE" "$brief" >/dev/null \
      || fail "$id: turn-completion rule lost its allowed-endings line"
    grep -Fx -A "${#EARLY_STOP_LINES[@]}" "5. $TURN_COMPLETION_RULE" "$brief" | tail -n +2 \
      | diff -u "$expected" - >/dev/null \
      || fail "$id: turn-completion rule does not name the four early stops right after its allowed endings"
  done
  pass "fm-brief.sh: every rule-5 variant names the four early stops"
}

test_help_names_frontend_avoid_list() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" 'a generic "avoid an AI look" only swaps one default for another' \
    "fm-brief.sh --help lost why a UI task must name the patterns to avoid"
  assert_contains "$help" "name the specific default patterns to avoid" \
    "fm-brief.sh --help lost the frontend-design avoid-list instruction"
  assert_contains "$help" "checks its first result for default styles and extends that list" \
    "fm-brief.sh --help lost the first-result avoid-list check"
  pass "fm-brief.sh: --help tells firstmate to name a frontend avoid-list"
}

# The worker that opens a PR owns its review feedback until the task lands,
# including feedback that arrives AFTER the done report (a late review-bot pass,
# a human thread, a requested change). Both PR-producing modes share the watch
# timing but use their own feedback path. Neither path may weaken the
# never-merge prohibition. local-only has no PR, so it stays out.
test_pr_producing_modes_own_feedback_until_landing() {
  local home id mode brief watch_entry expected_action forbidden_action
  home="$TMP_ROOT/pr-watch-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR; do
    id="brief-pr-watch-${mode}"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    case "$mode" in
      no-mistakes)
        # shellcheck disable=SC2016
        watch_entry='append `done: PR {url} checks green at {pipeline head}, full suite {green run URL}` and enter the PR watch below.'
        expected_action='Drive late reviewer feedback back through no-mistakes, never by hand-editing the branch.'
        forbidden_action='fix and push on your `fm/'"$id"'` branch'
        ;;
      direct-PR)
        # shellcheck disable=SC2016
        watch_entry='append `done: PR {url}, GitHub Actions green at {green run URL}` to the status file and enter the PR watch below.'
        expected_action='Apply rule 8 directly to late reviewer feedback: fix and push on your `fm/'"$id"'` branch'
        forbidden_action='Drive late reviewer feedback back through no-mistakes'
        ;;
    esac
    assert_grep "$watch_entry" "$brief" \
      "$mode: done report did not enter the PR watch"
    assert_grep "Reporting done does not end your ownership of this PR - it stays yours until the task lands, normally by the PR merging, or by firstmate landing it locally if GitHub is down." "$brief" \
      "$mode: brief did not keep PR ownership until the task lands, including the outage local landing path"
    assert_grep "$expected_action" "$brief" \
      "$mode: brief did not use its own late-feedback path"
    assert_no_grep "$forbidden_action" "$brief" \
      "$mode: brief included the other mode's late-feedback path"
    assert_grep "After addressing new reviewer feedback, re-report status." "$brief" \
      "$mode: brief did not require a fresh status report after late feedback"
    if [ "$mode" = no-mistakes ]; then
      assert_grep "If a gate is waiting, respond there and let the pipeline handle the finding." "$brief" \
        "$mode: active monitor did not route late feedback through its gate"
      assert_grep "If the monitor has ended, rerun /no-mistakes." "$brief" \
        "$mode: ended monitor did not restart the pipeline for late feedback"
    fi
    assert_grep "Never merge the PR and never arm auto-merge; the configured merge authority owns that." "$brief" \
      "$mode: post-done watch weakened the never-merge prohibition"
  done

  # local-only produces no PR, so the post-done PR-watch block must not appear.
  id="brief-pr-watch-local-only"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only >/dev/null 2>&1 \
    || fail "local-only: ship brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_no_grep "it stays yours until the task lands" "$brief" \
    "local-only brief added a PR-watch contract it has no PR for"
  pass "fm-brief.sh: PR-producing modes own review feedback until the task lands; local-only stays out"
}

test_matt_flow_is_explicit_and_thin() {
  local home id brief status
  home="$TMP_ROOT/matt-flow-home"
  mkdir -p "$home/data"
  id="brief-matt-flow-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes --matt-flow >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "Matt-flow brief generation should exit 0"
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Matt-flow brief was not scaffolded"
  assert_grep "# Matt-flow" "$brief" \
    "Matt-flow brief missing its thin trigger section"
  assert_grep "This brief declares this task a Matt-flow task." "$brief" \
    "Matt-flow brief missing its explicit declaration"
  assert_grep "already done or are human-only and must not be invoked" "$brief" \
    "Matt-flow brief did not rule out the phases the worker cannot run"
  assert_grep "Enter at the installed \`tdd\` skill: write the failing test first, then make it pass." "$brief" \
    "Matt-flow brief missing its tdd entry point"
  assert_grep "blocked [key=matt-flow-tdd-missing]: tdd skill not installed in this worktree" "$brief" \
    "Matt-flow brief missing the blocked line for a worktree without tdd"
  assert_grep "Stop the flow after \`tdd\` and go straight to the validation in the Definition of done." "$brief" \
    "Matt-flow brief did not stop its skill flow after tdd"
  assert_grep "The no-mistakes pipeline in the Definition of done owns review, so do not run \`code-review\`, any other review skill, a review sub-agent, or a hand review pass before validation." "$brief" \
    "Matt-flow brief duplicated review before no-mistakes validation"
  assert_grep "Leave the failing-test commit as the phase artifact and append one status line at the phase transition." "$brief" \
    "Matt-flow brief missing its artifact and phase-transition status contract"
  assert_no_grep "Enter at the project-installed" "$brief" \
    "Matt-flow brief still entered at a human-only phase"
  assert_no_grep "phase by phase" "$brief" \
    "Matt-flow brief still told the worker to walk phases it cannot invoke"
  assert_no_grep "\`diagnosing-bugs\`" "$brief" \
    "Matt-flow brief retained the superseded bug-skill guidance"
  pass "fm-brief.sh: Matt-flow enters at a skill the worker can actually run"
}

# A brief scaffolded without --matt-flow must carry no flow text at all, so the
# rewrite above cannot leak the flow contract into ordinary ship briefs.
test_brief_without_matt_flow_has_no_flow_section() {
  local home id brief
  home="$TMP_ROOT/no-matt-flow-home"
  mkdir -p "$home/data"
  id="brief-no-matt-flow"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "plain ship brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_no_grep "# Matt-flow" "$brief" \
    "plain ship brief gained a Matt-flow section"
  assert_no_grep "matt-flow-tdd-missing" "$brief" \
    "plain ship brief gained the Matt-flow blocked line"
  assert_no_grep "\`tdd\`" "$brief" \
    "plain ship brief gained a tdd entry point"
  pass "fm-brief.sh: a brief without --matt-flow carries no flow text"
}

test_matt_flow_without_pipeline_keeps_code_review() {
  local home mode id brief
  home="$TMP_ROOT/matt-flow-without-pipeline-home"
  mkdir -p "$home/data"

  for mode in direct-PR local-only; do
    id="brief-matt-flow-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" --matt-flow >/dev/null 2>&1 \
      || fail "$mode Matt-flow brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep "# Matt-flow" "$brief" \
      "$mode Matt-flow brief missing its thin trigger section"
    assert_grep "Continue from \`tdd\` to the installed \`code-review\` skill, which owns review because no pipeline follows." "$brief" \
      "$mode Matt-flow brief did not retain review before delivery"
    assert_grep "Leave the failing-test commit and the review notes as the phase artifacts and append one status line at every phase transition." "$brief" \
      "$mode Matt-flow brief did not retain its review artifact"
    assert_no_grep "Stop the flow after \`tdd\`" "$brief" \
      "$mode Matt-flow brief stopped before its required review"
    assert_no_grep "The no-mistakes pipeline in the Definition of done owns review" "$brief" \
      "$mode Matt-flow brief assigned review to a pipeline it does not run"
    assert_grep "Run each of its review axes on Claude Opus 5.5 at xhigh, whatever runtime you are on, one call per axis: $REVIEWER_CMD." "$brief" \
      "$mode Matt-flow brief did not pin its review axes to Opus 5.5 at xhigh"
    assert_grep "Count a verdict only when that JSON's \`modelUsage\` names \`claude-opus-5-5\` and no other model." "$brief" \
      "$mode Matt-flow brief did not require a model-identity check on the review"
    assert_grep "If the review is refused or names another model, say so plainly in your status line and never substitute another reviewer." "$brief" \
      "$mode Matt-flow brief did not forbid a substitute reviewer"
  done
  pass "fm-brief.sh: Matt-flow retains review when no pipeline follows"
}

# Only a worker's own review runs the pinned reviewer: the no-mistakes pipeline
# owns review there, and ordinary ship briefs carry no self-review step.
test_pinned_reviewer_only_where_worker_reviews() {
  local home mode id brief
  home="$TMP_ROOT/pinned-reviewer-home"
  mkdir -p "$home/data"
  id="brief-reviewer-matt-no-mistakes"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes --matt-flow >/dev/null 2>&1 \
    || fail "no-mistakes Matt-flow brief failed to scaffold"
  assert_no_grep "claude -p --model opus" "$home/data/$id/brief.md" \
    "no-mistakes Matt-flow brief ran its own reviewer beside the pipeline"
  for mode in no-mistakes direct-PR local-only; do
    id="brief-reviewer-plain-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode ship brief failed to scaffold"
    assert_no_grep "claude -p --model opus" "$home/data/$id/brief.md" \
      "$mode ordinary ship brief gained a self-review step"
  done
  pass "fm-brief.sh: the pinned reviewer appears only where the worker reviews"
}

test_ship_validation_runs_full_suites_on_github() {
  local home id mode brief matt_brief scout_brief
  home="$TMP_ROOT/github-validation-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-github-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep "On this machine, run only the type check, lint, and tests for the files you touched." "$brief" \
      "$mode: ship brief did not limit local validation"
    assert_grep "Never run the full suite, e2e gating, \`bin/fm-test-run.sh --all\`, or a full lane set on this machine." "$brief" \
      "$mode: ship brief still permits a local full test run"
    assert_grep "Push your branch to \`origin\` under its own name, never \`main\`, and never open a PR for this full run." "$brief" \
      "$mode: ship brief did not limit its validation push"
    assert_grep 'gh workflow run ci.yml --ref <branch>' "$brief" \
      "$mode: ship brief did not dispatch ci.yml"
    assert_grep 'gh run list --workflow ci.yml --branch <branch> --limit 1 --json databaseId' "$brief" \
      "$mode: ship brief did not retrieve the dispatched run id"
    assert_grep 'gh run watch <id> --exit-status --interval 30' "$brief" \
      "$mode: ship brief did not wait for the GitHub run"
    assert_grep 'gh run view <id> --log-failed' "$brief" \
      "$mode: ship brief did not give the failed-log command"
    assert_grep 'fix the failure and repeat the GitHub Actions full run until it passes' "$brief" \
      "$mode: ship brief did not require a green full run"
    assert_grep 'green run URL' "$brief" \
      "$mode: ship brief ready line did not name the green run URL"
    case "$mode" in
      no-mistakes)
        assert_grep 'done: PR {url} checks green at {pipeline head}, full suite {green run URL}' "$brief" \
          "$mode: done line did not name the green full-suite run"
        ;;
      direct-PR)
        assert_grep 'done: PR {url}, GitHub Actions green at {green run URL}' "$brief" \
          "$mode: done line did not name the green full-suite run"
        ;;
      local-only)
        assert_grep 'done: ready in branch fm/brief-github-local-only, GitHub Actions green at {green run URL}' "$brief" \
          "$mode: ready line did not name the green full-suite run"
        ;;
    esac
  done

  brief="$home/data/brief-github-local-only/brief.md"
  assert_grep "1. Push only your own \`fm/brief-github-local-only\` branch, never \`main\`, and never open a PR. Firstmate handles the merge into local \`main\`." "$brief" \
    "local-only: rule 1 did not permit only the worker branch push"
  assert_no_grep 'Never push to any remote' "$brief" \
    "local-only: brief retained the old no-remote rule"
  assert_no_grep 'Do NOT push' "$brief" \
    "local-only: Definition of done retained the old no-push instruction"

  id="brief-github-matt"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode local-only --matt-flow >/dev/null 2>&1 \
    || fail "local-only --matt-flow: ship brief failed to scaffold"
  matt_brief="$home/data/$id/brief.md"
  assert_grep "Enter at the installed \`tdd\` skill: write the failing test first, then make it pass." "$matt_brief" \
    "Matt-flow brief lost its local test-first walk"
  assert_grep 'For any change a user can see, walk it before reporting done: as a signed-in user on a local build' "$matt_brief" \
    "Matt-flow brief lost its local live walk"
  assert_grep 'gh workflow run ci.yml --ref <branch>' "$matt_brief" \
    "Matt-flow brief did not send the full run to GitHub Actions"

  id="brief-github-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  scout_brief="$home/data/$id/brief.md"
  assert_no_grep 'gh workflow run ci.yml' "$scout_brief" \
    "scout brief gained the ship validation contract"
  pass "fm-brief.sh: ship full suites run in GitHub Actions while local checks stay narrow"
}

# A ship task's delivery mode is firstmate's per-task decision, so a missing or
# unusable value must stop the scaffold instead of silently defaulting. The
# no-mistakes-prod-only row is the conditional registry policy: it is never a task
# mode, and its refusal must say to classify the task's surface first.
# The aos hardening review (2026-09-04) found six holes of one shape: the builder
# proved the path it designed and never walked the path a real person takes. Every
# ship mode therefore demands the walk before done, with or without --matt-flow. A
# scout produces a report rather than a user-visible change, so it stays out.
test_ship_modes_demand_a_walked_path_before_done() {
  local home id mode brief flow flow_label walk_line done_line report_marker
  home="$TMP_ROOT/walked-path-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    for flow in plain matt-flow; do
      case "$flow" in
        plain)
          id="brief-walk-$mode"
          flow_label="$mode"
          FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
            || fail "$flow_label: ship brief failed to scaffold"
          ;;
        matt-flow)
          id="brief-walk-$mode-matt-flow"
          flow_label="$mode --matt-flow"
          FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" --matt-flow >/dev/null 2>&1 \
            || fail "$flow_label: ship brief failed to scaffold"
          ;;
      esac
      brief="$home/data/$id/brief.md"
      assert_grep "For any change a user can see, walk it before reporting done" "$brief" \
        "$flow_label: ship brief did not demand the walk before done"
      assert_grep "on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to)" "$brief" \
        "$flow_label: ship brief did not require the neighbouring paths"
      # local-only never opens a PR, so a preview deployment is unavailable and a one-line
      # status file cannot carry a heading; its proof lands in the final commit message.
      case "$mode" in
        local-only)
          assert_grep "as a signed-in user on a local build," "$brief" \
            "$flow_label: ship brief did not send the walk to a local build"
          assert_no_grep "on the preview deployment" "$brief" \
            "$flow_label: ship brief sent a never-pushed branch to a preview deployment"
          assert_grep "Write what you saw, step by step, under a \`## What I walked\` section in the body of your final commit message on this branch, in plain text and with no screenshots." "$brief" \
            "$flow_label: ship brief did not route the What I walked section to the commit message"
          assert_grep "walked {the path you walked}" "$brief" \
            "$flow_label: ship brief did not make the done line name the path walked"
          report_marker="append \`done: ready in branch"
          ;;
        no-mistakes)
          assert_grep "as a signed-in user on the preview deployment (or a local build when the project has no preview)" "$brief" \
            "$flow_label: ship brief did not say where to walk the change"
          assert_grep "Paste what you saw, step by step, under \`## What I walked\` in the PR body, with a viewport screenshot per path." "$brief" \
            "$flow_label: ship brief did not require the What I walked section and its screenshots"
          report_marker="After /no-mistakes reports CI green"
          ;;
        *)
          assert_grep "as a signed-in user on the preview deployment (or a local build when the project has no preview)" "$brief" \
            "$flow_label: ship brief did not say where to walk the change"
          assert_grep "Paste what you saw, step by step, under \`## What I walked\` in the PR body, with a viewport screenshot per path." "$brief" \
            "$flow_label: ship brief did not require the What I walked section and its screenshots"
          report_marker="push your branch and open a PR"
          ;;
      esac
      assert_grep "A done without that section is not done; firstmate sends it back." "$brief" \
        "$flow_label: ship brief did not give the walk a consequence"
      walk_line=$(grep -n -F -- "walk it before reporting done" "$brief" | head -1 | cut -d: -f1)
      done_line=$(grep -n -F -- "$report_marker" "$brief" | head -1 | cut -d: -f1)
      [ -n "$walk_line" ] && [ -n "$done_line" ] \
        || fail "$flow_label: ship brief is missing the walk line or the report-done line"
      [ "$walk_line" -lt "$done_line" ] \
        || fail "$flow_label: ship brief puts the walk demand after the report-done step"
    done
  done

  id="brief-walk-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_no_grep "## What I walked" "$brief" \
    "scout brief demanded a walked-path proof for a deliverable that ships no change"

  pass "fm-brief.sh: every ship mode demands a walked-path proof; scout stays out"
}

test_ship_mode_is_required_and_closed_set() {
  local home id out status label flag expect
  home="$TMP_ROOT/mode-required-home"
  mkdir -p "$home/data"
  id=0
  while IFS='|' read -r label flag expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    # shellcheck disable=SC2086  # flag is an intentional word-split arg list (may be empty)
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "brief-required-$id" some-proj $flag 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/data/brief-required-$id/brief.md" "$label: refused scaffold still wrote a brief"
  done <<'ROWS'
missing --mode||ship briefs require --mode
empty --mode value|--mode|requires a value
unknown mode value|--mode nope|must be one of no-mistakes, direct-PR, local-only
conditional policy is not a task mode|--mode no-mistakes-prod-only|classify this task's surface
ROWS
  pass "fm-brief.sh: ship --mode is required and closed-set validated"
}

# The registry is the captain's standing posture, not this task's answer: the
# scaffold must follow the explicit flag even when the project is registered
# with a different mode, and must not consult the registry at all.
test_ship_mode_is_explicit_not_registry() {
  local home brief
  home="$TMP_ROOT/explicit-over-registry-home"
  write_registry "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a5 direct-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "explicit no-mistakes brief on a direct-PR project should scaffold"
  brief="$home/data/brief-explicit-a5/brief.md"
  grep -qx "Delivery contract: mode=no-mistakes" "$brief" \
    || fail "registered direct-PR posture overrode the explicit --mode"
  assert_grep "run /no-mistakes to validate and ship a PR" "$brief" \
    "explicit no-mistakes brief did not render the pipeline definition of done"

  # An unregistered project is not a blocker either, because nothing is looked up.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" brief-explicit-a6 never-registered --mode local-only >/dev/null 2>&1 \
    || fail "unregistered project should still scaffold from the explicit mode"
  grep -qx "Delivery contract: mode=local-only" "$home/data/brief-explicit-a6/brief.md" \
    || fail "unregistered project did not honour the explicit --mode"
  pass "fm-brief.sh: the explicit ship mode wins over the registered posture"
}

# yolo is firstmate's approval authority and never reaches the worker, and a scout
# or charter carries no delivery contract. Each must refuse rather than accept and
# discard the flag, which would look recorded but change nothing.
test_delivery_flags_are_refused_where_they_do_not_apply() {
  local home out status label args expect
  home="$TMP_ROOT/refused-flags-home"
  mkdir -p "$home/data"
  while IFS='|' read -r label args expect; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain why"
  done <<'ROWS'
yolo on a ship brief|brief-refused-b1 some-proj --mode direct-PR --yolo on|--yolo is not a brief input
yolo=value form on a ship brief|brief-refused-b2 some-proj --mode direct-PR --yolo=off|--yolo is not a brief input
mode on a scout brief|brief-refused-b3 some-proj --scout --mode direct-PR|--mode applies only to ship briefs
mode on a secondmate charter|brief-refused-b4 --secondmate --no-projects --mode no-mistakes|--mode applies only to ship briefs
Matt-flow on a scout brief|brief-refused-b5 some-proj --scout --matt-flow|--matt-flow applies only to ship briefs
Matt-flow on a secondmate charter|brief-refused-b6 --secondmate --no-projects --matt-flow|--matt-flow applies only to ship briefs
ROWS
  pass "fm-brief.sh: ship-only delivery flags are refused elsewhere, never silently dropped"
}

test_faster_paths_use_configured_authority_without_stacked_review() {
  local home id brief
  home="$TMP_ROOT/configured-authority-home"
  write_registry "$home"
  id="brief-direct-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority decides whether to merge the PR; firstmate relays the outcome." "$brief" \
    "direct-PR brief lost configured merge authority"
  assert_no_grep "The captain reviews and merges the PR" "$brief" \
    "direct-PR brief hard-coded captain-only authority"
  id="brief-local-authority-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj --mode local-only >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path." "$brief" \
    "local-only brief lost configured merge authority and guarded landing"
  assert_no_grep "The captain approves the ready branch" "$brief" \
    "local-only brief hard-coded captain-only authority"
  assert_no_grep "Firstmate then reviews your branch diff" "$brief" \
    "local-only brief retained a personal review stacked on the selected delivery path"
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "local-only brief must not include the no-mistakes --intent contract"
  id="brief-direct-intent-a4"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" direct-proj --mode direct-PR >/dev/null 2>&1
  assert_no_grep "make \`--intent\` preserve all relevant content from this brief" "$home/data/$id/brief.md" \
    "direct-PR brief must not include the no-mistakes --intent contract"
  pass "fm-brief.sh: faster paths use configured authority without stacked review"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`no-mistakes axi run --help`' "$brief" \
    "no-mistakes DOD must render literal backticks around the help command"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep '`help`' "$brief" \
    "no-mistakes DOD must render literal backticks around help"
  assert_grep "make \`--intent\` preserve all relevant content from this brief" "$brief" \
    "no-mistakes DOD must require --intent to retain the accepted task contract"
  assert_grep "carrying only each requirement's current accepted form" "$brief" \
    "no-mistakes DOD must replace superseded requirements with their current accepted form"
  assert_grep "retain direct requirements instead of substituting a diff summary" "$brief" \
    "no-mistakes DOD must keep direct requirements and exclude generic scaffold boilerplate from --intent"
  assert_grep "exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific" "$brief" \
    "no-mistakes DOD must exclude non-task-specific scaffold boilerplate from --intent"
  assert_grep "firstmate's authority check" "$brief" \
    "no-mistakes DOD lost its authority-check wording"
  assert_grep ".agents/skills/review-loop-stop/SKILL.md" "$brief" \
    "no-mistakes DOD must load the repeated-review stop before another fix response"
  assert_grep "$ROOT/bin/fm-review-loop-stop.sh" "$brief" \
    "no-mistakes DOD must give the worker the resolved Firstmate helper path"
  pass "fm-brief.sh: no-mistakes DOD keeps its apostrophe prose, now parse-safe"
}

# The no-mistakes DOD must send the worker straight into validation instead
# of stopping at a "done: built" line to wait for firstmate to hand across
# the /no-mistakes instruction. That hand-off added a supervisor round trip
# on every ship task. Pin the new direct-validation prose and the absence of
# the old wait-for-firstmate line so the round trip cannot silently return.
test_no_mistakes_dod_self_drives_into_validation() {
  local home id brief
  home="$TMP_ROOT/selfdrive-home"
  mkdir -p "$home/data"
  id="brief-selfdrive-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "run /no-mistakes to validate and ship a PR" "$brief" \
    "no-mistakes DOD must tell the worker to run /no-mistakes directly"
  assert_grep "proceed directly to validation" "$brief" \
    "no-mistakes DOD must tell the worker not to wait for firstmate"
  assert_no_grep "Firstmate will then instruct you to run /no-mistakes" "$brief" \
    "no-mistakes DOD must not keep the old wait-for-firstmate round-trip line"
  pass "fm-brief.sh: no-mistakes DOD self-drives into validation"
}

# The pipeline can rebase and merge the branch while the worker's local head stays
# at the pre-rebase commit. That stale head later makes teardown refuse already-landed
# work as unlanded, costing the captain a discard decision he should never face.
# The no-mistakes DOD must therefore require the worker to sync its local branch to
# the pipeline head before reporting done, and to name that head in the done line.
# direct-PR and local-only never run the pipeline, so the requirement must not leak
# into their briefs.
test_no_mistakes_dod_syncs_to_pipeline_head_before_done() {
  local home id mode brief ci_line sync_line done_line
  home="$TMP_ROOT/sync-home"
  mkdir -p "$home/data"

  id="brief-sync-no-mistakes"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "no-mistakes: ship brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep 'no-mistakes axi status' "$brief" \
    "no-mistakes DOD must require reading structured axi status before done"
  assert_grep 'branch_sync.next_action' "$brief" \
    "no-mistakes DOD must require following the reported branch sync action"
  assert_grep 'no-mistakes axi sync' "$brief" \
    "no-mistakes DOD must name the guarded sync command"
  assert_grep 'git rev-parse HEAD' "$brief" \
    "no-mistakes DOD must require proving the local head matches the pipeline head"
  assert_grep 'done: PR {url} checks green at {pipeline head}' "$brief" \
    "no-mistakes DOD done line must state the pipeline head"

  # The sync step must sit after the CI-green return point and before the done line.
  ci_line=$(grep -n 'After /no-mistakes reports CI green' "$brief" | cut -d: -f1)
  sync_line=$(grep -n 'no-mistakes axi status' "$brief" | cut -d: -f1)
  done_line=$(grep -n 'done: PR {url} checks green at {pipeline head}' "$brief" | cut -d: -f1)
  if [ -z "$ci_line" ] || [ -z "$sync_line" ] || [ -z "$done_line" ]; then
    fail "sync-before-done: expected CI-green, sync, and done markers were not all present"
  fi
  [ "$ci_line" -lt "$sync_line" ] \
    || fail "sync-before-done: the sync requirement must follow the CI-green return point"
  [ "$sync_line" -lt "$done_line" ] \
    || fail "sync-before-done: the sync requirement must precede the done line"

  for mode in direct-PR local-only; do
    id="brief-sync-${mode}"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_no_grep 'branch_sync.next_action' "$brief" \
      "$mode: brief must not require the no-mistakes pipeline sync it never runs"
    assert_no_grep 'no-mistakes axi status' "$brief" \
      "$mode: brief must not require reading no-mistakes pipeline state"
  done
  pass "fm-brief.sh: no-mistakes DOD syncs to the pipeline head before done; other modes stay out"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  assert_grep "unless the project carries that script's opt-out line" "$brief" \
    "project-memory contract would have a crewmate hand-add the section to an opted-out project"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "HERDR_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'" "$brief" \
    "Herdr lab brief must bind the absolute Firstmate helper path"
  assert_grep "HERDR_LAB_SESSION=\$(\"\$HERDR_LAB_HELPER\" name $id)" "$brief" \
    "Herdr lab brief missing helper-owned session naming"
  assert_grep "\"\$HERDR_LAB_HELPER\" provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned provisioning"
  assert_grep "\"\$HERDR_LAB_HELPER\" teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing helper-owned teardown"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "HERDR_LAB_HELPER=$helper" "$brief" \
    "Herdr lab brief must shell-quote an absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

# The captain's standing rule (2026-09-09): secrets come from the worktree's
# local env file, never the 1Password CLI. Pin the exact rule sentence in
# every scaffold that carries a numbered Rules section, and pin the --intent
# carry-forward sentence in every ship mode's Definition of done, so a
# paraphrase cannot silently drop the rule.
# shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
NO_1PASSWORD_RULE='Never run the 1Password CLI (`op run`, `op read`, `op item`, `op environment`, or any other `op` subcommand) for anything. Secrets come from this worktree'"'"'s `.env.local` or the app'"'"'s equivalent local env file. If a variable you need is missing there, append `blocked [key=missing-env-<NAME>]: <NAME> is missing from that local env file` and stop; never fetch it.'
# shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
NO_1PASSWORD_INTENT_CLAUSE='The no-1Password rule above is not scaffold boilerplate: the intent must carry the no-1Password rule verbatim so the pipeline'"'"'s review, test, document, and CI-fix agents inherit it'

# The working-directory guidance steers a worker off a `cd` in a compound
# command, the shape that can stall a Claude worker on an unresolvable
# permission prompt. Pin each alternative as literal text.
# shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
WORKDIR_CD_RULE='Do not put `cd <dir>` in a compound command such as `cd <dir> && grep ...`.'
# shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
WORKDIR_GIT_C_RULE='put an absolute path on the command itself, or use `git -C <dir> ...`.'
# shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
WORKDIR_SUBSHELL_RULE='scope the change to a subshell: `(cd <dir> && ...)`.'

test_no_1password_rule_in_ship_and_scout_scaffolds() {
  local home id brief
  home="$TMP_ROOT/no-1password-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-no1p-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep "$NO_1PASSWORD_RULE" "$brief" \
      "$mode: ship brief missing the exact no-1Password rule sentence"
  done

  id="brief-no1p-matt-flow"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode no-mistakes --matt-flow >/dev/null 2>&1 \
    || fail "matt-flow: ship brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "$NO_1PASSWORD_RULE" "$brief" \
    "matt-flow: ship brief missing the exact no-1Password rule sentence"

  id="brief-no1p-herdr-lab"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes --herdr-lab >/dev/null 2>&1 \
    || fail "herdr-lab: ship brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "$NO_1PASSWORD_RULE" "$brief" \
    "herdr-lab: ship brief missing the exact no-1Password rule sentence"

  id="brief-no1p-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout: brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "$NO_1PASSWORD_RULE" "$brief" \
    "scout: brief missing the exact no-1Password rule sentence"

  pass "fm-brief.sh: every scaffold with a Rules section forbids the 1Password CLI"
}

# A Claude worker can stall on a permission prompt when a compound command
# starts with `cd`, because the command's directory becomes unresolvable. Every
# ship and scout brief carries the reach-the-target advice; a secondmate charter
# does not, because it is not a project-work contract.
test_working_directory_guidance_reaches_ship_and_scout() {
  local home id mode brief
  home="$TMP_ROOT/workdir-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-workdir-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep "# Working directory" "$brief" "$mode: ship brief missing the working-directory section"
    assert_grep "$WORKDIR_CD_RULE" "$brief" \
      "$mode: ship brief missing the cd-in-compound-command rule"
    assert_grep "$WORKDIR_GIT_C_RULE" "$brief" \
      "$mode: ship brief missing the git -C alternative"
    assert_grep "$WORKDIR_SUBSHELL_RULE" "$brief" \
      "$mode: ship brief missing the subshell fallback"
  done

  id="brief-workdir-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "# Working directory" "$brief" "scout brief missing the working-directory section"
  assert_grep "$WORKDIR_CD_RULE" "$brief" \
    "scout brief missing the cd-in-compound-command rule"

  id="brief-workdir-secondmate"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1 \
    || fail "secondmate charter failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_no_grep "# Working directory" "$brief" \
    "secondmate charter must not carry the ship/scout working-directory section"

  pass "fm-brief.sh: ship and scout briefs carry the working-directory guidance"
}

test_no_1password_intent_carry_forward_in_ship_scaffolds() {
  local home id brief
  home="$TMP_ROOT/no-1password-intent-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-no1p-intent-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ship brief failed to scaffold"
    brief="$home/data/$id/brief.md"
    if [ "$mode" = no-mistakes ]; then
      assert_grep "$NO_1PASSWORD_INTENT_CLAUSE" "$brief" \
        "$mode: no-mistakes DOD missing the --intent no-1Password carry-forward sentence"
    else
      assert_no_grep "$NO_1PASSWORD_INTENT_CLAUSE" "$brief" \
        "$mode: brief has no --intent contract and must not carry the intent clause"
    fi
  done
  pass "fm-brief.sh: no-mistakes DOD requires --intent to carry the no-1Password rule verbatim"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  assert_grep 'working [key=<work-slug>]' "$brief" \
    "secondmate charter did not key material routed-work phases"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter did not close a quietly ended routed-work phase"
  assert_grep 'use the same key on its later' "$brief" \
    "secondmate charter did not supersede working phases with later states"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_secondmate_marked_request_reporting_contract() {
  local home brief
  home="$TMP_ROOT/marked-request-reporting-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=paused \
    FM_SECONDMATE_CHARTER='Handle routed domain work.' \
    "$ROOT/bin/fm-brief.sh" marked-request-reporting --secondmate --no-projects >/dev/null 2>&1
  brief="$home/data/marked-request-reporting/brief.md"

  assert_grep 'A marked request requires one correlated answer after the work' "$brief" \
    "secondmate charter did not require the correlated answer after the work"
  assert_grep 'does not require a separate receipt or start acknowledgement' "$brief" \
    "secondmate charter did not reject a separate receipt/start acknowledgement"
  assert_grep "Never append \`working:\` merely to acknowledge receipt or announce that a marked request has started." "$brief" \
    "secondmate charter did not forbid a generic working acknowledgement"
  assert_no_grep "Give every routed-work phase a stable key: open it with \`working" "$brief" \
    "secondmate charter retained the unconditional working opener"
  assert_grep 'When a routed-work phase has a supervisor-actionable material change worth reporting under the rule above' "$brief" \
    "secondmate charter did not limit keyed phases to reportable material changes"
  assert_grep "If its first reportable event is \`working [key=<work-slug>]: {material phase}\`" "$brief" \
    "secondmate charter lost keyed working syntax for a reportable material phase"
  assert_grep "use the same key on its later \`paused\`, \`done\`, \`failed\`, \`needs-decision\`, or \`blocked\` event" "$brief" \
    "secondmate charter lost same-key closure for a reportable material phase"
  assert_grep 'resolved [key=<work-slug>]' "$brief" \
    "secondmate charter lost resolved closure for a keyed material phase"

  assert_grep 'include that exact token in your parent status reply' "$brief" \
    "secondmate charter lost correlated parent results"
  assert_grep 'For a terse result, a status line is the whole answer.' "$brief" \
    "secondmate charter lost terse result reporting"
  assert_grep 'append a status line that points to that doc' "$brief" \
    "secondmate charter lost detailed document pointers"
  assert_grep 'Report only true captain-relevant outcomes or a declared external wait' "$brief" \
    "secondmate charter lost declared external waits"
  assert_grep 'a captain decision, a real blocker, a failure, or work ready for review' "$brief" \
    "secondmate charter lost decisions, blockers, failures, or ready outcomes"
  assert_grep 'States: working, needs-decision, blocked, paused, done, failed.' "$brief" \
    "secondmate charter changed the preserved status vocabulary"
  pass "fm-brief.sh: marked requests avoid generic acknowledgements and preserve material reporting"
}

test_secondmate_directory_paths_are_absolute_and_output_is_stable() {
  local root home data_override state_override brief baseline err status
  root="$TMP_ROOT/relative-directory-inputs"
  mkdir -p "$root"
  root=$(cd "$root" && pwd -P)
  home="$root/home"
  data_override="$root/data-override"
  state_override="$root/state-override"
  mkdir -p "$home/data" "$home/state" "$data_override" "$state_override" \
    "$root/cdpath/home/data" "$root/cdpath/home/state" \
    "$root/cdpath/data-override" "$root/cdpath/state-override"

  brief="$home/data/relative-home/brief.md"
  FM_HOME="$home" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-home-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-home --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_HOME changed charter bytes compared with the same absolute home"
  assert_grep ">> '$home/state/relative-home.status'" "$brief" \
    "relative FM_HOME did not render an absolute secondmate status path"

  brief="$home/data/relative-state/brief.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-state-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_STATE_OVERRIDE=state-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-state --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_STATE_OVERRIDE changed charter bytes compared with the same absolute state directory"
  assert_grep ">> '$state_override/relative-state.status'" "$brief" \
    "relative FM_STATE_OVERRIDE did not render an absolute secondmate status path"

  brief="$data_override/relative-data/brief.md"
  FM_HOME="$home" FM_DATA_OVERRIDE="$data_override" FM_SECONDMATE_CHARTER=x \
    "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  baseline="$root/absolute-data-charter"
  cp "$brief" "$baseline"
  rm -f "$brief"
  (
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME="$home" FM_DATA_OVERRIDE=data-override FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" relative-data --secondmate --no-projects >/dev/null 2>&1
  )
  cmp -s "$baseline" "$brief" \
    || fail "relative FM_DATA_OVERRIDE changed charter bytes compared with the same absolute data directory"
  assert_grep ">> '$home/state/relative-data.status'" "$brief" \
    "relative FM_DATA_OVERRIDE changed the absolute default status path"

  err="$root/unresolved.err"
  (
    cd "$root" || exit 1
    FM_HOME=missing-home FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-home --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_HOME must fail"
  assert_grep "FM_HOME directory cannot be resolved: missing-home" "$err" \
    "unresolved relative FM_HOME did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_STATE_OVERRIDE=missing-state FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-state --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_STATE_OVERRIDE must fail"
  assert_grep "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" "$err" \
    "unresolved relative FM_STATE_OVERRIDE did not fail loudly"

  (
    cd "$root" || exit 1
    FM_HOME="$home" FM_DATA_OVERRIDE=missing-data FM_SECONDMATE_CHARTER=x \
      "$ROOT/bin/fm-brief.sh" unresolved-data --secondmate --no-projects >/dev/null 2>"$err"
  ); status=$?
  expect_code 1 "$status" "an unresolved relative FM_DATA_OVERRIDE must fail"
  assert_grep "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" "$err" \
    "unresolved relative FM_DATA_OVERRIDE did not fail loudly"

  pass "fm-brief.sh: relative directory inputs ignore CDPATH, render stable absolute charter paths, or fail loudly"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --mode no-mistakes >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
    assert_grep 'a blocker or wait clears' "$brief" \
      "$kind brief did not require durable resolution when a blocker clears"
    assert_grep 'even when the answer is what started that work' "$brief" \
      "$kind brief did not warn that an answer-started done/working never closes a decision"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

test_scout_and_secondmate_load_decision_hold_policy() {
  local home scout charter
  home="$TMP_ROOT/decision-policy-home"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" sample-investigation sample --scout >/dev/null 2>&1
  scout="$home/data/sample-investigation/brief.md"
  assert_grep "$ROOT/.agents/skills/decision-hold-lifecycle/SKILL.md" "$scout" \
    "scout brief did not load the unresolved-decision policy before done"
  assert_grep "pass its shared completion gate for the report and any visual review" "$scout" \
    "scout brief did not cross-reference visual-review completion"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SECONDMATE_CHARTER='sample reviews' \
    "$ROOT/bin/fm-brief.sh" sample-mate --secondmate --no-projects >/dev/null 2>&1
  charter="$home/data/sample-mate/brief.md"
  assert_grep "load \`decision-hold-lifecycle\`" "$charter" \
    "secondmate charter did not load the shared decision policy for detailed investigations"
  pass "fm-brief.sh: investigation and visual-review completions load the shared decision policy"
}

# Scout and secondmate paths still scaffold well-formed briefs.
test_scout_and_secondmate_scaffold() {
  local brief
  FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-scout-q6 alpha --scout >/dev/null 2>&1 \
    || fail "fm-brief.sh scout scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-scout-q6/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "scout brief must declare itself a scout task"
  assert_grep "report.md" "$brief" "scout brief must point at the report deliverable"

  FM_SECONDMATE_CHARTER='Supervise the alpha domain.' \
    FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" brief-sm-q6 --secondmate alpha >/dev/null 2>&1 \
    || fail "fm-brief.sh secondmate scaffold exited non-zero"
  brief="$BRIEF_HOME/data/brief-sm-q6/brief.md"
  assert_present "$brief" "secondmate charter was not scaffolded"
  assert_grep "persistent second mate" "$brief" \
    "secondmate charter must declare its role"
  pass "fm-brief: scout and secondmate code paths still scaffold well-formed briefs"
}

test_worker_skills_section_reaches_ship_and_scout_only() {
  local home ship scout secondmate skill_root
  home="$TMP_ROOT/worker-skills-home"
  # shellcheck disable=SC2088 # The generated brief keeps these portable user-home pointers literal.
  skill_root='~/.agents/skills'
  secondmate="$home/data/worker-skills-secondmate/brief.md"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" worker-skills-ship sample --mode no-mistakes >/dev/null 2>&1
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" worker-skills-scout sample --scout >/dev/null 2>&1
  FM_HOME="$home" FM_SECONDMATE_CHARTER='sample charter' \
    "$ROOT/bin/fm-brief.sh" worker-skills-secondmate --secondmate --no-projects >/dev/null 2>&1 \
    || fail "secondmate scaffold failed before creating $secondmate"
  ship="$home/data/worker-skills-ship/brief.md"
  scout="$home/data/worker-skills-scout/brief.md"
  assert_present "$secondmate" "secondmate scaffold did not create $secondmate"

  for brief in "$ship" "$scout"; do
    assert_grep '# Session skills' "$brief" "worker brief omitted the session skills section"
    assert_grep "Every structured launch delivers caveman (\`full\`) and ponytail (\`full\`) when their installed skill files are available." "$brief" \
      "worker brief did not describe structured skill delivery"
    assert_grep "On a raw launch, load caveman and ponytail yourself before starting." "$brief" \
      "worker brief falsely described raw-launch skill delivery"
    assert_grep "caveman keeps chat terse; every durable output stays normal prose, for example commits, PRs, issues, docs, scout reports, review comments, and plans." "$brief" \
      "worker brief narrowed caveman's durable-output rule"
    assert_grep "The examples are not an exhaustive list." "$brief" \
      "worker brief treated the durable-output examples as exhaustive"
    assert_grep "without dropping required validation, error handling, security, accessibility, or brief-required tests" "$brief" \
      "worker brief let ponytail drop required safeguards"
    assert_grep "This brief's test requirements win over ponytail's test rule." "$brief" \
      "worker brief did not resolve the ponytail test-rule collision"
    assert_grep "$skill_root/caveman/SKILL.md" "$brief" \
      "worker brief omitted the caveman source pointer"
    assert_grep "$skill_root/ponytail/SKILL.md" "$brief" \
      "worker brief omitted the ponytail source pointer"
    assert_grep "For delivered skills, the skill-defined off phrases \`stop caveman\` and \`stop ponytail\` are available." "$brief" \
      "worker brief omitted the two off-switch phrases"
  done
  assert_no_grep '# Session skills' "$secondmate" \
    "secondmate charter received worker-only skills"
  pass "ship and scout briefs describe available worker skills without changing secondmate charters"
}

test_no_subagents_rule_emits_in_every_variant() {
  # Item 7 of fm-anti-drift-hardening (captain standing order 2026-08-21): the
  # no-subagents standing rule must reach every worker through the generated
  # brief - scout and every ship delivery mode alike.
  local home id mode brief sentence
  home="$TMP_ROOT/subagent-home"
  write_registry "$home"
  sentence="Do not spawn subagents, background agents, or sub-workers; do all work directly in your own session."

  for mode in no-mistakes direct-PR local-only; do
    id="brief-nosub-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "ship brief --mode $mode failed to scaffold"
    brief="$home/data/$id/brief.md"
    assert_grep "$sentence" "$brief" "$id: ship brief missing the no-subagents standing rule"
    awk -v s="$sentence" '
      $0 == "# Rules" { in_rules = 1 }
      in_rules && index($0, s) { found = 1 }
      in_rules && /^# / && $0 != "# Rules" { in_rules = 0 }
      END { exit !found }
    ' "$brief" || fail "$id: the no-subagents rule emitted outside the Rules section"
  done

  id=brief_no_sub_scout
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  assert_grep "$sentence" "$brief" "$id: scout brief missing the no-subagents standing rule"
  awk -v s="$sentence" '
    $0 == "# Rules" { in_rules = 1 }
    in_rules && index($0, s) { found = 1 }
    in_rules && /^# / && $0 != "# Rules" { in_rules = 0 }
    END { exit !found }
  ' "$brief" || fail "$id: the no-subagents rule emitted outside the Rules section"

  pass "every generated scout/ship brief carries the no-subagents standing rule inside its Rules section"
}

test_no_subagents_rule_emits_in_every_variant
test_script_parses
test_no_heredoc_in_command_substitution
test_stock_bash_generates_worker_brief
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_worker_turn_and_scope_rules
test_turn_rule_names_the_four_early_stops
test_help_names_frontend_avoid_list
test_pr_producing_modes_own_feedback_until_landing
test_matt_flow_is_explicit_and_thin
test_brief_without_matt_flow_has_no_flow_section
test_matt_flow_without_pipeline_keeps_code_review
test_pinned_reviewer_only_where_worker_reviews
test_ship_validation_runs_full_suites_on_github
test_ship_modes_demand_a_walked_path_before_done
test_ship_mode_is_required_and_closed_set
test_ship_mode_is_explicit_not_registry
test_delivery_flags_are_refused_where_they_do_not_apply
test_faster_paths_use_configured_authority_without_stacked_review
test_no_mistakes_dod_wording
test_no_mistakes_dod_self_drives_into_validation
test_no_mistakes_dod_syncs_to_pipeline_head_before_done
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_no_1password_rule_in_ship_and_scout_scaffolds
test_working_directory_guidance_reaches_ship_and_scout
test_no_1password_intent_carry_forward_in_ship_scaffolds
test_secondmate_no_projects_charter
test_secondmate_marked_request_reporting_contract
test_secondmate_directory_paths_are_absolute_and_output_is_stable
test_pause_verb_override_renders_all_brief_scaffolds
test_scout_and_secondmate_load_decision_hold_policy
test_scout_and_secondmate_scaffold
test_worker_skills_section_reaches_ship_and_scout_only

# Four worker-silence gaps closed on 2026-09-01 after five of fifteen workers
# stalled without firstmate ever acting on what they needed. Each stall traced to
# something the scaffold never said, so each fact is pinned here against the
# generated brief TEXT rather than the script source.
#   1. An unkeyed needs-decision/blocked line lands under the shared key
#      `default`, so a second unkeyed one silently overwrites the first.
#   2. Ending a turn with a validation gate open makes no progress.
#   3. Appending `resolved` records an answer; it does not do the work.
#   4. A local dependency or environment failure is the worker's own to fix.
# Every copyable status template in a generated brief must carry a [key=...]
# token, so the brief never contradicts the MUST it states.
# A template is a backticked example a worker appends verbatim. The opening
# verbs count whatever their body; a `resolved` example counts only when it
# carries a {placeholder} body, since bare `resolved` is a prose verb reference.
assert_every_example_keyed() {  # <generated-brief> <label>
  local brief=$1 label=$2 unkeyed templates
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  templates=$(grep -o '`\(needs-decision\|blocked\): [^`]*`' "$brief" || true)
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  templates="$templates"$'\n'$(grep -o '`resolved: [^`]*{[^`]*`' "$brief" || true)
  unkeyed=$(printf '%s\n' "$templates" | grep -v '\[key=' | grep . || true)
  [ -z "$unkeyed" ] \
    || fail "$label must key every appendable status template, found: $unkeyed"
}

test_status_protocol_closes_worker_silence_gaps() {
  local home id mode brief
  home="$TMP_ROOT/silence-home"
  mkdir -p "$home/data"

  for mode in no-mistakes direct-PR local-only; do
    id="brief-silence-$mode"
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --mode "$mode" >/dev/null 2>&1 \
      || fail "ship brief --mode $mode failed to scaffold"
    brief="$home/data/$id/brief.md"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'MUST carry `[key=<slug>]`' "$brief" \
      "$id: ship brief must require a key on every needs-decision and blocked line"
    assert_grep "lands under the shared key" "$brief" \
      "$id: ship brief must give the real reason a key is required"
    assert_grep "silently overwrites the first" "$brief" \
      "$id: ship brief must warn that a second unkeyed line overwrites the first"
    assert_no_grep "does not reach firstmate as an open decision" "$brief" \
      "$id: ship brief must not repeat the false claim that an unkeyed line never opens a decision"
    assert_every_example_keyed "$brief" \
      "$id: ship brief"
    assert_no_grep "if you opened it with one" "$brief" \
      "$id: ship brief must not make the resolved key conditional now that keys are required"
    assert_grep 'needs-decision [key=' "$brief" \
      "$id: ship brief must show the keyed form in its needs-decision example"
    assert_grep 'blocked [key=' "$brief" \
      "$id: ship brief must show the keyed form in its blocked example"
    assert_grep "Recording a decision is not acting on it" "$brief" \
      "$id: ship brief must separate recording an answer from doing the work"
    assert_grep "the work it unblocks still has to be done in the same turn" "$brief" \
      "$id: ship brief must require the answered work to happen in the same turn"
    assert_grep "broken environment inside your own worktree is yours to fix" "$brief" \
      "$id: ship brief must make local environment failures the worker's own to fix"
    assert_grep "Never write a real blocker as a \`working:\` line" "$brief" \
      "$id: ship brief must forbid hiding a real blocker in a working line"
  done

  brief="$home/data/brief-silence-no-mistakes/brief.md"
  assert_grep "While a validation gate is open, the turn is not finished" "$brief" \
    "no-mistakes DOD must say an open gate leaves the turn unfinished"
  assert_grep "drive the gate and process every return until it reaches an outcome" "$brief" \
    "no-mistakes DOD must require driving the gate to an outcome"

  id=brief_silence_scout
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1 \
    || fail "scout brief failed to scaffold"
  brief="$home/data/$id/brief.md"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'MUST carry `[key=<slug>]`' "$brief" \
    "scout brief must require a key on every needs-decision and blocked line"
  assert_grep "lands under the shared key" "$brief" \
    "scout brief must give the real reason a key is required"
  assert_grep "silently overwrites the first" "$brief" \
    "scout brief must warn that a second unkeyed line overwrites the first"
  assert_no_grep "does not reach firstmate as an open decision" "$brief" \
    "scout brief must not repeat the false claim that an unkeyed line never opens a decision"
  assert_every_example_keyed "$brief" \
    "scout brief"
  assert_no_grep "if you opened it with one" "$brief" \
    "scout brief must not make the resolved key conditional now that keys are required"
  assert_grep 'needs-decision [key=' "$brief" \
    "scout brief must show the keyed form in its needs-decision example"
  assert_grep 'blocked [key=' "$brief" \
    "scout brief must show the keyed form in its blocked example"
  assert_grep "Recording a decision is not acting on it" "$brief" \
    "scout brief must separate recording an answer from doing the work"
  assert_grep "the work it unblocks still has to be done in the same turn" "$brief" \
    "scout brief must require the answered work to happen in the same turn"
  assert_grep "broken environment inside your own worktree is yours to fix" "$brief" \
    "scout brief must make local environment failures the worker's own to fix"
  assert_grep "Never write a real blocker as a \`working:\` line" "$brief" \
    "scout brief must forbid hiding a real blocker in a working line"

  pass "fm-brief.sh: ship and scout briefs close the four worker-silence gaps"
}

test_status_protocol_closes_worker_silence_gaps
