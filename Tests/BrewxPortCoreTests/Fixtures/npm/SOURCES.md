# Fixture sources

Real npm output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. npm 11.20.0 with Node v26.13.1, both from the Homebrew formula `node` 26.13.1
(Homebrew 7.0.16); the global prefix is `/opt/homebrew`. Every npm command also had `npm_config_update_notifier=false`,
`npm_config_fund=false` and `npm_config_audit=false` in its environment. In the table, `npm` and `node` mean
`/opt/homebrew/bin/npm` and `/opt/homebrew/bin/node`. The test packages are `cowsay` (1.5.0 installed, 1.6.0 latest) and
`semver` (7.8.0 installed, 7.8.6 latest).

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
| `version.txt`, `version.exit` | `npm --version` | 0 |
| `node-version.txt`, `node-version.exit` | `node --version` | 0 |
| `prefix-g.txt`, `prefix-g.exit` | `npm prefix -g` | 0 |
| `ls-g-empty.json`, `ls-g-empty.exit` | `npm ls -g --json --depth=0` | 0 |
| `ls-g-long-empty.json`, `ls-g-long-empty.exit` | `npm ls -g --json --depth=0 --long` | 0 |
| `outdated-g-empty.json`, `outdated-g-empty.exit` | `npm outdated -g --json` | 1 |
| `install-g-cowsay-1.5.0.txt`, `install-g-cowsay-1.5.0.exit` | `npm install -g cowsay@1.5.0` | 0 |
| `install-g-semver-7.8.0.txt`, `install-g-semver-7.8.0.exit` | `npm install -g semver@7.8.0` | 0 |
| `ls-g.json`, `ls-g.exit` | `npm ls -g --json --depth=0` | 0 |
| `ls-g-long.json`, `ls-g-long.exit` | `npm ls -g --json --depth=0 --long` | 0 |
| `outdated-g.json`, `outdated-g.exit` | `npm outdated -g --json` | 1 |
| `search-cowsay.json`, `search-cowsay.exit` | `npm search --json --searchlimit=50 -- cowsay` | 0 |
| `search-nomatch.json`, `search-nomatch.exit` | `npm search --json --searchlimit=50 -- zzqxbrewxportnomatch` | 0 |
| `view-cowsay.json`, `view-cowsay.exit` | `npm view cowsay@latest name version description homepage license repository.url bin engines.node deprecated --json` | 0 |
| `view-unknown.json`, `view-unknown-stderr.txt`, `view-unknown.exit` | `npm view no-such-package-for-brewxport@latest name version description homepage license repository.url bin engines.node deprecated --json` | 1 |
| `view-invalid-name.json`, `view-invalid-name-stderr.txt`, `view-invalid-name.exit` | `npm view 'bad name!@latest' name version description homepage license repository.url bin engines.node deprecated --json` | 1 |
| `install-g-semver-latest-upgrade.txt`, `install-g-semver-latest-upgrade.exit` | `npm install -g semver@latest` | 0 |
| `outdated-g-after-upgrade.json`, `outdated-g-after-upgrade.exit` | `npm outdated -g --json` | 1 |
| `install-g-upgrade-all.txt`, `install-g-upgrade-all.exit` | `npm install -g cowsay@latest semver@latest` | 0 |
| `ls-g-after-upgrade-all.json`, `ls-g-after-upgrade-all.exit` | `npm ls -g --json --depth=0` | 0 |
| `uninstall-g-semver.txt`, `uninstall-g-semver.exit` | `npm uninstall -g semver` | 0 |
| `uninstall-g-not-installed.txt`, `uninstall-g-not-installed.exit` | `npm uninstall -g semver` | 0 |
| `install-g-unknown-stderr.txt`, `install-g-unknown.exit` | `npm install -g no-such-package-for-brewxport` | 1 |
| `install-g-invalid-name-stderr.txt`, `install-g-invalid-name.exit` | `npm install -g 'bad name!'` | 1 |
| `install-g-network-refused-stderr.txt`, `install-g-network-refused.exit` | `npm_config_registry=http://127.0.0.1:9/ npm install -g semver` | 1 |
| `outdated-g-network-refused.json`, `outdated-g-network-refused-stderr.txt`, `outdated-g-network-refused.exit` | `npm_config_registry=http://127.0.0.1:9/ npm outdated -g --json` | 1 |
| `search-network-refused.json`, `search-network-refused-stderr.txt`, `search-network-refused.exit` | `npm_config_registry=http://127.0.0.1:9/ npm search --json --searchlimit=50 -- cowsay` | 1 |
| `view-network-refused.json`, `view-network-refused-stderr.txt`, `view-network-refused.exit` | `npm_config_registry=http://127.0.0.1:9/ npm view cowsay@latest name version description homepage license repository.url bin engines.node deprecated --json` | 1 |
| `registry-cowsay-latest.json`, `registry-cowsay-latest.http` | `GET https://registry.npmjs.org/cowsay/latest` | HTTP 200 |
| `registry-semver-latest.json`, `registry-semver-latest.http` | `GET https://registry.npmjs.org/semver/latest` | HTTP 200 |
| `registry-cowsay-dist-tags.json`, `registry-cowsay-dist-tags.http` | `GET https://registry.npmjs.org/-/package/cowsay/dist-tags` | HTTP 200 |
| `registry-unknown-latest.json`, `registry-unknown-latest.http` | `GET https://registry.npmjs.org/no-such-package-for-brewxport/latest` | HTTP 404 |
| `registry-search-cowsay.json`, `registry-search-cowsay.http` | `GET https://registry.npmjs.org/-/v1/search?text=cowsay&size=20` | HTTP 200 |
| `install-g-restore-cowsay.txt`, `install-g-restore-cowsay.exit` | `npm install -g cowsay@1.5.0` | 0 |
| `install-g-restore-semver.txt`, `install-g-restore-semver.exit` | `npm install -g semver@7.8.0` | 0 |
| `ls-g-final.json`, `ls-g-final.exit` | `npm ls -g --json --depth=0` | 0 |
| `outdated-g-final.json`, `outdated-g-final.exit` | `npm outdated -g --json` | 1 |

