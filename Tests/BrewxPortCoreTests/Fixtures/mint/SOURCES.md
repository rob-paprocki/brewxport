# Fixture sources

Real Mint output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. Mint 0.18.0 from the Homebrew formula `mint` (Homebrew 7.0.16), building with
Swift 6.1.2 from the Command Line Tools; git 2.39.5 (Apple Git-154). In the table, `mint` means
`/opt/homebrew/bin/mint` and `git` means `/usr/bin/git`. From `list-one` on, every `mint` and `git` row also had
`GIT_TERMINAL_PROMPT=0`. The test package is `JohnSundell/Ink` (Swift, no dependencies, executable `ink-cli`): tag 0.5.0
installed, 0.6.0 latest. Each build took under a minute. Mint's folders are the defaults, `/Users/tester/.mint` and
`/Users/tester/.mint/bin`.

Every command ran over SSH as `tester` through `env -i`, so the environment held only `HOME=/Users/tester`,
`USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and
`PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front
of the command below. Stdin was `/dev/null` and there was no terminal. The working directory was `/Users/tester`,
except for the first rows named in the notes, which ran in the empty folder `/Users/tester/capwd`. That doesn't
change their output.

How to read the files: `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` is stderr and `NAME.exit` is the exit
code. A stdout or stderr file is left out when that stream was empty. For a `GET` row, `NAME.http` is the HTTP
status and `NAME.json` or `NAME.txt` is the body, fetched with `curl` in the same machine with the User-Agent
`BrewxPort-fixture-capture`. Rows are in the order they ran. Commands that change packages were run on purpose to
capture their output, and the last rows put back the outdated packages the snapshot `pre-plan9` keeps.

## Files

| File(s) | Command | Exit |
|---|---|---|
| `version.txt`, `version.exit` | `mint --version` | 0 |
| `list-empty.txt`, `list-empty.exit` | `mint list` | 0 |
| `git-version.txt`, `git-version.exit` | `git --version` | 0 |
| `install-ink-0.5.0.txt`, `install-ink-0.5.0.exit` | `mint install --overwrite n JohnSundell/Ink@0.5.0` | 0 |
| `list-one.txt`, `list-one.exit` | `mint list` | 0 |
| `metadata.json` | `/bin/cat /Users/tester/.mint/metadata.json` | 0 |
| `ls-remote-tags-refs.txt`, `ls-remote-tags-refs.exit` | `git ls-remote --tags --refs https://github.com/JohnSundell/Ink.git` | 0 |
| `ls-remote-tags.txt`, `ls-remote-tags.exit` | `git ls-remote --tags https://github.com/JohnSundell/Ink.git` | 0 |
| `install-ink-0.6.0-upgrade.txt`, `install-ink-0.6.0-upgrade.exit` | `mint install --overwrite n JohnSundell/Ink@0.6.0` | 0 |
| `list-two-versions.txt`, `list-two-versions.exit` | `mint list` | 0 |
| `install-ink-0.5.0-cached.txt`, `install-ink-0.5.0-cached.exit` | `mint install --overwrite n JohnSundell/Ink@0.5.0` | 0 |
| `list-relinked-old.txt`, `list-relinked-old.exit` | `mint list` | 0 |
| `list-inconsistent-cache-stderr.txt`, `list-inconsistent-cache.exit` | `mint list` | 1 |
| `install-unknown-repo.txt`, `install-unknown-repo-stderr.txt`, `install-unknown-repo.exit` | `mint install --overwrite n JohnSundell/NoSuchRepoForBrewxPort@1.0.0` | 1 |
| `ls-remote-unknown-repo-stderr.txt`, `ls-remote-unknown-repo.exit` | `git ls-remote --tags --refs https://github.com/JohnSundell/NoSuchRepoForBrewxPort.git` | 128 |
| `ls-remote-network-refused-stderr.txt`, `ls-remote-network-refused.exit` | `https_proxy=http://127.0.0.1:9 git ls-remote --tags --refs https://github.com/JohnSundell/Ink.git` | 128 |
| `install-cached-version-network-refused.txt`, `install-cached-version-network-refused.exit` | `https_proxy=http://127.0.0.1:9 mint install --overwrite n JohnSundell/Ink@0.6.0` | 0 |
| `uninstall-unknown-stderr.txt`, `uninstall-unknown.exit` | `mint uninstall NoSuchPackageForBrewxPort` | 0 |
| `uninstall-ink.txt`, `uninstall-ink.exit` | `mint uninstall https://github.com/JohnSundell/Ink.git` | 0 |
| `list-after-uninstall.txt`, `list-after-uninstall.exit` | `mint list` | 0 |
| `install-ink-0.5.0-final.txt`, `install-ink-0.5.0-final.exit` | `mint install --overwrite n JohnSundell/Ink@0.5.0` | 0 |
| `list-final.txt`, `list-final.exit` | `mint list` | 0 |
| `github-releases-latest-ink.json`, `github-releases-latest-ink.http` | `GET https://api.github.com/repos/JohnSundell/Ink/releases/latest` | HTTP 200 |
| `github-repo-ink.json`, `github-repo-ink.http` | `GET https://api.github.com/repos/JohnSundell/Ink` | HTTP 200 |
| `install-network-refused.txt`, `install-network-refused-stderr.txt`, `install-network-refused.exit` | `https_proxy=http://127.0.0.1:9 mint install --overwrite n JohnSundell/Ink@0.5.1` | 1 |
| `install-no-version-network-refused.txt`, `install-no-version-network-refused-stderr.txt`, `install-no-version-network-refused.exit` | `https_proxy=http://127.0.0.1:9 mint install --overwrite n JohnSundell/Ink` | 1 |
| `list-after-network-refused.txt`, `list-after-network-refused.exit` | `mint list` | 0 |

