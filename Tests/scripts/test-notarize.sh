#!/bin/bash
# Tests scripts/notarize.sh with stand-ins for xcrun (notarytool, stapler) and spctl, so it runs anywhere on a Mac
# without an Apple ID or a signing identity: an Accepted submission is stapled, re-zipped and checked; anything
# else stops with the submission id and leaves no zip behind; Gatekeeper's signer details are never printed.
#
# usage: Tests/scripts/test-notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/notarize.sh"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$SCRIPT" && pass "bash -n scripts/notarize.sh" || fail "bash -n scripts/notarize.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-notarize-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/xcrun" <<'STUB'
#!/bin/bash
echo "xcrun $*" >>"$STUB_LOG"
case "$1 $2" in
    "notarytool submit") printf '%s' "$NOTARY_JSON"; exit "${NOTARY_RC:-0}" ;;
    "stapler staple"|"stapler validate") exit "${STAPLE_RC:-0}" ;;
esac
exit 3
STUB
cat >"$TMP/bin/spctl" <<'STUB'
#!/bin/bash
echo "spctl $*" >>"$STUB_LOG"
printf '%s\n' "$SPCTL_OUT" >&2
exit "${SPCTL_RC:-0}"
STUB
chmod 755 "$TMP/bin/xcrun" "$TMP/bin/spctl"

GOOD_SPCTL=$'/x/BrewxPort.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Signer Name (TEAM123456)'

new_app() { # dir
    rm -rf "$1"
    mkdir -p "$1/BrewxPort.app/Contents/MacOS"
    plutil -create xml1 "$1/BrewxPort.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 1.2.3 "$1/BrewxPort.app/Contents/Info.plist"
    echo bin >"$1/BrewxPort.app/Contents/MacOS/BrewxPort"
}

run() { # dir profile -> sets rc, out
    : >"$TMP/log"
    set +e
    out="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" "$SCRIPT" "$1/BrewxPort.app" "$2" 2>&1)"
    rc=$?
    set -e
}

# Accepted: zipped, submitted with the profile, stapled, validated, zipped again, assessed.
new_app "$TMP/a"
NOTARY_JSON='{"id":"11111111-2222-3333-4444-555555555555","status":"Accepted","message":"ok"}' \
    SPCTL_OUT="$GOOD_SPCTL" run "$TMP/a" brewxport-notary
[ "$rc" -eq 0 ] && pass "Accepted: exit 0" || fail "Accepted: exit $rc: $out"
[ -f "$TMP/a/BrewxPort-1.2.3.zip" ] && pass "Accepted: BrewxPort-1.2.3.zip made" || fail "Accepted: no zip"
grep -q -- "/a/BrewxPort-1.2.3.zip --keychain-profile brewxport-notary --wait" "$TMP/log" &&
    pass "Accepted: submitted with the profile and --wait" || fail "Accepted: submit call: $(cat "$TMP/log")"
grep -q "stapler staple" "$TMP/log" && grep -q "stapler validate" "$TMP/log" &&
    pass "Accepted: stapled and validated" || fail "Accepted: not stapled"
grep -q -- "spctl -a -vvv -t exec" "$TMP/log" && pass "Accepted: Gatekeeper check ran" || fail "Accepted: no spctl"
[[ "$out" != *"Signer Name"* && "$out" != *"TEAM123456"* ]] && pass "Accepted: signer and team not printed" ||
    fail "Accepted: printed the signer or team"
[[ "$(unzip -l "$TMP/a/BrewxPort-1.2.3.zip")" == *"BrewxPort.app/Contents/Info.plist"* ]] &&
    pass "Accepted: the zip holds BrewxPort.app" || fail "Accepted: zip contents"

# Invalid: stops with the id and the log command, no zip, nothing stapled.
new_app "$TMP/b"
NOTARY_JSON='{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","status":"Invalid","message":"bad"}' NOTARY_RC=1 \
    SPCTL_OUT="$GOOD_SPCTL" run "$TMP/b" brewxport-notary
[ "$rc" -ne 0 ] && pass "Invalid: fails" || fail "Invalid: exit 0"
[[ "$out" == *"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* && "$out" == *"xcrun notarytool log"* ]] &&
    pass "Invalid: prints the submission id and the log command" || fail "Invalid: message: $out"
[ ! -e "$TMP/b/BrewxPort-1.2.3.zip" ] && pass "Invalid: no zip left" || fail "Invalid: zip left behind"
! grep -q "stapler" "$TMP/log" && pass "Invalid: nothing stapled" || fail "Invalid: stapled"

# In Progress (a --wait that gave up) and no result at all both fail.
new_app "$TMP/c"
NOTARY_JSON='{"id":"x","status":"In Progress"}' SPCTL_OUT="$GOOD_SPCTL" run "$TMP/c" brewxport-notary
[ "$rc" -ne 0 ] && pass "In Progress: fails" || fail "In Progress: exit 0"
new_app "$TMP/d"
NOTARY_JSON='' NOTARY_RC=69 SPCTL_OUT="$GOOD_SPCTL" run "$TMP/d" brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/d/BrewxPort-1.2.3.zip" ] && pass "no result: fails, no zip" || fail "no result: $out"

# Gatekeeper must say Notarized Developer ID; a rejection's details are not printed either.
new_app "$TMP/e"
NOTARY_JSON='{"id":"y","status":"Accepted"}' SPCTL_OUT=$'accepted\nsource=Developer ID\norigin=Signer Name (TEAM123456)' \
    run "$TMP/e" brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/e/BrewxPort-1.2.3.zip" ] && pass "not notarized per Gatekeeper: fails, no zip" ||
    fail "not notarized per Gatekeeper: exit $rc"
[[ "$out" != *"TEAM123456"* ]] && pass "Gatekeeper failure doesn't print the team" || fail "printed the team"
new_app "$TMP/f"
NOTARY_JSON='{"id":"z","status":"Accepted"}' SPCTL_OUT="rejected" SPCTL_RC=3 run "$TMP/f" brewxport-notary
[ "$rc" -ne 0 ] && pass "Gatekeeper rejection: fails" || fail "Gatekeeper rejection: exit 0"

# Accepted but the staple fails: the first (unstapled) zip must not be left behind.
new_app "$TMP/h"
NOTARY_JSON='{"id":"s","status":"Accepted"}' STAPLE_RC=65 SPCTL_OUT="$GOOD_SPCTL" run "$TMP/h" brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/h/BrewxPort-1.2.3.zip" ] && pass "staple failure: fails, no zip" ||
    fail "staple failure: exit $rc, zip $(ls "$TMP/h")"

# Bad input.
new_app "$TMP/g"
NOTARY_JSON='{"id":"z","status":"Accepted"}' SPCTL_OUT="$GOOD_SPCTL" run "$TMP/g" 'bad profile;x'
[ "$rc" -ne 0 ] && ! grep -q notarytool "$TMP/log" && pass "bad profile name: refused before submitting" ||
    fail "bad profile name accepted"
plutil -replace CFBundleShortVersionString -string 1.2 "$TMP/g/BrewxPort.app/Contents/Info.plist"
NOTARY_JSON='{"id":"z","status":"Accepted"}' SPCTL_OUT="$GOOD_SPCTL" run "$TMP/g" brewxport-notary
[ "$rc" -ne 0 ] && pass "version that isn't X.Y.Z: refused" || fail "bad version accepted"

if [ "$failures" -eq 0 ]; then echo "test-notarize: all passed"; else echo "test-notarize: $failures failure(s)"; exit 1; fi
