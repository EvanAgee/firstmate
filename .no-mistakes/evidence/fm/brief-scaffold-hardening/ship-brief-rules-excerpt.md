# Ship brief rules section (freshly generated, all three modes carry rules 8 and 9)

## mode=no-mistakes
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.
8. After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid.
9. Before reporting done for any PR with user-visible UI changes, use the exact upload command supplied by the project brief to upload viewport screenshots and embed them in the PR body; local paths do not count.

## mode=direct-PR
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.
8. After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid.
9. Before reporting done for any PR with user-visible UI changes, use the exact upload command supplied by the project brief to upload viewport screenshots and embed them in the PR body; local paths do not count.

## mode=local-only
7. Never stop, restart, or update the shared `no-mistakes` daemon - it is one instance serving
   every lane/home, so restarting it kills other lanes' in-flight pipeline runs. On ANY no-mistakes
   daemon error, append `blocked: {the daemon error}` and stop; only firstmate manages the daemon.
8. After CI is green and before reporting any PR done, check its review comments and resolve every actionable review-bot finding (including CodeRabbit and Copilot) and human review thread by fixing it or replying with a concrete reason it is not valid.
9. Before reporting done for any PR with user-visible UI changes, use the exact upload command supplied by the project brief to upload viewport screenshots and embed them in the PR body; local paths do not count.

## scout brief (no new rules, unchanged)
matches for 'CodeRabbit|viewport screenshots' in scout brief: 0
