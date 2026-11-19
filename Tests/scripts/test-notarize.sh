#!/bin/bash
# Tests scripts/notarize.sh, scripts/make-dmg.sh and scripts/make-pkg.sh with stand-ins for xcrun (notarytool,
# stapler), spctl, codesign and lipo, and for the signing half of productbuild and pkgutil, so it runs anywhere on
# a Mac without an Apple ID or a signing identity: an Accepted submission is stapled, re-zipped (or re-imaged, or
# re-packaged) and checked; anything else stops with the submission id and leaves no zip, disk image or package
# behind; Gatekeeper's and pkgutil's signer details are never printed. The disk images are made, mounted and
# detached with the real hdiutil, and the packages are built and expanded with the real pkgbuild, productbuild
# (without --sign) and pkgutil.
#
# usage: Tests/scripts/test-notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/notarize.sh"
DMG_SCRIPT="$ROOT/scripts/make-dmg.sh"
PKG_SCRIPT="$ROOT/scripts/make-pkg.sh"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$SCRIPT" && pass "bash -n scripts/notarize.sh" || fail "bash -n scripts/notarize.sh"
bash -n "$DMG_SCRIPT" && pass "bash -n scripts/make-dmg.sh" || fail "bash -n scripts/make-dmg.sh"
bash -n "$PKG_SCRIPT" && pass "bash -n scripts/make-pkg.sh" || fail "bash -n scripts/make-pkg.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-notarize-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd)"   # the scripts print paths in this form (TMPDIR ends in a slash)
mkdir -p "$TMP/bin"
cat >"$TMP/bin/xcrun" <<'STUB'
#!/bin/bash
echo "xcrun $*" >>"$STUB_LOG"
case "$1 $2" in
    "notarytool submit") printf '%s' "$NOTARY_JSON"; exit "${NOTARY_RC:-0}" ;;
    "stapler staple") exit "${STAPLE_RC:-0}" ;;
    "stapler validate") case "$3" in *.app) exit "${APP_STAPLED_RC:-${STAPLE_RC:-0}}" ;; esac; exit "${STAPLE_RC:-0}" ;;
esac
exit 3
STUB
cat >"$TMP/bin/codesign" <<'STUB'
#!/bin/bash
echo "codesign $*" >>"$STUB_LOG"
exit "${CODESIGN_RC:-0}"
STUB
cat >"$TMP/bin/lipo" <<'STUB'
#!/bin/bash
echo "lipo $*" >>"$STUB_LOG"
[ "$1" = -archs ] && { echo "${LIPO_ARCHS:-x86_64 arm64}"; exit 0; }
exit 3
STUB
cat >"$TMP/bin/spctl" <<'STUB'
#!/bin/bash
echo "spctl $*" >>"$STUB_LOG"
printf '%s\n' "$SPCTL_OUT" >&2
exit "${SPCTL_RC:-0}"
STUB
# productbuild: the real one, without the signing arguments (no identity here).
cat >"$TMP/bin/productbuild" <<'STUB'
#!/bin/bash
echo "productbuild $*" >>"$STUB_LOG"
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --sign|--keychain) shift 2 ;;
        --timestamp) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
exec /usr/bin/productbuild "${args[@]}"
STUB
# pkgutil: --check-signature answers from PKGUTIL_SIG; everything else is the real pkgutil.
cat >"$TMP/bin/pkgutil" <<'STUB'
#!/bin/bash
echo "pkgutil $*" >>"$STUB_LOG"
if [ "$1" = --check-signature ]; then printf '%s\n' "$PKGUTIL_SIG"; exit "${PKGUTIL_RC:-0}"; fi
exec /usr/sbin/pkgutil "$@"
STUB
chmod 755 "$TMP/bin/xcrun" "$TMP/bin/spctl" "$TMP/bin/codesign" "$TMP/bin/lipo" "$TMP/bin/productbuild" "$TMP/bin/pkgutil"

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

# --- scripts/make-dmg.sh ------------------------------------------------------------------------------------

SHA="0123456789ABCDEF0123456789ABCDEF01234567"
GOOD_DMG_SPCTL=$'/x/BrewxPort-1.2.3.dmg: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Signer Name (TEAM123456)'

