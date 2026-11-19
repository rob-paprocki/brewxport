#!/bin/bash
# Wraps a notarized BrewxPort.app in an installer package and leaves BrewxPort-<version>.pkg next to the app:
#
#   1. copies the app with ditto into a payload folder and builds a component package with pkgbuild
#      (identifier com.brewxport.app.pkg, install location /Applications, not relocatable, so it always lands in
#      /Applications even when another copy of the app is somewhere else; no pre- or postinstall scripts: the
#      helper registers itself when the app first starts)
#   2. builds a distribution package with productbuild (title BrewxPort, macOS 15 or later, x86_64 and arm64),
#      signed with the Developer ID Installer identity and a secure timestamp, and checks it with
#      `pkgutil --check-signature`
#   3. with --notarize: submits it with `xcrun notarytool submit --keychain-profile PROFILE --wait`, stops unless
#      the status is Accepted, staples the ticket and checks it with Gatekeeper (`spctl -a -vvv -t install` must
#      say Notarized Developer ID)
#   4. expands the package (`pkgutil --expand-full`) and checks what it would install: BrewxPort.app at
#      /Applications, three universal binaries, a valid signature, the app's stapled ticket (with --notarize),
#      no /Users/ path in any binary, and no scripts
#
# usage: scripts/make-pkg.sh APP --sign SHA1 [--keychain PATH] (--notarize PROFILE | --unnotarized)
#
#   APP            the signed BrewxPort.app. With --notarize it must already be notarized and stapled
#                  (scripts/build-app.sh --notarize PROFILE --pkg does both, in that order).
#   --sign         the SHA-1 of the Developer ID Installer identity, as build-app.sh resolved it. Never printed.
#   --keychain     sign from this keychain only (a CI temporary keychain).
#   --notarize     the notarytool keychain profile. Every release is made this way.
#   --unnotarized  skip notarization, for tests only. The package is named BrewxPort-<version>-unnotarized.pkg.
#
# A finished package is left only when every step passed: a failed step removes it.
set -euo pipefail

die() { echo "make-pkg: $*" >&2; exit 1; }

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
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument: $1 (see --help)" ;;
        *) [ -z "$APP" ] || die "only one app, please"; APP="$1"; shift ;;
    esac
