# Fixture sources

Real Cargo and rustup output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. rustup 1.29.3 from the Homebrew formula `rustup` (Homebrew 7.0.16),
which is keg-only: `cargo` and `rustc` in the table mean the proxies in `/opt/homebrew/opt/rustup/bin`, and `rustup`
means `/opt/homebrew/bin/rustup`. Toolchain `stable-aarch64-apple-darwin`: cargo 1.100.0 (3acc79c0c 2026-11-05), rustc
1.100.0 (0ef1bc386 2026-11-09). The table leaves out two environment settings: every `cargo` and `rustc` row, and
`rustup-version-no-toolchain`, had `RUSTUP_AUTO_INSTALL=0`, and from `install-list-empty` on the `cargo` rows also had
`PATH` starting with `/opt/homebrew/opt/rustup/bin`. The other `rustup` rows had neither. The test crate is `ripgrep`
(14.1.0 installed, 16.0.0 latest), which installs the executable `rg`. Each build took about 12 seconds. The Command
Line Tools were installed.

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
| `rustup-version-autoinstall.txt`, `rustup-version-autoinstall-stderr.txt`, `rustup-version-autoinstall.exit` | `rustup --version` | 0 |
| `version.txt`, `version.exit` | `cargo --version` | 0 |
| `toolchain-uninstall-stable-stderr.txt`, `toolchain-uninstall-stable.exit` | `rustup toolchain uninstall stable` | 0 |
| `version-no-toolchain-stderr.txt`, `version-no-toolchain.exit` | `cargo --version` | 1 |
| `rustup-version-no-toolchain.txt`, `rustup-version-no-toolchain-stderr.txt`, `rustup-version-no-toolchain.exit` | `rustup --version` | 0 |
| `toolchain-install-stable-minimal.txt`, `toolchain-install-stable-minimal-stderr.txt`, `toolchain-install-stable-minimal.exit` | `rustup toolchain install stable --profile minimal` | 0 |
| `rustup-default-stable.txt`, `rustup-default-stable-stderr.txt`, `rustup-default-stable.exit` | `rustup default stable` | 0 |
| `version-after-setup.txt`, `version-after-setup.exit` | `cargo --version` | 0 |
| `rustc-version.txt`, `rustc-version.exit` | `rustc --version` | 0 |
| `install-list-empty.exit` | `cargo install --list` | 0 |
| `search-ripgrep.txt`, `search-ripgrep-stderr.txt`, `search-ripgrep.exit` | `cargo search --limit 20 --color never ripgrep` | 0 |
| `search-nomatch.exit` | `cargo search --limit 20 --color never zzqxbrewxportnomatch` | 0 |
| `info-ripgrep.txt`, `info-ripgrep-stderr.txt`, `info-ripgrep.exit` | `cargo info --color never ripgrep` | 0 |
| `info-unknown-stderr.txt`, `info-unknown.exit` | `cargo info --color never no-such-crate-for-brewxport` | 101 |
| `install-ripgrep-14.1.0-stderr.txt`, `install-ripgrep-14.1.0.exit` | `cargo install ripgrep@14.1.0` | 0 |
| `install-list.txt`, `install-list.exit` | `cargo install --list` | 0 |
| `crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `crates.toml` | `/bin/cat /Users/tester/.cargo/.crates.toml` | 0 |
| `install-ripgrep-14.1.0-again-stderr.txt`, `install-ripgrep-14.1.0-again.exit` | `cargo install ripgrep@14.1.0` | 0 |
| `install-ripgrep-upgrade-stderr.txt`, `install-ripgrep-upgrade.exit` | `cargo install ripgrep` | 0 |
| `install-list-after-upgrade.txt`, `install-list-after-upgrade.exit` | `cargo install --list` | 0 |
| `crates2-after-upgrade.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `install-ripgrep-current-again-stderr.txt`, `install-ripgrep-current-again.exit` | `cargo install ripgrep` | 0 |
| `uninstall-ripgrep-stderr.txt`, `uninstall-ripgrep.exit` | `cargo uninstall ripgrep` | 0 |
| `uninstall-not-installed-stderr.txt`, `uninstall-not-installed.exit` | `cargo uninstall ripgrep` | 101 |
| `crates2-after-uninstall.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `install-unknown-stderr.txt`, `install-unknown.exit` | `cargo install no-such-crate-for-brewxport` | 101 |
| `install-invalid-name-stderr.txt`, `install-invalid-name.exit` | `cargo install 'bad name!'` | 101 |
| `install-network-refused-stderr.txt`, `install-network-refused.exit` | `https_proxy=http://127.0.0.1:9 cargo install ripgrep` | 101 |
| `search-network-refused-stderr.txt`, `search-network-refused.exit` | `https_proxy=http://127.0.0.1:9 cargo search --limit 20 --color never ripgrep` | 101 |
| `index-ripgrep.txt`, `index-ripgrep.http` | `GET https://index.crates.io/ri/pg/ripgrep` | HTTP 200 |
| `index-unknown.txt`, `index-unknown.http` | `GET https://index.crates.io/no/-s/no-such-crate-for-brewxport` | HTTP 404 |
| `api-crate-ripgrep.json`, `api-crate-ripgrep.http` | `GET https://crates.io/api/v1/crates/ripgrep` | HTTP 200 |
| `api-search-ripgrep.json`, `api-search-ripgrep.http` | `GET https://crates.io/api/v1/crates?q=ripgrep&per_page=20` | HTTP 200 |
| `install-ripgrep-14.1.0-final-stderr.txt`, `install-ripgrep-14.1.0-final.exit` | `cargo install ripgrep@14.1.0` | 0 |
| `install-list-final.txt`, `install-list-final.exit` | `cargo install --list` | 0 |

