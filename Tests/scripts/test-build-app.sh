#!/bin/bash
# Builds BrewxPort.app into a temporary directory with scripts/build-app.sh and checks the result independently of
# the script's own checks: layout, universal binaries, signatures, entitlements, the Developer ID code
# requirements, the launchd plist, the helper's embedded BrewxPortClientRequirement, that no team ID reached the
# build output, and `BrewxPort --self-check`.
#
# usage: Tests/scripts/test-build-app.sh [build-app.sh arguments, e.g. --identity NAME --keychain PATH]
# Needs a code-signing identity (see build-app.sh) and the network (secure timestamps). It never registers the
# helper: the app only runs with --self-check.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build-app.sh"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$SCRIPT" && pass "bash -n scripts/build-app.sh" || fail "bash -n scripts/build-app.sh"
bash -n "$0" && pass "bash -n Tests/scripts/test-build-app.sh" || fail "bash -n Tests/scripts/test-build-app.sh"
bash -n "$ROOT/scripts/demo.sh" && pass "bash -n scripts/demo.sh" || fail "bash -n scripts/demo.sh"

# Demo mode builds none of the live services: no forbidden name on any non-comment line of Sources/BrewxPortUI/Demo.
forbidden="$(grep -EnR 'ProcessRunner|RunSession\(|HelperRegistration|LiveDaemonService|NSXPCConnection|SMAppService' \
    "$ROOT/Sources/BrewxPortUI/Demo" | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
[ -z "$forbidden" ] && pass "Sources/BrewxPortUI/Demo builds no live services" ||
    fail "a live service is named in Sources/BrewxPortUI/Demo: $forbidden"
# The app's demo launch (DemoLaunch, DemoApp, the delegate's demo paths) doesn't either, nor the live engines.
forbidden="$(grep -EnH 'ProcessRunner|RunSession\(|HelperRegistration|LiveDaemonService|NSXPCConnection|SMAppService|LiveServices|Engines\.make' \
    "$ROOT/Sources/BrewxPort/DemoApp.swift" "$ROOT/Sources/BrewxPort/AppDelegate+Demo.swift" |
    grep -Ev '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
[ -z "$forbidden" ] && pass "the app's demo launch builds no live services" ||
    fail "a live service is named in the app's demo launch: $forbidden"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-build-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/build.log"

if "$SCRIPT" ${1+"$@"} --out "$TMP/out" >"$LOG" 2>&1; then
    pass "build-app.sh exited 0"
else
    tail -40 "$LOG" >&2
    fail "build-app.sh failed"
    exit 1
fi

APP="$TMP/out/BrewxPort.app"
last="$(tail -1 "$LOG")"
printed="${last#built }"
if [ "$printed" != "$last" ] && [ "$(basename "$printed")" = BrewxPort.app ] &&
    [ "$(cd "$(dirname "$printed")" && pwd -P)" = "$(cd "$TMP/out" && pwd -P)" ]; then
    pass "prints the bundle path last"
else
    fail "last line isn't the bundle path"
fi
[ ! -e "$TMP/out/.brewxport-build" ] && pass "work directory removed" || fail "work directory left behind"

# Layout
for path in Contents/Info.plist Contents/MacOS/BrewxPort Contents/MacOS/brewxport-askpass \
    Contents/Library/HelperTools/BrewxPortHelper Contents/Library/LaunchDaemons/com.brewxport.helper.plist; do
    [ -f "$APP/$path" ] && pass "$path" || fail "missing $path"
done
for path in Contents/MacOS/BrewxPort Contents/MacOS/brewxport-askpass Contents/Library/HelperTools/BrewxPortHelper; do
    [ -x "$APP/$path" ] || fail "$path isn't executable"
done
[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = com.brewxport.app ] &&
    pass "bundle id com.brewxport.app" || fail "bundle id isn't com.brewxport.app"
[ ! -e "$APP/Contents/Resources/DemoFixtures" ] && pass "a default build has no demo fixtures" ||
    fail "a default build has Contents/Resources/DemoFixtures"

# Signatures
codesign --verify --strict --deep "$APP" && pass "codesign --verify --strict --deep" || fail "codesign verify"
team=""
check() { # path identifier
    local path="$APP/$1" id="$2" archs info entitlements
    archs="$(lipo -archs "$path")"
    [ "$archs" = "x86_64 arm64" ] || [ "$archs" = "arm64 x86_64" ] || fail "$1 is $archs"
    info="$(codesign -dv --verbose=4 "$path" 2>&1)"
    [[ "$info" == *"Identifier=$id"$'\n'* ]] || fail "$1: identifier isn't $id"
    [[ "$info" =~ flags=0x[0-9a-f]*\(runtime\) ]] || fail "$1: no hardened runtime"
    [[ "$info" == *$'\n'"Timestamp="* ]] || fail "$1: no secure timestamp"
    local this_team
    this_team="$(printf '%s\n' "$info" | awk -F= '/^TeamIdentifier=/ { print $2 }')"
    [[ "$this_team" =~ ^[A-Z0-9]{10}$ ]] || fail "$1: no team identifier"
    if [ -z "$team" ]; then team="$this_team"; elif [ "$team" != "$this_team" ]; then fail "$1: different team"; fi
    entitlements="$(codesign -d --entitlements - --xml "$path" 2>/dev/null || true)"
    [ -z "$entitlements" ] || fail "$1 has entitlements"
    [[ "$entitlements" != *get-task-allow* ]] || fail "$1 has get-task-allow"
    pass "$1: $archs, $id, runtime, timestamp, no entitlements"
}
check Contents/MacOS/BrewxPort com.brewxport.app
check Contents/MacOS/brewxport-askpass com.brewxport.askpass
check Contents/Library/HelperTools/BrewxPortHelper com.brewxport.helper

