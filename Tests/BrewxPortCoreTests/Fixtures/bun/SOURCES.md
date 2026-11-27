# Fixture sources

Real Bun output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. Bun 1.4.5 (826ef2a6f) from the Homebrew formula `bun` (Homebrew 7.0.16). In the
table, `bun` means `/opt/homebrew/bin/bun`. The global folder is `/Users/tester/.bun/install/global` and the bin folder
`/Users/tester/.bun/bin`. The test packages are `cowsay` (1.5.0 installed, 1.6.0 latest) and `semver` (7.8.0 installed,
7.8.6 latest). Node 26.13.1 from Homebrew was installed in the same machine.

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
| `version.txt`, `version.exit` | `bun --version` | 0 |
| `pm-ls-g-empty.txt`, `pm-ls-g-empty.exit` | `bun pm ls -g` | 0 |
| `outdated-g-empty.txt`, `outdated-g-empty-stderr.txt`, `outdated-g-empty.exit` | `bun outdated -g` | 1 |
| `pm-bin-g.txt`, `pm-bin-g.exit` | `bun pm bin -g` | 0 |
| `add-g-cowsay-1.5.0.txt`, `add-g-cowsay-1.5.0-stderr.txt`, `add-g-cowsay-1.5.0.exit` | `bun add -g cowsay@1.5.0` | 0 |
| `add-g-semver-7.8.0.txt`, `add-g-semver-7.8.0-stderr.txt`, `add-g-semver-7.8.0.exit` | `bun add -g semver@7.8.0` | 0 |
| `pm-ls-g.txt`, `pm-ls-g.exit` | `bun pm ls -g` | 0 |
| `outdated-g.txt`, `outdated-g.exit` | `bun outdated -g` | 0 |
| `global-package.json` | `/bin/cat /Users/tester/.bun/install/global/package.json` | 0 |
| `info-cowsay-json.json`, `info-cowsay-json.exit` | `bun info cowsay --json` | 0 |
| `info-cowsay-latest-json.json`, `info-cowsay-latest-json.exit` | `bun info cowsay dist-tags.latest --json` | 0 |
| `info-unknown-json-stderr.txt`, `info-unknown-json.exit` | `bun info no-such-package-for-brewxport --json` | 1 |
| `update-g-latest-cowsay.txt`, `update-g-latest-cowsay-stderr.txt`, `update-g-latest-cowsay.exit` | `bun update -g --latest cowsay` | 0 |
| `pm-ls-g-after-update.txt`, `pm-ls-g-after-update.exit` | `bun pm ls -g` | 0 |
| `global-package-after-update.json` | `/bin/cat /Users/tester/.bun/install/global/package.json` | 0 |
| `outdated-g-after-update.txt`, `outdated-g-after-update.exit` | `bun outdated -g` | 0 |
| `update-g-latest-all.txt`, `update-g-latest-all-stderr.txt`, `update-g-latest-all.exit` | `bun update -g --latest` | 0 |
| `pm-ls-g-after-update-all.txt`, `pm-ls-g-after-update-all.exit` | `bun pm ls -g` | 0 |
| `remove-g-cowsay.txt`, `remove-g-cowsay-stderr.txt`, `remove-g-cowsay.exit` | `bun remove -g cowsay` | 0 |
| `remove-g-not-installed.txt`, `remove-g-not-installed.exit` | `bun remove -g cowsay` | 0 |
| `add-g-unknown.txt`, `add-g-unknown-stderr.txt`, `add-g-unknown.exit` | `bun add -g no-such-package-for-brewxport` | 1 |
| `add-g-invalid-name.txt`, `add-g-invalid-name-stderr.txt`, `add-g-invalid-name.exit` | `bun add -g 'bad name!'` | 1 |
| `add-g-network-refused.txt`, `add-g-network-refused-stderr.txt`, `add-g-network-refused.exit` | `BUN_CONFIG_REGISTRY=http://127.0.0.1:9/ bun add -g cowsay` | 1 |
| `outdated-g-network-refused.txt`, `outdated-g-network-refused-stderr.txt`, `outdated-g-network-refused.exit` | `BUN_CONFIG_REGISTRY=http://127.0.0.1:9/ bun outdated -g` | 1 |
| `info-network-refused-stderr.txt`, `info-network-refused.exit` | `BUN_CONFIG_REGISTRY=http://127.0.0.1:9/ bun info cowsay --json` | 1 |
| `registry-search-cowsay.json`, `registry-search-cowsay.http` | `GET https://registry.npmjs.org/-/v1/search?text=cowsay&size=20` | HTTP 200 |
| `registry-search-nomatch.json`, `registry-search-nomatch.http` | `GET https://registry.npmjs.org/-/v1/search?text=zzqxbrewxportnomatch&size=20` | HTTP 200 |
| `add-g-restore-cowsay.txt`, `add-g-restore-cowsay-stderr.txt`, `add-g-restore-cowsay.exit` | `bun add -g cowsay@1.5.0` | 0 |
| `add-g-restore-semver.txt`, `add-g-restore-semver-stderr.txt`, `add-g-restore-semver.exit` | `bun add -g semver@7.8.0` | 0 |
| `pm-ls-g-final.txt`, `pm-ls-g-final.exit` | `bun pm ls -g` | 0 |
| `outdated-g-final.txt`, `outdated-g-final.exit` | `bun outdated -g` | 0 |

