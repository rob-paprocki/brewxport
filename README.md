# BrewxPort

A native Mac app for finding, installing and updating software from Homebrew, nanobrew, MacPorts and the Mac App Store, all in one window.

[![Release](https://img.shields.io/github/v/release/rob-paprocki/brewxport)](https://github.com/rob-paprocki/brewxport/releases/latest)
![macOS](https://img.shields.io/badge/macOS-15%2B-blue)
![Arch](https://img.shields.io/badge/arch-Intel%20%7C%20Apple%20Silicon-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/updates-dark.png">
  <img alt="BrewxPort's Updates view" src="docs/images/updates-light.png" width="800">
</picture>

## Why

- Search nanobrew, Homebrew, MacPorts and mas at once. Matching packages sit side by side, and you pick which engine installs it.
- Update everything behind one admin password, like a single UAC prompt on Windows.
- Set up a new Mac from a bundle file exported on the old one, with plain Brewfiles for import and export too. This is coming in a later release.
- Keep Intel Macs going. Homebrew plans to drop Intel in 2027, so MacPorts gets full support here.

**Does not:** replace the engines themselves, or run on Windows or Linux.

## Requirements

| Item | Supported |
|------|-----------|
| macOS | 15 Sequoia or later |
| Hardware | Intel and Apple Silicon |
| Engines | Any of Homebrew, nanobrew, MacPorts, mas |
| Building from source | Swift 6 toolchain (Xcode 16 or later, or the Command Line Tools) |

### What each engine is for

| Engine | What BrewxPort uses it for |
|--------|----------------------------|
| Homebrew | Formulae and casks, and casks whose installers need admin rights |
| nanobrew | Faster installs of Homebrew's own packages on Apple Silicon |
| MacPorts | Ports with variants, and long-term Intel support |
| Mac App Store (`mas`) | Apps you got from the App Store |

## Install

Download `BrewxPort-X.Y.Z.zip` from the [latest release](https://github.com/rob-paprocki/brewxport/releases/latest), unzip it and drag `BrewxPort.app` into Applications. The app is signed with a Developer ID and notarized by Apple, so it opens like any other downloaded app. The zip is added a few minutes after a release appears, so if the newest one only lists the source files, check back shortly. Each release also has the source as `brewxport-X.Y.Z.tar.gz`, with its checksum in `SHA256SUMS`.

## Quick start

BrewxPort builds with Swift Package Manager and two scripts. There's no Xcode project. Clone the repository and run the tests:

```bash
git clone https://github.com/rob-paprocki/brewxport.git
cd brewxport
swift test
```

Try the window with sample data. Demo mode uses recorded engine output and only simulates installs, upgrades and removals, so no engine command runs:

```bash
scripts/demo.sh
```

Build a signed, universal `BrewxPort.app` into `build/`:

```bash
scripts/build-app.sh --identity "Developer ID Application"
```

Add `--notarize PROFILE` to have Apple notarize it as well. `PROFILE` is a keychain profile you make once with `xcrun notarytool store-credentials`. The script staples the ticket to the app and leaves `BrewxPort-X.Y.Z.zip` next to it.

> [!WARNING]
> A normal launch of `BrewxPort.app` registers its admin helper. Try it in a virtual machine, or use `scripts/demo.sh`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
