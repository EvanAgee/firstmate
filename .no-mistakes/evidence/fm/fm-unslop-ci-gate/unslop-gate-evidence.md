# Unslop CI gate — end-to-end evidence

Tested `.github/workflows/unslop.yml` (unslop 0.1.7) against the author's intent.

## 1. Only error+gateable rules can fail the build
Unslop's own rule model (`unslop --list-rules`). Exactly two rules are
`severity=error` AND `gateable=true`:

```
id          | tier | severity | gateable
exact-clone |  A   | error    | true
dead-code   |  A   | error    | true
```

The workflow gates with `--fail-on exact-clone,dead-code` — precisely those two.
Every other rule is warning/info and non-gateable, so it stays report-only.

## 2. Gate FAILS on an error+gateable finding
Two identical exported functions -> exact-clone:

```
$ unslop --format json --fail-on exact-clone,dead-code src/a.js src/c.js
[ { "ruleId": "exact-clone", "tier": "A", "severity": "error", "gateable": true, ... } ]
unslop: quality gate failed: rule exact-clone
exit=1   # nonzero -> CI job fails (as intended)
```

## 3. Non-gateable code PASSES (warnings report-only)
Code with no exact-clone/dead-code finding:

```
$ unslop --format json --fail-on exact-clone,dead-code src/a.js
exit=0   # gate passes; warnings/info do not fail the build
```

## 4. Changed-file filter selects only supported code
PR touching README.md + src/a.js + src/b.js:

```
has_code=true
files selected:
  ./src/a.js
  ./src/b.js      # README.md correctly excluded
```

## 5. Docs-only PR is a fast no-op
PR touching only README.md + docs/guide.md:

```
has_code=false  ->  Set up Node / cache / install / scan steps ALL skipped (if: has_code == 'true')
```

## 6. This task's own change is a no-op for unslop
Only changed file is `.github/workflows/unslop.yml` — a `.yml`, not a supported
code extension, so unslop-against-own-changes is correctly a no-op.

## Workflow semantic model (parsed YAML)
- trigger: pull_request on `main`
- permissions: `contents: read`
- 6 steps; the 4 install/scan steps guard on `steps.changed.outputs.has_code == 'true'`
- npm download cache key pins `unslop-0.1.7-oxlint-1.50.0`; oxlint@1.50.0 pinned alongside unslop@0.1.7
