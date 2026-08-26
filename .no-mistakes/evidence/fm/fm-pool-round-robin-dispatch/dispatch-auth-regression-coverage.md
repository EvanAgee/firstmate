## Regression coverage

`tests/fm-vendor-auth-probe.test.sh` drives the real script against a fake vendor CLI that records every invocation's argv and anything readable on stdin.
It asserts that the script accepts no harness, model, or provider input, never calls `quota-axi`, exits alike for every probe result because it renders no verdict, invokes only the two fixed non-destructive argv forms with stdin closed, holds a real bound even when the configured bound is zero or malformed, and never echoes raw vendor output.
`tests/fm-spawn-dispatch-profile.test.sh` owns spawn's deterministic profile and harness refusals.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
`tests/fm-quota-array-dispatch-live-e2e.test.sh` drives the public Pi skill-loading interface against one fake `quota-axi --json` snapshot per case.
It covers round-robin fewest-live-workers selection, the quota-headroom tie-break when live counts are equal, and the strongest-reasoning-class constraint.
The equal-live tie-break case also holds the unmeasurable-runway invariant: a member with unmeasurable runway stays eligible rather than being dropped, and loses the tie only on lower known headroom.
