#!/usr/bin/env bash
# Evidence-only: public /rigs JSON plus bootstrap of the example pool config.
# Lives in the evidence directory, not the worktree.
set -u
ROOT="/Users/evanagee/.no-mistakes/worktrees/b99440365b40/01M0ZBGE371TMD4EA2400QJCFM"
EVID="/Users/evanagee/.no-mistakes/evidence/01M0ZBGE371TMD4EA2400QJCFM"
cd "$ROOT"
# shellcheck source=/dev/null
. tests/api-helpers.sh

home=$(fm_test_api_home evidence-rigs)
cat > "$home/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {
      "when": "The task is a builder assignment.",
      "use": [
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" },
        { "harness": "grok", "model": "grok-4", "effort": "high", "enabled": false }
      ]
    }
  ],
  "default": [
    { "harness": "pi", "model": "xai/grok-4.6", "effort": "medium" }
  ]
}
EOF
port=$(fm_test_api_start "$home")
resp=$(fm_test_api_http "$port" /rigs)
HTTP_CODE=
HTTP_BODY=
IFS= read -r HTTP_CODE <<<"$resp" || true
HTTP_BODY=$(printf '%s\n' "$resp" | tail -n +2)
printf '%s\n' "$HTTP_BODY" | python3 -m json.tool > "$EVID/rigs-pools.json"
printf 'HTTP %s\n' "$HTTP_CODE" > "$EVID/rigs-pools.meta.txt"
fm_test_api_stop "$home"

# Bootstrap the shipped example pool config in a hermetic home.
# shellcheck source=/dev/null
. tests/lib.sh
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
case_dir=$(fm_test_tmproot evidence-bootstrap-example)
mkdir -p "$case_dir/home/config"
printf '%s\n' manual > "$case_dir/home/config/backlog-backend"
cp "$ROOT/docs/examples/crew-dispatch.json" "$case_dir/home/config/crew-dispatch.json"
fakebin=$(fm_fakebin "$case_dir")
fm_fake_exit0 "$fakebin" tmux node
cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.29; exit 0; }
exit 0
SH
chmod +x "$fakebin/gh-axi"
cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin/gh"
cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
fi
exit 0
SH
chmod +x "$fakebin/treehouse"
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 'no-mistakes version v1.31.2 (fake)'; exit 0; }
exit 0
SH
chmod +x "$fakebin/no-mistakes"
cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.30; exit 0; }
exit 0
SH
chmod +x "$fakebin/chrome-devtools-axi"
cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.46; exit 0; }
exit 0
SH
chmod +x "$fakebin/lavish-axi"
cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '%s\n' 0.1.25; exit 0; }
exit 0
SH
chmod +x "$fakebin/quota-axi"
cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' 0.2.4; exit 0; fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --body-file <path>' '  --archive-body'
  exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
  exit 0
fi
exit 0
SH
chmod +x "$fakebin/tasks-axi"
real_jq=$(command -v jq)
cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
chmod +x "$fakebin/jq"

{
  echo "example keys: $(python3 -c 'import json; d=json.load(open("'"$case_dir/home/config/crew-dispatch.json"'")); print(sorted(d.keys()))')"
  echo "rule use types and split presence:"
  python3 - <<PY
import json
p="$case_dir/home/config/crew-dispatch.json"
d=json.load(open(p))
print("top-level split:", "split" in d)
for i,r in enumerate(d["rules"]):
    use=r["use"]
    kind="array" if isinstance(use, list) else "object"
    members=use if isinstance(use, list) else [use]
    print(f"rule[{i}] when={r['when'][:48]!r} use={kind} n={len(members)} split_on_rule={'split' in r}")
    for m in members:
        print("  member", {k:m.get(k) for k in ('harness','model','effort','enabled','split')})
print("default n=", len(d["default"]), "split_on_default=", any("split" in x for x in d["default"]))
PY
  echo "--- bootstrap (silent expected) ---"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  if [ -z "$out" ]; then
    echo "bootstrap: silent (example pool config accepted)"
  else
    echo "bootstrap output:"
    printf '%s\n' "$out"
  fi
  echo "--- bootstrap verbose ---"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh"
} > "$EVID/example-pool-bootstrap.txt" 2>&1
echo done