new_full_app() { # dir: an app with all three binaries, as build-app.sh lays them out
    new_app "$1"
    # pkgbuild only sees a bundle with an identifier and a package type.
    plutil -insert CFBundleIdentifier -string com.brewxport.app "$1/BrewxPort.app/Contents/Info.plist"
    plutil -insert CFBundlePackageType -string APPL "$1/BrewxPort.app/Contents/Info.plist"
    plutil -insert CFBundleExecutable -string BrewxPort "$1/BrewxPort.app/Contents/Info.plist"
    mkdir -p "$1/BrewxPort.app/Contents/Library/HelperTools"
    echo askpass >"$1/BrewxPort.app/Contents/MacOS/brewxport-askpass"
    echo helper >"$1/BrewxPort.app/Contents/Library/HelperTools/BrewxPortHelper"
    chmod 755 "$1/BrewxPort.app/Contents/MacOS/BrewxPort" "$1/BrewxPort.app/Contents/MacOS/brewxport-askpass" \
        "$1/BrewxPort.app/Contents/Library/HelperTools/BrewxPortHelper"
}

run_dmg() { # dir args... -> sets rc, out
    local dir="$1"; shift
    : >"$TMP/log"
    set +e
    out="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" "$DMG_SCRIPT" "$dir/BrewxPort.app" "$@" 2>&1)"
    rc=$?
    set -e
}

still_mounted() { hdiutil info | grep -c -- "$TMP" || true; }

# Accepted: imaged, signed, submitted with the profile, stapled, assessed as an opened file, checked mounted.
new_full_app "$TMP/m"
NOTARY_JSON='{"id":"99999999-2222-3333-4444-555555555555","status":"Accepted"}' SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/m" --sign "$SHA" --notarize brewxport-notary
DMG="$TMP/m/BrewxPort-1.2.3.dmg"
[ "$rc" -eq 0 ] && pass "dmg Accepted: exit 0" || fail "dmg Accepted: exit $rc: $out"
[ -f "$DMG" ] && pass "dmg Accepted: BrewxPort-1.2.3.dmg made" || fail "dmg Accepted: no image"
[ "$(printf '%s\n' "$out" | tail -1)" = "made $DMG" ] && pass "dmg Accepted: prints the image path last" ||
    fail "dmg Accepted: last line: $(printf '%s\n' "$out" | tail -1)"
grep -q -- "codesign --force --timestamp --sign $SHA $DMG" "$TMP/log" && pass "dmg Accepted: image signed with a timestamp" ||
    fail "dmg Accepted: codesign call: $(grep codesign "$TMP/log")"
grep -q -- "notarytool submit $DMG --keychain-profile brewxport-notary --wait" "$TMP/log" &&
    pass "dmg Accepted: the image itself is submitted with the profile and --wait" || fail "dmg Accepted: submit call"
grep -q -- "stapler staple $DMG" "$TMP/log" && grep -q -- "stapler validate $DMG" "$TMP/log" &&
    pass "dmg Accepted: image stapled and validated" || fail "dmg Accepted: image not stapled"
grep -q -- "spctl -a -vvv -t open --context context:primary-signature $DMG" "$TMP/log" &&
    pass "dmg Accepted: Gatekeeper open check ran" || fail "dmg Accepted: no spctl -t open"
grep -q -- "stapler validate $TMP/m/BrewxPort.app" "$TMP/log" && grep -q -- "stapler validate .*/mount/BrewxPort.app" "$TMP/log" &&
    pass "dmg Accepted: the app's ticket checked before imaging and on the image" || fail "dmg Accepted: app ticket checks"
[ "$(grep -c -- "lipo -archs .*/mount/BrewxPort.app/" "$TMP/log")" -eq 3 ] &&
    pass "dmg Accepted: all three binaries on the image checked for both architectures" || fail "dmg Accepted: lipo calls"
[[ "$out" != *"Signer Name"* && "$out" != *"TEAM123456"* && "$out" != *"$SHA"* ]] &&
    pass "dmg Accepted: signer, team and identity not printed" || fail "dmg Accepted: printed the signer, team or identity"
