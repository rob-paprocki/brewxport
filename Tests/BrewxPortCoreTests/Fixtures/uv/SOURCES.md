# Fixture sources

Real `uv tool` output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. uv 0.13.10 from the Homebrew formula `uv` (Homebrew 7.0.16); tools run on
Python 3.15.2 from Homebrew's `python@3.15`. In the table, `uv` means `/opt/homebrew/bin/uv`. The test tools are `ruff`
(0.6.0 installed with a `==0.6.0` pin, 0.17.6 latest) and `isort` (5.13.2 installed, 9.0.2 latest; it has two
executables). uv has no JSON output for `tool list`, so these text files are what the parser is pinned to.

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
| `version.txt`, `version.exit` | `uv --version` | 0 |
| `tool-list-empty-stderr.txt`, `tool-list-empty.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `tool-list-outdated-empty-stderr.txt`, `tool-list-outdated-empty.exit` | `uv tool list --outdated --color never --no-progress` | 0 |
| `tool-dir.txt`, `tool-dir.exit` | `uv tool dir --color never --no-progress` | 0 |
| `tool-dir-bin.txt`, `tool-dir-bin.exit` | `uv tool dir --bin --color never --no-progress` | 0 |
| `tool-install-ruff-0.6.0-stderr.txt`, `tool-install-ruff-0.6.0.exit` | `uv tool install --color never --no-progress ruff==0.6.0` | 0 |
| `tool-install-isort-5.13.2-stderr.txt`, `tool-install-isort-5.13.2.exit` | `uv tool install --color never --no-progress isort==5.13.2` | 0 |
| `tool-list.txt`, `tool-list.exit` | `uv tool list --color never --no-progress` | 0 |
| `tool-list-specifiers.txt`, `tool-list-specifiers.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `tool-list-outdated.txt`, `tool-list-outdated.exit` | `uv tool list --outdated --color never --no-progress` | 0 |
| `tool-list-specifiers-outdated.txt`, `tool-list-specifiers-outdated.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `tool-list-paths.txt`, `tool-list-paths.exit` | `uv tool list --show-paths --color never --no-progress` | 0 |
| `tool-list-all-flags.txt`, `tool-list-all-flags.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `tool-upgrade-isort-pinned-stderr.txt`, `tool-upgrade-isort-pinned.exit` | `uv tool upgrade --color never --no-progress isort` | 0 |
| `tool-install-isort-unpinned-stderr.txt`, `tool-install-isort-unpinned.exit` | `uv tool install --color never --no-progress isort` | 0 |
| `tool-list-specifiers-after-unpin.txt`, `tool-list-specifiers-after-unpin.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `tool-upgrade-isort-stderr.txt`, `tool-upgrade-isort.exit` | `uv tool upgrade --color never --no-progress isort` | 0 |
| `tool-upgrade-all-stderr.txt`, `tool-upgrade-all.exit` | `uv tool upgrade --all --color never --no-progress` | 0 |
| `tool-list-after-upgrade-all.txt`, `tool-list-after-upgrade-all.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `tool-install-reinstall-ruff-stderr.txt`, `tool-install-reinstall-ruff.exit` | `uv tool install --reinstall --color never --no-progress ruff==0.6.0` | 0 |
| `tool-uninstall-isort-stderr.txt`, `tool-uninstall-isort.exit` | `uv tool uninstall --color never --no-progress isort` | 0 |
| `tool-uninstall-not-installed-stderr.txt`, `tool-uninstall-not-installed.exit` | `uv tool uninstall --color never --no-progress isort` | 2 |
| `tool-install-unknown-stderr.txt`, `tool-install-unknown.exit` | `uv tool install --color never --no-progress no-such-package-for-brewxport` | 1 |
| `tool-install-invalid-name-stderr.txt`, `tool-install-invalid-name.exit` | `uv tool install --color never --no-progress 'bad name!'` | 2 |
| `tool-install-pipx-clash-stderr.txt`, `tool-install-pipx-clash.exit` | `uv tool install --color never --no-progress cowsay` | 2 |
| `tool-install-network-refused-stderr.txt`, `tool-install-network-refused.exit` | `UV_DEFAULT_INDEX=http://127.0.0.1:9/simple uv tool install --color never --no-progress isort` | 2 |
| `tool-install-restore-isort-stderr.txt`, `tool-install-restore-isort.exit` | `uv tool install --color never --no-progress isort==5.13.2` | 0 |
| `tool-install-restore-isort-unpinned-stderr.txt`, `tool-install-restore-isort-unpinned.exit` | `uv tool install --color never --no-progress isort` | 0 |
| `tool-list-outdated-network-refused-stderr.txt`, `tool-list-outdated-network-refused.exit` | `https_proxy=http://127.0.0.1:9 uv tool list --outdated --color never --no-progress` | 2 |
| `tool-list-outdated-network-refused-no-cache-stderr.txt`, `tool-list-outdated-network-refused-no-cache.exit` | `https_proxy=http://127.0.0.1:9 UV_NO_CACHE=1 uv tool list --outdated --color never --no-progress` | 2 |
| `tool-upgrade-network-refused-no-cache-stderr.txt`, `tool-upgrade-network-refused-no-cache.exit` | `https_proxy=http://127.0.0.1:9 UV_NO_CACHE=1 uv tool upgrade --color never --no-progress isort` | 1 |
| `tool-list-final.txt`, `tool-list-final.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |

## Notes

- The first five rows (`version` to `tool-dir-bin`) ran in `/Users/tester/capwd`.
- With no tools, `tool list` (with or without `--outdated`) prints nothing on stdout, `No tools installed` on stderr, and
  exits 0.
- `tool install`, `tool upgrade` and `tool uninstall` write only to stderr; stdout stays empty.
- Installing with `==` records a pin, shown as `[required: ==X]`. `tool upgrade` then does nothing: it prints
  `Nothing to upgrade` and a hint, and exits 0 (`tool-upgrade-isort-pinned`, `tool-upgrade-all`). `--outdated` still
  shows `[latest: X]` for a pinned tool.
- `tool install isort` with no version, over the pinned 5.13.2, kept 5.13.2 and dropped the pin without reinstalling
  (`Checked 1 package`). After that, `tool upgrade isort` moved it to 9.0.2. The last rows repeat those two installs to
  leave isort at 5.13.2 with no pin.
- Exit codes: 2 for a tool that isn't installed, an invalid name, an executable clash and network failures of `tool
  install` and `tool list --outdated`; 1 for an unknown package and a failed `tool upgrade`.
- `tool-install-pipx-clash`: pipx already had `cowsay` in `~/.local/bin`. uv resolved and installed the package, then
  stopped with `error: Executable already exists: cowsay` and a hint to use `--force`. No uv tool was left behind.
- Network refused: `tool-install-network-refused` points `UV_DEFAULT_INDEX` at a closed port; the other rows use
  `https_proxy=http://127.0.0.1:9`, with or without `UV_NO_CACHE=1`. `tool list --outdated` fails as a whole (exit 2, no
  stdout) as soon as one lookup fails, even with the cache allowed.
