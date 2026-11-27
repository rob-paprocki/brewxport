# Fixture sources

Real pipx output, captured 2026-11-26 in a throwaway macOS 15.6.1 (arm64) virtual machine,
saved afterwards as snapshot `pre-plan9`. pipx 1.19.1 from the Homebrew formula `pipx` (Homebrew 7.0.16), running on Python
3.15.2 from `python@3.15`. In the table, `pipx` means `/opt/homebrew/bin/pipx`. The test packages are `cowsay` (5.0
installed, 6.1 latest) and `black` (24.2.0 installed, 26.10.1 latest).

pipx chose the uv backend by itself, because Homebrew's `uv` 0.13.10 was on PATH: `environment.txt` shows
`PIPX_RESOLVED_BACKEND=uv` and `PIPX_BACKEND_SOURCE=auto-path`, and every venv's metadata says `"backend": "uv"`.

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
| `version.txt`, `version.exit` | `pipx --version` | 0 |
| `list-json-empty.json`, `list-json-empty-stderr.txt`, `list-json-empty.exit` | `pipx list --json` | 0 |
| `list-empty-stderr.txt`, `list-empty.exit` | `pipx list` | 0 |
| `list-outdated-empty.json`, `list-outdated-empty.exit` | `pipx list --outdated --output json` | 0 |
| `environment-pipx-home.txt`, `environment-pipx-home.exit` | `pipx environment --value PIPX_HOME` | 0 |
| `environment-pipx-bin-dir.txt`, `environment-pipx-bin-dir.exit` | `pipx environment --value PIPX_BIN_DIR` | 0 |
| `install-json-cowsay-5.0.json`, `install-json-cowsay-5.0.exit` | `pipx install --output json cowsay==5.0` | 0 |
| `install-black-24.2.0.txt`, `install-black-24.2.0-stderr.txt`, `install-black-24.2.0.exit` | `pipx install black==24.2.0` | 0 |
| `list-json.json`, `list-json.exit` | `pipx list --json` | 0 |
| `list.txt`, `list.exit` | `pipx list` | 0 |
| `list-short.txt`, `list-short.exit` | `pipx list --short` | 0 |
| `list-outdated-json.json`, `list-outdated-json.exit` | `pipx list --outdated --output json` | 0 |
| `list-outdated.txt`, `list-outdated.exit` | `pipx list --outdated` | 0 |
| `upgrade-json-cowsay.json`, `upgrade-json-cowsay.exit` | `pipx upgrade --output json cowsay` | 0 |
| `list-json-after-upgrade.json`, `list-json-after-upgrade.exit` | `pipx list --json` | 0 |
| `upgrade-json-already-current.json`, `upgrade-json-already-current.exit` | `pipx upgrade --output json cowsay` | 0 |
| `upgrade-all-json.json`, `upgrade-all-json.exit` | `pipx upgrade-all --output json` | 0 |
| `list-outdated-json-after-upgrade-all.json`, `list-outdated-json-after-upgrade-all.exit` | `pipx list --outdated --output json` | 0 |
| `uninstall-json-cowsay.json`, `uninstall-json-cowsay.exit` | `pipx uninstall --output json cowsay` | 0 |
| `uninstall-json-not-installed.json`, `uninstall-json-not-installed.exit` | `pipx uninstall --output json cowsay` | 1 |
| `install-json-unknown.json`, `install-json-unknown-stderr.txt`, `install-json-unknown.exit` | `pipx install --output json no-such-package-for-brewxport` | 1 |
| `install-json-invalid-name.json`, `install-json-invalid-name.exit` | `pipx install --output json 'bad name!'` | 1 |
| `environment.txt`, `environment.exit` | `pipx environment` | 0 |
| `pypi-cowsay.json`, `pypi-cowsay.http` | `GET https://pypi.org/pypi/cowsay/json` | HTTP 200 |
| `pypi-unknown.json`, `pypi-unknown.http` | `GET https://pypi.org/pypi/no-such-package-for-brewxport/json` | HTTP 404 |
| `install-already-installed.txt`, `install-already-installed.exit` | `pipx install cowsay==5.0` | 0 |
| `install-restore-black.txt`, `install-restore-black-stderr.txt`, `install-restore-black.exit` | `pipx install --force black==24.2.0` | 0 |
| `install-json-network-refused.json`, `install-json-network-refused-stderr.txt`, `install-json-network-refused.exit` | `https_proxy=http://127.0.0.1:9 pipx install --output json httpie` | 1 |
| `list-outdated-json-network-refused.json`, `list-outdated-json-network-refused.exit` | `https_proxy=http://127.0.0.1:9 pipx list --outdated --output json` | 1 |
| `list-outdated-json-network-refused-no-cache.json`, `list-outdated-json-network-refused-no-cache.exit` | `https_proxy=http://127.0.0.1:9 UV_NO_CACHE=1 pipx list --outdated --output json` | 1 |
| `upgrade-json-network-refused-no-cache.json`, `upgrade-json-network-refused-no-cache-stderr.txt`, `upgrade-json-network-refused-no-cache.exit` | `https_proxy=http://127.0.0.1:9 UV_NO_CACHE=1 pipx upgrade --output json black` | 1 |
| `install-force-cowsay-5.0.txt`, `install-force-cowsay-5.0-stderr.txt`, `install-force-cowsay-5.0.exit` | `pipx install --force cowsay==5.0` | 0 |
| `list-json-final.json`, `list-json-final.exit` | `pipx list --json` | 0 |
| `list-outdated-json-final.json`, `list-outdated-json-final.exit` | `pipx list --outdated --output json` | 0 |