[ "$(still_mounted)" -eq 0 ] && pass "dmg Accepted: nothing left mounted" || fail "dmg Accepted: an image is still mounted"
if [ -f "$DMG" ]; then
    mkdir "$TMP/look"
    hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$TMP/look" -quiet
    [ "$(diskutil info -plist "$TMP/look" | plutil -extract VolumeName raw -o - -)" = "BrewxPort 1.2.3" ] &&
        pass "dmg Accepted: volume named BrewxPort 1.2.3" || fail "dmg Accepted: volume name"
    [ "$(readlink "$TMP/look/Applications")" = /Applications ] && pass "dmg Accepted: Applications link" ||
        fail "dmg Accepted: no Applications link"
    [ -x "$TMP/look/BrewxPort.app/Contents/Library/HelperTools/BrewxPortHelper" ] &&
        pass "dmg Accepted: the image holds BrewxPort.app" || fail "dmg Accepted: image contents"
    hdiutil detach "$TMP/look" -quiet
fi

# Invalid: stops with the id and the log command, no image, nothing stapled, nothing mounted.
new_full_app "$TMP/n"
NOTARY_JSON='{"id":"bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee","status":"Invalid"}' NOTARY_RC=1 SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/n" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && pass "dmg Invalid: fails" || fail "dmg Invalid: exit 0"
[[ "$out" == *"bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"* && "$out" == *"xcrun notarytool log"* ]] &&
    pass "dmg Invalid: prints the submission id and the log command" || fail "dmg Invalid: message: $out"
[ -z "$(ls "$TMP/n" | grep '\.dmg$' || true)" ] && pass "dmg Invalid: no image left" || fail "dmg Invalid: image left behind"
! grep -q "stapler staple" "$TMP/log" && pass "dmg Invalid: nothing stapled" || fail "dmg Invalid: stapled"

# Accepted, but the staple fails: no image.
new_full_app "$TMP/o"
NOTARY_JSON='{"id":"s","status":"Accepted"}' STAPLE_RC=65 APP_STAPLED_RC=0 SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/o" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/o/BrewxPort-1.2.3.dmg" ] && pass "dmg staple failure: fails, no image" ||
    fail "dmg staple failure: exit $rc"

# Gatekeeper must say Notarized Developer ID, and its details are not printed.
new_full_app "$TMP/p"
NOTARY_JSON='{"id":"t","status":"Accepted"}' SPCTL_OUT=$'accepted\nsource=Developer ID\norigin=Signer Name (TEAM123456)' \
    run_dmg "$TMP/p" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/p/BrewxPort-1.2.3.dmg" ] && pass "dmg not notarized per Gatekeeper: fails, no image" ||
    fail "dmg not notarized per Gatekeeper: exit $rc"
[[ "$out" != *"TEAM123456"* ]] && pass "dmg Gatekeeper failure doesn't print the team" || fail "dmg: printed the team"

# An app without a stapled ticket is refused before anything is imaged or submitted.
new_full_app "$TMP/q"
NOTARY_JSON='{"id":"u","status":"Accepted"}' APP_STAPLED_RC=65 SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/q" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && ! grep -q notarytool "$TMP/log" && ! grep -q codesign "$TMP/log" &&
    pass "dmg of an unstapled app: refused before imaging" || fail "dmg of an unstapled app: exit $rc"

# A binary that isn't universal, or that holds a home-folder path, fails the mounted check: no image, unmounted.
new_full_app "$TMP/r"
NOTARY_JSON='{"id":"v","status":"Accepted"}' LIPO_ARCHS=arm64 SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/r" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/r/BrewxPort-1.2.3.dmg" ] && [[ "$out" == *"not universal"* ]] &&
    pass "dmg with an arm64-only binary: fails, no image" || fail "dmg with an arm64-only binary: exit $rc: $out"
[ "$(still_mounted)" -eq 0 ] && pass "dmg failed check: nothing left mounted" || fail "dmg failed check: still mounted"
new_full_app "$TMP/s"
echo "/Users/somebody/src/x.swift" >>"$TMP/s/BrewxPort.app/Contents/MacOS/brewxport-askpass"
NOTARY_JSON='{"id":"w","status":"Accepted"}' SPCTL_OUT="$GOOD_DMG_SPCTL" \
    run_dmg "$TMP/s" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/s/BrewxPort-1.2.3.dmg" ] && [[ "$out" == *"build-machine paths"* ]] &&
    [[ "$out" != *"somebody"* ]] && pass "dmg with a /Users/ path: fails, counts only, no image" ||
    fail "dmg with a /Users/ path: exit $rc: $out"

