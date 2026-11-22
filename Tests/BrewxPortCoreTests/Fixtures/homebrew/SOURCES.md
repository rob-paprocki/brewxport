# Fixture sources

`version-no-git.txt`: real `brew --version` output (exit 0), captured 2026-11-21 in a throwaway macOS 27 virtual machine after
BrewxPort set up Homebrew from the official Homebrew.pkg 7.0.15 without Command Line Tools installed.

`uses-installed-openssl.txt`, `uses-installed-none.txt`, `uses-installed-unknown-stderr.txt`: real `brew uses --installed <formula>` output
(Homebrew 7.0.15), captured 2026-11-21 in a throwaway macOS 27 virtual machine after `brew install wget`. `openssl@4` is used by `wget`;
`wget` has no installed dependents (empty output). All three exited 0. The unknown-formula case prints a warning to stderr and still exits 0.

`info-alias-python3.json`: real `brew info --json=v2 --formula python3` output (Homebrew 7.0.13, run with `HOMEBREW_NO_AUTO_UPDATE=1`),
captured 2026-11-21 in a throwaway macOS 27 virtual machine (snapshot `pre-plan6`). Exit 0. `python3` is an alias: the one formula in the answer
is `python@3.15` (its `aliases` list `python`, `python3` and `python@3`), so `info()` takes it through the single-result fallback.

`info-cask-droid.json`, `info-installed-cask-deps.json`, `uses-installed-ripgrep-cask.txt`, `uses-installed-pcre2-chain.txt`: real Homebrew 7.0.13
output (run with `HOMEBREW_NO_AUTO_UPDATE=1`), captured 2026-11-22 in a throwaway macOS 27 virtual machine (snapshot `pre-plan7`) after
`brew install --cask droid`. The cask `droid` declares `depends_on.formula: ["ripgrep"]`, and `ripgrep` pulls in `pcre2`, so Homebrew installed both
formulae as dependencies. `info-cask-droid.json` is `brew info --json=v2 --cask droid`. `info-installed-cask-deps.json` is
`brew info --json=v2 --installed`: `mas` (already in the VM) has `installed_on_request: true`; `ripgrep` and `pcre2` have `installed_on_request: false`
and no `installed_as_dependency` field (the field is not set for a cask-driven install, so use `installed_on_request`). `uses-installed-ripgrep-cask.txt` is
`brew uses --installed ripgrep` and prints `droid`, the cask: `brew uses --installed` counts installed casks as dependents. `uses-installed-pcre2-chain.txt`
is `brew uses --installed pcre2` and prints only `ripgrep`. All exited 0.