## Notes

- The first nine rows (`rustup-version-autoinstall` to `rustc-version`) ran in `/Users/tester/capwd`.
- `rustup --version`, run before any toolchain existed and without `RUSTUP_AUTO_INSTALL=0`, downloaded and installed
  the whole stable toolchain (six components) before it answered (`rustup-version-autoinstall-stderr.txt`). Homebrew's
  rustup sets `stable` as a fallback default. `version.txt` was captured right after, with that toolchain.
- To capture the no-toolchain case, the toolchain was then removed: with `RUSTUP_AUTO_INSTALL=0`, `cargo --version`
  exits 1 with `toolchain 'stable-aarch64-apple-darwin' is not installed`, and `rustup --version` exits 0 but prints the
  same error on stderr. Set Up was then done the way the research suggests: `rustup toolchain install stable --profile
  minimal`, then `rustup default stable`. `version-after-setup.txt` matches `version.txt`.
- `install --list` with no `~/.cargo` folder printed nothing and exited 0, and created `~/.cargo/.crates.toml` and
  `~/.cargo/.crates2.json` as empty files.
- `crates2.json`, `crates2-after-upgrade.json`, `crates2-after-uninstall.json` and `crates.toml` are copies of
  `~/.cargo/.crates2.json` and `~/.cargo/.crates.toml` at those points. `version_req` is `"=14.1.0"` after
  `install ripgrep@14.1.0` and `null` after a plain `install ripgrep`. The source strings
  (`registry+https://github.com/rust-lang/crates.io-index`) are as captured.
- `install` and `uninstall` write only to stderr. Installing a version that is already there prints `Ignored package
  ... is already installed` and exits 0.
- Errors exit 101: unknown crate, invalid name, uninstalling a crate that isn't installed, and network failures. Network
  refused means `https_proxy=http://127.0.0.1:9`.
- `search` with no match prints nothing on either stream and exits 0. `info` downloads the crate file first (see its
  stderr).
- `index-ripgrep.txt` is the sparse-index file, one JSON object per version. The 404 body for an unknown crate
  (`index-unknown.txt`) is XML from the storage service. crates.io's API answered 200 to the User-Agent
  `BrewxPort-fixture-capture`.
