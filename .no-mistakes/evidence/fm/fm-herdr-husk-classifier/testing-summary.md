# CodeRabbit review-fix evidence

## 1. Already-stopped exit retires leftover busy wiring

Public interface: `bin/fm-control.sh <id> exit` against a stubbed tmux backend.

- **Red (pre-fix):** exit still printed `already-stopped t1` with no bytes sent, but left `t1.busy-gen` and `t1.busy-state` in place for both a dead agent and a missing endpoint.
- **Green (post-fix):** the same `already-stopped` outcome now removes both sidecars.

See `busy-retirement-red-before-fix.log` and `busy-retirement-green-after-fix.log`.
The same contract is now pinned in `tests/fm-control.test.sh`.

## 2. Classifier comment matches the idle-shell/`ps` recheck

The husk classifier is exercised through `fm_backend_herdr_pane_agent_state` / `fm_backend_herdr_agent_state`:

- stale `done` binding over a bare shell → `no-agent` / `dead`
- `done` binding with a live omp foreground → `live` / `alive`
- closed pane → `dead` / `missing`

That path is the idle-shell proof (`fm_backend_herdr_pane_idle_shell_sample`), not JSON-only.
The corrected comment is in `herdr-classifier-docstring.txt`.
