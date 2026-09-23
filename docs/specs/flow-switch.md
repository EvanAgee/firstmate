# Flow switch: fast local-only flow and the full PR flow, toggled per project

Decision: captain, 2026-09-16, after the 45-minute harness-wiki install. aos production serves three
users, so the guard moves from before the merge to right after it. The full PR flow stays available
and the two must be switchable in seconds, both ways.

## The two flows

| | full (today) | fast |
|---|---|---|
| Registry posture | `[no-mistakes-prod-only +yolo]` | `[local-only +yolo]` |
| Worker delivery | pipeline or PR, waits for checks | clean local branch, stops |
| Merge | `bin/fm-pr-merge.sh` after green | `bin/fm-merge-local.sh --push`: fast-forward, push main, close linked issues |
| GitHub main ruleset (`Copilot review for default branch`, id 17617595 on aos) | active | disabled |
| Automatic Copilot review ruleset (20852194) | active | disabled |
| Commit-identity ruleset (23315573) | active | active, never touched |
| Guard | seven required checks before merge | the existing CI run on main, deploy only after green (decision 0290), plus automatic revert on red (aos #3908) |

Lanes already running finish under the flow they launched in. The switch never touches a live lane.

## `bin/fm-flow.sh <project> fast|full|status`

- `fast`: rewrite the project's registry line in `data/projects.md` to `[local-only +yolo]`, keeping the
  description and dates intact; set enforcement `disabled` on the project's main-protection ruleset and
  its automatic-review ruleset; append a dated line to `data/captain.md` under Working style recording
  that firstmate may push `<project>` main without asking while fast is on; print the open fleet PRs on
  that project so none is stranded. Refuse if the post-merge main workflow is absent from the project's
  default branch (aos: the workflow from #3908) unless `--no-guard` is passed with a reason.
- `full`: restore the registry line to the value recorded at the last `fast` flip (stored in
  `state/.flow-<project>`), set both rulesets back to `active`, and remove the push-authority line.
- `status`: print the registry posture, each ruleset's enforcement, the stored previous posture, and
  a one-word verdict: `fast`, `full`, or `DRIFT` when the sides disagree. It also reports whether the
  main-protection ruleset still carries `pull_request` or `required_status_checks` rules, so it is
  visible when the gates are already gone.
- Ruleset ids come from the GitHub API by target condition and name, never hardcoded: the
  main-protection ruleset is the active branch ruleset whose conditions include `~DEFAULT_BRANCH`
  (2026-09-17 decision, option (b) adapted: match by target, not rule list, since the required
  checks were removed from the aos main ruleset before the switch shipped); the review ruleset is
  the one whose name contains `Copilot`, excluding the already-matched main ruleset. Print the
  matched ids and their current rule types. Refuse when zero or more than one match.
- Every GitHub write goes through `gh api` with `-X PUT`; a 403 is reported as a rate-limit or
  permission problem, never retried in a loop.
- Idempotent: running `fast` twice changes nothing the second time and says so.

## What the switch does not do

It never merges, pushes, spawns, or edits a project's code. It never deletes a ruleset. It never
changes `config/crew-dispatch.json`. The post-merge workflow is a project change and ships separately.

## Tests

Shell tests beside the script, in the repo's existing test style: registry rewrite round-trip (fast then
full restores the exact line), ruleset matching (zero, one, many), drift verdict, refusal without the
guard workflow, idempotent second run. GitHub calls are stubbed the way sibling tests stub `gh`.

## Firstmate rules that change with the flip

- AGENTS.md hard rule 2 (never merge a PR without the captain's word) is untouched: fast mode has no PR.
- The global "never git push without asking" rule is relaxed only for the project while fast is on, by
  the dated captain.md line the script writes and removes.
- Content drops keep the 2026-09-16 rule: no red test, no walk, no screenshots.

## Changelog in fast mode (follow-up, not part of the switch)

The in-app changelog page reads the `aos-release-note:v1` block from PR bodies (`.claude/scripts/pr-release-note.mjs`,
`changelog-disposition.mjs`). Fast mode has no PR, so the block moves into the merge commit body and the changelog
reader must accept commits on main as a source. Backlog: aos-changelog-from-commits, dispatched after the first flip.
