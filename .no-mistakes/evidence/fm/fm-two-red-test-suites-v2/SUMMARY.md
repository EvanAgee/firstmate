# Test evidence: two red suites now honest about environment

## Machine facts (why the suites were red)
- Ancestry of a test run here: `zsh` <- `claude` <- `no-mistakes`. A real
  `claude` process IS in the ancestry, so the no-marker walk cannot bottom out
  at `unknown`.
- `chromium` on PATH is a broken stub: it execs
  `/Applications/Chromium.app/Contents/MacOS/Chromium`, which is not installed.
  So a browser is "found" but cannot render anything.

## 1. omp detection suite

Base commit f72f767a, this machine -> FAILS (reproduces the reported bug):

    not ok - no markers should detect unknown, got: claude (missing: 'unknown')

Branch, same machine -> passes with a loud skip:

    skip: ambient harness (claude) confirmed in this run's process ancestry;
    the no-marker walk cannot bottom out at unknown here

### The skip is not a blanket pass
Run detached from the claude ancestor (ancestry is just `bash`, no harness):
- branch suite -> passes, prints NO skip line, fully assertive.
- branch suite pointed at a detector whose layer-2 ancestry walk is regressed
  (always answers `claude` instead of walking) -> FAILS:

      not ok - no markers should detect unknown, got: claude (missing: 'unknown')

So a genuine detector regression on clean CI still fails. The skip only fires
when a harness really is in the ancestry.

## 2. calm Pi extension suite

Branch, this machine (broken chromium stub) -> passes, DOM assertion skipped
loudly, every other test still runs:

    skip: headless Chrome cannot render even a minimal control page in this
    environment; the rendered-export DOM assertion requires a working
    display/GPU, the rest of the E2E still runs

### Still fully assertive where the browser works
Real Chrome exists at /Applications/Google Chrome.app and renders the control
page fine. Re-run with FM_CHROME_BIN pointed at it:
- 3 consecutive runs, all exit 0.
- ZERO skip lines. The rendered-export DOM assertion actually executed each time.

### The DOM assertion still bites
Fed the suite's real DOM checker some deliberately broken exports:
- valid DOM                      -> exit 0
- hook-message leaked into chat  -> exit 1
- missing operational row        -> exit 1
- synthetic input leaked         -> exit 1

## 3. Folded flake fix
The restore assertion now uses `wait_for_text`, which re-captures the tmux pane
each poll, matching its two siblings a few lines above. 3 of 3 consecutive
assertive runs green, no flake.
