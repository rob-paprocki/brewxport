#!/bin/bash
# Builds a signed, universal (arm64 + x86_64) BrewxPort.app:
#
#   BrewxPort.app/Contents/Info.plist
#   BrewxPort.app/Contents/MacOS/BrewxPort                                (com.brewxport.app)
#   BrewxPort.app/Contents/MacOS/brewxport-askpass                        (com.brewxport.askpass)
#   BrewxPort.app/Contents/Library/HelperTools/BrewxPortHelper            (com.brewxport.helper)
#   BrewxPort.app/Contents/Library/LaunchDaemons/com.brewxport.helper.plist
#
# usage: scripts/build-app.sh [--identity NAME] [--keychain PATH] [--out DIR] [--with-demo-fixtures]
#                             [--notarize PROFILE]
#
#   --identity  code-signing identity: a name (or part of one) or a SHA-1. Default: $BREWXPORT_SIGN_IDENTITY, else
#               "Developer ID Application". It must match exactly one valid identity.
#   --keychain  look for the identity in this keychain only, and sign from it (a CI temporary keychain).
#   --out       output directory (default: build/ at the top of the repository, which git ignores).
#   --with-demo-fixtures  also copy Tests/BrewxPortCoreTests/Fixtures to Contents/Resources/DemoFixtures, so
#               `BrewxPort --demo` works from the bundle. Never for a release: a release bundle has no fixtures.
#   --notarize  after the build, notarize and staple the app with this notarytool keychain profile and leave
#               BrewxPort-<version>.zip next to it (scripts/notarize.sh). Every release is built this way.
#
# The team ID is read from the identity's certificate (its OU) at build time and is never stored in the
# repository or printed. It goes into BrewxPortHelper's embedded Info.plist as BrewxPortClientRequirement, so the helper
# only talks to a com.brewxport.app signed by the same team.
#
# BrewxPortHelper is linked on its own: `swift build` applies -Xlinker flags to every product it links, and only the
# helper may carry the __TEXT,__info_plist section. BrewxPort and brewxport-askpass are built and copied out first,
# then BrewxPortHelper is built with the -sectcreate flags and copied out at once.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${BREWXPORT_SIGN_IDENTITY:-Developer ID Application}"
KEYCHAIN=""
OUT="$ROOT/build"
DEMO_FIXTURES=0
NOTARY_PROFILE=""

die() { echo "build-app: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) [ $# -ge 2 ] || die "--identity needs a value"; IDENTITY="$2"; shift 2 ;;
        --keychain) [ $# -ge 2 ] || die "--keychain needs a value"; KEYCHAIN="$2"; shift 2 ;;
        --out) [ $# -ge 2 ] || die "--out needs a value"; OUT="$2"; shift 2 ;;
        --with-demo-fixtures) DEMO_FIXTURES=1; shift ;;
        --notarize) [ $# -ge 2 ] || die "--notarize needs a keychain profile"; NOTARY_PROFILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$IDENTITY" ] || die "the signing identity is empty"
if [ -n "$NOTARY_PROFILE" ] && [ "$DEMO_FIXTURES" -eq 1 ]; then
    die "--notarize is for releases, and a release bundle has no demo fixtures"
fi
if [ -n "$KEYCHAIN" ]; then
    [ -f "$KEYCHAIN" ] || die "no keychain at $KEYCHAIN"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

# Warns when this Mac isn't marked as a development Mac: a normal launch of the BrewxPort.app this builds would
# register its admin helper here. Reads the marker only; it never sets it. A CI runner never launches the app.
if [ -z "${CI:-}" ] && ! defaults read com.brewxport.app BrewxPortDevelopmentMac 2>/dev/null | grep -qiE '^(1|true|yes)$'; then
    echo "warning: this Mac isn't marked as a development Mac, so a normal launch of BrewxPort.app here registers its" >&2
    echo "         admin helper. To mark it: defaults write com.brewxport.app BrewxPortDevelopmentMac -bool true" >&2
fi

APP="$OUT/BrewxPort.app"
WORK="$OUT/.brewxport-build"
BUNDLE_RES="$ROOT/Resources/bundle"
ARCHS="arm64 x86_64"
APP_ID="com.brewxport.app"
HELPER_ID="com.brewxport.helper"
ASKPASS_ID="com.brewxport.askpass"

rm -rf "$WORK" "$APP"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- Signing identity and team ------------------------------------------------------------------------------

keychain_args=()
if [ -n "$KEYCHAIN" ]; then keychain_args=("$KEYCHAIN"); fi

# Every valid identity as "SHA1<TAB>name", one per line, without duplicates.
identities="$(security find-identity -v -p codesigning ${keychain_args[@]+"${keychain_args[@]}"} |
    awk '/^ *[0-9]+\) [0-9A-F]{40} "/ {
        sha = $2; name = $0; sub(/^[^"]*"/, "", name); sub(/"[^"]*$/, "", name)
        if (!(sha in seen)) { seen[sha] = 1; print sha "\t" name }
    }')"