# launchd plist
plist="$APP/Contents/Library/LaunchDaemons/com.brewxport.helper.plist"
[ "$(plutil -extract Label raw -o - "$plist")" = com.brewxport.helper ] && pass "Label" || fail "Label"
program="$(plutil -extract BundleProgram raw -o - "$plist")"
[ "$program" = Contents/Library/HelperTools/BrewxPortHelper ] && [ -f "$APP/$program" ] &&
    pass "BundleProgram exists" || fail "BundleProgram $program"
[ "$(plutil -extract MachServices xml1 -o - "$plist" | grep -c '<key>com.brewxport.helper</key>')" = 1 ] &&
    pass "MachServices com.brewxport.helper" || fail "MachServices"
[ "$(plutil -extract AssociatedBundleIdentifiers json -o - "$plist")" = '["com.brewxport.app"]' ] &&
    pass "AssociatedBundleIdentifiers" || fail "AssociatedBundleIdentifiers"

# Same string as CodeIdentity.requirement(identifier:team:) and build-app.sh's; change all three together.
requirement() { # identifier
    printf 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"' "$1" "$team"
    printf ' and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]'
}

# Each binary satisfies the requirement the others check it against, Developer ID clauses included. The
# requirement holds the team, so only pass or fail is printed.
for pair in Contents/MacOS/BrewxPort:com.brewxport.app Contents/MacOS/brewxport-askpass:com.brewxport.askpass \
    Contents/Library/HelperTools/BrewxPortHelper:com.brewxport.helper; do
    path="${pair%%:*}" id="${pair##*:}"
    codesign -v -R="$(requirement "$id")" "$APP/$path" >/dev/null 2>&1 &&
        pass "$path satisfies its Developer ID requirement" || fail "$path doesn't satisfy its Developer ID requirement"
done

# The helper's embedded Info.plist, in both slices, with this team (compared, never printed).
want="$(requirement com.brewxport.app)"
for arch in arm64 x86_64; do
    lipo -thin "$arch" "$APP/Contents/Library/HelperTools/BrewxPortHelper" -output "$TMP/helper-$arch"
    embedded="$(launchctl plist __TEXT,__info_plist "$TMP/helper-$arch" 2>/dev/null || true)"
    [[ "$embedded" == *"\"BrewxPortClientRequirement\" = \"$want\""* ]] &&
        pass "BrewxPortHelper ($arch) embeds BrewxPortClientRequirement" || fail "BrewxPortHelper ($arch) requirement"
done

# No team ID in what the build printed, or in any tracked file.
if [ -n "$team" ]; then
    ! grep -q -- "$team" "$LOG" && pass "team ID not printed" || fail "the build output contains the team ID"
    ! git -C "$ROOT" grep -q -- "$team" && pass "team ID not in tracked files" || fail "a tracked file has the team ID"
fi

# No build-machine path ships: no /Users/ in any bundled binary's symbols (the debug map) or strings.
no_home_paths() { # app label
    local path in_symbols in_strings
    for path in Contents/MacOS/BrewxPort Contents/MacOS/brewxport-askpass Contents/Library/HelperTools/BrewxPortHelper; do
        in_symbols="$(nm -ap "$1/$path" 2>/dev/null | grep -c '/Users/' || true)"
        in_strings="$(strings -a "$1/$path" | grep -c '/Users/' || true)"
        [ "$in_symbols" -eq 0 ] && [ "$in_strings" -eq 0 ] &&
            pass "$2$path: no /Users/ paths (symbols 0, strings 0)" ||
            fail "$2$path: /Users/ paths: $in_symbols in symbols, $in_strings in strings"
    done
}
no_home_paths "$APP" ""
grep -q "no /Users/ paths in its symbols or strings" "$LOG" && pass "build-app.sh checks for /Users/ paths itself" ||
    fail "build-app.sh didn't report its /Users/ check"

# The app starts and checks its engines without touching the helper.
if out="$("$APP/Contents/MacOS/BrewxPort" --self-check 2>&1)"; then
    [[ "$out" == *"engine(s) present"* ]] && pass "BrewxPort --self-check" || fail "self-check output: $out"
else
    fail "BrewxPort --self-check exited non-zero"
fi

# --with-demo-fixtures puts the captures in the bundle, inside the signature.
if "$SCRIPT" ${1+"$@"} --with-demo-fixtures --out "$TMP/demo-out" >"$TMP/demo-build.log" 2>&1; then
    DEMO_APP="$TMP/demo-out/BrewxPort.app"
    [ -f "$DEMO_APP/Contents/Resources/DemoFixtures/homebrew/outdated.json" ] &&
        pass "a --with-demo-fixtures build has DemoFixtures/homebrew/outdated.json" ||
        fail "a --with-demo-fixtures build lacks DemoFixtures/homebrew/outdated.json"
    codesign --verify --strict --deep "$DEMO_APP" && pass "the demo-fixtures build verifies" ||
        fail "the demo-fixtures build doesn't verify"
    no_home_paths "$DEMO_APP" "demo build: "
else
    tail -40 "$TMP/demo-build.log" >&2
    fail "build-app.sh --with-demo-fixtures failed"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