## Notes

- The first three rows (`version` to `git-version`) ran in `/Users/tester/capwd`.
- `mint list` with nothing ever installed prints `🌱 No mint packages installed`. After the last package is uninstalled it
  prints `🌱 Installed mint packages:` and an empty line instead (`list-after-uninstall.txt`).
- `*` marks the linked version. Installing a version that is already built only relinks it: `already installed`, then
  `Linked ink-cli 0.5.0 to /Users/tester/.mint/bin, replacing version 0.6.0` (`install-ink-0.5.0-cached.txt`).
- `metadata.json` is a copy of `/Users/tester/.mint/metadata.json` (no newline at the end, as on disk). The linked
  executable `/Users/tester/.mint/bin/ink-cli` is a symlink to
  `/Users/tester/.mint/packages/github.com_JohnSundell_Ink/build/<tag>/ink-cli`.
- `list-inconsistent-cache` was provoked on purpose: an empty folder `stray-folder` was made in
  `/Users/tester/.mint/packages`. `mint list` then exits 1 with `Error: The folder “build” doesn’t exist.` on stderr. The
  folder was removed right after.
- An unknown repository makes git ask for credentials. With `GIT_TERMINAL_PROMPT=0`, `git` fails with `could not read
  Username` (exit 128) and `mint install` exits 1.
- Network refused means `https_proxy=http://127.0.0.1:9`. `install-cached-version-network-refused` exits 0, because 0.6.0
  was already built and Mint relinked it without going online. `install-network-refused` asks for 0.5.1, which wasn't
  built, and fails to clone (exit 1). With no version, Mint reports `Git repo not found` (exit 1), although the repository
  exists.
- `uninstall` of a package Mint can't find prints a message on stderr and exits 0. `uninstall` with the full git URL
  removes every version.
- `ls-remote --tags` with and without `--refs` gave the same lines: Ink has only lightweight tags. The order is git's
  (by name), not by version.
- `github-*.json` are GitHub REST API answers (no token) for the latest release and the repository.
- Nothing was scrubbed.

## Task 13 captures (`t13-*`)