# --unnotarized: a local-test image under its own name, with no notarytool or Gatekeeper call.
new_full_app "$TMP/t"
SPCTL_OUT="$GOOD_DMG_SPCTL" run_dmg "$TMP/t" --sign "$SHA" --unnotarized
[ "$rc" -eq 0 ] && [ -f "$TMP/t/BrewxPort-1.2.3-unnotarized.dmg" ] && [ ! -e "$TMP/t/BrewxPort-1.2.3.dmg" ] &&
    pass "dmg --unnotarized: BrewxPort-1.2.3-unnotarized.dmg only" || fail "dmg --unnotarized: exit $rc: $out"
! grep -q -e notarytool -e spctl -e stapler "$TMP/log" && pass "dmg --unnotarized: no notarytool, stapler or spctl" ||
    fail "dmg --unnotarized: called notarytool, stapler or spctl"

# Bad input is refused before anything runs.
new_full_app "$TMP/u"
for args in "--sign $SHA" "--sign $SHA --notarize p --unnotarized" "--sign abc --unnotarized" \
    "--sign $SHA --notarize bad;profile" "--unnotarized"; do
    # shellcheck disable=SC2086
    run_dmg "$TMP/u" $args
    [ "$rc" -ne 0 ] && [ ! -s "$TMP/log" ] && pass "dmg refuses: $args" || fail "dmg accepted: $args"
done
mkdir -p "$TMP/u/BrewxPort.app/Contents/Resources/DemoFixtures"
run_dmg "$TMP/u" --sign "$SHA" --unnotarized
[ "$rc" -ne 0 ] && [ ! -s "$TMP/log" ] && pass "dmg refuses an app with demo fixtures" || fail "dmg imaged demo fixtures"

# build-app.sh refuses the disk-image flags in the wrong company before it builds anything.
for args in "--dmg" "--dmg-unnotarized --notarize p" "--notarize p --dmg --dmg-unnotarized" \
    "--dmg-unnotarized --with-demo-fixtures" "--notarize p --dmg --with-demo-fixtures"; do
    set +e
    # shellcheck disable=SC2086
    bout="$("$ROOT/scripts/build-app.sh" $args --out "$TMP/never" 2>&1)"
    brc=$?
    set -e
    [ "$brc" -ne 0 ] && [ ! -e "$TMP/never" ] && [[ "$bout" == build-app:* ]] && pass "build-app refuses: $args" ||
        fail "build-app accepted: $args ($bout)"
done

# --- scripts/make-pkg.sh ------------------------------------------------------------------------------------

GOOD_SIG=$'Package "BrewxPort-1.2.3.pkg":\n   Status: signed by a developer certificate issued by Apple for distribution\n   Notarization: trusted by the Apple notary service\n   Signed with a trusted timestamp on: 2026-11-19 04:00:00 +0000\n   Certificate Chain:\n    1. Developer ID Installer: Signer Name (TEAM123456)'
GOOD_PKG_SPCTL=$'/x/BrewxPort-1.2.3.pkg: accepted\nsource=Notarized Developer ID\norigin=Developer ID Installer: Signer Name (TEAM123456)'

run_pkg() { # dir args... -> sets rc, out
    local dir="$1"; shift
    : >"$TMP/log"
    set +e
    out="$(PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" "$PKG_SCRIPT" "$dir/BrewxPort.app" "$@" 2>&1)"
    rc=$?
    set -e
}

# Accepted: built, signed with a timestamp, submitted, stapled, assessed for install, expanded and checked.
new_full_app "$TMP/pa"
NOTARY_JSON='{"id":"77777777-2222-3333-4444-555555555555","status":"Accepted"}' PKGUTIL_SIG="$GOOD_SIG" \
    SPCTL_OUT="$GOOD_PKG_SPCTL" run_pkg "$TMP/pa" --sign "$SHA" --notarize brewxport-notary
PKG="$TMP/pa/BrewxPort-1.2.3.pkg"
[ "$rc" -eq 0 ] && pass "pkg Accepted: exit 0" || fail "pkg Accepted: exit $rc: $out"
[ -f "$PKG" ] && pass "pkg Accepted: BrewxPort-1.2.3.pkg made" || fail "pkg Accepted: no package"
[ "$(printf '%s\n' "$out" | tail -1)" = "made $PKG" ] && pass "pkg Accepted: prints the package path last" ||
    fail "pkg Accepted: last line"