upper_identity="$(printf '%s' "$IDENTITY" | tr 'a-f' 'A-F')"
matches="$(printf '%s\n' "$identities" | awk -F'\t' -v want="$IDENTITY" -v sha="$upper_identity" '
    NF == 2 && ($1 == sha || index($2, want) > 0) { print $1 }')"
count="$(printf '%s' "$matches" | grep -c . || true)"
[ "$count" -ge 1 ] || die "no valid code-signing identity matches the one asked for"
[ "$count" -eq 1 ] || die "$count identities match; pass the SHA-1 of one with --identity"
SIGN_SHA="$matches"

# The certificate whose SHA-1 is SIGN_SHA, then its subject's OU.
TEAM="$(security find-certificate -a -Z -p ${keychain_args[@]+"${keychain_args[@]}"} |
    awk -v sha="$SIGN_SHA" '/^SHA-1 hash:/ { grab = ($3 == sha) } grab { print } /END CERTIFICATE/ && grab { exit }' |
    sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' |
    /usr/bin/openssl x509 -noout -subject -nameopt multiline 2>/dev/null |
    awk -F' = ' '/organizationalUnitName/ { print $2; exit }')"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || die "couldn't read a team ID from the identity's certificate"

# Same string as CodeIdentity.requirement(identifier:team:) and the test script's; change all three together.
# The last two clauses require a Developer ID chain (intermediate CA and Developer ID Application leaf).
requirement() { # identifier
    printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"' "$1" "$TEAM"
    printf ' and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
}
CLIENT_REQUIREMENT="$(requirement "$APP_ID")"

# --- Build --------------------------------------------------------------------------------------------------

SWIFT=(swift build -c release --package-path "$ROOT")
for arch in $ARCHS; do SWIFT+=(--arch "$arch"); done
BIN="$("${SWIFT[@]}" --show-bin-path)"

echo "==> building BrewxPort and brewxport-askpass (release, $ARCHS)"
for product in BrewxPort brewxport-askpass; do
    "${SWIFT[@]}" --product "$product"
    cp "$BIN/$product" "$WORK/$product"
done

echo "==> building BrewxPortHelper with its embedded Info.plist"
HELPER_PLIST="$WORK/BrewxPortHelper-Info.plist"
cp "$BUNDLE_RES/BrewxPortHelper-Info.plist" "$HELPER_PLIST"
plutil -insert BrewxPortClientRequirement -string "$CLIENT_REQUIREMENT" "$HELPER_PLIST"
plutil -lint -s "$HELPER_PLIST"
# Belt and braces: the build system did relink when only the plist's contents changed (checked with swift 6.4.2),
# and removing the product makes sure of it. The exact-match check under "Verify" catches a stale section anyway.
rm -f "$BIN/BrewxPortHelper"
"${SWIFT[@]}" --product BrewxPortHelper \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HELPER_PLIST"
cp "$BIN/BrewxPortHelper" "$WORK/BrewxPortHelper"

# --- Assemble -----------------------------------------------------------------------------------------------

echo "==> assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/HelperTools" "$APP/Contents/Library/LaunchDaemons"
cp "$BUNDLE_RES/BrewxPort-Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/BrewxPort" "$APP/Contents/MacOS/BrewxPort"
cp "$WORK/brewxport-askpass" "$APP/Contents/MacOS/brewxport-askpass"
cp "$WORK/BrewxPortHelper" "$APP/Contents/Library/HelperTools/BrewxPortHelper"
cp "$BUNDLE_RES/com.brewxport.helper.plist" "$APP/Contents/Library/LaunchDaemons/com.brewxport.helper.plist"
chmod 755 "$APP/Contents/MacOS/BrewxPort" "$APP/Contents/MacOS/brewxport-askpass" \
    "$APP/Contents/Library/HelperTools/BrewxPortHelper"
if [ "$DEMO_FIXTURES" -eq 1 ]; then
    echo "==> copying the demo fixtures (not for a release)"
    mkdir -p "$APP/Contents/Resources"
    cp -R "$ROOT/Tests/BrewxPortCoreTests/Fixtures" "$APP/Contents/Resources/DemoFixtures"
fi

# --- Strip the debug map ------------------------------------------------------------------------------------

# The linker leaves a debug map (STABS: N_OSO object-file paths and N_SO source paths) in each binary, and
# those paths sit under the build machine's home folder. strip -S removes debug symbols only: exported and
# dynamic symbols, and the helper's __TEXT,__info_plist section, stay. It must run before signing.
echo "==> stripping the debug map"
BINARIES=("$APP/Contents/MacOS/BrewxPort" "$APP/Contents/MacOS/brewxport-askpass"
    "$APP/Contents/Library/HelperTools/BrewxPortHelper")
for path in "${BINARIES[@]}"; do
    strip -S "$path" || die "strip -S failed on $(basename "$path")"
done

# --- Sign, inside out ---------------------------------------------------------------------------------------

