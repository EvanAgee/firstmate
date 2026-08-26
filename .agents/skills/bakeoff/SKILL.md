---
name: bakeoff
description: >-
  Run a harness and model bake-off that gives one identical coding task to several combinations, reviews each result, scores them, and publishes a Lavish comparison.
  Use when the captain invokes /bakeoff or asks to compare models on the same task.
user-invocable: true
metadata:
  internal: true
---

# bakeoff

Compare harness and model combinations on one identical coding task, then publish a scored Lavish comparison.

## Flow

1. Pick a self-contained, testable task with a clear finish line.
   Prefer a feature that has already merged so every agent can branch from the pre-feature commit and the shipped diff can serve as the reference answer.
   Confirm that the base commit does not contain the feature by searching for a key symbol.
2. Write one brief with the same words for every agent.
   Include the acceptance criteria, the task's blast-radius trap, and a "prove your work" section that names the repository's test and type-check commands and asks for a `RESULT.md`.
   Save it as `scratch/bakeoff/BRIEF.md`.
3. Run `scripts/run-bakeoff.sh <clone> <base-ref> <brief> <work-root> [timeout] [slug-filter]`.
   The script creates one isolated worktree per roster entry from `<base-ref>`, installs dependencies, launches each agent headless, times it, and captures its diff, `RESULT.md`, and `manifest.tsv` row.
   Use `slug-filter` to run one canary before the full roster.
4. Run `scripts/review-bakeoff.sh <work-root> <brief> <reference-diff>`.
   The script gives each result one adversarial Opus 4.8 review against the acceptance criteria and reference diff, then writes `<slug>.verdict.json`.
5. Run `scripts/score-bakeoff.sh <work-root>`.
   The script aggregates the verdicts into a ranked leaderboard and `doc-data.json`.
6. Build a self-contained HTML comparison from `doc-data.json`.
   Include a podium, results table, one card per model with the judge's flaws, and a section for agents that did not finish.
   Open it with the `lavish` skill.
7. Remove every worktree with `git -C <clone> worktree remove --force <worktree>`.
   Delete every bake-off branch with `git -C <clone> branch -D bakeoff/<slug>`, then remove the scratch directory.

## Default roster

Verify every harness's current headless flags with `--help` before a run because the flags can change.

| slug | harness | model | launch |
| --- | --- | --- | --- |
| fable | claude | fable | `claude -p --model {M} --dangerously-skip-permissions` |
| opus5 | claude | claude-opus-5 | same |
| opus48 | claude | claude-opus-4-8 | same |
| sonnet5 | claude | claude-sonnet-5 | same |
| codex-sol | codex | gpt-5.6-sol | `codex exec -m {M} --dangerously-bypass-approvals-and-sandbox -` |
| grok46 | pi | xai/grok-4.6 | `pi --print --model {M} --approve` |
| glm53 | pi | z-ai/glm-5.3-flash | same |
| kimik3 | pi | chutes/moonshotai/Kimi-K3-TEE | same, requires a funded `CHUTES_API_KEY` |
| deepseekv4 | pi | chutes/deepseek-ai/DeepSeek-V4-Flash-0731-TEE | same, has wedged before |

The known-flaky entries are `pi/openai/gpt-5.6-luna` and `pi/openai/gpt-5.6-terra` because they use a pay-per-token OpenAI key that may have no credit and conflicts with the subscription-only billing rule.
Kimi K3 requires a funded Chutes account.
DeepSeek V4 has wedged before.
Record these failures instead of hiding them.

## Scoring rubric

Opus 4.8 returns one JSON object per agent with five strict scores from 1 to 10.

- `correctness` asks whether the result would compile and pass its tests.
- `spec_fit` asks whether the result satisfies the acceptance criteria.
- `code_quality` asks whether the code is clean, idiomatic, uses one source of truth, and matches its surroundings.
- `test_quality` asks whether the tests prove visible behavior instead of wiring.
- `safety` asks whether the result respected the blast radius, kept safe defaults, and left load-bearing shared code alone.

The total is the sum of the five scores out of 50.
The comparison also shows `buildable`, `meets_spec`, `avoided_shared_section_trap`, `has_tests`, and `in_scope`.
Rename `avoided_shared_section_trap` for each run so it names the task's real trap.
The judge also returns `one_line` and `notable_flaws` for each model's card.
The judge sees the task brief, the human reference solution, the agent's `RESULT.md`, and the agent's diff.

## Safety

- Never push, open a pull request, or merge.
- Keep every worktree outside the clone and delete it after the comparison.
- Creating worktrees writes to the clone's Git directory, so get the captain's approval in the current session before running the bake-off.
- Record install time separately from agent time so dependency setup does not affect the comparison.
- Use the scripts' portable Perl timeout because macOS has no `timeout` command.
- Capture changes with `git diff <base>` so committed and uncommitted work both appear.
- Run one cheap canary, `grok46` by default, through the entire flow before starting the full roster.
- Record setup, install, timeout, agent, and empty-result failures without retrying forever.
