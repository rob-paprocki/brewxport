# Setup fixtures: where each file came from

Captured 2026-11-21. All real output, unedited. VM: macOS 15.6.1, arm64 (a throwaway test VM).

| File | How it was captured |
|---|---|
| `homebrew-release.json` | `gh api repos/Homebrew/brew/releases/latest` (tag 7.0.15) |
| `macports-release.json` | `gh api repos/macports/macports-base/releases/latest` (tag v2.12.7) |
| `nanobrew-release.json` | `gh api repos/justrach/nanobrew/releases/latest` (tag v0.1.216) |
| `softwareupdate-list-none.txt` | `softwareupdate -l`, no placeholder file (captured on a VM that already had the Command Line Tools) |
| `softwareupdate-list-clt.txt` | `softwareupdate -l` after `touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress` |
| `pkgutil-homebrew.txt` | `pkgutil --check-signature Homebrew.pkg` (7.0.15) |
| `spctl-homebrew.txt` | `spctl -a -vvv -t install Homebrew.pkg` |
| `pkgutil-macports.txt` | `pkgutil --check-signature MacPorts.pkg` (downloaded `MacPorts-2.12.7-15-Sequoia.pkg`, renamed first) |
| `spctl-macports.txt` | `spctl -a -vvv -t install MacPorts.pkg` (same renamed file) |

The downloads were renamed (`Homebrew.pkg`, `MacPorts.pkg`) before the pkgutil and spctl captures, so those fixtures show the short names. Parse verdicts from the content, never the file name.

Pinned values:

- Homebrew Developer ID Installer team ID: `927JGANW46` (`Developer ID Installer: Patrick Linnane (927JGANW46)`). Becomes `EngineSetupTrust.homebrewTeamID`.
- MacPorts team ID, seen once and not pinned (a release manager's personal certificate, may change): `QTA3A3B7F3`.
- SHA-256 of both pkgs, as downloaded in the VM, equals the `digest` in the release JSON.