## Notes

- The first six rows (`version` to `outdated-g-empty`) ran in `/Users/tester/capwd`.
- `outdated -g --json` exits 1 whenever anything is outdated. Even with no packages installed it exits 1, because npm
  itself (11.20.0) is behind 12.2.3.
- With `--json`, errors go to stdout as `{"error": {"code": ..., "summary": ..., "detail": ...}}` with exit 1, and npm also
  prints its `npm error` lines to stderr. Codes captured: `E404` (unknown package), `EINVALIDPACKAGENAME` (`view` of
  `bad name!`) and `ECONNREFUSED` (registry on a closed port).
- `install -g 'bad name!'` fails with `EINVALIDTAGNAME`, not `EINVALIDPACKAGENAME`: npm reads the part after the space
  as a tag.
- `uninstall -g` of a package that isn't installed prints `up to date` and exits 0.
- `search` with no match prints `[]` between blank lines and exits 0.
- Each network-refused row took about 70 seconds, because npm retries before it gives up.
- `install-g-upgrade-all` upgraded both packages; the two `install-g-restore-*` rows put the old versions back.
- Scrubbed: every e-mail address became `user@example.com` (108 in `search-cowsay.json`, 41 in
  `registry-search-cowsay.json`, 5 in `registry-semver-latest.json`, 3 in `registry-cowsay-latest.json`, 1 in
  `ls-g-long.json`). Names, user names and registry URLs are as captured. No other change.

## Non-registry globals

Captured 2026-11-26 in the same virtual machine, starting from the snapshot `pre-plan9` (cowsay 1.5.0 and semver 7.8.0
installed, as above), with the same `env -i` environment, npm 11.20.0 and Node v26.13.1. Stdin was `/dev/null`, the
working directory `/Users/tester`. Afterwards the machine was put back to the snapshot. These files show how npm lists
globals that did not come from the registry. They sit beside the registry installs `cowsay` and `semver`.

Installed first, in this order (all exit 0):

| Package | Source | Command |
|---|---|---|
| `he` | GitHub shorthand | `npm install -g github:mathiasbynens/he` |
| `n` | repository URL | `npm install -g git+https://github.com/tj/n.git` |
| `capture-pkg` | local folder | `npm install -g ~/capture-pkg` (minimal `package.json` with a `bin`) |
| `capture-link` | `npm link` | `npm link`, run inside `~/capture-link` (same minimal shape) |
| `is-number` 7.0.0 | tarball | `npm pack is-number@7.0.0`, then `npm install -g ./is-number-7.0.0.tgz` |

