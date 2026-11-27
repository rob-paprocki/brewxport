# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release starts with an
**Upgrading:** line that says whether you need to do anything when you update.

## [Unreleased]

## [0.8.0] - 2026-11-27

**Upgrading:** If automatic updates are set to Update what doesn't need a password or Update everything, they now also update the tools BrewxPort finds from npm, pipx, uv, Cargo, Bun, RubyGems and Mint, except held ones. To keep a tool as it is, choose Ignore updates on its row.

### Added

- Seven language package managers: npm, pipx, uv, Cargo, Bun, RubyGems and Mint. BrewxPort lists, searches, installs, updates and removes the command-line tools you install with them, under a new Languages group in the sidebar. Each one has its own section on Updates, Installed and Discover, with an Update button on Updates. Their updates show in the menu bar and run in automatic updates.
- Set Up on a language package manager's page when you don't have it. It installs Homebrew's `node`, `pipx`, `uv`, `rustup` (then Rust's stable toolchain), `bun`, `ruby` or `mint`. On a Mac without Homebrew, pipx, uv, Rust and Mint come from MacPorts. No installer scripts are downloaded.
- Language tools never ask for a password and never run as root, so Update what doesn't need a password includes them.
- When your account can't change a package manager's folder, as with macOS's own Ruby, Install, Update and Uninstall are off for it, and its page says why and how to fix it. It offers Set Up Homebrew's Ruby… or Set Up Homebrew's Node… when Homebrew is there without that runtime and the two copies wouldn't clash.
- Held updates show a pause symbol and the reason, such as "Needs Rust 1.96" or "Came with Ruby", and automatic updates leave them out.
- When a registry doesn't answer for some tools, their section says how many it couldn't check, like "2 tools couldn't be checked", and still lists the rest.
- When your language tools run on Homebrew's Node, Ruby or Python, automatic updates hold back the updates that would break them: a new major version of Node, a new minor version of Ruby, and a `python@3.x` update when pipx or uv tools were made with its old copy (or BrewxPort can't tell). Updates that would bring one of those along wait too, and you get one notification instead. Updating it yourself shows a warning first. Afterwards, Repair tools on the npm, RubyGems, pipx or uv page rebuilds or reinstalls those tools.
- Before it removes a `python@3.x`, the Uninstall sheet names the pipx and uv tools that run on it and will stop working.
- Installed's mark for a package installed twice also covers the same tool from two package managers. It pairs them by the command they install, like `fd` from Homebrew's fd and Cargo's fd-find, or by name, like `ripgrep` from Homebrew and Cargo. It ticks the copy your login shell runs, or says when it can't tell, as when both copies are in one folder.
- A language package manager's page says when its folder for tools isn't on your PATH, and offers Add to PATH. RubyGems' folder is named but not added, because its name changes with each Ruby minor version.
- Bundle and Brewfile exports say in one line which language tools they leave out, like "Not included: 3 language tools (npm, Cargo)".
- Some steps take one tool at a time (pipx updates and removals, uv installs, Cargo installs and updates, and every Mint step), so BrewxPort runs one for each tool, and each tool gets its own result.
- Bun older than 1.4.5 shows as Too old, with how to update it.

### Changed

- Homebrew updates no longer remove a Node, Ruby or Python that Homebrew installed only as a dependency when your language tools run on it. The npm, RubyGems, pipx or uv page says so.

### Fixed

- Refresh (⌘R) and Check again read your login shell's PATH again. Before, BrewxPort read it once per launch, so a PATH you changed in Terminal only showed up after you quit and reopened BrewxPort.

## [0.7.0] - 2026-11-26

**Upgrading:** BrewxPort now stays in the menu bar when you close its window and checks for updates every 12 hours. To keep the old behaviour, set Settings > Check for updates to Never.

### Added

- A menu bar icon with an update count, and a menu with per-manager Update buttons, Update All…, Check Now and Refresh MacPorts….
- Scheduled update checks, every 12 hours by default, or every hour, 4 hours or 24 hours.
- Notifications when new updates are found and after automatic updates.
- Automatic updates in three modes: Notify me, Update what doesn't need a password, and Update everything.
- Automatic updates leave out a package when updating it would also update one you ignored or skipped, and a notification says so.
- A Settings window (⌘,) and a one-time sheet on first launch that explains background checks.
- Open BrewxPort at login.
- Refresh MacPorts… on the Updates page and in the menu bar menu.

