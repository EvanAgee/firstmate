# Red/green proof: the new tests fail on the old code

The new test cases were copied onto the base-commit tree (git archive 2b36faaf)
and run one at a time, so each case's own verdict is visible.

```
OLD CODE, case: test_post_acquire_prelaunch_failure_releases_route_claim_and_retries
  not ok - a pre-launch failure must release its claim, not close it (unexpected: '"profile-route-prelaunch-z6-t73575-2942"')

OLD CODE, case: test_bare_project_name_refuses_before_route_claim_and_retries
  not ok - route store changed for a spawn that failed before route admission:\n1c1

OLD CODE, case: test_mode_mismatch_refuses_before_route_claim
  not ok - route store changed for a spawn that failed before route admission:\n1c1

OLD CODE, case: test_omp_guard_refusal_releases_route_claim
  not ok - a pre-launch guard refusal must leave the route's recorded state untouched (missing: '"omp":{"state":"eligible"')

OLD CODE, case: test_genuine_launch_failure_records_launch_failed
  ok - a genuine launch failure after the harness process started still records launch-failed and excludes the route

OLD CODE, fm-route.sh release subcommand:
  error: unknown subcommand: release
```

# Green: the same tests on the fixed code (51ec7b0b)

```
$ bash tests/fm-spawn-route-admission.test.sh
ok - a class-based spawn acquires a route and finishes it successfully
ok - a class-based spawn excludes an exhausted route from an unpinned pool and lands on the eligible one
ok - a class-based spawn refuses to launch when every approved route is excluded
ok - a captain override bypasses provider-availability admission the same way it bypasses the enabled filter
ok - a post-acquire pre-launch failure releases its claim and the same task id retries immediately
ok - a bare project name fails before any route claim, leaving route.json byte-identical, and the retry launches
ok - a brief/mode disagreement fails before any route claim, route.json byte-identical
ok - a pre-launch harness guard refusal releases its claim and frees the task id
ok - a genuine launch failure after the harness process started still records launch-failed and excludes the route
ok - a pinned class spawn resolves to its pin on every tie-cursor rotation
ok - a switched-off pool member's route never wins admission for its class
ok - an already-closed assignment record never authorizes a fresh launch
ok - a spawn with no dispatch class never touches the route store
ok - a failed candidate lookup refuses the spawn instead of silently skipping admission
# all fm-spawn-route-admission tests passed

$ bash tests/fm-route.test.sh   (release cases only)
ok - release deletes a running record, leaves routes untouched, and frees the id
ok - release refuses a foreign owner and leaves the record untouched
ok - release never deletes closed history and is a no-op for a missing id
ok - release refuses malformed requests before writing anything
# all fm-route tests passed
```

Note: 'a genuine launch failure ... still records launch-failed' passes on BOTH
versions. That is intended. It is the preserved behavior, not a bug being fixed.