Then, to get installs that look outdated, `is-number` was removed (`npm uninstall -g is-number`) and installed again as
`npm install -g github:jonschlinkert/is-number#6.0.0` (GitHub shorthand, old tag), and `ms` came from a tarball:
`npm pack ms@2.0.0`, then `npm install -g ./ms-2.0.0.tgz`. The listing files below were captured after these steps, so
`is-number` is the 6.0.0 GitHub install; the 7.0.0 tarball install was never captured.

| File(s) | Command | Exit |
|---|---|---|
| `nonregistry-ls-g.json`, `nonregistry-ls-g.exit` | `npm ls -g --json --depth=0` | 0 |
| `nonregistry-ls-g-long.json`, `nonregistry-ls-g-long.exit` | `npm ls -g --json --depth=0 --long` | 0 |
| `nonregistry-outdated-g.json`, `nonregistry-outdated-g.exit` | `npm outdated -g --json` | 1 |
| `nonregistry-package-fields.txt` | `grep -E '"_(resolved\|from\|id)"' $(npm prefix -g)/lib/node_modules/<name>/package.json` for each package | 1 for all but `he` (no match); 2 for `he` |
| `nonregistry-node-modules-ls.txt` | `ls -la $(npm prefix -g)/lib/node_modules` | 0 |

Notes:

- Only the local folder and the `npm link` installs carry a `resolved` value (`file:../../../../Users/tester/<folder>`) in
  `ls --json`, and `--long` adds `_dependencies` entries of the form `file:/Users/tester/<folder>`. Both are symlinks in
  `lib/node_modules`. Nothing tells the `npm link` install apart from the folder install.
- The GitHub, repository URL and tarball installs have no `resolved`, no `_resolved`, no `_from`: `ls` shows them exactly
  like a registry install (`version` plus `overridden`). npm 11 doesn't write `_resolved` or `_from` into
  `package.json`, so the field check matches nothing for any package, `cowsay` included.
- `he` (installed from `github:` shorthand) came out as a dangling symlink into npm's temporary clone folder in
  `~/.npm/_cacache/tmp`, which npm had already deleted. `ls` shows it with no `version`, and `outdated` lists it with
  no `current`. This is real npm behavior from the capture, kept on purpose.
- `outdated -g --json` lists `is-number` (GitHub, 6.0.0) and `ms` (tarball, 2.0.0) as ordinary registry updates, and
  gives no sign of how they were installed. It leaves out `capture-pkg`, `capture-link` and `n`.
- Scrubbed: two e-mail addresses in `nonregistry-ls-g-long.json` became `user@example.com` (one author field, one
  `email` field). No other change.

## Task 13 captures (`t13-*`)

