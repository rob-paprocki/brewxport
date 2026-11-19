#!/bin/bash
# Puts a signed BrewxPort.app on a disk image and leaves BrewxPort-<version>.dmg next to the app:
#
#   1. copies the app with ditto into a staging folder, next to a symlink to /Applications
#   2. makes a compressed image (UDZO, HFS+) with hdiutil, volume name "BrewxPort <version>"
#   3. signs the image with the Developer ID identity (secure timestamp)
#   4. with --notarize: submits the image with `xcrun notarytool submit --keychain-profile PROFILE --wait`, stops
#      unless the status is Accepted, staples the ticket to the image and checks it with Gatekeeper
#      (`spctl -a -vvv -t open --context context:primary-signature` must say Notarized Developer ID)
#   5. mounts the image read-only and checks what a downloader gets: the volume name, BrewxPort.app and the
#      /Applications link, three universal binaries (arm64 and x86_64), a valid signature, the app's stapled
#      ticket (with --notarize), and no /Users/ path in any binary
#
# usage: scripts/make-dmg.sh APP --sign SHA1 [--keychain PATH] (--notarize PROFILE | --unnotarized)
#
#   APP            the signed BrewxPort.app. With --notarize it must already be notarized and stapled
#                  (scripts/build-app.sh --notarize PROFILE --dmg does both, in that order).
#   --sign         the SHA-1 of the code-signing identity, as build-app.sh resolved it. Never printed.
#   --keychain     sign from this keychain only (a CI temporary keychain).
#   --notarize     the notarytool keychain profile. Every release is made this way.
#   --unnotarized  skip notarization, for local tests only. The image is named
#                  BrewxPort-<version>-unnotarized.dmg so it can't pass for a release download.
#
# A finished image is left only when every step passed: a failed step removes it and detaches the image.
set -euo pipefail

die() { echo "make-dmg: $*" >&2; exit 1; }

APP=""
SIGN_SHA=""
KEYCHAIN=""
PROFILE=""
UNNOTARIZED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --sign) [ $# -ge 2 ] || die "--sign needs a SHA-1"; SIGN_SHA="$2"; shift 2 ;;
        --keychain) [ $# -ge 2 ] || die "--keychain needs a value"; KEYCHAIN="$2"; shift 2 ;;
        --notarize) [ $# -ge 2 ] || die "--notarize needs a keychain profile"; PROFILE="$2"; shift 2 ;;
        --unnotarized) UNNOTARIZED=1; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument: $1 (see --help)" ;;
        *) [ -z "$APP" ] || die "only one app, please"; APP="$1"; shift ;;
    esac
done
[ -n "$APP" ] || die "usage: scripts/make-dmg.sh APP --sign SHA1 [--keychain PATH] (--notarize PROFILE | --unnotarized)"
[ -d "$APP" ] && [ -f "$APP/Contents/Info.plist" ] || die "no app bundle at $APP"
[[ "$SIGN_SHA" =~ ^[0-9A-F]{40}$ ]] || die "--sign needs the identity's SHA-1 (40 hex digits, upper case)"
if [ -n "$PROFILE" ] && [ "$UNNOTARIZED" -eq 1 ]; then die "--notarize and --unnotarized don't go together"; fi
if [ -z "$PROFILE" ] && [ "$UNNOTARIZED" -eq 0 ]; then die "pass --notarize PROFILE (or --unnotarized for a local test)"; fi
if [ -n "$PROFILE" ]; then
    [[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "the keychain profile name may hold only letters, digits, . _ -"
fi
if [ -n "$KEYCHAIN" ]; then [ -f "$KEYCHAIN" ] || die "no keychain at $KEYCHAIN"; fi
[ ! -e "$APP/Contents/Resources/DemoFixtures" ] || die "the app has demo fixtures; a disk image never ships them"

APP="$(cd "$APP" && pwd)"
OUT="$(dirname "$APP")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString isn't X.Y.Z"
VOLUME="BrewxPort $VERSION"
if [ "$UNNOTARIZED" -eq 1 ]; then DMG="$OUT/BrewxPort-$VERSION-unnotarized.dmg"; else DMG="$OUT/BrewxPort-$VERSION.dmg"; fi
BINARIES="Contents/MacOS/BrewxPort Contents/MacOS/brewxport-askpass Contents/Library/HelperTools/BrewxPortHelper"

if [ -n "$PROFILE" ]; then
    xcrun stapler validate "$APP" >/dev/null 2>&1 ||
        die "the app has no stapled ticket; notarize it first (scripts/build-app.sh --notarize PROFILE --dmg)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-dmg.XXXXXX")"
MOUNT=""
FINISHED=0
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
    [ "$FINISHED" -eq 1 ] || rm -f "$DMG"
}
trap cleanup EXIT

# --- Make and sign the image --------------------------------------------------------------------------------

echo "==> staging $(basename "$APP") and an Applications link"
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/BrewxPort.app"
ln -s /Applications "$WORK/stage/Applications"