echo "==> signing (hardened runtime, secure timestamp, no entitlements)"
CODESIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_SHA")
if [ -n "$KEYCHAIN" ]; then CODESIGN+=(--keychain "$KEYCHAIN"); fi
"${CODESIGN[@]}" --identifier "$ASKPASS_ID" "$APP/Contents/MacOS/brewxport-askpass"
"${CODESIGN[@]}" --identifier "$HELPER_ID" "$APP/Contents/Library/HelperTools/BrewxPortHelper"
"${CODESIGN[@]}" "$APP"

# --- Verify -------------------------------------------------------------------------------------------------

echo "==> verifying"
codesign --verify --strict --deep "$APP" || die "codesign --verify --strict --deep failed"

check_binary() { # path identifier
    local path="$1" id="$2" archs info entitlements
    [ -x "$path" ] || die "missing $path"
    archs="$(lipo -archs "$path")"
    [ "$(printf '%s\n' $archs | sort | tr '\n' ' ')" = "arm64 x86_64 " ] || die "$(basename "$path") is $archs, not universal"
    info="$(codesign -dv --verbose=4 "$path" 2>&1)"
    [[ "$info" == *"Identifier=$id"$'\n'* ]] || die "$(basename "$path"): identifier isn't $id"
    [[ "$info" == *"TeamIdentifier=$TEAM"* ]] || die "$(basename "$path"): signed by another team"
    [[ "$info" =~ flags=0x[0-9a-f]*\(runtime\) ]] || die "$(basename "$path"): no hardened runtime"
    [[ "$info" == *$'\n'"Timestamp="* ]] || die "$(basename "$path"): no secure timestamp"
    entitlements="$(codesign -d --entitlements - --xml "$path" 2>/dev/null || true)"
    [ -z "$entitlements" ] || die "$(basename "$path") has entitlements; a shipped binary must have none"
    echo "    $(basename "$path"): $archs, $id, runtime, timestamp, no entitlements"
}
check_binary "$APP/Contents/MacOS/BrewxPort" "$APP_ID"
check_binary "$APP/Contents/MacOS/brewxport-askpass" "$ASKPASS_ID"
check_binary "$APP/Contents/Library/HelperTools/BrewxPortHelper" "$HELPER_ID"

# No build-machine path may ship: a home folder names its user. Counts only, never the text.
for path in "${BINARIES[@]}"; do
    in_symbols="$(nm -ap "$path" 2>/dev/null | grep -c '/Users/' || true)"
    in_strings="$(strings -a "$path" | grep -c '/Users/' || true)"
    [ "$in_symbols" -eq 0 ] && [ "$in_strings" -eq 0 ] ||
        die "$(basename "$path") holds build-machine paths (/Users/: $in_symbols in its symbols, $in_strings in its strings)"
    echo "    $(basename "$path"): no /Users/ paths in its symbols or strings"
done

DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/com.brewxport.helper.plist"
[ "$(plutil -extract Label raw -o - "$DAEMON_PLIST")" = "$HELPER_ID" ] || die "launchd plist: wrong Label"
MACH="$(plutil -extract MachServices xml1 -o - "$DAEMON_PLIST")"
[[ "$MACH" == *"<key>$HELPER_ID</key>"*"<true/>"* ]] || die "launchd plist: MachServices lacks $HELPER_ID"
[ "$(plutil -extract AssociatedBundleIdentifiers.0 raw -o - "$DAEMON_PLIST")" = "$APP_ID" ] ||
    die "launchd plist: AssociatedBundleIdentifiers isn't [$APP_ID]"
PROGRAM="$(plutil -extract BundleProgram raw -o - "$DAEMON_PLIST")"
[ -f "$APP/$PROGRAM" ] || die "launchd plist: BundleProgram $PROGRAM isn't in the bundle"
echo "    launchd plist: BundleProgram $PROGRAM exists"

# BrewxPortClientRequirement must be in the helper's __info_plist in both slices, and only in the helper.
for arch in $ARCHS; do
    lipo -thin "$arch" "$APP/Contents/Library/HelperTools/BrewxPortHelper" -output "$WORK/helper-$arch"
    rm -f "$WORK/info-$arch.plist"
    segedit "$WORK/helper-$arch" -extract __TEXT __info_plist "$WORK/info-$arch.plist" ||
        die "BrewxPortHelper ($arch) has no __TEXT,__info_plist section"
    embedded="$(plutil -extract BrewxPortClientRequirement raw -o - "$WORK/info-$arch.plist" 2>/dev/null || true)"
    [ "$embedded" = "$CLIENT_REQUIREMENT" ] || die "BrewxPortHelper ($arch): BrewxPortClientRequirement is missing or wrong"
    echo "    BrewxPortHelper ($arch): BrewxPortClientRequirement embedded"
done
for name in BrewxPort brewxport-askpass; do
    sections="$(otool -l "$APP/Contents/MacOS/$name")"
    [[ "$sections" != *"sectname __info_plist"* ]] || die "$name carries an __info_plist section; only the helper may"
done

echo "built $APP"

if [ -n "$NOTARY_PROFILE" ]; then
    "$ROOT/scripts/notarize.sh" "$APP" "$NOTARY_PROFILE"
fi
