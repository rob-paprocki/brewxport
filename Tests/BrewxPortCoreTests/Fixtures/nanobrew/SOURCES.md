# Fixture sources

`leaves.json`, `leaves-tree.txt`, `deps-jq.json`, `info-jq.json`, `list-chain.json`: real `nb leaves --json`, `nb leaves --tree`,
`nb deps --json jq`, `nb info --json jq` and `nb list --json` output (nanobrew v0.1.216), captured 2026-11-21 in a throwaway macOS 27 virtual
machine with `jq` installed (which pulled in `oniguruma`) next to `figlet` and `tree`. All exited 0. `oniguruma` is absent from `leaves`
because `jq` needs it.

`info-alias-python3.json`, `info-alias-python3-stderr.txt`: real `nb info --json python3` stdout and stderr (nanobrew v0.1.216), captured
2026-11-21 in the same throwaway macOS 27 virtual machine (snapshot `pre-plan6`). Exit 1: nb does not resolve Homebrew aliases. `JQ`,
`python` and `python@3` gave the same "not found" answer, so nb matches names exactly.