done
[ -n "$APP" ] || die "usage: scripts/make-pkg.sh APP --sign SHA1 [--keychain PATH] (--notarize PROFILE | --unnotarized)"
[ -d "$APP" ] && [ -f "$APP/Contents/Info.plist" ] || die "no app bundle at $APP"
[[ "$SIGN_SHA" =~ ^[0-9A-F]{40}$ ]] || die "--sign needs the installer identity's SHA-1 (40 hex digits, upper case)"
if [ -n "$PROFILE" ] && [ "$UNNOTARIZED" -eq 1 ]; then die "--notarize and --unnotarized don't go together"; fi
if [ -z "$PROFILE" ] && [ "$UNNOTARIZED" -eq 0 ]; then die "pass --notarize PROFILE (or --unnotarized for a test)"; fi
if [ -n "$PROFILE" ]; then
    [[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || die "the keychain profile name may hold only letters, digits, . _ -"
fi
if [ -n "$KEYCHAIN" ]; then [ -f "$KEYCHAIN" ] || die "no keychain at $KEYCHAIN"; fi
[ ! -e "$APP/Contents/Resources/DemoFixtures" ] || die "the app has demo fixtures; a package never ships them"

APP="$(cd "$APP" && pwd)"
OUT="$(dirname "$APP")"
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString isn't X.Y.Z"
PKG_ID="com.brewxport.app.pkg"
if [ "$UNNOTARIZED" -eq 1 ]; then PKG="$OUT/BrewxPort-$VERSION-unnotarized.pkg"; else PKG="$OUT/BrewxPort-$VERSION.pkg"; fi
BINARIES="Contents/MacOS/BrewxPort Contents/MacOS/brewxport-askpass Contents/Library/HelperTools/BrewxPortHelper"

if [ -n "$PROFILE" ]; then
    xcrun stapler validate "$APP" >/dev/null 2>&1 ||
        die "the app has no stapled ticket; notarize it first (scripts/build-app.sh --notarize PROFILE --pkg)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-pkg.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"
FINISHED=0
cleanup() {
    rm -rf "$WORK"
    [ "$FINISHED" -eq 1 ] || rm -f "$PKG"
}
trap cleanup EXIT

# --- Build and sign ---------------------------------------------------------------------------------------

echo "==> building the component package ($PKG_ID $VERSION, installs to /Applications)"
mkdir -p "$WORK/root" "$WORK/packages"
ditto "$APP" "$WORK/root/BrewxPort.app"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
count="$(plutil -convert json -o - "$WORK/component.plist" | grep -o '"RootRelativeBundlePath"' | wc -l | tr -d ' ')"
[ "$count" -ge 1 ] || die "pkgbuild found no bundle in the payload"
i=0
while [ "$i" -lt "$count" ]; do
    plutil -replace "$i.BundleIsRelocatable" -bool false "$WORK/component.plist"
    i=$((i + 1))
done
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --identifier "$PKG_ID" \
    --version "$VERSION" --install-location /Applications "$WORK/packages/BrewxPort-component.pkg" >/dev/null

echo "==> building the signed distribution package $(basename "$PKG")"
cat >"$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>BrewxPort</title>
    <options customize="never" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
    <allowed-os-versions>
        <os-version min="15.0"/>
    </allowed-os-versions>
    <choices-outline>
        <line choice="default">
            <line choice="$PKG_ID"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$PKG_ID" visible="false">
        <pkg-ref id="$PKG_ID"/>
    </choice>
    <pkg-ref id="$PKG_ID" version="$VERSION" onConclusion="none">BrewxPort-component.pkg</pkg-ref>
</installer-gui-script>
XML
PRODUCTBUILD=(productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK/packages"
    --sign "$SIGN_SHA" --timestamp)
if [ -n "$KEYCHAIN" ]; then PRODUCTBUILD+=(--keychain "$KEYCHAIN"); fi
rm -f "$PKG"
"${PRODUCTBUILD[@]}" "$PKG" >/dev/null 2>&1 || die "productbuild failed"

# pkgutil's output names the signer and team; only the parts checked are printed.
signature="$(pkgutil --check-signature "$PKG" 2>&1)" || die "pkgutil --check-signature rejected the package"
[[ "$signature" == *"Developer ID Installer:"* ]] || die "the package isn't signed with a Developer ID Installer identity"
[[ "$signature" == *"Signed with a trusted timestamp"* ]] || die "the package's signature has no trusted timestamp"
echo "    signed with a Developer ID Installer identity and a trusted timestamp"

# --- Notarize -----------------------------------------------------------------------------------------------

if [ -n "$PROFILE" ]; then
    echo "==> submitting the package to Apple's notary service (profile $PROFILE); this waits for the result"
    RESULT="$WORK/notary.json"
    submitted=0
    xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait --output-format json >"$RESULT" || submitted=$?
    status="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || true)"
    id="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        if [ -n "$id" ]; then
            die "notarization status is '${status:-unknown}', not Accepted (submission id $id). Read why with: xcrun notarytool log $id --keychain-profile $PROFILE"
        fi
        die "notarytool gave no result (exit $submitted); check the profile with: xcrun notarytool history --keychain-profile $PROFILE"
    fi
    echo "    Accepted (submission id $id)"

    echo "==> stapling the ticket to the package"
    xcrun stapler staple "$PKG" || die "stapling the package failed"
    xcrun stapler validate "$PKG" || die "the package's stapled ticket doesn't validate"

    echo "==> checking the package with Gatekeeper"
    assessment="$(spctl -a -vvv -t install "$PKG" 2>&1)" ||
        die "Gatekeeper rejected the package; see: spctl -a -vvv -t install $PKG"
    [[ "$assessment" == *"source=Notarized Developer ID"* ]] ||
        die "Gatekeeper doesn't see the package as notarized; see: spctl -a -vvv -t install $PKG"
    echo "    accepted, source=Notarized Developer ID"
fi

# --- Check what it would install ----------------------------------------------------------------------------

echo "==> expanding the package to check it"
pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null || die "pkgutil --expand-full failed"
COMPONENT="$WORK/expanded/BrewxPort-component.pkg"
[ -d "$COMPONENT" ] || die "the package holds no BrewxPort-component.pkg"
dist="$(cat "$WORK/expanded/Distribution")"
[[ "$dist" == *'hostArchitectures="x86_64,arm64"'* && "$dist" == *'<os-version min="15.0"/>'* &&
    "$dist" == *"<title>BrewxPort</title>"* ]] || die "the distribution lacks its title, architectures or macOS 15 floor"
info="$(cat "$COMPONENT/PackageInfo")"
[[ "$info" == *"identifier=\"$PKG_ID\""* && "$info" == *"version=\"$VERSION\""* &&
    "$info" == *'install-location="/Applications"'* ]] || die "PackageInfo has the wrong identifier, version or location"
# pkgbuild writes an empty <relocate/> either way; a relocatable bundle shows up inside a <relocate> element.
[[ "$info" == *'relocatable="false"'* && "$info" != *"<relocate>"* ]] ||
    die "the package is relocatable; it must always install to /Applications"
# A script shows up as <preinstall file=…/> or <postinstall file=…/>; postinstall-action="none" is not one.
[ ! -e "$COMPONENT/Scripts" ] && [[ "$info" != *"<preinstall "* && "$info" != *"<postinstall "* ]] ||
    die "the package has install scripts"
extra="$(cd "$COMPONENT/Payload" && ls -A | grep -Ev '^BrewxPort\.app$' || true)"
[ -d "$COMPONENT/Payload/BrewxPort.app" ] && [ -z "$extra" ] || die "the payload isn't BrewxPort.app alone"
echo "    installs BrewxPort.app ($PKG_ID $VERSION) to /Applications, not relocatable, no scripts"

PAYLOAD_APP="$COMPONENT/Payload/BrewxPort.app"
for rel in $BINARIES; do
    path="$PAYLOAD_APP/$rel"
    [ -x "$path" ] || die "the package's app has no $rel"
    archs="$(lipo -archs "$path" 2>/dev/null || true)"
    [ "$(printf '%s\n' $archs | sort | tr '\n' ' ')" = "arm64 x86_64 " ] ||
        die "$(basename "$rel") in the package is '$archs', not universal"
    in_symbols="$(nm -ap "$path" 2>/dev/null | grep -c '/Users/' || true)"
    in_strings="$(strings -a "$path" | grep -c '/Users/' || true)"
    [ "$in_symbols" -eq 0 ] && [ "$in_strings" -eq 0 ] ||
        die "$(basename "$rel") in the package holds build-machine paths (/Users/: $in_symbols in its symbols, $in_strings in its strings)"
    echo "    $(basename "$rel"): arm64 x86_64, no /Users/ paths"
done
codesign --verify --strict --deep "$PAYLOAD_APP" >/dev/null 2>&1 ||
    die "the app in the package doesn't pass codesign --verify --strict --deep"
echo "    the app's signature verifies"
if [ -n "$PROFILE" ]; then
    xcrun stapler validate "$PAYLOAD_APP" >/dev/null 2>&1 || die "the app in the package has no stapled ticket"
    echo "    the app in the package has its stapled ticket"
fi

FINISHED=1
if [ "$UNNOTARIZED" -eq 1 ]; then echo "warning: $(basename "$PKG") isn't notarized; it's for tests only" >&2; fi
echo "made $PKG"