### Changed

- MacPorts updates show up after MacPorts refreshes its own list. Every MacPorts update run does that first, and so does Refresh MacPorts….
- Every MacPorts update run starts by refreshing the port catalogue with `port selfupdate`, which may update MacPorts itself. If that fails, the upgrades are skipped.
- The Updates toolbar's Refresh button has a menu with Refresh MacPorts….

## [0.6.0] - 2026-11-25

**Upgrading:** nothing to do.

### Added

- Updates, Installed and Discover group packages by package manager. Each section shows a count and a collapse arrow. View > Group by Package Manager (⌥⌘G) turns it off and brings back the flat list.
- Each package manager's section on Updates has an Update button that updates only that manager. It asks for at most one password.

### Fixed

- Discover's engine picker shows the picked engine's name next to its icon. It used to show only the icon.
- Uninstalling a Homebrew package that's already gone (Homebrew says "No such keg") counts it as removed instead of failing.
- When a Homebrew formula you uninstall is already gone, BrewxPort no longer removes a cask with the same name in its place.
- Setting up MacPorts no longer reports a failure after MacPorts installed when BrewxPort's helper can't read one of your shell startup files, such as one still downloading from iCloud. The run log says it couldn't check your PATH instead.

## [0.5.0] - 2026-11-22

**Upgrading:** nothing to do.

### Added

- Uninstall offers leftovers: the Uninstall sheet lists the libraries only your picks used, under a ticked Also remove leftovers box. Untick it and only your picks go. Homebrew and MacPorts, apps included.

### Changed

- Uninstall shows a sheet with everything it will remove instead of a short confirmation.
- Uninstalling from Homebrew no longer removes unused libraries on its own. What's removed is what the Uninstall sheet lists.
- While a package manager setup waits for BrewxPort's helper, the setup offer says "Checking BrewxPort's helper…" and its rows and Set Up button are off until the helper answers.

### Fixed

- After setting up MacPorts, the run log says whether MacPorts was added to your PATH. Before, it always said it was.
- nanobrew packages that another nanobrew package needs are no longer removed by Uninstall. The sheet says what needs them.
- Network errors while setting up a package manager say what went wrong in plain words, like "no internet connection".
- When Homebrew reports "already locked" right after an install, the package list waits a moment and tries once more before showing the error.
- A failed nanobrew setup no longer leaves a folder behind that blocks the next try.
- When a run can't go ahead, its message shows at the bottom of the window. Before, a long message could push the window's content up under the title bar and the message out of sight.
- On a standard account, the Uninstall sheet says removing MacPorts or Mac App Store packages needs an administrator account, and only removes what that account can.

### Security

- BrewxPort's helper refuses MacPorts commands from accounts that aren't administrators.
- BrewxPort won't set up nanobrew in /opt when other users can write to /opt.

## [0.4.0] - 2026-11-22

**Upgrading:** nothing to do.

### Added

- Move to: right-click a command-line tool on Installed, or choose Package > Move to, to move it to Homebrew, nanobrew or MacPorts. Packages that need it move too, after a preview that lists everything. Old copies are removed only after the new ones are installed and checked, and leftover libraries are offered for removal. Moves between Homebrew and nanobrew need no password.
- Add to PATH on the Move to preview: when the other package manager's folder isn't on your PATH, one click adds the line to `~/.zprofile` or `~/.bash_profile`. Nothing is edited unless you click it.
- BrewxPort has an app icon: a ship carrying colored containers. Earlier versions showed macOS's blank app icon.
- A Helper row at the bottom of the sidebar shows whether BrewxPort's helper is ready or needs your approval. Its page says what the helper does, has Check again (and Reinstall helper when it's broken), and opens Login Items in System Settings, where macOS lists it. The helper used to show only on the MacPorts page.

### Changed

- A wrong administrator password brings the password sheet back, up to three tries, instead of ending the run. A new run's password sheet no longer shows the last run's error.

### Fixed