## Notes

- The first four rows (`version` to `pm-bin-g`) ran in `/Users/tester/capwd`.
- `outdated -g` exits 0 even when its table lists outdated packages. Before the first `add -g` there is no global
  `package.json`, and it exits 1 with `missing package.json, nothing outdated` on stderr. With the registry unreachable it
  exits 1 and prints only its header line.
- The header of `pm ls -g` counts every installed package (42), but the tree lists only the two top-level ones.
- `add -g name@version` saves that exact version in the global `package.json` (`global-package.json`); `update -g --latest`
  rewrites it (`global-package-after-update.json`). Both files are copies of
  `/Users/tester/.bun/install/global/package.json` at those points, with no newline at the end, as on disk.
- `remove -g` of a package that isn't installed exits 0 and prints `[0.00ms] done`.
- `info` of an unknown package exits 1 with nothing on stdout and a plain-text 404 message on stderr.
- Network refused means `BUN_CONFIG_REGISTRY=http://127.0.0.1:9/`.
- `update-g-latest-all` upgraded `semver` too; the `add-g-restore-*` rows put the old versions back.
- `registry-search-*.json` is the npm registry search API, which Bun has no command for.
- Scrubbed: every e-mail address became `user@example.com` (3 in `info-cowsay-json.json`, 41 in
  `registry-search-cowsay.json`). No other change.

## Task 13 captures (`t13-*`)