- Nothing was scrubbed. The default index `https://pypi.org/simple/` appears as captured.

## Task 13 captures (`t13-*`)

uv 0.13.10 from the Homebrew formula `uv`. `uv` means `/opt/homebrew/bin/uv`. Pythons on the machine: Homebrew's `python@3.15` 3.15.2, the Command Line Tools' `/usr/bin/python3` 3.9.6, and the CPython 3.12.16 and PyPy 3.12.15 that uv downloaded for these rows (`t13-python-list-installed.txt`). The tools at the start: `ruff` 0.6.0 (`==0.6.0`) and `isort` 5.13.2 (no requirement), both on `python@3.15`. The `old-*` rows ran older uv versions, each installed into a venv of its own (`uv pip install uv==X` into `~/olduv/venv-X`, not captured), against the same tools. The Homebrew rows these rows refer to are in `../pipx/SOURCES.md` (`t13-brew-*`).

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-version.txt`, `t13-version.exit` | `uv --version` | 0 |
| `t13-install-black-range-extras-with-py312-stderr.txt`, `t13-install-black-range-extras-with-py312.exit` | `uv tool install --color never --no-progress --python 3.12 --with 'click>=8' --with colorama 'black[d]>=24,<24.3.0'` | 0 |
| `t13-install-git-stderr.txt`, `t13-install-git.exit` | `uv tool install --color never --no-progress git+https://github.com/pypa/sampleproject` | 0 |
| `t13-install-wheel-url-stderr.txt`, `t13-install-wheel-url.exit` | `uv tool install --color never --no-progress https://files.pythonhosted.org/packages/1a/03/bef6fff907e212d67a0003f8ea4819307bba91b2856074a0763dd483ccc4/pyfiglet-1.0.2-py3-none-any.whl` | 0 |
| `t13-install-pypy-stderr.txt`, `t13-install-pypy.exit` | `uv tool install --color never --no-progress --python pypy tabulate` | 0 |
| `t13-install-isort-range-stderr.txt`, `t13-install-isort-range.exit` | `uv tool install --color never --no-progress 'isort>=5,<7'` | 0 |
| `t13-python-list-installed.txt`, `t13-python-list-installed.exit` | `uv python list --only-installed --color never --no-progress` | 0 |
| `t13-list-plain-many.txt`, `t13-list-plain-many.exit` | `uv tool list --color never --no-progress` | 0 |
| `t13-list-specifiers-many.txt`, `t13-list-specifiers-many.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `t13-list-outdated-many.txt`, `t13-list-outdated-many.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `t13-list-all-flags-many.txt`, `t13-list-all-flags-many.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-receipt-black.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/black/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-black.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/black/pyvenv.cfg` | 0 |
| `t13-receipt-isort.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/isort/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-isort.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/isort/pyvenv.cfg` | 0 |
| `t13-receipt-ruff.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-ruff.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg` | 0 |
| `t13-receipt-sampleproject.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/sampleproject/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-sampleproject.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/sampleproject/pyvenv.cfg` | 0 |
| `t13-receipt-pyfiglet.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/pyfiglet/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-pyfiglet.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/pyfiglet/pyvenv.cfg` | 0 |
| `t13-receipt-tabulate.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/tabulate/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-tabulate.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/tabulate/pyvenv.cfg` | 0 |
| `t13-tool-python-links.txt`, `t13-tool-python-links.exit` | `/bin/ls -l /Users/tester/.local/share/uv/tools/black/bin/python /Users/tester/.local/share/uv/tools/isort/bin/python /Users/tester/.local/share/uv/tools/tabulate/bin/python /Users/tester/.local/share/uv/tools/pyfiglet/bin/python` | 0 |
| `t13-upgrade-isort-in-range-stderr.txt`, `t13-upgrade-isort-in-range.exit` | `uv tool upgrade --color never --no-progress isort` | 0 |
| `t13-list-outdated-after-in-range-upgrade.txt`, `t13-list-outdated-after-in-range-upgrade.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `t13-broken-link-list.txt`, `t13-broken-link-list-stderr.txt`, `t13-broken-link-list.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `t13-broken-link-outdated.txt`, `t13-broken-link-outdated-stderr.txt`, `t13-broken-link-outdated.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `t13-broken-link-all-flags.txt`, `t13-broken-link-all-flags-stderr.txt`, `t13-broken-link-all-flags.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-python-uninstall-312-stderr.txt`, `t13-python-uninstall-312.exit` | `uv python uninstall --color never --no-progress 3.12` | 0 |
| `t13-broken-python-list.txt`, `t13-broken-python-list-stderr.txt`, `t13-broken-python-list.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `t13-broken-python-outdated.txt`, `t13-broken-python-outdated-stderr.txt`, `t13-broken-python-outdated.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `t13-broken-python-all-flags.txt`, `t13-broken-python-all-flags-stderr.txt`, `t13-broken-python-all-flags.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-broken-python-plain.txt`, `t13-broken-python-plain-stderr.txt`, `t13-broken-python-plain.exit` | `uv tool list --color never --no-progress` | 0 |
| `t13-broken-python-receipt-black.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/black/uv-receipt.toml` | 0 |
| `t13-upgrade-broken-black-stderr.txt`, `t13-upgrade-broken-black.exit` | `uv tool upgrade --color never --no-progress black` | 1 |
| `t13-repair-black-stderr.txt`, `t13-repair-black.exit` | `uv tool install --reinstall --color never --no-progress --python 3.12 --with 'click>=8' --with colorama 'black[d]>=24,<24.3.0'` | 0 |
| `t13-repair-tabulate-stderr.txt`, `t13-repair-tabulate.exit` | `uv tool install --reinstall --color never --no-progress --python pypy tabulate` | 2 |
| `t13-list-after-repair.txt`, `t13-list-after-repair-stderr.txt`, `t13-list-after-repair.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-receipt-black-after-repair.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/black/uv-receipt.toml` | 0 |
| `t13-pyvenv-cfg-black-after-repair.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/black/pyvenv.cfg` | 0 |
| `t13-repair-tabulate-uv-suggestion-stderr.txt`, `t13-repair-tabulate-uv-suggestion.exit` | `uv tool install tabulate --reinstall` | 2 |
| `t13-repair-tabulate-force-stderr.txt`, `t13-repair-tabulate-force.exit` | `uv tool install --reinstall --force --color never --no-progress --python pypy tabulate` | 0 |
| `t13-list-after-tabulate-attempts.txt`, `t13-list-after-tabulate-attempts.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-on-system-python-list.txt`, `t13-on-system-python-list.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-on-system-python-links.txt`, `t13-on-system-python-links.exit` | `/bin/ls -l /Users/tester/.local/share/uv/tools/ruff/bin/python /Users/tester/.local/share/uv/tools/isort/bin/python` | 0 |
| `t13-on-system-python-receipt-ruff.toml` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/uv-receipt.toml` | 0 |
| `t13-on-system-python-pyvenv-cfg-ruff.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg` | 0 |
| `t13-repair-ruff-moves-to-managed-python-stderr.txt`, `t13-repair-ruff-moves-to-managed-python.exit` | `uv tool install --reinstall --color never --no-progress ruff==0.6.0` | 0 |
| `t13-repair-ruff-moves-to-managed-python-links.txt`, `t13-repair-ruff-moves-to-managed-python-links.exit` | `/bin/ls -l /Users/tester/.local/share/uv/tools/ruff/bin/python /Users/tester/.local/share/uv/tools/isort/bin/python` | 0 |
| `t13-repair-ruff-moves-to-managed-python-pyvenv-cfg.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg` | 0 |
| `t13-python-list-three.txt`, `t13-python-list-three.exit` | `uv python list --only-installed --color never --no-progress` | 0 |
| `t13-on-homebrew-python-list.txt`, `t13-on-homebrew-python-list.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-on-homebrew-python-links.txt`, `t13-on-homebrew-python-links.exit` | `/bin/ls -l /Users/tester/.local/share/uv/tools/ruff/bin/python /Users/tester/.local/share/uv/tools/isort/bin/python` | 0 |
| `t13-on-homebrew-python-pyvenv-cfg-ruff.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg` | 0 |
| `t13-homebrew-python-removed-list.txt`, `t13-homebrew-python-removed-list-stderr.txt`, `t13-homebrew-python-removed-list.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-homebrew-python-removed-list-specifiers.txt`, `t13-homebrew-python-removed-list-specifiers-stderr.txt`, `t13-homebrew-python-removed-list-specifiers.exit` | `uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `t13-homebrew-python-removed-outdated.txt`, `t13-homebrew-python-removed-outdated-stderr.txt`, `t13-homebrew-python-removed-outdated.exit` | `uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |
| `t13-homebrew-python-removed-links.txt`, `t13-homebrew-python-removed-links.exit` | `/bin/ls -l /Users/tester/.local/share/uv/tools/ruff/bin/python /Users/tester/.local/share/uv/tools/isort/bin/python` | 0 |
| `t13-homebrew-python-removed-repair-ruff-stderr.txt`, `t13-homebrew-python-removed-repair-ruff.exit` | `uv tool install --reinstall --color never --no-progress ruff==0.6.0` | 0 |
| `t13-homebrew-python-removed-repair-isort-stderr.txt`, `t13-homebrew-python-removed-repair-isort.exit` | `uv tool install --reinstall --color never --no-progress 'isort>=5,<7'` | 0 |
| `t13-homebrew-python-removed-list-after-repair.txt`, `t13-homebrew-python-removed-list-after-repair.exit` | `uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-homebrew-python-removed-pyvenv-cfg-ruff-after-repair.cfg` | `/bin/cat /Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg` | 0 |
| `t13-old-0.4.5-version.txt`, `t13-old-0.4.5-version.exit` | `/Users/tester/olduv/venv-0.4.5/bin/uv --version` | 0 |
| `t13-old-0.4.5-list-specifiers-stderr.txt`, `t13-old-0.4.5-list-specifiers.exit` | `/Users/tester/olduv/venv-0.4.5/bin/uv tool list --show-version-specifiers --color never --no-progress` | 2 |
| `t13-old-0.4.6-version.txt`, `t13-old-0.4.6-version.exit` | `/Users/tester/olduv/venv-0.4.6/bin/uv --version` | 0 |
| `t13-old-0.4.6-list-specifiers.txt`, `t13-old-0.4.6-list-specifiers.exit` | `/Users/tester/olduv/venv-0.4.6/bin/uv tool list --show-version-specifiers --color never --no-progress` | 0 |
| `t13-old-0.9.1-version.txt`, `t13-old-0.9.1-version.exit` | `/Users/tester/olduv/venv-0.9.1/bin/uv --version` | 0 |
| `t13-old-0.9.1-list-all-flags-stderr.txt`, `t13-old-0.9.1-list-all-flags.exit` | `/Users/tester/olduv/venv-0.9.1/bin/uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 2 |
| `t13-old-0.9.2-version.txt`, `t13-old-0.9.2-version.exit` | `/Users/tester/olduv/venv-0.9.2/bin/uv --version` | 0 |
| `t13-old-0.9.2-list-all-flags.txt`, `t13-old-0.9.2-list-all-flags.exit` | `/Users/tester/olduv/venv-0.9.2/bin/uv tool list --show-version-specifiers --show-with --show-extras --show-python --show-paths --color never --no-progress` | 0 |
| `t13-old-0.10.9-version.txt`, `t13-old-0.10.9-version.exit` | `/Users/tester/olduv/venv-0.10.9/bin/uv --version` | 0 |
| `t13-old-0.10.9-list-outdated-stderr.txt`, `t13-old-0.10.9-list-outdated.exit` | `/Users/tester/olduv/venv-0.10.9/bin/uv tool list --show-version-specifiers --outdated --color never --no-progress` | 2 |
| `t13-old-0.10.10-version.txt`, `t13-old-0.10.10-version.exit` | `/Users/tester/olduv/venv-0.10.10/bin/uv --version` | 0 |
| `t13-old-0.10.10-list-outdated.txt`, `t13-old-0.10.10-list-outdated.exit` | `/Users/tester/olduv/venv-0.10.10/bin/uv tool list --show-version-specifiers --outdated --color never --no-progress` | 0 |

### Notes

- Setup: `pipx uninstall black` first (pipx's black owned `~/.local/bin/black`).
- `--outdated` prints only tools with a newer version: the git and PyPy tools are missing from `t13-list-outdated-many.txt`. A requirement from git or a URL prints with two spaces after `required:`.
- `t13-install-isort-range`: `isort>=5,<7` over the installed 5.13.2 keeps 5.13.2 (`Checked 1 package`). `--outdated` then reports `[latest: 9.0.2]`, outside the range, while `t13-upgrade-isort-in-range` moves it to 6.1.0, and after that `--outdated` still shows 9.0.2.
- Broken tools: before `t13-broken-link-*`, `tools/tabulate/bin/python` was deleted; `t13-python-uninstall-312` removed both 3.12 Pythons uv had (CPython and PyPy). Listings exit 0, leave the broken tools out and warn on stderr (`environment not found`, or `Invalid environment ... missing Python executable`), with paths relative to the working directory.
- Repairs in `UvEngine.repairArguments`' form: `t13-repair-black` worked (and uv downloaded CPython 3.12 again, which brought back the other tools on it). `t13-repair-tabulate` fails for the deleted link (exit 2), and so does uv's own suggestion (`t13-repair-tabulate-uv-suggestion`); only `--force` (`t13-repair-tabulate-force`) gets past it.
- `t13-on-system-python-*`: ruff and isort had been reinstalled (not captured) with `UV_PYTHON_PREFERENCE=only-system` and a PATH without Homebrew's folder, which put them on the Command Line Tools' Python 3.9.6. `t13-repair-ruff-moves-to-managed-python` (BrewxPort's repair: no `--python`, since the receipt names none) then moved ruff to uv's CPython 3.12.16 (`Ignoring existing environment`).
- `t13-on-homebrew-python-*`: ruff and isort reinstalled the same way with `/opt/homebrew/bin` first on PATH, which put them on `python@3.15` again. Then `brew uninstall pipx` autoremoved `python@3.15` (`../pipx/t13-brew-uninstall-pipx-autoremove-3`) before the `t13-homebrew-python-removed-*` rows. The repairs there installed both tools on uv's CPython 3.12.16.
- A first try at the Homebrew rows was dropped: nothing in it had run on Homebrew's Python.
- `t13-old-*`: uv 0.4.5 refuses `--show-version-specifiers`, 0.9.1 `--show-python`, 0.10.9 `--outdated`; 0.4.6, 0.9.2 and 0.10.10 accept them. uv 0.4.6 prints `[required: ]` for a tool installed without a requirement.
- Receipts (`t13-receipt-*.toml`) and `t13-pyvenv-cfg-*.cfg` are copies of each tool's `uv-receipt.toml` and `pyvenv.cfg`. The wheel URL and git URL are public and kept as captured. Nothing was scrubbed.