grep -q -- "productbuild .*--sign $SHA --timestamp" "$TMP/log" && pass "pkg Accepted: productbuild signs with a timestamp" ||
    fail "pkg Accepted: productbuild call: $(grep productbuild "$TMP/log")"
grep -q -- "pkgutil --check-signature $PKG" "$TMP/log" && pass "pkg Accepted: signature checked" || fail "pkg Accepted: no signature check"
grep -q -- "notarytool submit $PKG --keychain-profile brewxport-notary --wait" "$TMP/log" &&
    pass "pkg Accepted: the package itself is submitted" || fail "pkg Accepted: submit call"
grep -q -- "stapler staple $PKG" "$TMP/log" && pass "pkg Accepted: package stapled" || fail "pkg Accepted: not stapled"
grep -q -- "spctl -a -vvv -t install $PKG" "$TMP/log" && pass "pkg Accepted: Gatekeeper install check ran" ||
    fail "pkg Accepted: no spctl -t install"
[ "$(grep -c -- "lipo -archs .*/Payload/BrewxPort.app/" "$TMP/log")" -eq 3 ] &&
    pass "pkg Accepted: all three binaries in the payload checked" || fail "pkg Accepted: lipo calls"
[[ "$out" != *"Signer Name"* && "$out" != *"TEAM123456"* && "$out" != *"$SHA"* ]] &&
    pass "pkg Accepted: signer, team and identity not printed" || fail "pkg Accepted: printed the signer, team or identity"
if [ -f "$PKG" ]; then
    /usr/sbin/pkgutil --expand-full "$PKG" "$TMP/pa-x" >/dev/null
    info="$(cat "$TMP/pa-x/BrewxPort-component.pkg/PackageInfo")"
    dist="$(cat "$TMP/pa-x/Distribution")"
    [[ "$info" == *'identifier="com.brewxport.app.pkg"'* && "$info" == *'version="1.2.3"'* &&
        "$info" == *'install-location="/Applications"'* ]] && pass "pkg Accepted: com.brewxport.app.pkg 1.2.3 to /Applications" ||
        fail "pkg Accepted: PackageInfo"
    [[ "$info" == *'relocatable="false"'* && "$info" != *"<relocate>"* ]] && pass "pkg Accepted: not relocatable" || fail "pkg Accepted: relocatable"
    [[ "$info" != *"<preinstall "* && "$info" != *"<postinstall "* ]] && pass "pkg Accepted: no install scripts" || fail "pkg Accepted: scripts"
    [[ "$dist" == *"<title>BrewxPort</title>"* && "$dist" == *'hostArchitectures="x86_64,arm64"'* &&
        "$dist" == *'<os-version min="15.0"/>'* ]] && pass "pkg Accepted: title, both architectures, macOS 15 floor" ||
        fail "pkg Accepted: Distribution"
fi

# Invalid: stops with the id, no package, nothing stapled.
new_full_app "$TMP/pb"
NOTARY_JSON='{"id":"cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee","status":"Invalid"}' NOTARY_RC=1 PKGUTIL_SIG="$GOOD_SIG" \
    SPCTL_OUT="$GOOD_PKG_SPCTL" run_pkg "$TMP/pb" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [[ "$out" == *"cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee"* ]] && [ ! -e "$TMP/pb/BrewxPort-1.2.3.pkg" ] &&
    ! grep -q "stapler staple" "$TMP/log" && pass "pkg Invalid: fails with the id, no package, nothing stapled" ||
    fail "pkg Invalid: exit $rc: $out"

# Staple failure, a Gatekeeper answer that isn't notarized, a signature that isn't Developer ID Installer or
# has no timestamp: each fails and leaves no package.
new_full_app "$TMP/pc"
NOTARY_JSON='{"id":"s","status":"Accepted"}' STAPLE_RC=65 APP_STAPLED_RC=0 PKGUTIL_SIG="$GOOD_SIG" \
    SPCTL_OUT="$GOOD_PKG_SPCTL" run_pkg "$TMP/pc" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/pc/BrewxPort-1.2.3.pkg" ] && pass "pkg staple failure: fails, no package" ||
    fail "pkg staple failure: exit $rc"
new_full_app "$TMP/pd"
NOTARY_JSON='{"id":"t","status":"Accepted"}' PKGUTIL_SIG="$GOOD_SIG" \
    SPCTL_OUT=$'accepted\nsource=Developer ID\norigin=Developer ID Installer: Signer Name (TEAM123456)' \
    run_pkg "$TMP/pd" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/pd/BrewxPort-1.2.3.pkg" ] && [[ "$out" != *"TEAM123456"* ]] &&
    pass "pkg not notarized per Gatekeeper: fails, no package, team not printed" || fail "pkg Gatekeeper: exit $rc"
