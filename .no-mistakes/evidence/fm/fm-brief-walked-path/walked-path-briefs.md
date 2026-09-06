# What I walked - generated brief evidence

Generated with: bin/fm-brief.sh <id> acme-dashboard --mode <mode> [--matt-flow]

## mode=no-mistakes
```
For any change a user can see, walk it before reporting done: as a signed-in user on the preview deployment (or a local build when the project has no preview), on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Paste what you saw, step by step, under `## What I walked` in the PR body, with a viewport screenshot per path.
A done without that section is not done; firstmate sends it back.
After /no-mistakes reports CI green (the CI-ready return point), append `done: PR {url} checks green` and enter the PR watch below.
Do not wait for no-mistakes to keep monitoring in the background.
--- report-done line ---
After /no-mistakes reports CI green (the CI-ready return point), append `done: PR {url} checks green` and enter the PR watch below.
```

## mode=no-mistakes --matt-flow
```
For any change a user can see, walk it before reporting done: as a signed-in user on the preview deployment (or a local build when the project has no preview), on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Paste what you saw, step by step, under `## What I walked` in the PR body, with a viewport screenshot per path.
A done without that section is not done; firstmate sends it back.
After /no-mistakes reports CI green (the CI-ready return point), append `done: PR {url} checks green` and enter the PR watch below.
Do not wait for no-mistakes to keep monitoring in the background.
--- report-done line ---
After /no-mistakes reports CI green (the CI-ready return point), append `done: PR {url} checks green` and enter the PR watch below.
```

## mode=direct-PR
```
For any change a user can see, walk it before reporting done: as a signed-in user on the preview deployment (or a local build when the project has no preview), on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Paste what you saw, step by step, under `## What I walked` in the PR body, with a viewport screenshot per path.
A done without that section is not done; firstmate sends it back.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and enter the PR watch below.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
--- report-done line ---
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and enter the PR watch below.
```

## mode=direct-PR --matt-flow
```
For any change a user can see, walk it before reporting done: as a signed-in user on the preview deployment (or a local build when the project has no preview), on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Paste what you saw, step by step, under `## What I walked` in the PR body, with a viewport screenshot per path.
A done without that section is not done; firstmate sends it back.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and enter the PR watch below.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
--- report-done line ---
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and enter the PR watch below.
```

## mode=local-only
```
For any change a user can see, walk it before reporting done: as a signed-in user on a local build, on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Write what you saw, step by step, under a `## What I walked` section in the body of your final commit message on this branch, in plain text and with no screenshots.
A done without that section is not done; firstmate sends it back.
When it is implemented and committed, append `done: ready in branch fm/demo-local-only, walked {the path you walked}` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
--- report-done line ---
When it is implemented and committed, append `done: ready in branch fm/demo-local-only, walked {the path you walked}` to the status file and stop.
```

## mode=local-only --matt-flow
```
For any change a user can see, walk it before reporting done: as a signed-in user on a local build, on the path the issue describes and the two paths beside it (the screen you arrive from and the one you leave to).
Write what you saw, step by step, under a `## What I walked` section in the body of your final commit message on this branch, in plain text and with no screenshots.
A done without that section is not done; firstmate sends it back.
When it is implemented and committed, append `done: ready in branch fm/demo-local-only-matt, walked {the path you walked}` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
--- report-done line ---
When it is implemented and committed, append `done: ready in branch fm/demo-local-only-matt, walked {the path you walked}` to the status file and stop.
```

## --scout (must contain zero occurrences)
```
occurrences of "## What I walked" in scout brief: 0
```
