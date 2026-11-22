# Fixture sources

`version-no-git.txt`: real `brew --version` output (exit 0), captured 2026-11-21 in a throwaway macOS 27 virtual machine after
BrewxPort set up Homebrew from the official Homebrew.pkg 7.0.15 without Command Line Tools installed.

`uses-installed-openssl.txt`, `uses-installed-none.txt`, `uses-installed-unknown-stderr.txt`: real `brew uses --installed <formula>` output
(Homebrew 7.0.15), captured 2026-11-21 in a throwaway macOS 27 virtual machine after `brew install wget`. `openssl@4` is used by `wget`;
`wget` has no installed dependents (empty output). All three exited 0. The unknown-formula case prints a warning to stderr and still exits 0.

`info-alias-python3.json`: real `brew info --json=v2 --formula python3` output (Homebrew 7.0.13, run with `HOMEBREW_NO_AUTO_UPDATE=1`),
captured 2026-11-21 in a throwaway macOS 27 virtual machine (snapshot `pre-plan6`). Exit 0. `python3` is an alias: the one formula in the answer
is `python@3.15` (its `aliases` list `python`, `python3` and `python@3`), so `info()` takes it through the single-result fallback.
