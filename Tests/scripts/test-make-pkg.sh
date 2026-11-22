#!/bin/bash
# Builds an unnotarized installer package with scripts/make-pkg.sh and checks its distribution independently of
# the script's own checks: two package references (the app and the empty setup-engine marker), the "Set up
# Homebrew" / "Set up MacPorts" choices, ticked by default and picked by an isArm() test, the marker's empty
# payload, no scripts anywhere, and that Installer itself lists the choice for this Mac's architecture
# (`installer -showChoicesXML`, which installs nothing).
#
# This is a local and release-gate test: it needs signing identities, so it prints SKIP and exits 0 anywhere they
# are missing (plain CI, a fresh machine).
#
# usage: Tests/scripts/test-make-pkg.sh [--app BrewxPort.app] [--keychain PATH]
#   --app       a signed BrewxPort.app to wrap. Without it, one is built with scripts/build-app.sh.
#   --keychain  find the identities in, and sign from, this keychain only (a CI temporary keychain).
# Needs a Developer ID Application (unless --app is given) and a Developer ID Installer identity (set
# BREWXPORT_APP_SHA / BREWXPORT_INSTALLER_SHA to pick; otherwise the first of each is used) and the network
# (secure timestamps). It never notarizes and never installs the package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$ROOT/scripts/make-pkg.sh" && pass "bash -n scripts/make-pkg.sh" || fail "bash -n scripts/make-pkg.sh"
bash -n "$0" && pass "bash -n Tests/scripts/test-make-pkg.sh" || fail "bash -n Tests/scripts/test-make-pkg.sh"