- The `.pkg` installer's Customize step shows a plain list: BrewxPort, ticked and greyed out, with the "Set up" checkbox below it. In 0.3.0 both sat under a row with no name and a half-ticked checkbox.
- The "Set up" checkbox's description says why it shows Zero KB: nothing is downloaded until BrewxPort next opens. For MacPorts it also mentions the 1.3 GB Command Line Tools download when they're missing.

## [0.3.0] - 2026-11-22

**Upgrading:** nothing to do.

### Added

- A Bundles page. Open a `.brewxportbundle` or a Brewfile from File > Open Bundle (⌘O) or by double-clicking a bundle in Finder. The preview groups packages by engine, marks what's already installed, and gives setup steps for a missing engine. It installs the ticked rows behind at most one password.
- Export everything installed to a `.brewxportbundle`, or to a Brewfile. The Brewfile holds only what `brew bundle` reads, and BrewxPort lists what it leaves out, by name, before it writes.
- An Include Dependencies in Exports option, in the File menu and the Bundles page's Export menu. Turn it off and exports hold only what you installed yourself. Packages that came in as another package's dependency are left out, and installing the file on another Mac brings them back. nanobrew doesn't record which packages were dependencies, so all of its packages stay in.
- Brewfile import lists every line or entry BrewxPort doesn't handle, with its line number and the reason, and counts the blank and comment lines. Nothing is dropped silently.
- Third-party taps are flagged and start unticked, unless a ticked package needs one. Homebrew 7's `trusted: true` on third-party formulae is accepted.
- Imported files are treated as untrusted. Only plain package, tap and App Store lines are read, and lines inside Ruby blocks aren't handled. BrewxPort follows simple platform checks like `if OS.mac?`; after any other Ruby code, every later line is marked not handled. Most options aren't applied, and files over 8 MB or 10,000 entries are refused.
- Version pins in a bundle are kept but not applied. Installing Mac App Store apps from a bundle hasn't been tested in a virtual machine yet.
- A setup screen at launch when none of the four package managers is set up, whether BrewxPort came from the `.pkg`, the DMG or the zip. It lists the recommended package manager first and the others below, with Set Up and Not now. If the helper still needs approval, it asks for it in System Settings > General > Login Items and carries on.
- Set up Homebrew, MacPorts, nanobrew or `mas` from inside BrewxPort: File > Set Up Package Manager…, the Set Up button on a missing package manager's Engines page, and the Bundles page's missing-engine banner. Each setup needs an administrator account. Homebrew, MacPorts and nanobrew ask for the password once, and `mas` asks only when it goes in through MacPorts.
- Homebrew and MacPorts come from their official installer packages, checked against the published checksum and Apple's notarization. Homebrew's signing team is checked too. nanobrew comes from its release archive, checked against both published checksums, and then `nb init` runs. `mas` installs through Homebrew or MacPorts. BrewxPort doesn't run downloaded scripts itself. The official Homebrew and MacPorts packages run their own install scripts through Apple's installer, and nanobrew's `nb init` runs once with your administrator password. BrewxPort doesn't edit your shell files, and the run log says whether each installer added itself to your PATH.
- MacPorts setup installs Apple's Command Line Tools first if they're missing, about 1.3 GB. Homebrew isn't offered on Intel Macs, which it no longer supports.
- The `.pkg` installer has a checkbox on its Customize step, ticked by default: "Set up Homebrew" on Apple silicon Macs, "Set up MacPorts" on Intel Macs. It only records your choice. BrewxPort starts that setup the next time it opens, after every `.pkg` install with the box ticked, upgrades included, unless the package manager is already there.

## [0.2.1] - 2026-11-21

**Upgrading:** nothing to do.

### Fixed

- Updates works from current Homebrew data. BrewxPort used to stop Homebrew from refreshing its list of available versions, so it only knew about releases up to the last time you ran `brew` in Terminal. It still doesn't update Homebrew itself or your taps.
- When something goes wrong in a run, the panel says "Finished with problems" instead of "Finished". That covers a step that failed or was skipped, such as app updates on an account that isn't an administrator.
- After an update, BrewxPort checks Updates again and names any package that's still out of date.

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
