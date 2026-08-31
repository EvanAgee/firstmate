# Generated PR feedback ownership contracts

## no-mistakes generated Definition of done

# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, run /no-mistakes to validate and ship a PR.
Do not stop and wait for firstmate to instruct you - proceed directly to validation.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.
- After every Review gate returns findings, load `/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M1CTVZ4M0HY5Z59KYHX9ZJT5/.agents/skills/review-loop-stop/SKILL.md` and follow it before another fix response.
  Its resolved Firstmate code root is `/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M1CTVZ4M0HY5Z59KYHX9ZJT5`.
  Use `/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M1CTVZ4M0HY5Z59KYHX9ZJT5/bin/fm-review-loop-stop.sh` for every record and resolve call.

After /no-mistakes reports CI green (the CI-ready return point), append `done: PR {url} checks green` and enter the PR watch below.
Do not wait for no-mistakes to keep monitoring in the background.

Reporting done does not end your ownership of this PR - it stays yours until it merges.
Stay on watch after reporting done.
After addressing new reviewer feedback, re-report status.
Drive late reviewer feedback back through no-mistakes, never by hand-editing the branch.
If a gate is waiting, respond there and let the pipeline handle the finding.
If the monitor has ended, rerun /no-mistakes.
Never merge the PR and never arm auto-merge; the configured merge authority owns that.

## direct-PR generated Definition of done

# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and enter the PR watch below.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.

Reporting done does not end your ownership of this PR - it stays yours until it merges.
Stay on watch after reporting done.
After addressing new reviewer feedback, re-report status.
Apply rule 8 directly to late reviewer feedback: fix and push on your `fm/evidence-direct-PR` branch, resolve the threads, or reply with a concrete reason a finding is not valid.
Never merge the PR and never arm auto-merge; the configured merge authority owns that.

## local-only generated Definition of done

# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/evidence-local-only`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/evidence-local-only` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.

## Firstmate routing contract

Until the PR lands, reviewer feedback on it routes back to the worker that opened it, not a fresh agent; the ship brief owns that worker's post-done duty.
