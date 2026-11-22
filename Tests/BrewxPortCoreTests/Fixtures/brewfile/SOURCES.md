# Fixture sources

Nothing in this folder is hand-written. Each file is either captured from a real
`brew bundle dump` run or copied verbatim from Homebrew's own documentation.

## Captured from a VM

`dump-basic.Brewfile`, `dump-describe.Brewfile`, `dump-vscode.Brewfile` and
`../homebrew/tap.txt` came from a clean arm64 macOS 15.6.1 VM with Homebrew 7.0.15,
run with `HOMEBREW_NO_AUTO_UPDATE=1`. The machine had one third-party tap
(`FelixKratz/formulae`), formulae `jq`, `mas` and `FelixKratz/formulae/borders`,
casks `rectangle` and `visual-studio-code`, and the VS Code extension `ms-python.python`
(which pulled in three more `ms-python.*` extensions).

| File | Command |
| --- | --- |
| `dump-basic.Brewfile` | `brew bundle dump --no-describe --file=dump-basic.Brewfile --force` |
| `dump-describe.Brewfile` | `brew bundle dump --file=dump-describe.Brewfile --force` (description comments are the default in Homebrew 7; the old `--describe` flag is now disabled and errors) |
| `dump-vscode.Brewfile` | `brew bundle dump --vscode --file=dump-vscode.Brewfile --force` (in Homebrew 7 this dumps only VS Code extensions) |
| `../homebrew/tap.txt` | `brew tap` |

No `mas "..."` line appears in these dumps: the VM was not signed in to the App Store, so
`mas list` was empty. `homebrew-bundle-types.Brewfile` carries the `mas` line format instead.

## Copied from Homebrew documentation

`homebrew-bundle-readme.Brewfile` is lines 310-374 of the first `ruby` code block under
"Rather than all `Brewfile` functionality one-by-one" (the commented example), and
`homebrew-bundle-types.Brewfile` is lines 65-81 of the `ruby` block under "Types", both from
`docs/Brew-Bundle-and-Brewfile.md` in https://github.com/Homebrew/brew, copied byte for byte with one exception: in `homebrew-bundle-readme.Brewfile` line 2 the
host `bitbucket.org` was changed to `example.com`, because `Tests/check_repo.py` rejects any
email-shaped value outside its allow-list. The line still parses the same way (a `tap` with a URL).

- Commit: `3e47189a707c739ee1278a28a3b845f5834574e6`
- URL: https://raw.githubusercontent.com/Homebrew/brew/3e47189a707c739ee1278a28a3b845f5834574e6/docs/Brew-Bundle-and-Brewfile.md
- Retrieved: 2026-11-19
- Licence: BSD-2-Clause (notice below)

```
BSD 2-Clause License

Copyright (c) 2009-present, Homebrew contributors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