- Nothing was scrubbed.

## Task 13 captures (`t13-*`)

rustup 1.29.3 from the Homebrew formula `rustup` (keg-only, `t13-brew-info-rustup.json`), toolchain `stable-aarch64-apple-darwin` with cargo and rustc 1.100.0, and toolchain 1.90.0 (installed by `t13-toolchain-install-1.90`, default for the MSRV rows only). `cargo`, `rustc` and `rustup` mean the files in `/opt/homebrew/opt/rustup/bin`. Every `cargo` and `rustc` row had `RUSTUP_AUTO_INSTALL=0` and `PATH=/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` (not repeated in the table); the `rustup` rows had neither. The crates at the start: `ripgrep` 14.1.0 from crates.io. Two crates were made in the machine for these rows (not captured): `~/capcrate`, package `capture-crate` 0.1.0 with the executables `cap-one` and `cap-two` and the features `extra` (default) and `fancy`, also a git repository with one commit tagged `v0.1.0`; and `~/othercrate`, package `other-crate` 0.1.0 with one executable named `rg`.

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-version.txt`, `t13-version.exit` | `cargo --version` | 0 |
| `t13-rustc-version.txt`, `t13-rustc-version.exit` | `rustc --version` | 0 |
| `t13-start-install-list.txt`, `t13-start-install-list.exit` | `cargo install --list` | 0 |
| `t13-start-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-path-stderr.txt`, `t13-install-path.exit` | `cargo install --path /Users/tester/capcrate` | 0 |
| `t13-path-install-list.txt`, `t13-path-install-list.exit` | `cargo install --list` | 0 |
| `t13-path-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-uninstall-capture-crate-1-stderr.txt`, `t13-uninstall-capture-crate-1.exit` | `cargo uninstall capture-crate` | 0 |
| `t13-install-path-features-stderr.txt`, `t13-install-path-features.exit` | `cargo install --path /Users/tester/capcrate --features fancy` | 0 |
| `t13-path-features-install-list.txt`, `t13-path-features-install-list.exit` | `cargo install --list` | 0 |
| `t13-path-features-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-uninstall-capture-crate-2-stderr.txt`, `t13-uninstall-capture-crate-2.exit` | `cargo uninstall capture-crate` | 0 |
| `t13-install-path-no-default-stderr.txt`, `t13-install-path-no-default.exit` | `cargo install --path /Users/tester/capcrate --no-default-features` | 0 |
| `t13-path-no-default-install-list.txt`, `t13-path-no-default-install-list.exit` | `cargo install --list` | 0 |
| `t13-path-no-default-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-uninstall-capture-crate-3-stderr.txt`, `t13-uninstall-capture-crate-3.exit` | `cargo uninstall capture-crate` | 0 |
| `t13-install-path-bin-one-stderr.txt`, `t13-install-path-bin-one.exit` | `cargo install --path /Users/tester/capcrate --bin cap-one` | 0 |
| `t13-path-bin-one-install-list.txt`, `t13-path-bin-one-install-list.exit` | `cargo install --list` | 0 |
| `t13-path-bin-one-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-path-bin-two-stderr.txt`, `t13-install-path-bin-two.exit` | `cargo install --path /Users/tester/capcrate --bin cap-two` | 0 |
| `t13-path-bin-two-install-list.txt`, `t13-path-bin-two-install-list.exit` | `cargo install --list` | 0 |
| `t13-path-bin-two-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-uninstall-capture-crate-4-stderr.txt`, `t13-uninstall-capture-crate-4.exit` | `cargo uninstall capture-crate` | 0 |
| `t13-install-git-file-stderr.txt`, `t13-install-git-file.exit` | `cargo install --git file:///Users/tester/capcrate` | 0 |
| `t13-git-file-install-list.txt`, `t13-git-file-install-list.exit` | `cargo install --list` | 0 |
| `t13-git-file-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-path-over-git-stderr.txt`, `t13-install-path-over-git.exit` | `cargo install --path /Users/tester/capcrate` | 0 |
| `t13-uninstall-capture-crate-5-stderr.txt`, `t13-uninstall-capture-crate-5.exit` | `cargo uninstall capture-crate` | 0 |
| `t13-toolchain-install-1.90.txt`, `t13-toolchain-install-1.90-stderr.txt`, `t13-toolchain-install-1.90.exit` | `rustup toolchain install 1.90 --profile minimal` | 0 |
| `t13-rustup-default-1.90.txt`, `t13-rustup-default-1.90-stderr.txt`, `t13-rustup-default-1.90.exit` | `rustup default 1.90` | 0 |
| `t13-msrv-rustc-version.txt`, `t13-msrv-rustc-version.exit` | `rustc --version` | 0 |
| `t13-msrv-install-ripgrep-16-stderr.txt`, `t13-msrv-install-ripgrep-16.exit` | `cargo install ripgrep --version =16.0.0` | 101 |
| `t13-msrv-install-ripgrep-plain-stderr.txt`, `t13-msrv-install-ripgrep-plain.exit` | `cargo install ripgrep` | 101 |
| `t13-msrv-install-list.txt`, `t13-msrv-install-list.exit` | `cargo install --list` | 0 |
| `t13-msrv-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-rustup-default-stable.txt`, `t13-rustup-default-stable-stderr.txt`, `t13-rustup-default-stable.exit` | `rustup default stable` | 0 |
| `t13-install-ripgrep-16-exact-stderr.txt`, `t13-install-ripgrep-16-exact.exit` | `cargo install ripgrep --version =16.0.0` | 0 |
| `t13-ripgrep-16-install-list.txt`, `t13-ripgrep-16-install-list.exit` | `cargo install --list` | 0 |
| `t13-ripgrep-16-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-ripgrep-16-exact-again-stderr.txt`, `t13-install-ripgrep-16-exact-again.exit` | `cargo install ripgrep --version =16.0.0` | 0 |
| `t13-install-git-ripgrep-no-force-stderr.txt`, `t13-install-git-ripgrep-no-force.exit` | `cargo install --git https://github.com/BurntSushi/ripgrep --tag 14.1.1 ripgrep` | 0 |
| `t13-git-ripgrep-no-force-install-list.txt`, `t13-git-ripgrep-no-force-install-list.exit` | `cargo install --list` | 0 |
| `t13-git-ripgrep-no-force-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-git-ripgrep-force-stderr.txt`, `t13-install-git-ripgrep-force.exit` | `cargo install --force --git https://github.com/BurntSushi/ripgrep --tag 14.1.1 ripgrep` | 0 |
| `t13-git-ripgrep-install-list.txt`, `t13-git-ripgrep-install-list.exit` | `cargo install --list` | 0 |
| `t13-git-ripgrep-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-registry-over-git-stderr.txt`, `t13-install-registry-over-git.exit` | `cargo install ripgrep --version =16.0.0` | 0 |
| `t13-registry-over-git-install-list.txt`, `t13-registry-over-git-install-list.exit` | `cargo install --list` | 0 |
| `t13-registry-over-git-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-tokei-prerelease-stderr.txt`, `t13-install-tokei-prerelease.exit` | `cargo install tokei --version =13.0.0-alpha.8` | 0 |
| `t13-tokei-prerelease-install-list.txt`, `t13-tokei-prerelease-install-list.exit` | `cargo install --list` | 0 |
| `t13-tokei-prerelease-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-tokei-prerelease-next-stderr.txt`, `t13-install-tokei-prerelease-next.exit` | `cargo install tokei --version =13.0.0-alpha.9` | 0 |
| `t13-tokei-prerelease-next-install-list.txt`, `t13-tokei-prerelease-next-install-list.exit` | `cargo install --list` | 0 |
| `t13-tokei-prerelease-next-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-tokei-plain-stderr.txt`, `t13-install-tokei-plain.exit` | `cargo install tokei` | 0 |
| `t13-tokei-plain-install-list.txt`, `t13-tokei-plain-install-list.exit` | `cargo install --list` | 0 |
| `t13-tokei-plain-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-tokei-prerelease-down-stderr.txt`, `t13-install-tokei-prerelease-down.exit` | `cargo install tokei --version =13.0.0-alpha.9` | 0 |
| `t13-tokei-prerelease-down-install-list.txt`, `t13-tokei-prerelease-down-install-list.exit` | `cargo install --list` | 0 |
| `t13-tokei-prerelease-down-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-config-root-install-stderr.txt`, `t13-config-root-install.exit` | `cargo install --path /Users/tester/capcrate` | 0 |
| `t13-config-root-install-list.txt`, `t13-config-root-install-list.exit` | `cargo install --list` | 0 |
| `t13-config-root-ls.txt`, `t13-config-root-ls.exit` | `/bin/ls -A /Users/tester/cargo-alt-root /Users/tester/cargo-alt-root/bin` | 0 |
| `t13-config-root-crates2.json` | `/bin/cat /Users/tester/cargo-alt-root/.crates2.json` | 0 |
| `t13-config-root-home-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-clash-no-force-stderr.txt`, `t13-install-clash-no-force.exit` | `cargo install --path /Users/tester/othercrate` | 101 |
| `t13-install-clash-force-stderr.txt`, `t13-install-clash-force.exit` | `cargo install --force --path /Users/tester/othercrate` | 0 |
| `t13-clash-force-install-list.txt`, `t13-clash-force-install-list.exit` | `cargo install --list` | 0 |
| `t13-clash-force-crates2.json` | `/bin/cat /Users/tester/.cargo/.crates2.json` | 0 |
| `t13-install-registry-over-clash-stderr.txt`, `t13-install-registry-over-clash.exit` | `cargo install ripgrep --version =16.0.0` | 101 |
| `t13-brew-info-rustup.json`, `t13-brew-info-rustup.exit` | `brew info --json=v2 rustup` | 0 |

