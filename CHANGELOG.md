# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release starts with an
**Upgrading:** line that says whether you need to do anything when you update.

## [Unreleased]

## [0.2.0] - 2026-11-19

**Upgrading:** nothing to do. From this release on, download `BrewxPort-X.Y.Z.dmg` and drag BrewxPort to Applications, or run the new installer package. The zip is still there.

### Added

- Each release now has a disk image, `BrewxPort-X.Y.Z.dmg`, signed and notarized like the app inside it. Open it and drag BrewxPort to Applications. `scripts/build-app.sh --notarize PROFILE --dmg` builds it.
- Each release also has an installer package, `BrewxPort-X.Y.Z.pkg`, for people and deployment tools that prefer one. It installs the same app to Applications, has no install scripts, and is signed and notarized. `scripts/build-app.sh --notarize PROFILE --pkg` builds it.

## [0.1.0] - 2026-11-19

**Upgrading:** nothing to do.

### Added

- Core engine layer for Homebrew, nanobrew, MacPorts and the Mac App Store: finds each engine, searches them all at once, and lists installed and outdated packages.
- A sidebar window with Discover, Updates, Installed and an Engines section that shows each engine's status, version and path.
- Discover searches every installed engine at once and lists the same package from different engines side by side.
- Select packages by click, Cmd or Shift-click, or checkboxes, and right-click any row to install, update, uninstall, ignore, skip a version, show details or copy its name.
- Updates lists outdated packages from every engine and updates all of them, or just the ones you pick, behind one password. It can also ignore a package or skip one version, and BrewxPort remembers both.
- Installed marks a package that more than one engine has installed, and ticks the copy your login shell runs first. This works when BrewxPort is opened from Terminal too.
- The Arch column shows what an installed MacPorts port was built for: arm64, x86_64 or universal. Updates shows the same. Other engines' rows show the arch the engine runs as.
- A details pane with description, homepage, versions, dependencies and install options (MacPorts variants and extra arguments).
- On a standard (non-admin) account, BrewxPort runs the steps that don't need admin rights, says which ones it skipped and doesn't try to set up its helper. So far only unit tests cover this. Nobody has tried it on a real standard account yet.
- Quitting during a run asks first, then cancels it.
- A nanobrew cask whose installer needs admin rights is installed through Homebrew. Discover then shows nanobrew's row as installed too.
- VoiceOver reads each run step's state and every progress spinner. Error lines in the run log have a warning symbol as well as red text.
- BrewxPort is open source under the MIT license.
- Each release comes as a signed and notarized app, `BrewxPort-X.Y.Z.zip`, plus the source as `brewxport-X.Y.Z.tar.gz`. To notarize your own build, run `scripts/build-app.sh --notarize PROFILE`.