Mint 0.18.0 from the Homebrew formula `mint`, building with Swift from the Command Line Tools; git 2.39.5 (Apple Git-154). `mint` means `/opt/homebrew/bin/mint` and `git` `/usr/bin/git`. Every `mint` row but `t13-version` had `GIT_TERMINAL_PROMPT=0` (not repeated in the table). The `ls-remote-hardened` rows are `MintEngine`'s own tag lookup: its `gitOptions` and `gitVariables`, run from `/`. The package at the start: `JohnSundell/Ink` 0.5.0. Three packages were made in the machine as local git repositories (not captured), each with commits by `capture <user@example.com>`: `~/mintpkgs/MultiTool` (executables `multi-a` and `multi-b`, tags 1.0.0 and 1.1.0), `~/mintpkgs/forks/Ink` (a second package called Ink, executable `ink-fork`, tag 1.0.0) and `~/mintpkgs/solo` (executable `solo`, tag 1.0.0).

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-version.txt`, `t13-version.exit` | `mint --version` | 0 |
| `t13-list-start.txt`, `t13-list-start.exit` | `mint list` | 0 |
| `t13-metadata-start.json` | `/bin/cat /Users/tester/.mint/metadata.json` | 0 |
| `t13-ls-remote-hardened-ink.txt`, `t13-ls-remote-hardened-ink.exit` | (in `/`) `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false HOME=/var/empty XDG_CONFIG_HOME=/var/empty /usr/bin/git -c protocol.allow=never -c protocol.https.allow=always -c credential.helper= -c core.askPass= ls-remote --tags --refs https://github.com/JohnSundell/Ink.git` | 0 |
| `t13-ls-remote-hardened-v-tags.txt`, `t13-ls-remote-hardened-v-tags.exit` | (in `/`) `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false HOME=/var/empty XDG_CONFIG_HOME=/var/empty /usr/bin/git -c protocol.allow=never -c protocol.https.allow=always -c credential.helper= -c core.askPass= ls-remote --tags --refs https://github.com/mac-cain13/R.swift.git` | 0 |
| `t13-ls-remote-hardened-unknown-stderr.txt`, `t13-ls-remote-hardened-unknown.exit` | (in `/`) `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false HOME=/var/empty XDG_CONFIG_HOME=/var/empty /usr/bin/git -c protocol.allow=never -c protocol.https.allow=always -c credential.helper= -c core.askPass= ls-remote --tags --refs https://github.com/JohnSundell/NoSuchRepoForBrewxPort.git` | 128 |
| `t13-ls-remote-hardened-network-refused-stderr.txt`, `t13-ls-remote-hardened-network-refused.exit` | (in `/`) `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ASKPASS=/usr/bin/false SSH_ASKPASS=/usr/bin/false HOME=/var/empty XDG_CONFIG_HOME=/var/empty https_proxy=http://127.0.0.1:9 /usr/bin/git -c protocol.allow=never -c protocol.https.allow=always -c credential.helper= -c core.askPass= ls-remote --tags --refs https://github.com/JohnSundell/Ink.git` | 128 |
| `t13-install-file-url.txt`, `t13-install-file-url.exit` | `mint install --overwrite n file:///Users/tester/mintpkgs/MultiTool@1.0.0` | 0 |
| `t13-list-file-url.txt`, `t13-list-file-url.exit` | `mint list` | 0 |
| `t13-metadata-file-url.json` | `/bin/cat /Users/tester/.mint/metadata.json` | 0 |
| `t13-bin-file-url.txt`, `t13-bin-file-url.exit` | `/bin/ls -l /Users/tester/.mint/bin` | 0 |
| `t13-install-overwrite-n-skip.txt`, `t13-install-overwrite-n-skip.exit` | `mint install --overwrite n file:///Users/tester/mintpkgs/MultiTool@1.1.0` | 0 |
| `t13-list-overwrite-n-skip.txt`, `t13-list-overwrite-n-skip.exit` | `mint list` | 0 |
| `t13-bin-overwrite-n-skip.txt`, `t13-bin-overwrite-n-skip.exit` | `/bin/ls -l /Users/tester/.mint/bin` | 0 |
| `t13-install-second-ink.txt`, `t13-install-second-ink.exit` | `mint install --overwrite n file:///Users/tester/mintpkgs/forks/Ink@1.0.0` | 0 |
| `t13-list-two-inks.txt`, `t13-list-two-inks.exit` | `mint list` | 0 |
| `t13-metadata-two-inks.json` | `/bin/cat /Users/tester/.mint/metadata.json` | 0 |
| `t13-packages-two-inks.txt`, `t13-packages-two-inks.exit` | `/bin/ls /Users/tester/.mint/packages` | 0 |
| `t13-uninstall-github-url-two-inks.txt`, `t13-uninstall-github-url-two-inks.exit` | `mint uninstall https://github.com/JohnSundell/Ink.git` | 0 |
| `t13-list-after-uninstall-github-url.txt`, `t13-list-after-uninstall-github-url.exit` | `mint list` | 0 |
| `t13-uninstall-name-ink.txt`, `t13-uninstall-name-ink.exit` | `mint uninstall Ink` | 0 |
| `t13-list-after-uninstall-name-ink.txt`, `t13-list-after-uninstall-name-ink.exit` | `mint list` | 0 |
| `t13-uninstall-name-multitool.txt`, `t13-uninstall-name-multitool.exit` | `mint uninstall MultiTool` | 0 |
| `t13-list-after-uninstall-name-multitool.txt`, `t13-list-after-uninstall-name-multitool.exit` | `mint list` | 0 |
| `t13-metadata-end.json` | `/bin/cat /Users/tester/.mint/metadata.json` | 0 |
| `t13-install-same-name-executable.txt`, `t13-install-same-name-executable.exit` | `mint install --overwrite n file:///Users/tester/mintpkgs/solo@1.0.0` | 0 |
| `t13-list-same-name-executable.txt`, `t13-list-same-name-executable.exit` | `mint list` | 0 |

### Notes

- `--overwrite n` with a file Mint didn't make where it links `multi-b` (a regular two-line script put in `~/.mint/bin` before `t13-install-overwrite-n-skip`): Mint links `multi-a`, says nothing about `multi-b` and exits 0. `mint list` then shows `1.1.0 (multi-a *, multi-b)`.
- Two packages called Ink are listed as `Ink (<url>)` each. `uninstall https://github.com/JohnSundell/Ink.git` removes only that one; `uninstall Ink` then removes the other; `uninstall MultiTool` removes every version.
- A package installed from a `file://` URL is listed by its last path part, and the URL is its key in `metadata.json`. A package whose one executable has its own name (`solo`) is listed without brackets.
- Hardened lookups: tags come back as before. For an unknown repository git prints `unable to read askpass response from '/usr/bin/false'` and then `could not read Username ... terminal prompts disabled` (exit 128). R.swift's tags mix `v`-prefixed (older) and plain ones, and some aren't semver (`v1.0.0.beta.1`).
- `metadata-*` rows are copies of `~/.mint/metadata.json` (no newline at the end). Nothing was scrubbed.