npm 11.20.0 and Node v26.13.1 from the Homebrew formula `node` 26.13.1 (Homebrew 7.0.16), then npm 12.2.3, installed over it by `t13-install-g-npm-12`. Rows named `npm11-` ran npm 11.20.0, rows named `npm12-` ran npm 12.2.3. Every `npm` row had `npm_config_update_notifier=false`, `npm_config_fund=false` and `npm_config_audit=false` too (not repeated in the table). `npm` means `/opt/homebrew/bin/npm`. The old-node rows put Node v18.20.8 from nodejs.org (`node-v18.20.8-darwin-arm64.tar.gz`, unpacked into `/Users/tester/oldnode`) first on PATH. The globals at the start: `cowsay` 1.5.0, `semver` 7.8.0, npm.

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-npm11-version.txt`, `t13-npm11-version.exit` | `npm --version` | 0 |
| `t13-node-modules-ls.txt`, `t13-node-modules-ls.exit` | `/bin/ls -la /opt/homebrew/lib/node_modules` | 0 |
| `t13-npm11-view-cowsay.json`, `t13-npm11-view-cowsay.exit` | `npm view cowsay@latest name version description homepage --json` | 0 |
| `t13-npm11-rebuild-g-stderr.txt`, `t13-npm11-rebuild-g.exit` | `npm rebuild -g` | 1 |
| `t13-npm11-ls-g-broken-dep.json`, `t13-npm11-ls-g-broken-dep.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm11-ls-g-broken-dep-all.json`, `t13-npm11-ls-g-broken-dep-all.exit` | `npm ls -g --json` | 0 |
| `t13-npm11-outdated-g-broken-dep.json`, `t13-npm11-outdated-g-broken-dep.exit` | `npm outdated -g --json` | 1 |
| `t13-npm11-ls-g-broken-package-json.json`, `t13-npm11-ls-g-broken-package-json.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm11-outdated-g-broken-package-json.json`, `t13-npm11-outdated-g-broken-package-json.exit` | `npm outdated -g --json` | 1 |
| `t13-npm11-install-g-restore-cowsay.txt`, `t13-npm11-install-g-restore-cowsay.exit` | `npm install -g cowsay@1.5.0` | 0 |
| `t13-npm11-ls-g-restored.json`, `t13-npm11-ls-g-restored.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-no-node-version-stderr.txt`, `t13-no-node-version.exit` | `PATH=/usr/bin:/bin:/usr/sbin:/sbin npm --version` | 127 |
| `t13-no-node-ls-g-stderr.txt`, `t13-no-node-ls-g.exit` | `PATH=/usr/bin:/bin:/usr/sbin:/sbin npm ls -g --json --depth=0` | 127 |
| `t13-npm11-install-g-unwritable-prefix-stderr.txt`, `t13-npm11-install-g-unwritable-prefix.exit` | `npm_config_prefix=/usr/local npm install -g semver` | 243 |
| `t13-npm11-prefix-g-unwritable.txt`, `t13-npm11-prefix-g-unwritable.exit` | `npm_config_prefix=/usr/local npm prefix -g` | 0 |
| `t13-old-node-version.txt`, `t13-old-node-version.exit` | `PATH=/Users/tester/oldnode/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin /Users/tester/oldnode/bin/node --version` | 0 |
| `t13-npm11-old-node-version.txt`, `t13-npm11-old-node-version-stderr.txt`, `t13-npm11-old-node-version.exit` | `PATH=/Users/tester/oldnode/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin npm --version` | 0 |
| `t13-npm11-old-node-outdated-g.json`, `t13-npm11-old-node-outdated-g-stderr.txt`, `t13-npm11-old-node-outdated-g.exit` | `PATH=/Users/tester/oldnode/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin npm outdated -g --json` | 1 |
| `t13-npm11-old-node-ls-g.json`, `t13-npm11-old-node-ls-g-stderr.txt`, `t13-npm11-old-node-ls-g.exit` | `PATH=/Users/tester/oldnode/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin npm ls -g --json --depth=0` | 0 |
| `t13-npm11-rebuild-g-named.txt`, `t13-npm11-rebuild-g-named.exit` | `npm rebuild -g cowsay semver` | 0 |
| `t13-npm11-rebuild-g-again-stderr.txt`, `t13-npm11-rebuild-g-again.exit` | `npm rebuild -g` | 1 |
| `t13-npm11-ls-g-broken-dep-all-flag.json`, `t13-npm11-ls-g-broken-dep-all-flag-stderr.txt`, `t13-npm11-ls-g-broken-dep-all-flag.exit` | `npm ls -g --json --all` | 1 |
| `t13-npm11-ls-g-broken-dep-depth1.json`, `t13-npm11-ls-g-broken-dep-depth1-stderr.txt`, `t13-npm11-ls-g-broken-dep-depth1.exit` | `npm ls -g --json --depth=1` | 1 |
| `t13-npm11-install-g-restore-cowsay-2.txt`, `t13-npm11-install-g-restore-cowsay-2.exit` | `npm install -g cowsay@1.5.0` | 0 |
| `t13-install-g-npm-12.txt`, `t13-install-g-npm-12.exit` | `npm install -g npm@12` | 0 |
| `t13-npm12-version.txt`, `t13-npm12-version.exit` | `npm --version` | 0 |
| `t13-npm12-bin-npm-ls.txt`, `t13-npm12-bin-npm-ls.exit` | `/bin/ls -l /opt/homebrew/bin/npm /opt/homebrew/bin/npx` | 0 |
| `t13-npm12-prefix-g.txt`, `t13-npm12-prefix-g.exit` | `npm prefix -g` | 0 |
| `t13-npm12-ls-g.json`, `t13-npm12-ls-g.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm12-outdated-g.json`, `t13-npm12-outdated-g.exit` | `npm outdated -g --json` | 1 |
| `t13-npm12-view-cowsay.json`, `t13-npm12-view-cowsay.exit` | `npm view cowsay@latest name version description homepage --json` | 0 |
| `t13-npm12-view-unknown.json`, `t13-npm12-view-unknown-stderr.txt`, `t13-npm12-view-unknown.exit` | `npm view no-such-package-for-brewxport@latest name version description homepage --json` | 1 |
| `t13-npm12-search-cowsay.json`, `t13-npm12-search-cowsay.exit` | `npm search --json --searchlimit=50 -- cowsay` | 0 |
| `t13-npm12-search-nomatch.json`, `t13-npm12-search-nomatch.exit` | `npm search --json --searchlimit=50 -- zzqxbrewxportnomatch` | 0 |
| `t13-npm12-rebuild-g.txt`, `t13-npm12-rebuild-g.exit` | `npm rebuild -g` | 0 |
| `t13-npm12-ls-g-broken-dep.json`, `t13-npm12-ls-g-broken-dep.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm12-ls-g-broken-dep-depth1.json`, `t13-npm12-ls-g-broken-dep-depth1-stderr.txt`, `t13-npm12-ls-g-broken-dep-depth1.exit` | `npm ls -g --json --depth=1` | 1 |
| `t13-npm12-install-g-latest-both.txt`, `t13-npm12-install-g-latest-both.exit` | `npm install -g cowsay@latest semver@latest` | 0 |
| `t13-npm12-ls-g-all-latest.json`, `t13-npm12-ls-g-all-latest.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm12-outdated-g-nothing.json`, `t13-npm12-outdated-g-nothing.exit` | `npm outdated -g --json` | 0 |
| `t13-npm12-outdated-g-nothing-text.exit` | `npm outdated -g` | 0 |
| `t13-npm12-uninstall-g-two.txt`, `t13-npm12-uninstall-g-two.exit` | `npm uninstall -g cowsay semver` | 0 |
| `t13-npm12-ls-g-only-npm.json`, `t13-npm12-ls-g-only-npm.exit` | `npm ls -g --json --depth=0` | 0 |
| `t13-npm12-outdated-g-only-npm.json`, `t13-npm12-outdated-g-only-npm.exit` | `npm outdated -g --json` | 0 |
| `t13-brew-info-node.json`, `t13-brew-info-node.exit` | `brew info --json=v2 node` | 0 |

### Notes

- `t13-node-modules-ls.txt`: Homebrew's node 26.13.1 ships npm but no `corepack` in `lib/node_modules`.
- `t13-npm11-rebuild-g`: `npm rebuild -g` exits 1 with `EEXIST` on `/opt/homebrew/bin/npm`, which is Homebrew's link into the Cellar (`../Cellar/node/26.13.1_4/bin/npm`), not npm's own. Naming the packages (`t13-npm11-rebuild-g-named`) works. After `npm install -g npm@12` replaced that link with npm's own (`t13-npm12-bin-npm-ls.txt`), `t13-npm12-rebuild-g` exits 0.
- Missing dependency: before `t13-npm11-ls-g-broken-dep`, and again before `t13-npm11-ls-g-broken-dep-all-flag` and `t13-npm12-ls-g-broken-dep`, the folder `lib/node_modules/cowsay/node_modules/yargs` was deleted. With `--depth=0` npm lists everything and exits 0, as if nothing were wrong. With `--all` or `--depth=1` it exits 1 (`ELSPROBLEMS`): stdout still holds the whole tree, plus `problems` and an `error` object. `t13-npm11-install-g-restore-cowsay` and `-2` put cowsay back.
- Broken package.json: before `t13-npm11-ls-g-broken-package-json`, semver's `package.json` was replaced with text that isn't JSON. `ls` exits 0 and lists semver without a `version`; `outdated` lists it without `current`. The file was put back right after.
- `t13-no-node-*`: npm with no `node` on PATH: `env: node: No such file or directory`, exit 127.
- `t13-npm11-install-g-unwritable-prefix`: `/usr/local` belongs to root and has no `lib` folder: `EACCES`, exit 243.
- `t13-npm11-old-node-*`: npm 11.20.0 under Node 18.20.8 only warns on stderr (`does not support Node.js`) and answers as usual; its `outdated` gives npm itself a `latest` of 10.9.11.
- npm 12 answers `view` with an array (`t13-npm12-view-cowsay.json`). With every global at its latest (`t13-npm12-install-g-latest-both`), `outdated -g --json` prints `{}` and exits 0; the text form prints nothing.
- Scrubbed: 109 e-mail addresses in `t13-npm12-search-cowsay.json` became `user@example.com`. Nothing else was changed.