new_full_app "$TMP/pe"
NOTARY_JSON='{"id":"u","status":"Accepted"}' PKGUTIL_SIG=$'Status: signed\n   Signed with a trusted timestamp on: x\n    1. Developer ID Application: Signer Name (TEAM123456)' \
    SPCTL_OUT="$GOOD_PKG_SPCTL" run_pkg "$TMP/pe" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/pe/BrewxPort-1.2.3.pkg" ] && ! grep -q notarytool "$TMP/log" &&
    pass "pkg signed without a Developer ID Installer identity: refused before notarizing" || fail "pkg signer check: exit $rc"
new_full_app "$TMP/pf"
NOTARY_JSON='{"id":"v","status":"Accepted"}' PKGUTIL_SIG=$'Status: signed\n    1. Developer ID Installer: Signer Name (TEAM123456)' \
    SPCTL_OUT="$GOOD_PKG_SPCTL" run_pkg "$TMP/pf" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/pf/BrewxPort-1.2.3.pkg" ] && pass "pkg signature without a timestamp: refused" ||
    fail "pkg timestamp check: exit $rc"

# An unstapled app is refused before anything is built; a payload binary that isn't universal fails the check.
new_full_app "$TMP/pg"
NOTARY_JSON='{"id":"w","status":"Accepted"}' APP_STAPLED_RC=65 PKGUTIL_SIG="$GOOD_SIG" SPCTL_OUT="$GOOD_PKG_SPCTL" \
    run_pkg "$TMP/pg" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && ! grep -q -e productbuild -e notarytool "$TMP/log" && pass "pkg of an unstapled app: refused before building" ||
    fail "pkg of an unstapled app: exit $rc"
new_full_app "$TMP/ph"
NOTARY_JSON='{"id":"x","status":"Accepted"}' LIPO_ARCHS=x86_64 PKGUTIL_SIG="$GOOD_SIG" SPCTL_OUT="$GOOD_PKG_SPCTL" \
    run_pkg "$TMP/ph" --sign "$SHA" --notarize brewxport-notary
[ "$rc" -ne 0 ] && [ ! -e "$TMP/ph/BrewxPort-1.2.3.pkg" ] && [[ "$out" == *"not universal"* ]] &&
    pass "pkg with an x86_64-only binary: fails, no package" || fail "pkg x86_64-only: exit $rc: $out"

# --unnotarized, and bad input.
new_full_app "$TMP/pi"
PKGUTIL_SIG="$GOOD_SIG" run_pkg "$TMP/pi" --sign "$SHA" --unnotarized
[ "$rc" -eq 0 ] && [ -f "$TMP/pi/BrewxPort-1.2.3-unnotarized.pkg" ] && ! grep -q -e notarytool -e spctl -e stapler "$TMP/log" &&
    pass "pkg --unnotarized: BrewxPort-1.2.3-unnotarized.pkg, no notarytool, stapler or spctl" ||
    fail "pkg --unnotarized: exit $rc: $out"
new_full_app "$TMP/pj"
for args in "--sign $SHA" "--sign $SHA --notarize p --unnotarized" "--sign abc --unnotarized" "--sign $SHA --notarize bad;p"; do
    # shellcheck disable=SC2086
    run_pkg "$TMP/pj" $args
    [ "$rc" -ne 0 ] && [ ! -s "$TMP/log" ] && pass "pkg refuses: $args" || fail "pkg accepted: $args"
done
for args in "--pkg" "--notarize p --pkg --with-demo-fixtures"; do
    set +e
    # shellcheck disable=SC2086
    bout="$("$ROOT/scripts/build-app.sh" $args --out "$TMP/never" 2>&1)"
    brc=$?
    set -e
    [ "$brc" -ne 0 ] && [ ! -e "$TMP/never" ] && [[ "$bout" == build-app:* ]] && pass "build-app refuses: $args" ||
        fail "build-app accepted: $args ($bout)"
done

if [ "$failures" -eq 0 ]; then echo "test-notarize: all passed"; else echo "test-notarize: $failures failure(s)"; exit 1; fi