## Notes

- The first six rows (`version` to `environment-pipx-bin-dir`) ran in `/Users/tester/capwd`.
- With nothing installed, `list --json` prints its JSON on stdout and `nothing has been installed with pipx 😴` on
  stderr, and exits 0.
- `--json` output is indented with four spaces, `--output json` with two.
- `upgrade cowsay` moved a package installed as `cowsay==5.0` to 6.1: the `==` in `package_or_url` doesn't hold it back.
- `upgrade-all` upgraded `black` too; `install-restore-black` put 24.2.0 back.
- `install cowsay==5.0` over an installed 6.1 printed "already installed", changed nothing and exited 0
  (`install-already-installed`). `install --force` was needed to go back to 5.0.
- `install-force-cowsay-5.0-stderr.txt` warns that `cowsay` was already on PATH at `/opt/homebrew/bin/cowsay`. That is npm's
  `cowsay` in the same machine.
- Error codes in the JSON: `package_install_failed` (unknown package, invalid name, network refused),
  `environment_uninstall_failed` (not installed), `environment_outdated_check_failed` (one per venv when the index
  can't be reached; status `error`, exit 1) and `pipx_error` (failed upgrade, with the uv command line in the message).
- Network refused means `https_proxy=http://127.0.0.1:9`. `PIP_INDEX_URL` has no effect with the uv backend: a first try
  with it pointed at a closed port installed cowsay 6.1 from PyPI anyway, so those captures were dropped.
  `UV_NO_CACHE=1` makes sure uv's cache can't answer instead; the outdated check failed the same way with and without it.
- `package_or_url` and `pip_args` hold exactly what was typed (`cowsay==5.0`, `[]`). No index URL or token was used, so
  nothing in them needed scrubbing.
- `pypi-cowsay.json` is PyPI's JSON for cowsay; its one e-mail address (`author_email`) became `user@example.com`.
  `/pypi/black/json` was fetched too but left out: it is 900 KB.

## Task 13 captures (`t13-*`)

pipx 1.19.1 from the Homebrew formula `pipx`, on Python 3.15.2 from `python@3.15`, with the uv backend (uv 0.13.10). `pipx` means `/opt/homebrew/bin/pipx`. The older pipx versions (1.5.0, 1.6.0, 1.15.0, 1.15.1, 1.15.2) were each installed into a venv of their own on uv's CPython 3.12.16 (`uv venv --python 3.12 ~/oldpipx/venv-X`, then `uv pip install pipx==X`, not captured) and run only for these rows: `iso` rows with their own `PIPX_HOME`, `PIPX_BIN_DIR` and `PIPX_MAN_DIR` under `~/oldpipx`, `real` rows with the default home that pipx 1.19.1 uses. The `t13-brew-*` rows are Homebrew 7.0.16 (`brew` means `/opt/homebrew/bin/brew`), each with `HOMEBREW_NO_AUTO_UPDATE=1` (not repeated in the table).

Captured 2026-11-27 in the same throwaway macOS 15.6.1 (arm64) virtual machine, starting from the snapshot `pre-plan9` (the state the rows above leave behind); the machine was put back to that snapshot afterwards. Same environment and file conventions as above: `env -i` with `HOME=/Users/tester`, `USER=tester`, `LANG=en_US.UTF-8`, `NO_COLOR=1` and `PATH=/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`, plus anything shown in front of a command; stdin `/dev/null`, no terminal, working directory `/Users/tester` unless a row says otherwise. `NAME.json` or `NAME.txt` is stdout, `NAME-stderr.txt` stderr and `NAME.exit` the exit code; a stream that was empty has no file. A `/bin/cat` row is a copy of that file as it was on disk (no exit file). Every file name starts with `t13-`, and rows are in the order they ran. Steps that only set something up (making a folder, deleting a file on purpose, writing a config file) weren't captured; the notes say where they happened.

| File(s) | Command | Exit |
|---|---|---|
| `t13-version.txt`, `t13-version.exit` | `pipx --version` | 0 |
| `t13-pyvenv-cfg-black.cfg` | `/bin/cat '/Users/tester/Library/Application Support/pipx/venvs/black/pyvenv.cfg'` | 0 |
| `t13-pyvenv-cfg-cowsay.cfg` | `/bin/cat '/Users/tester/Library/Application Support/pipx/venvs/cowsay/pyvenv.cfg'` | 0 |
| `t13-venv-python-links.txt`, `t13-venv-python-links.exit` | `/bin/ls -l '/Users/tester/Library/Application Support/pipx/venvs/black/bin/python' '/Users/tester/Library/Application Support/pipx/venvs/black/bin/python3' '/Users/tester/Library/Application Support/pipx/venvs/cowsay/bin/python'` | 0 |
| `t13-old-1.5.0-version.txt`, `t13-old-1.5.0-version-stderr.txt`, `t13-old-1.5.0-version.exit` | `/Users/tester/oldpipx/venv-1.5.0/bin/pipx --version` | 0 |
| `t13-old-1.5.0-iso-install-cowsay.txt`, `t13-old-1.5.0-iso-install-cowsay-stderr.txt`, `t13-old-1.5.0-iso-install-cowsay.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx install cowsay==5.0` | 0 |
| `t13-old-1.5.0-iso-install-black.txt`, `t13-old-1.5.0-iso-install-black-stderr.txt`, `t13-old-1.5.0-iso-install-black.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx install black==24.2.0` | 0 |
| `t13-old-1.5.0-iso-list-json.json`, `t13-old-1.5.0-iso-list-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx list --json` | 0 |
| `t13-old-1.5.0-iso-list-outdated-json-stderr.txt`, `t13-old-1.5.0-iso-list-outdated-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx list --outdated --output json` | 2 |
| `t13-old-1.5.0-iso-upgrade-two-stderr.txt`, `t13-old-1.5.0-iso-upgrade-two.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx upgrade cowsay black` | 2 |
| `t13-old-1.5.0-iso-list-json-after-upgrade.json`, `t13-old-1.5.0-iso-list-json-after-upgrade.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.5.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.5.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.5.0 /Users/tester/oldpipx/venv-1.5.0/bin/pipx list --json` | 0 |
| `t13-old-1.5.0-real-list-json-stderr.txt`, `t13-old-1.5.0-real-list-json.exit` | `/Users/tester/oldpipx/venv-1.5.0/bin/pipx list --json` | 1 |
| `t13-old-1.5.0-real-list.txt`, `t13-old-1.5.0-real-list-stderr.txt`, `t13-old-1.5.0-real-list.exit` | `/Users/tester/oldpipx/venv-1.5.0/bin/pipx list` | 1 |
| `t13-old-1.15.2-version.txt`, `t13-old-1.15.2-version.exit` | `/Users/tester/oldpipx/venv-1.15.2/bin/pipx --version` | 0 |
| `t13-old-1.15.2-iso-install-cowsay.txt`, `t13-old-1.15.2-iso-install-cowsay-stderr.txt`, `t13-old-1.15.2-iso-install-cowsay.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx install cowsay==5.0` | 0 |
| `t13-old-1.15.2-iso-install-black.txt`, `t13-old-1.15.2-iso-install-black-stderr.txt`, `t13-old-1.15.2-iso-install-black.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx install black==24.2.0` | 0 |
| `t13-old-1.15.2-iso-list-json.json`, `t13-old-1.15.2-iso-list-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx list --json` | 0 |
| `t13-old-1.15.2-iso-list-outdated-json.json`, `t13-old-1.15.2-iso-list-outdated-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx list --outdated --output json` | 0 |
| `t13-old-1.15.2-iso-upgrade-two.txt`, `t13-old-1.15.2-iso-upgrade-two-stderr.txt`, `t13-old-1.15.2-iso-upgrade-two.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx upgrade cowsay black` | 0 |
| `t13-old-1.15.2-iso-list-json-after-upgrade.json`, `t13-old-1.15.2-iso-list-json-after-upgrade.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.2 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.2 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.2 /Users/tester/oldpipx/venv-1.15.2/bin/pipx list --json` | 0 |
| `t13-old-1.15.2-real-list-json.json`, `t13-old-1.15.2-real-list-json.exit` | `/Users/tester/oldpipx/venv-1.15.2/bin/pipx list --json` | 0 |
| `t13-old-1.15.2-real-list.txt`, `t13-old-1.15.2-real-list.exit` | `/Users/tester/oldpipx/venv-1.15.2/bin/pipx list` | 0 |
| `t13-install-capitalized.txt`, `t13-install-capitalized-stderr.txt`, `t13-install-capitalized.exit` | `pipx install Pygments` | 0 |
| `t13-install-local-folder-stderr.txt`, `t13-install-local-folder.exit` | `pipx install /Users/tester/capture-tool` | 1 |
| `t13-install-private-index-suffix.txt`, `t13-install-private-index-suffix-stderr.txt`, `t13-install-private-index-suffix.exit` | `pipx install --suffix=-private --index-url http://127.0.0.1:8765/simple/ pyjokes` | 0 |
| `t13-list-json-six.json`, `t13-list-json-six.exit` | `pipx list --json` | 0 |
| `t13-list-outdated-json-index-up.json`, `t13-list-outdated-json-index-up.exit` | `pipx list --outdated --output json` | 0 |
| `t13-list-outdated-json-private-index-down.json`, `t13-list-outdated-json-private-index-down.exit` | `pipx list --outdated --output json` | 1 |
| `t13-list-json-broken-venv.json`, `t13-list-json-broken-venv-stderr.txt`, `t13-list-json-broken-venv.exit` | `pipx list --json` | 1 |
| `t13-list-broken-venv.txt`, `t13-list-broken-venv-stderr.txt`, `t13-list-broken-venv.exit` | `pipx list` | 1 |
| `t13-list-short-broken-venv.txt`, `t13-list-short-broken-venv-stderr.txt`, `t13-list-short-broken-venv.exit` | `pipx list --short` | 1 |
| `t13-list-outdated-json-broken-venv.json`, `t13-list-outdated-json-broken-venv.exit` | `pipx list --outdated --output json` | 1 |
| `t13-upgrade-broken-venv-stderr.txt`, `t13-upgrade-broken-venv.exit` | `pipx upgrade cowsay` | 1 |
| `t13-reinstall-all.txt`, `t13-reinstall-all-stderr.txt`, `t13-reinstall-all.exit` | `pipx reinstall-all` | 0 |
| `t13-list-json-after-reinstall-all.json`, `t13-list-json-after-reinstall-all.exit` | `pipx list --json` | 0 |
| `t13-pyvenv-cfg-cowsay-after-reinstall-all.cfg` | `/bin/cat '/Users/tester/Library/Application Support/pipx/venvs/cowsay/pyvenv.cfg'` | 0 |
| `t13-install-local-folder-2.txt`, `t13-install-local-folder-2-stderr.txt`, `t13-install-local-folder-2.exit` | `pipx install /Users/tester/capture-tool` | 0 |
| `t13-list-outdated-json-local-folder.json`, `t13-list-outdated-json-local-folder.exit` | `pipx list --outdated --output json` | 1 |
| `t13-list-json-local-folder.json`, `t13-list-json-local-folder.exit` | `pipx list --json` | 0 |
| `t13-old-1.15.0-version.txt`, `t13-old-1.15.0-version-stderr.txt`, `t13-old-1.15.0-version.exit` | `/Users/tester/oldpipx/venv-1.15.0/bin/pipx --version` | 0 |
| `t13-old-1.15.0-iso-install-cowsay.txt`, `t13-old-1.15.0-iso-install-cowsay-stderr.txt`, `t13-old-1.15.0-iso-install-cowsay.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.0 /Users/tester/oldpipx/venv-1.15.0/bin/pipx install cowsay==5.0` | 0 |
| `t13-old-1.15.0-iso-list-outdated-json-stderr.txt`, `t13-old-1.15.0-iso-list-outdated-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.0 /Users/tester/oldpipx/venv-1.15.0/bin/pipx list --outdated --output json` | 2 |
| `t13-old-1.15.1-version.txt`, `t13-old-1.15.1-version.exit` | `/Users/tester/oldpipx/venv-1.15.1/bin/pipx --version` | 0 |
| `t13-old-1.15.1-iso-install-cowsay.txt`, `t13-old-1.15.1-iso-install-cowsay-stderr.txt`, `t13-old-1.15.1-iso-install-cowsay.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.1 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.1 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.1 /Users/tester/oldpipx/venv-1.15.1/bin/pipx install cowsay==5.0` | 0 |
| `t13-old-1.15.1-iso-list-outdated-json.json`, `t13-old-1.15.1-iso-list-outdated-json.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.15.1 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.15.1 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.15.1 /Users/tester/oldpipx/venv-1.15.1/bin/pipx list --outdated --output json` | 0 |
| `t13-old-1.6.0-iso-upgrade-two.txt`, `t13-old-1.6.0-iso-upgrade-two-stderr.txt`, `t13-old-1.6.0-iso-upgrade-two.exit` | `PIPX_HOME=/Users/tester/oldpipx/home-1.6.0 PIPX_BIN_DIR=/Users/tester/oldpipx/bin-1.6.0 PIPX_MAN_DIR=/Users/tester/oldpipx/man-1.6.0 /Users/tester/oldpipx/venv-1.6.0/bin/pipx upgrade cowsay black` | 0 |
| `t13-brew-info-python.json`, `t13-brew-info-python.exit` | `brew info --json=v2 python@3.15` | 0 |
| `t13-brew-info-pipx.json`, `t13-brew-info-pipx.exit` | `brew info --json=v2 pipx` | 0 |
| `t13-brew-uses-installed-python.txt`, `t13-brew-uses-installed-python.exit` | `brew uses --installed python@3.15` | 0 |
| `t13-brew-autoremove-dry-run-start.exit` | `brew autoremove --dry-run` | 0 |
| `t13-brew-uninstall-pipx-no-autoremove.txt`, `t13-brew-uninstall-pipx-no-autoremove.exit` | `HOMEBREW_NO_AUTOREMOVE=1 brew uninstall pipx` | 0 |
| `t13-brew-uses-installed-python-orphan.exit` | `brew uses --installed python@3.15` | 0 |
| `t13-brew-autoremove-dry-run-orphan.txt`, `t13-brew-autoremove-dry-run-orphan.exit` | `brew autoremove --dry-run` | 0 |
| `t13-brew-upgrade-hello.txt`, `t13-brew-upgrade-hello-stderr.txt`, `t13-brew-upgrade-hello.exit` | `brew upgrade hello` | 0 |
| `t13-brew-list-formula-after-upgrade.txt`, `t13-brew-list-formula-after-upgrade.exit` | `brew list --formula` | 0 |
| `t13-brew-install-pipx-again.txt`, `t13-brew-install-pipx-again-stderr.txt`, `t13-brew-install-pipx-again.exit` | `brew install pipx` | 0 |
| `t13-brew-uninstall-pipx-autoremove.txt`, `t13-brew-uninstall-pipx-autoremove.exit` | `brew uninstall pipx` | 0 |
| `t13-brew-list-formula-after-uninstall.txt`, `t13-brew-list-formula-after-uninstall.exit` | `brew list --formula` | 0 |
| `t13-brew-uninstall-pipx-autoremove-2.txt`, `t13-brew-uninstall-pipx-autoremove-2.exit` | `brew uninstall pipx` | 0 |
| `t13-brew-uninstall-pipx-autoremove-3.txt`, `t13-brew-uninstall-pipx-autoremove-3.exit` | `brew uninstall pipx` | 0 |

### Notes

- Which pipx answers `list --outdated --output json`: 1.5.0, 1.6.0, 1.7.1, 1.8.0, 1.9.0, 1.10.1, 1.11.2, 1.12.0, 1.13.0, 1.14.1 and 1.15.0 refuse it (argparse, exit 2); 1.15.1 is the first that answers (`t13-old-1.15.0-*`, `t13-old-1.15.1-*`). The versions between were checked the same way but not kept.
- `upgrade` with two venvs: pipx 1.5.0 refuses the second name (exit 2); 1.6.0 and 1.15.2 upgrade both.
- `t13-old-1.5.0-real-*`: pipx 1.5.0 can't read venvs that pipx 1.19.1 made (`Unknown metadata version 0.12`, exit 1), and warns about the space in the home path. pipx 1.15.2 reads them.
- `t13-install-capitalized`: `pipx install Pygments` makes the venv `pygments`.
- `t13-install-local-folder` failed because the folder's `pyproject.toml` lacked hatchling's package setting; with it added, `t13-install-local-folder-2` worked. In `list --outdated` that tool is `skipped` with reason `non-index`.
- Private index: python's `http.server` on `127.0.0.1:8765` served `pyjokes-0.6.0-py2.py3-none-any.whl` as a simple index. It was stopped before `t13-list-outdated-json-private-index-down` (that venv's check fails, the others still answer: `status` `partial`, exit 1, `packages_checked` counts the failed venv) and started again for `t13-reinstall-all`. The venv keeps `pip_args` `--index-url http://127.0.0.1:8765/simple/` (no token).
- Broken venv: before `t13-list-json-broken-venv`, `venvs/cowsay/bin/python` was deleted. `list --json` exits 1 with only an empty line on stderr, but still prints the other venvs; `list` names the broken one on stderr (`invalid interpreter`); `list --outdated` reports it as one failed venv; `upgrade` refuses it. `t13-reinstall-all` repaired it (exit 0).
- `t13-pyvenv-cfg-*.cfg`: both venvs' `home` is `/opt/homebrew/opt/python@3.15/bin`, also after `reinstall-all`.
- Homebrew: `brew upgrade hello` doesn't autoremove a Python left with no dependents (`t13-brew-uninstall-pipx-no-autoremove`, `t13-brew-autoremove-dry-run-orphan`, `t13-brew-upgrade-hello`); `brew uninstall pipx` with Homebrew's default autoremove removes `python@3.15` and `mpdecimal` (`t13-brew-uninstall-pipx-autoremove`, `-2`, `-3`). Before `-2` and `-3`, pipx was installed again with `brew install pipx`; those two install outputs aren't kept, because `Tests/check_repo.py` reads the Python bottle's file name in them as an e-mail address. `t13-brew-info-python.json` is `brew info --json=v2 python@3.15`.
- These rows ran before the uv rows; the uv rows start by removing pipx's `black` (`pipx uninstall black`, not captured).