### Notes

- `-install-list` rows are `cargo install --list` and `-crates2` rows copies of `~/.cargo/.crates2.json`, taken after the step they're named after.
- `--bin cap-one` records `"bins":["cap-one"]` only; a later `--bin cap-two` adds `cap-two` to the same install.
- A path install's key is `capture-crate 0.1.0 (path+file:///Users/tester/capcrate)`, a local git one's `(git+file:///…#<commit>)`, GitHub's `(git+https://github.com/BurntSushi/ripgrep?tag=14.1.1#<commit>)`. `install --list` shows the path, or the URL with a short commit, in brackets.
- `t13-msrv-*`: on Rust 1.90, both `install ripgrep --version =16.0.0` and plain `install ripgrep` refuse (exit 101, `requires rustc 1.96 or newer`) and name the newest version that fits (15.2.0); neither installs it.
- `t13-install-git-ripgrep-no-force`: the same package name from another source replaces the crates.io install without `--force`, and crates.io's replaces the git one back (`t13-install-registry-over-git`). A different package with an `rg` executable is refused before anything is built (`t13-install-clash-no-force`, exit 101), and with `--force` replaces ripgrep.
- Pre-releases (tokei): `--version =13.0.0-alpha.9` over alpha.8 replaces it; plain `install tokei` over the pre-release installs 15.0.0, the newest stable; `--version =13.0.0-alpha.9` over 15.0.0 goes back down without a word. tokei's pre-releases are older than its stable, so whether a plain install goes below a newer pre-release wasn't tested.
- `t13-config-root-*`: `~/.cargo/config.toml` held `[install]` `root = "/Users/tester/cargo-alt-root"` for these rows only. cargo installs there, keeps its record there and lists that root; `~/.cargo/.crates2.json` doesn't change.
- The first script stopped at the MSRV rows (zsh reads a word starting with `=` as a command path), before running any of them; they ran from the same state with the versions quoted.
- Nothing was scrubbed.