Bun 1.4.5 (826ef2a6f) from the Homebrew formula `bun`. `bun` means `/opt/homebrew/bin/bun`. The globals at the start: `cowsay` 1.5.0 and `semver` 7.8.0, in `/Users/tester/.bun/install/global`. `~/capture-pkg` (not captured) is a folder with a minimal `package.json` (`capture-pkg` 1.0.0, one `bin`).

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-version.txt`, `t13-version.exit` | `bun --version` | 0 |
| `t13-add-g-github.txt`, `t13-add-g-github-stderr.txt`, `t13-add-g-github.exit` | `bun add -g github:mathiasbynens/he` | 0 |
| `t13-add-g-scoped-old.txt`, `t13-add-g-scoped-old-stderr.txt`, `t13-add-g-scoped-old.exit` | `bun add -g @antfu/ni@0.21.0` | 0 |
| `t13-add-g-folder.txt`, `t13-add-g-folder-stderr.txt`, `t13-add-g-folder.exit` | `bun add -g /Users/tester/capture-pkg` | 0 |
| `t13-pm-ls-g-mixed.txt`, `t13-pm-ls-g-mixed.exit` | `bun pm ls -g` | 0 |
| `t13-global-package-mixed.json` | `/bin/cat /Users/tester/.bun/install/global/package.json` | 0 |
| `t13-outdated-g-mixed.txt`, `t13-outdated-g-mixed.exit` | `bun outdated -g` | 0 |
| `t13-outdated-g-min-release-age.txt`, `t13-outdated-g-min-release-age.exit` | `bun outdated -g` | 0 |
| `t13-outdated-g-scope-refused.txt`, `t13-outdated-g-scope-refused-stderr.txt`, `t13-outdated-g-scope-refused.exit` | `bun outdated -g` | 1 |
| `t13-add-g-two.txt`, `t13-add-g-two-stderr.txt`, `t13-add-g-two.exit` | `bun add -g is-number@6.0.0 ms@2.0.0` | 0 |
| `t13-pm-ls-g-after-add-two.txt`, `t13-pm-ls-g-after-add-two.exit` | `bun pm ls -g` | 0 |
| `t13-update-g-latest-two.txt`, `t13-update-g-latest-two-stderr.txt`, `t13-update-g-latest-two.exit` | `bun update -g --latest is-number ms` | 0 |
| `t13-pm-ls-g-after-update-two.txt`, `t13-pm-ls-g-after-update-two.exit` | `bun pm ls -g` | 0 |
| `t13-global-package-after-update-two.json` | `/bin/cat /Users/tester/.bun/install/global/package.json` | 0 |
| `t13-remove-g-two.txt`, `t13-remove-g-two-stderr.txt`, `t13-remove-g-two.exit` | `bun remove -g is-number ms` | 0 |
| `t13-add-g-two-one-unknown.txt`, `t13-add-g-two-one-unknown-stderr.txt`, `t13-add-g-two-one-unknown.exit` | `bun add -g left-pad no-such-package-for-brewxport` | 1 |
| `t13-pm-ls-g-after-two-one-unknown.txt`, `t13-pm-ls-g-after-two-one-unknown.exit` | `bun pm ls -g` | 0 |
| `t13-remove-g-two-one-missing.txt`, `t13-remove-g-two-one-missing.exit` | `bun remove -g left-pad no-such-package-for-brewxport` | 0 |
| `t13-pm-ls-g-end.txt`, `t13-pm-ls-g-end.exit` | `bun pm ls -g` | 0 |
| `t13-env-global-dir-add.txt`, `t13-env-global-dir-add-stderr.txt`, `t13-env-global-dir-add.exit` | `BUN_INSTALL_GLOBAL_DIR=/Users/tester/bun-alt-global bun add -g cowsay@1.5.0` | 1 |
| `t13-env-global-dir-pm-ls.txt`, `t13-env-global-dir-pm-ls.exit` | `BUN_INSTALL_GLOBAL_DIR=/Users/tester/bun-alt-global bun pm ls -g` | 0 |
| `t13-env-global-dir-pm-bin.txt`, `t13-env-global-dir-pm-bin.exit` | `BUN_INSTALL_GLOBAL_DIR=/Users/tester/bun-alt-global bun pm bin -g` | 0 |
| `t13-env-global-dir-outdated.txt`, `t13-env-global-dir-outdated.exit` | `BUN_INSTALL_GLOBAL_DIR=/Users/tester/bun-alt-global bun outdated -g` | 0 |
| `t13-bunfig-global-dir-add.txt`, `t13-bunfig-global-dir-add-stderr.txt`, `t13-bunfig-global-dir-add.exit` | `bun add -g semver@7.8.0` | 1 |
| `t13-bunfig-global-dir-pm-ls.txt`, `t13-bunfig-global-dir-pm-ls.exit` | `bun pm ls -g` | 0 |
| `t13-bunfig-global-dir-pm-bin.txt`, `t13-bunfig-global-dir-pm-bin.exit` | `bun pm bin -g` | 0 |
| `t13-pm-ls-g-default-after.txt`, `t13-pm-ls-g-default-after.exit` | `bun pm ls -g` | 0 |

### Notes

- `pm ls -g` shows a GitHub install as `he@github:mathiasbynens/he#ab02411`, a folder install as `capture-pkg@../../../capture-pkg` and a scoped one as `@antfu/ni@0.21.0`. `outdated -g` leaves the GitHub and folder installs out.
- `~/.bunfig.toml` before `t13-outdated-g-min-release-age`: `[install]` `minimumReleaseAge = 31536000`. Rows the age held back get ` *`, and semver's shows 7.7.3, older than the installed 7.8.0.
- `~/.bunfig.toml` before `t13-outdated-g-scope-refused`: `[install.scopes]` `"@antfu" = "http://127.0.0.1:9/"`. Bun prints the other rows, exits 1 and names the package on stderr.
- Several names: `add -g` and `update -g --latest` with two names work in one command. With one unknown name (`t13-add-g-two-one-unknown`) the whole command fails (exit 1) and neither package is installed.
- `t13-env-global-dir-*` ran with `BUN_INSTALL_GLOBAL_DIR=/Users/tester/bun-alt-global`, `t13-bunfig-global-dir-*` with `~/.bunfig.toml` `[install]` `globalDir = "/Users/tester/bun-alt-global2"`. The `pm ls -g` header follows either; `pm bin -g` stays `~/.bun/bin`. Adding cowsay there exits 1 (`failed to link cowsay: EEXIST`, the default folder's cowsay owns the link) although the package was installed.
- `~/.bunfig.toml` was removed after each of those rows. Nothing was scrubbed.
