#!/bin/bash
# Notarizes a signed BrewxPort.app and leaves the release download next to it:
#
#   1. zips the app with ditto into BrewxPort-<version>.zip (the version from its Info.plist)
#   2. submits the zip with `xcrun notarytool submit --keychain-profile PROFILE --wait`
#   3. stops unless the status is Accepted, and prints the submission id for `xcrun notarytool log`
#   4. staples the ticket to the app (`xcrun stapler staple`) and validates it
#   5. zips the stapled app again, so the download works offline too
#   6. checks the app with Gatekeeper: `spctl -a -vvv -t exec` must accept it as Notarized Developer ID
#
# usage: scripts/notarize.sh APP PROFILE
#
#   APP      the signed BrewxPort.app (scripts/build-app.sh --notarize PROFILE calls this for you)
#   PROFILE  a notarytool keychain profile, made once with `xcrun notarytool store-credentials`.
#            The Apple ID's app-specific password lives in the keychain, never in a file here.
set -euo pipefail

die() { echo "notarize: $*" >&2; exit 1; }

[ $# -eq 2 ] || die "usage: scripts/notarize.sh APP PROFILE"
APP="$1"
PROFILE="$2"
[ -d "$APP" ] && [ -f "$APP/Contents/Info.plist" ] || die "no app bundle at $APP"
[[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "the keychain profile name may hold only letters, digits, . _ -"

APP="$(cd "$APP" && pwd)"
OUT="$(dirname "$APP")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString isn't X.Y.Z"
ZIP="$OUT/BrewxPort-$VERSION.zip"
RESULT="$(mktemp "${TMPDIR:-/tmp}/brewxport-notary.XXXXXX")"
FINISHED=0
# A zip is left behind only when every step below passed: a failed staple or check removes it.
trap 'rm -f "$RESULT"; [ "$FINISHED" -eq 1 ] || rm -f "$ZIP"' EXIT

zip_app() {
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
}

echo "==> zipping $(basename "$APP") into $(basename "$ZIP")"
zip_app

echo "==> submitting to Apple's notary service (profile $PROFILE); this waits for the result"
submitted=0
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT" || submitted=$?
status="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
id="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
if [ "$status" != "Accepted" ]; then
    rm -f "$ZIP"
    if [ -n "$id" ]; then
        die "notarization status is '${status:-unknown}', not Accepted (submission id $id). Read why with: xcrun notarytool log $id --keychain-profile $PROFILE"
    fi
    die "notarytool gave no result (exit $submitted); check the profile with: xcrun notarytool history --keychain-profile $PROFILE"
fi
echo "    Accepted (submission id $id)"

echo "==> stapling the ticket to the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> zipping the stapled app"
zip_app

echo "==> checking with Gatekeeper"
# spctl's own output names the signer and team; like build-app.sh, this script never prints them.
assessment="$(spctl -a -vvv -t exec "$APP" 2>&1)" ||
    { rm -f "$ZIP"; die "Gatekeeper rejected the app; see: spctl -a -vvv -t exec $APP"; }
[[ "$assessment" == *"source=Notarized Developer ID"* ]] ||
    { rm -f "$ZIP"; die "Gatekeeper doesn't see the app as notarized; see: spctl -a -vvv -t exec $APP"; }
echo "    accepted, source=Notarized Developer ID"

FINISHED=1
echo "notarized $ZIP"
