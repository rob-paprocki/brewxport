#!/bin/bash
# Runs BrewxPort in demo mode: the real window on the captured engine output in Tests/BrewxPortCoreTests/Fixtures, with
# simulated installs, upgrades and removals. Nothing on this Mac is changed, no engine command runs, and BrewxPort's
# helper is never registered.
#
# It runs as build/BrewxPortDemo.app (bundle id com.brewxport.demo, name "BrewxPort Demo"), so it never shares an identity or
# defaults domain with the real app and computer-use can be granted it. The bundle holds only the debug binary, an
# Info.plist and the fixtures in Contents/Resources/DemoFixtures: no helper, launchd plist or askpass. Normal mode
# starts it with `open -n`; --snapshot runs the bundle's binary directly instead, so the exit code comes back.
#
# usage: scripts/demo.sh [--appearance light|dark] [--snapshot DIR] [--demo-arch arm64|x86_64]
#                        [--demo-bundle inventory|brewfile] [--demo-missing ENGINE]... [--demo-states]
#
#   --appearance  force the light or dark appearance
#   --snapshot    write discover-, updates-, installed-, bundles- and setup-<appearance>.png into DIR, then quit (exit 0
#                 when all five were written, 1 on failure or after 30 s)
#   --demo-arch   pretend to be an Apple silicon or an Intel Mac (engine order, Homebrew prefix, captures)
#   --demo-bundle open a sample on Bundles at launch (with --snapshot, in the Bundles picture): "inventory" is an
#                 export of the demo's own packages, made in memory; "brewfile" is a real Brewfile written by
#                 `brew bundle dump`, with its description comments
#   --demo-missing show a language engine (npm, pipx, uv, cargo, bun, gem or mint) as not installed, so its page
#                 shows Set Up; once per engine
#   --demo-states add the states the captures can't show, partly invented (see DemoStates.swift): an update held
#                 for the Rust it needs, tools a check couldn't look up, gems that came with Ruby, and Homebrew's
#                 node held back for npm's tools
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Warns when this Mac isn't marked as a development Mac: a normal launch of a real BrewxPort.app here would register
# its admin helper. Reads the marker only; it never sets it.
if ! defaults read com.brewxport.app BrewxPortDevelopmentMac 2>/dev/null | grep -qiE '^(1|true|yes)$'; then
    echo "warning: this Mac isn't marked as a development Mac, so a normal launch of BrewxPort.app here registers its" >&2
    echo "         admin helper. To mark it: defaults write com.brewxport.app BrewxPortDevelopmentMac -bool true" >&2
fi

swift build --package-path "$ROOT" --product BrewxPort
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

APP="$ROOT/build/BrewxPortDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BrewxPort" "$APP/Contents/MacOS/BrewxPort"
cp -R "$ROOT/Tests/BrewxPortCoreTests/Fixtures" "$APP/Contents/Resources/DemoFixtures"
cp "$ROOT/Resources/bundle/BrewxPort-Info.plist" "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleIdentifier com.brewxport.demo" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleName BrewxPort Demo" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleDisplayName BrewxPort Demo" "$APP/Contents/Info.plist"
# The demo knows the bundle type (so its open and save panels do) but doesn't own it: the real app exports the
# type, the demo only imports it, and it never claims the Finder's double-click.
"$PB" -c "Copy :UTExportedTypeDeclarations :UTImportedTypeDeclarations" "$APP/Contents/Info.plist"
"$PB" -c "Delete :UTExportedTypeDeclarations" "$APP/Contents/Info.plist"
"$PB" -c "Set :CFBundleDocumentTypes:0:LSHandlerRank None" "$APP/Contents/Info.plist"
codesign --force -s - --deep "$APP" >/dev/null 2>&1

for arg in "$@"; do
    [ "$arg" = --snapshot ] && exec "$APP/Contents/MacOS/BrewxPort" --demo "$@"
done
exec open -n "$APP" --args --demo "$@"
