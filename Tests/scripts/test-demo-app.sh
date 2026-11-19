#!/bin/bash
# Builds build/BrewxPortDemo.app with scripts/demo.sh (snapshot mode into a temp dir, so nothing stays open) and
# checks its layout and identity: com.brewxport.demo, "BrewxPort Demo", the BrewxPort binary, DemoFixtures, ad-hoc signed,
# and no BrewxPortHelper, launchd plist or brewxport-askpass anywhere inside.
#
# usage: Tests/scripts/test-demo-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/BrewxPortDemo.app"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$0" && pass "bash -n Tests/scripts/test-demo-app.sh" || fail "bash -n Tests/scripts/test-demo-app.sh"
bash -n "$ROOT/scripts/demo.sh" && pass "bash -n scripts/demo.sh" || fail "bash -n scripts/demo.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-demo-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Snapshot mode runs the bundle's binary directly and quits; the exit code doesn't matter here, only the bundle.
"$ROOT/scripts/demo.sh" --snapshot "$TMP/shots" >"$TMP/demo.log" 2>&1 || true

[ -x "$APP/Contents/MacOS/BrewxPort" ] && pass "Contents/MacOS/BrewxPort is executable" || fail "no Contents/MacOS/BrewxPort"
[ -d "$APP/Contents/Resources/DemoFixtures" ] && pass "DemoFixtures present" || fail "no DemoFixtures"
[ "$(ls "$APP/Contents/MacOS")" = BrewxPort ] && pass "MacOS holds only BrewxPort" || fail "extra files in MacOS"
PB=/usr/libexec/PlistBuddy
for pair in CFBundleIdentifier:com.brewxport.demo "CFBundleName:BrewxPort Demo" "CFBundleDisplayName:BrewxPort Demo" CFBundleExecutable:BrewxPort; do
    key="${pair%%:*}"; want="${pair#*:}"
    got="$("$PB" -c "Print :$key" "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [ "$got" = "$want" ] && pass "$key = $want" || fail "$key is '$got', wanted '$want'"
done
extra="$(find "$APP" \( -iname '*helper*' -o -iname '*.plist' -o -iname '*askpass*' \) ! -path "$APP/Contents/Info.plist" \
    ! -path "$APP/Contents/Resources/DemoFixtures/*" || true)"
[ -z "$extra" ] && pass "no helper, launchd plist or askpass in the bundle" || fail "unexpected files: $extra"
codesign --verify --deep "$APP" 2>/dev/null && pass "ad-hoc signature verifies" || fail "signature does not verify"

[ "$failures" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$failures failed" >&2
exit 1