APP=""
KEYCHAIN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) [ $# -ge 2 ] || { echo "--app needs a path" >&2; exit 2; }; APP="$2"; shift 2 ;;
        --keychain) [ $# -ge 2 ] || { echo "--keychain needs a path" >&2; exit 2; }; KEYCHAIN="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-pkg-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Prints the first matching identity's SHA-1, or nothing. Never fails, so a missing identity reaches the SKIP below.
sha() { # pattern
    local found=""
    if [ -n "$KEYCHAIN" ]; then
        found="$(security find-identity -v "$KEYCHAIN" 2>/dev/null | grep "$1" || true)"
    else
        found="$(security find-identity -v 2>/dev/null | grep "$1" || true)"
    fi
    printf '%s\n' "$found" | awk 'NR == 1 {print $2}'
}
app_sha=""
if [ -z "$APP" ]; then app_sha="${BREWXPORT_APP_SHA:-$(sha 'Developer ID Application')}"; fi
inst_sha="${BREWXPORT_INSTALLER_SHA:-$(sha 'Developer ID Installer')}"
if [ -z "$inst_sha" ] || { [ -z "$APP" ] && [ -z "$app_sha" ]; }; then
    echo "SKIP: no Developer ID identities in the keychain"
    exit 0
fi
KC=()
if [ -n "$KEYCHAIN" ]; then KC=(--keychain "$KEYCHAIN"); fi
if [ -z "$APP" ]; then
    "$ROOT/scripts/build-app.sh" --identity "$app_sha" ${KC[@]+"${KC[@]}"} --out "$TMP/out" >"$TMP/build.log" 2>&1 ||
        { tail -30 "$TMP/build.log" >&2; fail "build-app.sh failed"; exit 1; }
    APP="$TMP/out/BrewxPort.app"
fi

# make-pkg leaves the package next to the app, so work on a copy.
mkdir -p "$TMP/app"
ditto "$APP" "$TMP/app/BrewxPort.app"
if "$ROOT/scripts/make-pkg.sh" "$TMP/app/BrewxPort.app" --sign "$inst_sha" ${KC[@]+"${KC[@]}"} --unnotarized >"$TMP/pkg.log" 2>&1; then
    pass "make-pkg.sh exited 0"
else
    tail -30 "$TMP/pkg.log" >&2
    fail "make-pkg.sh failed"
    exit 1
fi
PKG="$(ls "$TMP"/app/BrewxPort-*-unnotarized.pkg)"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$TMP/app/BrewxPort.app/Contents/Info.plist")"

pkgutil --expand-full "$PKG" "$TMP/expanded" >/dev/null
dist="$(cat "$TMP/expanded/Distribution")"
has() { [[ "$dist" == *"$1"* ]]; } # $1 is literal text

has 'customize="allow"' && pass "Customize is offered" || fail "no customize=\"allow\""
has '<pkg-ref id="com.brewxport.app.pkg"' && pass "app pkg-ref" || fail "no com.brewxport.app.pkg pkg-ref"
has '<pkg-ref id="com.brewxport.setup-engine.pkg"' && pass "marker pkg-ref" || fail "no com.brewxport.setup-engine.pkg pkg-ref"
has "function isArm(){ var v = system.sysctl('hw.optional.arm64'); return v == 1; }" &&
    pass "isArm() script" || fail "no isArm() script"
grep -E '<choice id="setup-engine-homebrew"' <<<"$dist" | grep 'title="Set up Homebrew"' | grep -q 'visible="isArm()"' &&
    pass "Homebrew choice on Apple silicon" || fail "no Homebrew choice shown by isArm()"
grep -E '<choice id="setup-engine-macports"' <<<"$dist" | grep 'title="Set up MacPorts"' | grep -q 'visible="!isArm()"' &&
    pass "MacPorts choice on Intel" || fail "no MacPorts choice shown by !isArm()"
[ "$(grep -c 'start_selected="isArm()"\|start_selected="!isArm()"' <<<"$dist" | tr -d ' ')" = 2 ] &&
    pass "each setup choice starts ticked only on its own architecture" || fail "start_selected isn't tied to isArm()"
grep -E '<choice id="com\.brewxport\.app\.pkg"' <<<"$dist" | grep -q 'visible="false"' &&
    pass "the app choice is hidden, so always installed" || fail "the app choice isn't hidden"
[ "$(grep -c '<pkg-ref id="com.brewxport.setup-engine.pkg"[^>]*>[^<]' <<<"$dist" | tr -d ' ')" = 1 ] &&
    pass "one marker package file" || fail "the marker package isn't referenced exactly once"

MARKER="$TMP/expanded/BrewxPort-setup-engine.pkg"
[ -d "$MARKER" ] && pass "the marker component is in the package" || fail "no BrewxPort-setup-engine.pkg"
minfo="$(cat "$MARKER/PackageInfo" 2>/dev/null || true)"
[[ "$minfo" == *'identifier="com.brewxport.setup-engine.pkg"'* && "$minfo" == *"version=\"$VERSION\""* ]] &&
    pass "marker identifier and version $VERSION" || fail "marker PackageInfo has the wrong identifier or version"
if [ -d "$MARKER/Payload" ]; then
    [ -z "$(ls -A "$MARKER/Payload")" ] && pass "marker payload is empty" || fail "marker payload isn't empty"
else
    fail "marker has no Payload (an empty root should still write a receipt)"
fi
scripts="$(find "$TMP/expanded" \( -name Scripts -o -name preinstall -o -name postinstall \))"
if [ -z "$scripts" ] && [[ "$minfo" != *"<preinstall "* && "$minfo" != *"<postinstall "* ]]; then
    pass "no scripts anywhere"
else
    fail "the package has scripts"
fi

choices="$(installer -pkg "$PKG" -showChoicesXML -target / 2>&1 || true)"
if [ "$(uname -m)" = arm64 ]; then want="Set up Homebrew"; else want="Set up MacPorts"; fi
[[ "$choices" == *"<string>$want</string>"* ]] &&
    pass "installer -showChoicesXML lists \"$want\" for $(uname -m)" || fail "installer doesn't list \"$want\""

if [ "$failures" -eq 0 ]; then echo "all passed"; exit 0; fi
echo "$failures failure(s)" >&2
exit 1
