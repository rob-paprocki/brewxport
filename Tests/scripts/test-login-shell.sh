#!/bin/bash
# Runs the app's login-shell PATH probe (brewxport-smoke login-path) the way it runs when BrewxPort is started from a
# terminal: under `script`, so the probe's parent has a controlling terminal. The shell is the real `zsh -i -l -c`,
# with HOME set to a temp folder whose .zshrc prints a banner and adds a directory to PATH, so no real rc file loads.
#
# Two arms, every run:
#   --same-session (the old behaviour): zsh sits in a background process group on the terminal, is stopped by
#     SIGTTIN and never answers; the probe falls back to the system PATH after its timeout.
#   default (a new session, no controlling terminal): zsh answers at once, with the .zshrc directory and without
#     the banner, and captures the allowlisted location variable the .zshrc sets (CARGO_HOME) but not a variable
#     outside the allowlist (NPM_TOKEN) or one whose value isn't an absolute path (BUN_INSTALL).
#
# usage: Tests/scripts/test-login-shell.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

bash -n "$0" && pass "bash -n Tests/scripts/test-login-shell.sh" || fail "bash -n Tests/scripts/test-login-shell.sh"
[ -x /bin/zsh ] || { echo "SKIP: no /bin/zsh"; exit 0; }
grep -qx /bin/zsh /etc/shells || { echo "SKIP: /bin/zsh isn't in /etc/shells"; exit 0; }

swift build --package-path "$ROOT" --product brewxport-smoke >/dev/null
SMOKE="$(swift build --package-path "$ROOT" --show-bin-path)/brewxport-smoke"
[ -x "$SMOKE" ] || { echo "FAIL: no brewxport-smoke at $SMOKE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/brewxport-login-shell.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/.zshrc" <<'EOF'
echo "Welcome to the brewxport test shell"
path=(/brewxport-test/zshrc-bin $path)
export CARGO_HOME=/brewxport-test/cargo-home
export NPM_TOKEN=/brewxport-test/not-allowlisted
export BUN_INSTALL=relative/bun
EOF

# probe <out> [args…]: the probe under a pseudo-terminal, with the temp HOME and nothing else of this shell's
# environment that could point zsh at real rc files.
probe() {
    local out="$1"; shift
    env -i HOME="$TMP" USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="$TMP" LANG=en_US.UTF-8 \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        script -q /dev/null "$SMOKE" login-path --shell /bin/zsh "$@" </dev/null >"$out" 2>&1 || true
    # The terminal echoes the EOF from /dev/null as ^D before the output, and ends lines with CR LF.
    tr -d '\r' <"$out" | sed 's/^\^D//' >"$out.txt"
}

start=$(date +%s)
probe "$TMP/same" --same-session
took=$(( $(date +%s) - start ))
if grep -q 'source: systemDefault' "$TMP/same.txt" && grep -q "didn't answer within" "$TMP/same.txt"; then
    pass "same session on a terminal: no answer, system PATH after the timeout (${took} s)"
else
    fail "same session on a terminal answered; the test no longer reproduces the hang: $(cat "$TMP/same.txt")"
fi

start=$(date +%s)
probe "$TMP/new"
took=$(( $(date +%s) - start ))
grep -q 'source: loginShell' "$TMP/new.txt" && pass "new session: the login shell answered (${took} s)" \
    || fail "new session didn't answer: $(cat "$TMP/new.txt")"
grep -qx /brewxport-test/zshrc-bin "$TMP/new.txt" && pass "PATH includes the .zshrc directory" \
    || fail "the .zshrc directory is missing: $(cat "$TMP/new.txt")"
grep -q Welcome "$TMP/new.txt" && fail "the rc-file banner leaked into the answer" || pass "banner ignored"
grep -qx 'variables: CARGO_HOME' "$TMP/new.txt" \
    && pass "captured CARGO_HOME only (not NPM_TOKEN, not a relative BUN_INSTALL)" \
    || fail "unexpected captured variables: $(grep '^variables:' "$TMP/new.txt")"
grep -q 'brewxport-test/cargo-home\|not-allowlisted' "$TMP/new.txt" \
    && fail "a variable's value was printed" || pass "no variable values printed"
[ "$took" -lt 4 ] && pass "answered well inside the 5 s timeout" || fail "took ${took} s"

[ "$failures" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$failures failed" >&2
exit 1
