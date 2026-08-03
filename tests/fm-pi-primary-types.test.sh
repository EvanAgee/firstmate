#!/usr/bin/env bash
# Strict no-emit contract check for the tracked Firstmate Pi extensions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v npm >/dev/null 2>&1 || { echo "skip: npm not found for Pi extension typecheck"; exit 0; }
command -v tsc >/dev/null 2>&1 || { echo "skip: tsc not found for Pi extension typecheck"; exit 0; }

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
if [ ! -d "$PI_PACKAGE_DIR/node_modules/typebox" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" ] || \
   [ ! -d "$PI_PACKAGE_DIR/node_modules/@types/node" ]; then
  echo "not ok - installed Pi package is missing pi-tui, typebox, or Node declarations" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/adapter/.pi/extensions/lib" "$TMP_ROOT/adapter/bin" \
  "$TMP_ROOT/node_modules/@earendil-works" "$TMP_ROOT/node_modules/@types"
# Keep the pre-existing Calm/turn-end fixture layout stable so adapter imports cannot perturb unrelated type coverage.
cp "$ROOT/.pi/extensions/fm-calm.ts" "$TMP_ROOT/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$TMP_ROOT/fm-primary-turnend-guard.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$TMP_ROOT/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$TMP_ROOT/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$TMP_ROOT/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/lib/fm-operational-input.ts"
# Compile the public Pi adapter at its real relative path so the extracted core is reached transitively rather than imported as a test-only internal module.
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$TMP_ROOT/adapter/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$TMP_ROOT/adapter/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$TMP_ROOT/adapter/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/bin/fm-primary-watch-core.ts" "$TMP_ROOT/adapter/bin/fm-primary-watch-core.ts"
cp "$ROOT/bin/fm-pi-compatible-runtimes" "$TMP_ROOT/adapter/bin/fm-pi-compatible-runtimes"
ln -s "$PI_PACKAGE_DIR" "$TMP_ROOT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$TMP_ROOT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_PACKAGE_DIR/node_modules/typebox" "$TMP_ROOT/node_modules/typebox"
ln -s "$PI_PACKAGE_DIR/node_modules/@types/node" "$TMP_ROOT/node_modules/@types/node"

cat > "$TMP_ROOT/package.json" <<'JSON'
{"type":"module"}
JSON
cat > "$TMP_ROOT/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["fm-calm.ts", "fm-primary-turnend-guard.ts", "lib/*.ts"]
}
JSON
cat > "$TMP_ROOT/tsconfig-adapter.json" <<'JSON'
{
  "compilerOptions": {
    "allowImportingTsExtensions": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "noEmit": true,
    "skipLibCheck": true,
    "strict": true,
    "target": "ES2022",
    "types": ["node"]
  },
  "include": ["adapter/.pi/extensions/fm-primary-pi-watch.ts", "adapter/bin/*.ts"]
}
JSON

tsc -p "$TMP_ROOT/tsconfig-adapter.json" || exit 1
tsc -p "$TMP_ROOT/tsconfig.json" || exit 1
version=$(jq -r '.version' "$PI_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - tracked Pi extensions pass strict no-emit typecheck against Pi %s\n' "$version"