echo "==> making $(basename "$DMG") (UDZO, volume \"$VOLUME\")"
rm -f "$DMG"
# hdiutil create now and then fails with "Resource busy"; a second try almost always works.
made=0
for attempt in 1 2 3; do
    if hdiutil create -volname "$VOLUME" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 \
        -ov -quiet "$DMG"; then made=1; break; fi
    echo "    hdiutil create failed (try $attempt of 3)" >&2
    rm -f "$DMG"
    sleep 2
done
[ "$made" -eq 1 ] || die "hdiutil create failed three times"

echo "==> signing the image (secure timestamp)"
CODESIGN=(codesign --force --timestamp --sign "$SIGN_SHA")
if [ -n "$KEYCHAIN" ]; then CODESIGN+=(--keychain "$KEYCHAIN"); fi
"${CODESIGN[@]}" "$DMG" >/dev/null 2>&1 || die "codesign failed on the image"
codesign --verify --strict "$DMG" >/dev/null 2>&1 || die "the image's signature doesn't verify"

# --- Notarize -----------------------------------------------------------------------------------------------

if [ -n "$PROFILE" ]; then
    echo "==> submitting the image to Apple's notary service (profile $PROFILE); this waits for the result"
    RESULT="$WORK/notary.json"
    submitted=0
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT" || submitted=$?
    status="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
    id="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        if [ -n "$id" ]; then
            die "notarization status is '${status:-unknown}', not Accepted (submission id $id). Read why with: xcrun notarytool log $id --keychain-profile $PROFILE"
        fi
        die "notarytool gave no result (exit $submitted); check the profile with: xcrun notarytool history --keychain-profile $PROFILE"
    fi
    echo "    Accepted (submission id $id)"

    echo "==> stapling the ticket to the image"
    xcrun stapler staple "$DMG" || die "stapling the image failed"
    xcrun stapler validate "$DMG" || die "the image's stapled ticket doesn't validate"

    echo "==> checking the image with Gatekeeper"
    # spctl's own output names the signer and team; this script never prints them.
    assessment="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1)" ||
        die "Gatekeeper rejected the image; see: spctl -a -vvv -t open --context context:primary-signature $DMG"
    [[ "$assessment" == *"source=Notarized Developer ID"* ]] ||
        die "Gatekeeper doesn't see the image as notarized; see: spctl -a -vvv -t open --context context:primary-signature $DMG"
    echo "    accepted, source=Notarized Developer ID"
fi

# --- Check what a downloader gets ---------------------------------------------------------------------------

echo "==> mounting the image read-only to check it"
mkdir -p "$WORK/mount"
hdiutil attach "$DMG" -nobrowse -readonly -noautoopen -mountpoint "$WORK/mount" -quiet ||
    die "hdiutil attach failed"
MOUNT="$WORK/mount"

name="$(diskutil info -plist "$MOUNT" | plutil -extract VolumeName raw -o - - 2>/dev/null || true)"
[ "$name" = "$VOLUME" ] || die "the volume is named '$name', not '$VOLUME'"
echo "    volume \"$VOLUME\""
[ -L "$MOUNT/Applications" ] && [ "$(readlink "$MOUNT/Applications")" = /Applications ] ||
    die "the image has no Applications link to /Applications"
[ -d "$MOUNT/BrewxPort.app" ] || die "the image has no BrewxPort.app"
extra="$(cd "$MOUNT" && ls -A | grep -Ev '^(BrewxPort\.app|Applications|\.fseventsd|\.Trashes|\.DS_Store)$' || true)"
[ -z "$extra" ] || die "the image holds something besides BrewxPort.app and Applications"
echo "    BrewxPort.app and the Applications link"

for rel in $BINARIES; do
    path="$MOUNT/BrewxPort.app/$rel"
    [ -x "$path" ] || die "the image's app has no $rel"
    archs="$(lipo -archs "$path" 2>/dev/null || true)"
    [ "$(printf '%s\n' $archs | sort | tr '\n' ' ')" = "arm64 x86_64 " ] ||
        die "$(basename "$rel") on the image is '$archs', not universal"
    in_symbols="$(nm -ap "$path" 2>/dev/null | grep -c '/Users/' || true)"
    in_strings="$(strings -a "$path" | grep -c '/Users/' || true)"
    [ "$in_symbols" -eq 0 ] && [ "$in_strings" -eq 0 ] ||
        die "$(basename "$rel") on the image holds build-machine paths (/Users/: $in_symbols in its symbols, $in_strings in its strings)"
    echo "    $(basename "$rel"): arm64 x86_64, no /Users/ paths"
done
codesign --verify --strict --deep "$MOUNT/BrewxPort.app" >/dev/null 2>&1 ||
    die "the app on the image doesn't pass codesign --verify --strict --deep"
echo "    the app's signature verifies"
if [ -n "$PROFILE" ]; then
    xcrun stapler validate "$MOUNT/BrewxPort.app" >/dev/null 2>&1 || die "the app on the image has no stapled ticket"
    echo "    the app on the image has its stapled ticket"
fi

hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet || die "hdiutil detach failed"
MOUNT=""

FINISHED=1
if [ "$UNNOTARIZED" -eq 1 ]; then echo "warning: $(basename "$DMG") isn't notarized; it's for local tests only" >&2; fi
echo "made $DMG"
