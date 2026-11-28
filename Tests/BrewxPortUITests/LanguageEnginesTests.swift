import Foundation
import BrewxPortCore
import BrewxPortRun
import Testing
@testable import BrewxPortUI

/// A login shell whose PATH a test changes, as the person's would after Add to PATH. Counts `askAgain()`.
final class SettablePath: PathResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String]
    private var _askedAgain = 0

    init(_ entries: [String]) { _entries = entries }

    var entries: [String] {
        get { lock.withLock { _entries } }
        set { lock.withLock { _entries = newValue } }
    }

    var askedAgain: Int { lock.withLock { _askedAgain } }

    func resolve() async -> ResolvedPath { ResolvedPath(entries: entries, source: .loginShell) }

    func askAgain() { lock.withLock { _askedAgain += 1 } }
}

/// Plan 9 Task 10b: the language engines' place in the rest of BrewxPort. Where an engine can't write, the PATH note,
/// the warning before a runtime update that breaks tools, Repair tools, and the uninstall sheet's Python warning.
@MainActor @Suite struct LanguageEnginesTests {
    typealias F = AppFixtures

    static func tool(_ engine: EngineID, _ name: String, installed: String? = "1", latest: String? = "2") -> Package {
        Package(id: PackageRef(engine: engine, kind: .tool, name: name), displayName: name,
                installedVersion: installed, latestVersion: latest, installedOnRequest: true)
    }

    static func formula(_ name: String, _ installed: String, _ latest: String? = nil) -> Package {
        Package(id: PackageRef(engine: .homebrew, kind: .formula, name: name), displayName: name,
                installedVersion: installed, latestVersion: latest, installedOnRequest: true)
    }

    static let wget = formula("wget", "1.24", "1.25")

    /// A model on the four system engines plus `languages`, whose Updates holds `outdated` and Installed `installed`,
    /// both loaded and settled.
    func model(_ languages: [any Engine], outdated: [Package], installed: [Package] = [],
               executor: FakeRunExecutor = FakeRunExecutor(), catalog: FakeCatalog = FakeCatalog(),
               engines systemEngines: [any Engine] = PlanFixtures.engines, path: any PathResolving = AppFixtures.NoPath(),
               shellPath: ShellPathEditor? = nil) async -> BrewxPortAppModel {
        for (engine, found) in Dictionary(grouping: installed, by: \.id.engine) {
            catalog.script(.installed, engine, packages: found)
        }
        let services = F.services(catalog: catalog, executor: executor, engines: systemEngines + languages, path: path,
                                  shellPath: shellPath)
        let model = await F.updatesModel(outdated, catalog: catalog, services: services)
        await model.installed.settled()
        return model
    }

    /// Ends hanging run `run` with every step succeeding.
    static func succeed(_ executor: FakeRunExecutor, run: Int) {
        let steps = executor.runs[run].steps.indices
        executor.finish(steps.flatMap { [RunEvent.started($0), .finished($0, 0)] } + [.done])
    }

    // MARK: Permissions

    /// npm's global folder belongs to root (Node from nodejs.org): its page says why and how to fix it, and nothing
    /// installs, updates or removes its tools (by hand or automatically) until a check finds it fixed.
    @Test func rootOwnedPrefixDisablesChanges() async throws {
        let reason = "npm installs tools into /usr/local, which your account can't change. Give npm a folder of your "
            + "own with npm config set prefix ~/.npm-global, then add ~/.npm-global/bin to your PATH."
        let npm = FakeLanguageEngine(.npm, installLocation: URL(fileURLWithPath: "/usr/local", isDirectory: true),
                                     readOnlyReason: reason)
        let cowsay = Self.tool(.npm, "cowsay")
        let executor = FakeRunExecutor()
        let model = await model([npm], outdated: [cowsay, Self.wget], installed: [cowsay], executor: executor)
        #expect(model.readOnlyReason(for: .npm) == reason)
        #expect(model.installLocation(for: .npm) == "/usr/local")
        #expect(model.readOnlyReason(for: .homebrew) == nil)

        // Updates: held from every update, pointing at the page; out of Update all, the badge and automatic updates.
        let row = try #require(model.updates.list.byRef[cowsay.id])
        #expect(model.updates.hold(for: row) == UpdateHold(
            reason: "Your account can't change npm's tools. The npm page says how to fix that.",
            blocksAutomatic: true, blocksManual: true))
        #expect(model.updates.updateAllRequests().map(\.package.id) == [Self.wget.id])
        #expect(model.updates.automaticRequests().map(\.package.id) == [Self.wget.id])
        #expect(model.updates.badgeCount == 1)

        // Update, Uninstall and Install are off for its rows, each saying why, and the paths that skip the menus start
        // nothing. Installed still shows the update, off.
        for view in [PackageView.updates, .installed] {
            let menu = model.rowMenuItems(for: [cowsay.id], in: view)
            for action in [RowAction.update, .uninstall] {
                let item = menu.first { $0.action == action }
                #expect(item?.isEnabled == false, "\(view) \(action)")
                #expect(item?.help == reason, "\(view) \(action)")
            }
        }
        #expect(model.hasReadOnlyUpdate(cowsay.id))
        #expect(!model.hasReadOnlyUpdate(Self.wget.id))
        model.perform(.uninstall, on: [cowsay.id])
        #expect(model.uninstall.state == .hidden)
        let semver = Self.tool(.npm, "semver", installed: nil, latest: "7.8.6")
        let discover = await F.source([semver], in: model)
        let items = RowActions.items(for: [semver.id], in: .discover, rows: discover.byRef, outdated: [],
                                     prefs: model.preferences, isRunning: false, canRun: true,
                                     readOnlyEngines: [.npm: reason])
        #expect(items.first { $0.action == .install }?.isEnabled == false)
        #expect(items.first { $0.action == .install }?.help == reason)
        model.perform(.install, on: [semver.id])
        model.perform(.update, on: [cowsay.id])
        #expect(executor.runs.isEmpty)

        // Fixed (a prefix of the person's own) and Check again on its page: nothing is held back any more, at once.
        npm.readOnlyReason = nil
        let reloads = model.listReloadCount
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.checkingEngines })
        #expect(model.listReloadCount == reloads)
        #expect(model.updates.hold(for: try #require(model.updates.list.byRef[cowsay.id])) == nil)
        #expect(model.updates.updateAllRequests().count == 2)
        #expect(model.rowMenuItems(for: [cowsay.id], in: .installed).first { $0.action == .uninstall }?.isEnabled
                == true)
    }

    /// Post-VM fix: macOS's own Ruby held RubyGems' rows with "Your account can't change RubyGems's tools"; a name
    /// ending in "s" takes the apostrophe alone.
    @Test func readOnlyRubyGemsHoldSaysRubyGemsTools() async throws {
        let gem = FakeLanguageEngine(.gem, readOnlyReason: "This is macOS's own Ruby, and only an administrator can "
                                     + "change its gems.")
        let rake = Self.tool(.gem, "rake")
        let model = await model([gem], outdated: [rake])
        #expect(model.updates.hold(for: try #require(model.updates.list.byRef[rake.id]))?.reason
                == "Your account can't change RubyGems' tools. The RubyGems page says how to fix that.")
    }

    /// Post-VM fix: every language engine's page has the same Capabilities line, the one thing BrewxPort does with
    /// each, whatever its output format (npm's and pipx's said "Machine-readable output", the rest "Install, update and
    /// remove"). The system engines' lines are as they were.
    @Test func languageEnginesShareOneCapabilitiesLine() {
        for engine in EngineID.allCases where engine.isLanguage {
            for capabilities in [EngineCapabilities(), [.jsonOutput]] {
                #expect(EngineRowText.capabilityLines(for: engine, capabilities)
                        == ["Install, update and remove command-line tools"], "\(engine)")
            }
        }
        #expect(EngineRowText.capabilityLines(for: .homebrew, [.casks, .jsonOutput])
                == ["Casks (Mac apps)", "Machine-readable output"])
        #expect(EngineRowText.capabilityLines(for: .macports, [.sourceBuilds]) == ["Builds from source, with variants"])
        #expect(EngineRowText.capabilityLines(for: .mas, []) == ["Install, update and remove"])
    }

    /// R49: the page's plain Capabilities line is secondary, as 0.7.0 showed it: the line for an engine with no
    /// capabilities of its own (a not-installed engine's page), and every language engine's one line. A system
    /// engine's own capabilities stay primary.
    @Test func plainCapabilitiesLineIsSecondary() {
        #expect(EngineRowText.capabilityLinesArePlain(for: .macports, []))
        #expect(EngineRowText.capabilityLinesArePlain(for: .mas, []))
        for engine in EngineID.allCases where engine.isLanguage {
            #expect(EngineRowText.capabilityLinesArePlain(for: engine, []), "\(engine)")
            #expect(EngineRowText.capabilityLinesArePlain(for: engine, [.jsonOutput]), "\(engine)")
        }
        #expect(!EngineRowText.capabilityLinesArePlain(for: .homebrew, [.casks, .jsonOutput]))
        #expect(!EngineRowText.capabilityLinesArePlain(for: .macports, [.sourceBuilds]))
        #expect(!EngineRowText.capabilityLinesArePlain(for: .mas, [.jsonOutput]))
    }

    /// A person's update that worked, whose package now offers a newer version held back for its own reason (a crate
    /// updated to 15 whose 16 needs a newer Rust), isn't "still out of date" in the run panel.
    @Test func heldNewerVersionAfterAPersonsUpdateIsntStillOutOfDate() async throws {
        let cargo = FakeLanguageEngine(.cargo)
        let ripgrep = Self.tool(.cargo, "ripgrep", installed: "14.1.0", latest: "15.0.0")
        let catalog = FakeCatalog()
        let executor = FakeRunExecutor(events: [], hang: true)
        let model = await model([cargo], outdated: [ripgrep], executor: executor, catalog: catalog)
        model.perform(.update, on: [ripgrep.id])
        #expect(await waitUntil { executor.runs.count == 1 })
        var after = ripgrep
        after.installedVersion = "15.0.0"
        after.latestVersion = "16.0.0"
        let hold = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        catalog.script(.outdated, .cargo, FakeCatalog.Script(result: .success([]),
                                                             held: [HeldUpdate(package: after, hold: hold)]))
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { !model.run.isRunning && model.updates.list.byRef[ripgrep.id]?.hold == hold })
        await model.updates.reloaded()
        #expect(!model.run.problems.contains { $0.hasPrefix("Still out of date") })
    }

    // MARK: The PATH note

    /// A manager's bin folder that isn't on the login shell's PATH: its page says so and offers the existing Add to
    /// PATH, which writes the line to the shell's startup file; once the shell has it, the note goes.
    @Test func missingBinFolderOffersAddToPath() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cargoBin = home.path + "/.cargo/bin"
        let cargo = FakeLanguageEngine(.cargo, binLocation: URL(fileURLWithPath: cargoBin, isDirectory: true))
        let bun = FakeLanguageEngine(.bun, binLocation: URL(fileURLWithPath: "/opt/homebrew/bin/", isDirectory: true))
        let unsafe = FakeLanguageEngine(.mint, binLocation: URL(fileURLWithPath: home.path + "/$(id)/bin"))
        let gems = "/opt/homebrew/lib/ruby/gems/4.0.0/bin"
        let gem = FakeLanguageEngine(.gem, binLocation: URL(fileURLWithPath: gems, isDirectory: true))
        let path = SettablePath(["/opt/homebrew/bin", "/usr/bin"])
        let model = await model([cargo, bun, unsafe, gem], outdated: [], path: path,
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        let note = try #require(model.pathNote(for: .cargo))
        #expect(note.text == "\(cargoBin) isn't on your PATH, so your shell doesn't find Cargo's tools.")
        #expect(note.line == ShellPathEditor.line(for: cargoBin))
        #expect(model.pathOffer == .append(ShellPathEditor.Target(file: "~/.zprofile", path: home.path + "/.zprofile")))
        #expect(model.pathNote(for: .bun) == nil)
        #expect(model.pathNote(for: .homebrew) == nil)
        // A folder a shell would read as code is named, but never offered.
        #expect(model.pathNote(for: .mint)?.line == nil)
        // RubyGems' bin folder carries its Ruby version: named, with why, never added (the line would go stale).
        #expect(model.pathNote(for: .gem) == PathNote(
            text: "\(gems) isn't on your PATH, so your shell doesn't find RubyGems' tools. Its name changes with each "
                + "Ruby minor version, so BrewxPort doesn't add it for you.", line: nil, bin: gems))
        model.addToPath(.gem)
        #expect(model.pathFix(for: .gem) == .offered)

        model.addToPath(.cargo)
        #expect(model.pathFix(for: .cargo) == .done(.added(file: "~/.zprofile")))
        #expect(try String(contentsOf: home.appendingPathComponent(".zprofile"), encoding: .utf8)
                == ShellPathEditor.line(for: cargoBin) + "\n")
        model.addToPath(.mint)
        #expect(model.pathFix(for: .mint) == .offered)
        path.entries.insert(cargoBin, at: 0)
        #expect(await waitUntil { model.pathNote(for: .cargo) == nil })
    }

    /// R30: Homebrew's Ruby is installed (keg folder `opt/ruby/bin`), but the login shell still finds macOS's gem first.
    /// RubyGems stays read-only and its Set Up isn't offered again; the page says Homebrew's Ruby needs the PATH line and
    /// offers Add to PATH for that folder. Once the PATH has it, the note goes.
    @Test func homebrewRubyInstalledButNotOnPathShowsPathNote() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let systemReason = "This is macOS's own Ruby, and only an administrator can change its gems. Set up "
            + "Homebrew's Ruby to manage gems with BrewxPort."
        let gem = FakeLanguageEngine(.gem, binLocation: URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                                     readOnlyReason: systemReason)
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let catalog = FakeCatalog(engines: [.homebrew: brew,
                                            .gem: .present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5")])
        catalog.script(.installed, .homebrew, packages: [Self.formula("ruby", "4.0.10")])
        let path = SettablePath(["/opt/homebrew/bin", "/usr/bin"])
        let model = await model([gem], outdated: [], catalog: catalog, path: path,
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        let folder = "/opt/homebrew/opt/ruby/bin"
        #expect(model.setupButton(for: .gem) == .hidden)
        #expect(model.setupLine(for: .gem) == nil)
        let note = try #require(model.pathNote(for: .gem))
        #expect(note.text == "Homebrew's Ruby is installed, but \(folder) isn't on your PATH, so your shell still runs "
                + "macOS's own Ruby.")
        #expect(note.line == ShellPathEditor.line(for: folder))
        // Post-VM fix: Add to PATH checks the engine again itself, so the page no longer asks for Check again...
        #expect(model.readOnlyReason(for: .gem) == "This is macOS's own Ruby, and only an administrator can change its "
                + "gems. Homebrew's Ruby is installed: add it to your PATH below.")
        model.addToPath(.gem)
        #expect(model.pathFix(for: .gem) == .done(.added(file: "~/.zprofile")))
        #expect(try String(contentsOf: home.appendingPathComponent(".zprofile"), encoding: .utf8)
                == ShellPathEditor.line(for: folder) + "\n")
        path.entries.insert(folder, at: 0)
        #expect(await waitUntil { model.pathNote(for: .gem) == nil })

        // ...except where the person adds the line themselves (a shell BrewxPort doesn't write to, fish).
        let fish = await self.model([gem], outdated: [], catalog: catalog,
                                    path: SettablePath(["/opt/homebrew/bin", "/usr/bin"]),
                                    shellPath: ShellPathEditor(home: home, shell: "/opt/homebrew/bin/fish"))
        fish.checkEnginesAgain()
        #expect(await waitUntil { fish.enginesChecked && fish.pathNote(for: .gem) != nil })
        #expect(fish.readOnlyReason(for: .gem) == "This is macOS's own Ruby, and only an administrator can change its "
                + "gems. Homebrew's Ruby is installed: add it to your PATH below, then click Check again.")

        // ...or where BrewxPort won't write the folder (a shell would read `$` as code): no line, no Add to PATH.
        let odd = FakeCatalog(engines: [.homebrew: .present(path: URL(fileURLWithPath: "/opt/home$brew/bin/brew"),
                                                            version: "4"),
                                        .gem: .present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5")])
        odd.script(.installed, .homebrew, packages: [Self.formula("ruby", "4.0.10")])
        let unwritten = await self.model([gem], outdated: [], catalog: odd,
                                         path: SettablePath(["/opt/homebrew/bin", "/usr/bin"]),
                                         shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        unwritten.checkEnginesAgain()
        #expect(await waitUntil { unwritten.enginesChecked && unwritten.pathNote(for: .gem) != nil })
        #expect(unwritten.pathNote(for: .gem)?.line == nil)
        #expect(unwritten.readOnlyReason(for: .gem) == "This is macOS's own Ruby, and only an administrator can change "
                + "its gems. Homebrew's Ruby is installed: add it to your PATH below, then click Check again.")
    }

    /// R49: when Add to PATH couldn't write the line (here ~/.zprofile is a folder), the person adds it themselves, so
    /// RubyGems' reason asks for Check again after, as it does where Add to PATH isn't offered.
    @Test func failedAddToPathAsksForCheckAgain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zprofile"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let gem = FakeLanguageEngine(.gem, binLocation: URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                                     readOnlyReason: "This is macOS's own Ruby, and only an administrator can change "
                                     + "its gems.")
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let system = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .gem: system])
        catalog.script(.installed, .homebrew, packages: [Self.formula("ruby", "4.0.10")])
        let model = await model([gem], outdated: [], catalog: catalog,
                                path: SettablePath(["/opt/homebrew/bin", "/usr/bin"]),
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked && model.pathNote(for: .gem) != nil })
        let reason = "This is macOS's own Ruby, and only an administrator can change its gems. Homebrew's Ruby is "
            + "installed: add it to your PATH below"
        #expect(model.readOnlyReason(for: .gem) == reason + ".")
        model.addToPath(.gem)
        #expect(model.pathFix(for: .gem) == .failed("~/.zprofile isn't a regular file, so BrewxPort didn't change it."))
        #expect(model.readOnlyReason(for: .gem) == reason + ", then click Check again.")
    }

    /// Post-VM fix (VM 1): RubyGems kept showing macOS's Ruby after Add to PATH until Check again. Add to PATH now asks
    /// the login shell again and detects the engines once its line is written, so the page moves to Homebrew's Ruby.
    @Test func addToPathChecksTheEngineAgain() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let gem = FakeLanguageEngine(.gem, binLocation: URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                                     readOnlyReason: "This is macOS's own Ruby, and only an administrator can change "
                                     + "its gems.")
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let system = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5.22")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .gem: system])
        catalog.script(.installed, .homebrew, packages: [Self.formula("ruby", "4.0.10")])
        let path = SettablePath(["/opt/homebrew/bin", "/usr/bin"])
        let model = await model([gem], outdated: [], catalog: catalog, path: path,
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked && model.pathNote(for: .gem) != nil })
        #expect(model.engineStatuses[.gem] == system)

        // The line goes in; the shell now finds Homebrew's gem, which this account can change.
        let folder = "/opt/homebrew/opt/ruby/bin"
        let homebrewGem = EngineStatus.present(path: URL(fileURLWithPath: folder + "/gem"), version: "4.1.0")
        catalog.setEngines([.homebrew: brew, .gem: homebrewGem])
        gem.readOnlyReason = nil
        path.entries.insert(folder, at: 0)
        let asked = path.askedAgain
        model.addToPath(.gem)
        #expect(model.pathFix(for: .gem) == .done(.added(file: "~/.zprofile")))
        #expect(model.checkingEngines)
        #expect(path.askedAgain > asked)
        #expect(await waitUntil { model.engineStatuses[.gem] == homebrewGem })
        #expect(model.readOnlyReason(for: .gem) == nil)
        #expect(await waitUntil { model.pathNote(for: .gem) == nil })
    }

    /// Post-VM fix: Add to PATH's check of the engines is never dropped. During a run it waits for the run's end, which
    /// checks them again; while another check is going (it may have read the shell before the line went in), it
    /// follows that one.
    @Test func addToPathCheckWaitsForTheRunOrTheCheckGoing() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let crates = home.path + "/.cargo/bin"
        let cargo = FakeLanguageEngine(.cargo, binLocation: URL(fileURLWithPath: crates, isDirectory: true))
        let keg = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/cargo"),
                                       version: "1.100.0")
        let own = EngineStatus.present(path: URL(fileURLWithPath: crates + "/cargo"), version: "1.100.0")
        let catalog = FakeCatalog(engines: [.cargo: keg])
        let executor = FakeRunExecutor(events: [], hang: true)
        let model = await model([cargo], outdated: [Self.wget], executor: executor, catalog: catalog,
                                path: SettablePath(["/opt/homebrew/bin", "/usr/bin"]),
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked && model.pathNote(for: .cargo) != nil })

        // During a run: nothing is checked until it ends, then the engines are.
        model.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 1 && model.run.isRunning })
        catalog.setEngines([.cargo: own])
        let asked = catalog.enginesAsked
        model.addToPath(.cargo)
        #expect(model.pathFix(for: .cargo) == .done(.added(file: "~/.zprofile")))
        #expect(!model.checkingEngines && catalog.enginesAsked == asked)
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { !model.run.isRunning && model.engineStatuses[.cargo] == own })

        // A check going that read the engines before the line went in (the keg's cargo): another follows it.
        #expect(await waitUntil { !model.checkingEngines })
        catalog.setEngines([.cargo: keg])
        let gate = Gate()
        catalog.enginesGate = gate
        model.checkEnginesAgain()
        #expect(await waitUntil { gate.waiting == 1 })
        catalog.setEngines([.cargo: own])
        catalog.enginesGate = nil
        let before = catalog.enginesAsked
        model.addToPath(.cargo)
        #expect(model.pathFix(for: .cargo) == .done(.alreadyPresent(file: "~/.zprofile")))
        gate.release()
        #expect(await waitUntil {
            !model.checkingEngines && catalog.enginesAsked == before + 1 && model.engineStatuses[.cargo] == own
        })
    }

    /// Post-VM fix (VM 2): after a check found RubyGems on Homebrew's Ruby, macOS's Ruby's `rake` stayed on Updates
    /// with an Update button. A language engine whose executable changed loses its rows on Updates and Installed at
    /// once, and both lists load again from the copy found; the other engines' rows stay meanwhile.
    @Test func anotherCopyOfAnEngineReloadsItsRows() async throws {
        let gem = FakeLanguageEngine(.gem, readOnlyReason: "This is macOS's own Ruby, and only an administrator can "
                                     + "change its gems.")
        let rake = Self.tool(.gem, "rake", installed: "13.1.0", latest: "13.3.1")
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let system = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5.22")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .gem: system])
        let model = await model([gem], outdated: [rake, Self.wget], installed: [rake], catalog: catalog)
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        #expect(model.updates.hold(for: try #require(model.updates.list.byRef[rake.id]))?.blocksManual == true)
        #expect(model.installed.list.byRef[rake.id] != nil)

        // Homebrew's Ruby is found now; its gems answer only once released.
        let rubocop = Self.tool(.gem, "rubocop", installed: "1.80.0", latest: "1.81.0")
        let gate = Gate()
        catalog.script(.outdated, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: gate))
        catalog.script(.installed, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: gate))
        let homebrewGem = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/opt/ruby/bin/gem"),
                                               version: "4.1.0")
        catalog.setEngines([.homebrew: brew, .gem: homebrewGem])
        gem.readOnlyReason = nil
        let reloads = model.listReloadCount
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.checkingEngines && model.engineStatuses[.gem] == homebrewGem })
        #expect(model.updates.list.byRef[rake.id] == nil)
        #expect(model.installed.list.byRef[rake.id] == nil)
        #expect(model.updates.updateAllRequests().map(\.package.id) == [Self.wget.id])
        #expect(model.updates.list.byRef[Self.wget.id] != nil)
        #expect(model.listReloadCount == reloads + 1)

        #expect(await waitUntil { gate.waiting == 2 })
        gate.release()
        #expect(await waitUntil {
            model.updates.list.byRef[rubocop.id] != nil && model.installed.list.byRef[rubocop.id] != nil
        })
        await model.updates.reloaded()
        await model.installed.settled()
        #expect(model.updates.list.byRef[rake.id] == nil)
        #expect(Set(model.updates.updateAllRequests().map(\.package.id)) == [rubocop.id, Self.wget.id])

        // Checked again with nothing changed: nothing reloads.
        let settled = model.listReloadCount
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.checkingEngines })
        #expect(model.listReloadCount == settled)
    }

    /// R49: a Set Up run's end loads the lists once, though the check after it finds RubyGems on Homebrew's Ruby. The
    /// run end's reload read the login shell again first, so it already asks the new copy: the check takes out only
    /// the rows the old copy listed that this reload hasn't replaced yet, at once, and leaves the reload's answer in.
    @Test func setUpRunEndLoadsTheListsOnce() async throws {
        let gem = FakeLanguageEngine(.gem, readOnlyReason: "This is macOS's own Ruby, and only an administrator can "
                                     + "change its gems.")
        let rake = Self.tool(.gem, "rake", installed: "13.1.0", latest: "13.3.1")
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let system = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5.22")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .gem: system])
        catalog.script(.installed, .homebrew, packages: [])
        let executor = FakeRunExecutor(events: [], hang: true)
        let model = await model([gem], outdated: [rake, Self.wget], installed: [rake], executor: executor,
                                catalog: catalog)
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        #expect(model.setUpEngine(.gem))
        #expect(await waitUntil { executor.runs.count == 1 && model.run.isRunning })

        // The run installs Homebrew's Ruby; the shell now finds its gem, whose gems answer once released.
        let homebrewGem = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/opt/ruby/bin/gem"),
                                               version: "4.1.0")
        catalog.setEngines([.homebrew: brew, .gem: homebrewGem])
        gem.readOnlyReason = nil
        let rubocop = Self.tool(.gem, "rubocop", installed: "1.80.0", latest: "1.81.0")
        let gate = Gate()
        catalog.script(.outdated, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: gate))
        catalog.script(.installed, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: gate))
        let reloads = model.listReloadCount
        Self.succeed(executor, run: 0)
        #expect(await waitUntil {
            !model.run.isRunning && !model.checkingEngines && model.engineStatuses[.gem] == homebrewGem
        })
        // macOS's Ruby's rake is gone at once, and nothing would update it with the new copy.
        #expect(model.updates.list.byRef[rake.id] == nil)
        #expect(model.installed.list.byRef[rake.id] == nil)
        #expect(model.updates.updateAllRequests().map(\.package.id) == [Self.wget.id])
        #expect(model.updates.list.byRef[Self.wget.id] != nil)

        // The run end's reload brings Homebrew's Ruby's gems; nothing loads them again.
        #expect(await waitUntil { gate.waiting == 2 })
        gate.release()
        #expect(await waitUntil {
            model.updates.list.byRef[rubocop.id] != nil && model.installed.list.byRef[rubocop.id] != nil
        })
        #expect(await waitUntil { !model.updates.list.loading && !model.installed.list.loading })
        #expect(model.listReloadCount == reloads + 1)
        #expect(model.updates.list.byRef[rake.id] == nil)
        gate.release()
    }

    /// Post-VM fix (VM 2), with the lists still loading: a load that had asked macOS's Ruby's gem before the check found
    /// Homebrew's Ruby answers after it. That late answer from the old copy is left out, so `rake` doesn't come back
    /// with an Update button; the load queued after it lists the new copy's gems.
    @Test func oldCopysLateAnswerIsLeftOut() async throws {
        let gem = FakeLanguageEngine(.gem, readOnlyReason: "This is macOS's own Ruby, and only an administrator can "
                                     + "change its gems.")
        let rake = Self.tool(.gem, "rake", installed: "13.1.0", latest: "13.3.1")
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let system = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5.22")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .gem: system])
        let model = await model([gem], outdated: [rake, Self.wget], installed: [rake], catalog: catalog)
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })

        // A Refresh asks the old copy, which answers only once released.
        let old = Gate()
        catalog.script(.outdated, .gem, FakeCatalog.Script(result: .success([rake]), gate: old))
        catalog.script(.installed, .gem, FakeCatalog.Script(result: .success([rake]), gate: old))
        model.refresh()
        #expect(await waitUntil { old.waiting == 2 })

        // Meanwhile a check finds Homebrew's Ruby, whose gems answer once released.
        let new = Gate()
        let rubocop = Self.tool(.gem, "rubocop", installed: "1.80.0", latest: "1.81.0")
        catalog.script(.outdated, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: new))
        catalog.script(.installed, .gem, FakeCatalog.Script(result: .success([rubocop]), gate: new))
        let homebrewGem = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/opt/ruby/bin/gem"),
                                               version: "4.1.0")
        catalog.setEngines([.homebrew: brew, .gem: homebrewGem])
        gem.readOnlyReason = nil
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.checkingEngines && model.engineStatuses[.gem] == homebrewGem })

        // The old copy answers late: left out, on both lists.
        old.release()
        #expect(await waitUntil { new.waiting == 2 })
        #expect(model.updates.list.byRef[rake.id] == nil)
        #expect(model.installed.list.byRef[rake.id] == nil)
        #expect(model.updates.updateAllRequests().map(\.package.id) == [Self.wget.id])

        new.release()
        #expect(await waitUntil {
            model.updates.list.byRef[rubocop.id] != nil && model.installed.list.byRef[rubocop.id] != nil
        })
        await model.updates.reloaded()
        #expect(model.updates.list.byRef[rake.id] == nil)
    }

    /// Which language engines a check found on another copy: another executable, or none where there was one. Not one
    /// newly found (no rows came from it), one whose version alone changed, a system engine, or any at the first check.
    @Test func whichEnginesMovedBetweenChecks() {
        func at(_ path: String, _ version: String = "1") -> EngineStatus {
            .present(path: URL(fileURLWithPath: path), version: version)
        }
        let before: [EngineID: EngineStatus] = [
            .gem: at("/usr/bin/gem"), .npm: at("/opt/homebrew/bin/npm"), .pipx: at("/opt/homebrew/bin/pipx"),
            .uv: .missing, .cargo: .unusable(path: URL(fileURLWithPath: "/Users/someone/.cargo/bin/cargo"), reason: "x"),
            .bun: .unsupported(path: URL(fileURLWithPath: "/opt/homebrew/bin/bun"), version: "1.2", reason: "old"),
            .homebrew: at("/opt/homebrew/bin/brew"),
        ]
        let after: [EngineID: EngineStatus] = [
            .gem: at("/opt/homebrew/opt/ruby/bin/gem"), .npm: at("/opt/homebrew/bin/npm", "11.6.2"), .pipx: .missing,
            .uv: at("/opt/homebrew/bin/uv"), .cargo: at("/Users/someone/.cargo/bin/cargo"),
            .bun: at("/Users/someone/.bun/bin/bun"), .homebrew: at("/usr/local/bin/brew"),
        ]
        #expect(BrewxPortAppModel.movedLanguageEngines(from: before, to: after) == [.gem, .pipx, .bun])
        #expect(BrewxPortAppModel.movedLanguageEngines(from: [:], to: after).isEmpty)
        #expect(BrewxPortAppModel.movedLanguageEngines(from: after, to: after).isEmpty)
    }

    /// Fix round 1: Homebrew's rustup is keg-only, so after its Set Up `cargo` and `rustup` are in
    /// `<prefix>/opt/rustup/bin` (found through the Cellar), off the PATH. Cargo's page names that folder beside
    /// `~/.cargo/bin` (where installed crates go), and Add to PATH adds both; once the PATH has the keg folder, only
    /// the crates' folder is left.
    @Test func homebrewRustupKegGetsAPathNote() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let crates = home.path + "/.cargo/bin"
        let keg = "/opt/homebrew/opt/rustup/bin"
        let cargo = FakeLanguageEngine(.cargo, binLocation: URL(fileURLWithPath: crates, isDirectory: true))
        let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
        let found = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/Cellar/rustup/1.29.2/bin/cargo"),
                                         version: "1.100.0")
        let catalog = FakeCatalog(engines: [.homebrew: brew, .cargo: found])
        let path = SettablePath(["/opt/homebrew/bin", "/usr/bin"])
        let model = await model([cargo], outdated: [], catalog: catalog, path: path,
                                shellPath: ShellPathEditor(home: home, shell: "/bin/zsh"))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        let note = try #require(model.pathNote(for: .cargo))
        #expect(note.text == "\(keg) and \(crates) aren't on your PATH, so your shell doesn't find Homebrew's cargo or "
                + "the tools Cargo installs.")
        #expect(note.line == ShellPathEditor.line(for: keg) + "\n" + ShellPathEditor.line(for: crates))
        #expect(EngineDetailText.pathCaption(model.pathOffer, lines: 2) == "Adds these lines to ~/.zprofile:")
        #expect(EngineDetailText.pathCaption(model.pathOffer, lines: 1) == "Adds this line to ~/.zprofile:")
        model.addToPath(.cargo)
        #expect(model.pathFix(for: .cargo) == .done(.added(file: "~/.zprofile")))
        #expect(try String(contentsOf: home.appendingPathComponent(".zprofile"), encoding: .utf8)
                == ShellPathEditor.line(for: keg) + "\n" + ShellPathEditor.line(for: crates) + "\n")

        // The keg folder on the PATH: only the crates' folder is left, as before.
        path.entries = [keg, "/opt/homebrew/bin", "/usr/bin"]
        model.refresh()
        #expect(await waitUntil {
            model.pathNote(for: .cargo)?.text == "\(crates) isn't on your PATH, so your shell doesn't find Cargo's tools."
        })
        // Only the keg folder missing.
        path.entries = [crates, "/opt/homebrew/bin", "/usr/bin"]
        model.refresh()
        #expect(await waitUntil {
            model.pathNote(for: .cargo)?.text == "\(keg) isn't on your PATH, so your shell doesn't find Homebrew's "
                + "cargo and rustup."
        })
        #expect(model.pathNote(for: .cargo)?.line == ShellPathEditor.line(for: keg))
    }

    /// The design: npm's page says its list is nvm's current default Node's when the npm it uses is nvm's; one that
    /// isn't a version manager's has no such line, and nor does a manager whose tools don't belong to one version.
    @Test func enginePageSaysWhichVersionTheListIsFor() async {
        let nvm = EngineStatus.present(path: URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm"),
                                       version: "10.9.0")
        let rbenv = EngineStatus.present(path: URL(fileURLWithPath: "/Users/someone/.rbenv/shims/gem"), version: "3.6.2")
        let homebrewGem = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/opt/ruby/bin/gem"),
                                               version: "4.1.0")
        let pipx = EngineStatus.present(path: URL(fileURLWithPath: "/Users/someone/.asdf/shims/pipx"), version: "1.8.0")
        for (gem, expected) in [(rbenv, "The list is for rbenv's current default Ruby. Other Ruby versions keep their "
                                    + "own gems."), (homebrewGem, nil)] as [(EngineStatus, String?)] {
            let catalog = FakeCatalog(engines: [.npm: nvm, .gem: gem, .pipx: pipx])
            let model = BrewxPortAppModel(services: F.services(catalog: catalog))
            model.checkEnginesAgain()
            #expect(await waitUntil { model.enginesChecked })
            #expect(model.versionManagerNote(for: .npm) == "The list is for nvm's current default Node. Other Node "
                    + "versions keep their own tools.")
            #expect(model.versionManagerNote(for: .gem) == expected)
            #expect(model.versionManagerNote(for: .pipx) == nil)
            #expect(model.versionManagerNote(for: .cargo) == nil)
        }
    }

    // MARK: Runtimes and Repair tools

    /// Updating a Ruby that RubyGems' tools run on, by hand, asks first; the update then runs, and once it has,
    /// the RubyGems page offers Repair tools, which installs again the tools Installed showed before the update.
    @Test func manualRuntimeUpdateWarns() async throws {
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], repairsOneAtATime: true)
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let lolcat = Self.tool(.gem, "lolcat", installed: "100.0.0", latest: nil)
        let catalog = FakeCatalog()
        // Nothing depends on Ruby or is needed by it, so updating wget doesn't bring it along.
        for name in ["ruby", "wget"] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        }
        let executor = FakeRunExecutor(events: [], hang: true)
        let model = await model([gem], outdated: [ruby, Self.wget], installed: [lolcat, ruby, Self.wget],
                                executor: executor, catalog: catalog,
                                engines: [MoveFakeEngine(wrapping: PlanFixtures.engines[0])]
                                    + PlanFixtures.engines.dropFirst())
        model.updateAll()
        #expect(executor.runs.isEmpty)
        let warning = try #require(model.runtimeWarning)
        #expect(warning.title == "Update Ruby?")
        #expect(warning.message == "Ruby 4.1 needs your gems reinstalled. After the update, use Repair tools on the "
                + "RubyGems page.")
        #expect(model.modalUp)
        model.cancelRuntimeUpdate()
        #expect(model.runtimeWarning == nil)
        #expect(executor.runs.isEmpty)

        // An update that leaves Ruby alone doesn't ask.
        model.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(model.runtimeWarning == nil)
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { !model.run.isRunning })

        model.updateAll()
        model.confirmRuntimeUpdate()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(Set(executor.runs[1].steps.flatMap(\.refs)) == [ruby.id, Self.wget.id])
        #expect(model.repairOffer(for: .gem) == nil)
        // The new Ruby's gem folder is empty: lolcat isn't listed any more.
        catalog.script(.installed, .gem, packages: [])
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { model.repairOffer(for: .gem) != nil })
        #expect(model.repairOffer(for: .gem) == "Ruby was updated, so your gems need reinstalling. Repair tools "
                + "does that.")
        #expect(model.repairOffer(for: .npm) == nil)

        model.repairTools(.gem)
        #expect(await waitUntil { executor.runs.count == 3 })
        let steps = executor.runs[2].steps
        #expect(steps.map(\.spec.arguments) == [["repair", "lolcat"]])
        #expect(steps.map(\.title) == ["RubyGems: lolcat"])
        #expect(steps.allSatisfy { $0.operation == .repair && RunRouting.route(for: $0) == .user })
        #expect(model.repairOffer(for: .gem) == nil)
    }

    /// An update that `brew upgrade` would bring a held runtime along with (yarn needs node) asks first, as an update of
    /// the runtime does, and once it ran, npm's page offers Repair tools.
    @Test func manualUpdateBringingAHeldRuntimeAlongWarns() async throws {
        let node = Self.formula("node", "25.2.1", "26.0.0")
        let yarn = Self.formula("yarn", "1.22.21", "1.22.22")
        let npm = FakeLanguageEngine(.npm, uses: [RuntimeUse(formula: "node")], repairsOneAtATime: true)
        let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        brew.setDependents("node", ["yarn"])
        let catalog = FakeCatalog()
        for (name, needs) in [("node", [String]()), ("yarn", ["node"]), ("wget", [])] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: needs))))
        }
        let cowsay = Self.tool(.npm, "cowsay", latest: nil)
        let executor = FakeRunExecutor(events: [], hang: true)
        let model = await model([npm], outdated: [node, yarn, Self.wget], installed: [node, yarn, Self.wget, cowsay],
                                executor: executor, catalog: catalog,
                                engines: [brew] + PlanFixtures.engines.dropFirst())
        #expect(model.updates.runtimesBroughtAlong(by: yarn.id) == [node.id])
        model.perform(.update, on: [yarn.id])
        #expect(executor.runs.isEmpty)
        let warning = try #require(model.runtimeWarning)
        #expect(warning.title == "Update Node?")
        #expect(warning.message == "Updating yarn also updates Node. Node 26 needs your npm tools rebuilt. After the "
                + "update, use Repair tools on the npm page.")
        // wget brings nothing along: no warning.
        model.cancelRuntimeUpdate()
        model.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(model.runtimeWarning == nil)
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { !model.run.isRunning })

        model.perform(.update, on: [yarn.id])
        model.confirmRuntimeUpdate()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(executor.runs[1].steps.flatMap(\.refs) == [yarn.id])
        // Homebrew brought node along: Installed shows the new version after the run.
        var updated = node
        updated.installedVersion = "26.0.0"
        catalog.script(.installed, .homebrew, packages: [updated, yarn, Self.wget])
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { model.repairOffer(for: .npm) != nil })
        #expect(model.repairOffer(for: .npm) == "Node was updated, so your npm tools need rebuilding. Repair tools "
                + "does that.")
    }

    /// When Homebrew's relations couldn't be read, an update only may bring the runtime along: the warning says
    /// "may", and Repair tools is offered only if the runtime's version did change.
    @Test func unreadRelationsSayMayAndOfferRepairOnlyIfTheRuntimeChanged() async throws {
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], repairsOneAtATime: true)
        let catalog = FakeCatalog()
        let executor = FakeRunExecutor(events: [], hang: true)
        // The plain Homebrew engine can't say what depends on Ruby here (its runner knows no `brew uses`).
        let model = await model([gem], outdated: [ruby, Self.wget], installed: [ruby, Self.wget], executor: executor,
                                catalog: catalog)
        #expect(model.updates.runtimesBroughtAlong(by: Self.wget.id) == [ruby.id])
        model.perform(.update, on: [Self.wget.id])
        #expect(model.runtimeWarning?.message == "Updating wget may also update Ruby. Ruby 4.1 needs your gems "
                + "reinstalled. After the update, use Repair tools on the RubyGems page.")
        model.confirmRuntimeUpdate()
        #expect(await waitUntil { executor.runs.count == 1 })
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { !model.run.isRunning })
        await model.installed.settled()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.repairOffer(for: .gem) == nil)

        // This time Homebrew did update Ruby along with wget.
        model.perform(.update, on: [Self.wget.id])
        model.confirmRuntimeUpdate()
        #expect(await waitUntil { executor.runs.count == 2 })
        var updated = ruby
        updated.installedVersion = "4.1.0"
        catalog.script(.installed, .homebrew, packages: [updated, Self.wget])
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { model.repairOffer(for: .gem) != nil })
    }

    /// Final review: the runtime holds are worked out after Updates has loaded (the engines are asked what their tools
    /// run on, then Homebrew's relations are read), and a manual update started meanwhile, as at launch, fails
    /// closed. The runtime's own update warns as if every installed engine's tools ran on it, any other Homebrew
    /// update "may also update" it, and once confirmed, Repair tools is offered as usual. An automatic run starts
    /// nothing then. Once the holds are in, the warning follows them: wget, which Ruby isn't related to, runs.
    @Test func manualUpdateWhileHoldsArePendingWarns() async throws {
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], repairsOneAtATime: true)
        let gate = Gate()
        gem.usesGate = gate
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let lolcat = Self.tool(.gem, "lolcat", installed: "100.0.0", latest: nil)
        let catalog = FakeCatalog()
        // Nothing depends on Ruby or is needed by it, so once the relations are read, updating wget doesn't bring it
        // along.
        for name in ["ruby", "wget"] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        }
        catalog.script(.installed, .homebrew, packages: [ruby, Self.wget])
        catalog.script(.installed, .gem, packages: [lolcat])
        catalog.script(.outdated, .homebrew, packages: [ruby, Self.wget])
        let executor = FakeRunExecutor(events: [], hang: true)
        let services = F.services(catalog: catalog, executor: executor,
                                  engines: [MoveFakeEngine(wrapping: PlanFixtures.engines[0])]
                                    + PlanFixtures.engines.dropFirst() + [gem])
        let model = BrewxPortAppModel(services: services)
        var opened = 0
        model.openMainWindow = { opened += 1 }
        model.refreshLists()
        // Launch: Updates has loaded, and RubyGems is being asked what its tools run on.
        #expect(await waitUntil { !model.updates.list.loading && gem.usesAsked >= 1 })
        #expect(model.updates.runtimeHolds.isEmpty)

        // An automatic run starts nothing, and shows nothing.
        #expect(!model.installRequests([ActionRequest(operation: .upgrade, package: Self.wget)], origin: .background))
        #expect(model.runtimeWarning == nil)
        #expect(executor.runs.isEmpty)
        #expect(!model.busy)
        // wget may bring Ruby along: Homebrew's relations aren't read yet.
        model.perform(.update, on: [Self.wget.id])
        #expect(executor.runs.isEmpty)
        #expect(model.runtimeWarning?.message == "Updating wget may also update Ruby. Ruby 4.1 needs your gems "
                + "reinstalled. After the update, use Repair tools on the RubyGems page.")
        model.cancelRuntimeUpdate()
        // The menu bar's Update All opens the window, where the warning is.
        model.menuUpdate(engine: nil)
        #expect(opened == 1)
        #expect(model.runtimeWarning?.title == "Update Ruby?")
        model.cancelRuntimeUpdate()

        // Ruby's own update, confirmed: it runs, and Repair tools is offered once it has.
        model.perform(.update, on: [ruby.id])
        let warning = try #require(model.runtimeWarning)
        #expect(warning.title == "Update Ruby?")
        #expect(warning.message == "Ruby 4.1 needs your gems reinstalled. After the update, use Repair tools on the "
                + "RubyGems page.")
        model.confirmRuntimeUpdate()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.flatMap(\.refs) == [ruby.id])

        // The answer comes in; then the run ends.
        gem.usesGate = nil
        gate.release()
        await model.updates.reloaded()
        #expect(model.updates.runtimeHolds[ruby.id] != nil)
        catalog.script(.installed, .gem, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { model.repairOffer(for: .gem) != nil })
        #expect(model.repairOffer(for: .gem) == "Ruby was updated, so your gems need reinstalling. Repair tools "
                + "does that.")
        #expect(await waitUntil { !model.run.isRunning && !model.updates.list.loading })
        await model.updates.reloaded()

        // With the holds in, wget runs without a warning.
        model.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(model.runtimeWarning == nil)
    }

    /// R44: while the holds are still being worked out, an engine whose detect hasn't finished counts as one that
    /// couldn't say what its tools run on. A real language engine has no executable until its first detect (which can
    /// wait for the login shell), so at launch RubyGems here has none yet; npm's answer keeps the holds pending. A
    /// manual Ruby update then still warns, and a Homebrew update may bring Ruby along. Once RubyGems is detected and
    /// the holds are in, it answers for itself.
    @Test func undetectedEngineCountsWhileHoldsArePending() async throws {
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], executableOnlyOnceDetected: true)
        let npm = FakeLanguageEngine(.npm, uses: [RuntimeUse(formula: "node")])
        let gate = Gate()
        npm.usesGate = gate
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let node = Self.formula("node", "26.13.1", "27.0.0")
        let catalog = FakeCatalog()
        for name in ["ruby", "node", "wget"] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        }
        catalog.script(.installed, .homebrew, packages: [ruby, node, Self.wget])
        catalog.script(.installed, .gem, packages: [Self.tool(.gem, "lolcat", installed: "100.0.0", latest: nil)])
        catalog.script(.installed, .npm, packages: [])
        catalog.script(.outdated, .homebrew, packages: [ruby, node, Self.wget])
        let executor = FakeRunExecutor(events: [], hang: true)
        let services = F.services(catalog: catalog, executor: executor,
                                  engines: [MoveFakeEngine(wrapping: PlanFixtures.engines[0])]
                                    + PlanFixtures.engines.dropFirst() + [gem, npm])
        let model = BrewxPortAppModel(services: services)
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && npm.usesAsked >= 1 })
        #expect(model.updates.pruning)
        #expect(gem.executableURL == nil)

        model.perform(.update, on: [ruby.id])
        // Node too: Homebrew's relations aren't read yet, so updating Ruby may bring Node along.
        #expect(model.runtimeWarning?.title == "Update Ruby and Node?")
        model.cancelRuntimeUpdate()
        model.perform(.update, on: [Self.wget.id])
        #expect(model.runtimeWarning?.message.hasPrefix("Updating wget may also update") == true)
        #expect(model.runtimeWarning?.message.contains("Ruby") == true)
        model.cancelRuntimeUpdate()
        #expect(executor.runs.isEmpty)

        // Once detected, the next reload's holds have RubyGems' own answer: Ruby is held for its gems.
        npm.usesGate = nil
        gate.release()
        #expect(await waitUntil { !model.updates.pruning })
        _ = await gem.detect()
        #expect(gem.executableURL != nil)
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && !model.updates.pruning })
        #expect(model.updates.runtimeHolds[ruby.id]?.engines == [.gem: []])
    }

    /// R45: an engine whose detect timed out (or failed) has no executable, but may well be installed: when the holds
    /// are worked out it counts as one that couldn't say what its tools run on, never as not installed. RubyGems'
    /// detect here never answers; the real catalog gives up on it (`.unusable`, "didn't answer within …"), and a Ruby
    /// update is held for it, the careful way, as the warning before it is.
    @Test func timedOutDetectCountsAsCouldntSay() async throws {
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], executableOnlyOnceDetected: true)
        let hung = Gate()
        gem.detectGate = hung
        let statuses = await PackageCatalog(engines: [gem], queryTimeout: .milliseconds(50)).presentEngines()
        guard case .unusable(_, let reason)? = statuses[.gem] else {
            Issue.record("expected the timed-out status, got \(String(describing: statuses[.gem]))")
            return
        }
        #expect(reason.contains("didn't answer"))
        #expect(gem.executableURL == nil)

        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let catalog = FakeCatalog(engines: statuses)
        let ref = PackageRef(engine: .homebrew, kind: .formula, name: "ruby")
        catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        catalog.script(.installed, .homebrew, packages: [ruby])
        catalog.script(.outdated, .homebrew, packages: [ruby])
        let services = F.services(catalog: catalog, executor: FakeRunExecutor(events: [], hang: true),
                                  engines: [MoveFakeEngine(wrapping: PlanFixtures.engines[0])]
                                    + PlanFixtures.engines.dropFirst() + [gem])
        let model = BrewxPortAppModel(services: services)
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && !model.updates.pruning })
        #expect(model.updates.runtimeHolds[ruby.id].map { Set($0.engines.keys) } == [.gem])
        #expect(gem.usesAsked == 0)
        model.perform(.update, on: [ruby.id])
        #expect(model.runtimeWarning?.title == "Update Ruby?")
        hung.release()
    }

    /// Fix round 1 (R44 with R45): while the holds are still being worked out, an engine whose detect timed out (no
    /// executable, `.unusable` in the engine check) counts as one that couldn't say too; only one found missing is left
    /// out. RubyGems' detect never answers here, and npm's gated answer keeps the holds pending: a Ruby update warns.
    @Test func timedOutDetectCountsWhileHoldsArePending() async throws {
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")], executableOnlyOnceDetected: true)
        let hung = Gate()
        gem.detectGate = hung
        let npm = FakeLanguageEngine(.npm, uses: [RuntimeUse(formula: "node")])
        let pending = Gate()
        npm.usesGate = pending
        var statuses = await PackageCatalog(engines: [gem], queryTimeout: .milliseconds(50)).presentEngines()
        guard case .unusable? = statuses[.gem] else {
            Issue.record("expected the timed-out status, got \(String(describing: statuses[.gem]))")
            return
        }
        statuses[.npm] = .present(path: try #require(npm.executableURL), version: "1")
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let node = Self.formula("node", "26.13.1", "27.0.0")
        let catalog = FakeCatalog(engines: statuses)
        for name in ["ruby", "node"] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        }
        catalog.script(.installed, .homebrew, packages: [ruby, node])
        catalog.script(.installed, .npm, packages: [])
        catalog.script(.outdated, .homebrew, packages: [ruby, node])
        let services = F.services(catalog: catalog, executor: FakeRunExecutor(events: [], hang: true),
                                  engines: [MoveFakeEngine(wrapping: PlanFixtures.engines[0])]
                                    + PlanFixtures.engines.dropFirst() + [gem, npm])
        let model = BrewxPortAppModel(services: services)
        model.checkEnginesAgain()
        #expect(await waitUntil { model.enginesChecked })
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && npm.usesAsked >= 1 })
        #expect(model.updates.pruning)
        model.perform(.update, on: [ruby.id])
        #expect(model.runtimeWarning?.title.contains("Ruby") == true)
        model.cancelRuntimeUpdate()
        npm.usesGate = nil
        pending.release()
        hung.release()
    }

    // MARK: Autoremove (R29)

    /// A python@3.x Homebrew installed only as a dependency, which pipx's tools run on: Homebrew's updates run with
    /// autoremove off, so its cleanup can't remove that Python, and pipx's page says so once. Automatic runs too.
    @Test func upgradeKeepsDependencyOnlyPythonUsedByTools() async throws {
        var python = Self.formula("python@3.15", "3.15.2")
        python.installedOnRequest = false
        let pipx = FakeLanguageEngine(.pipx, uses: [RuntimeUse(formula: "python@3.15", tools: ["black"])])
        let executor = FakeRunExecutor()
        let model = await model([pipx], outdated: [Self.wget], installed: [python, Self.wget], executor: executor)
        #expect(await waitUntil { !model.keptRuntimesPending })
        #expect(model.keptRuntimes == [python.id: [.pipx]])
        #expect(model.keptRuntimeNote(for: .pipx) == "Homebrew installed python@3.15 only as another package's "
                + "dependency. pipx's tools run on it, so BrewxPort keeps Homebrew from removing it when it updates.")
        #expect(model.keptRuntimeNote(for: .uv) == nil)
        model.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == ["1"])
        #expect(await waitUntil { !model.run.isRunning })
        #expect(model.installRequests([ActionRequest(operation: .upgrade, package: Self.wget)], origin: .background))
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(executor.runs[1].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == ["1"])
    }

    /// Until the engines have said which runtimes their tools run on (at launch, before Installed has loaded, and while
    /// they're asked after each load), Homebrew's updates run with autoremove off: failing closed. Once they've said no
    /// tool runs on it, steps are as before.
    @Test func autoremoveOffUntilTheEnginesAnswer() async throws {
        var python = Self.formula("python@3.15", "3.15.2")
        python.installedOnRequest = false
        let pipx = FakeLanguageEngine(.pipx, uses: [])
        let gate = Gate()
        pipx.usesGate = gate
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [python, Self.wget])
        catalog.script(.outdated, .homebrew, packages: [Self.wget])
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor,
                                                          engines: PlanFixtures.engines + [pipx]))
        let upgrade = [ActionRequest(operation: .upgrade, package: Self.wget)]
        // Nothing loaded yet.
        #expect(model.installRequests(upgrade, origin: .background))
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == ["1"])
        // Installed has loaded, and pipx hasn't answered yet: still off, and no page says anything yet.
        model.refreshLists()
        #expect(await waitUntil { gate.waiting == 1 })
        #expect(model.keptRuntimeNote(for: .pipx) == nil)
        #expect(model.installRequests(upgrade, origin: .background))
        #expect(await waitUntil { executor.runs.count == 2 && !model.run.isRunning })
        #expect(executor.runs[1].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == ["1"])
        // pipx's tools run on no Python: as before. (Each run's end reloads Installed and asks again; the gate holds
        // only the asks so far.)
        pipx.usesGate = nil
        gate.release()
        await model.installed.settled()
        #expect(await waitUntil { !model.keptRuntimesPending })
        #expect(model.installRequests(upgrade, origin: .background))
        #expect(await waitUntil { executor.runs.count == 3 })
        #expect(executor.runs[2].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == [nil])
    }

    /// Installed couldn't list Homebrew: finding no dependency-only runtime then says nothing, so Homebrew's updates
    /// keep autoremove off until a load that did list Homebrew finds none.
    @Test func autoremoveStaysOffWhileHomebrewCouldNotBeListed() async throws {
        let pipx = FakeLanguageEngine(.pipx, uses: [])
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew,
                       FakeCatalog.Script(result: .failure(EngineError(engine: .homebrew, message: "brew failed"))))
        catalog.script(.outdated, .homebrew, packages: [Self.wget])
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor,
                                                          engines: PlanFixtures.engines + [pipx]))
        model.refreshLists()
        await model.installed.settled()
        #expect(model.installed.list.failedEngines.contains(.homebrew))
        #expect(model.keptRuntimesPending)
        let upgrade = [ActionRequest(operation: .upgrade, package: Self.wget)]
        #expect(model.installRequests(upgrade, origin: .background))
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == ["1"])
        // The run's end reloaded Installed, and Homebrew still couldn't list: still off.
        await model.installed.settled()
        #expect(model.keptRuntimesPending)
        // Homebrew lists, with no dependency-only runtime: as before.
        catalog.script(.installed, .homebrew, packages: [Self.wget])
        model.refreshLists()
        await model.installed.settled()
        #expect(await waitUntil { !model.keptRuntimesPending })
        #expect(model.installRequests(upgrade, origin: .background))
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(executor.runs[1].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == [nil])
    }

    /// No language tool runs on a dependency-only runtime (or the runtime was asked for): Homebrew's steps are as
    /// before, and no page says anything.
    @Test func upgradeUnchangedWhenNoToolUsesRuntime() async throws {
        var python = Self.formula("python@3.15", "3.15.2")
        python.installedOnRequest = false
        let pipx = FakeLanguageEngine(.pipx, uses: [])
        let executor = FakeRunExecutor()
        let plain = await model([pipx], outdated: [Self.wget], installed: [python, Self.wget], executor: executor)
        #expect(await waitUntil { !plain.keptRuntimesPending })
        #expect(pipx.usesAsked >= 1)
        #expect(plain.keptRuntimes.isEmpty)
        #expect(plain.keptRuntimeNote(for: .pipx) == nil)
        plain.perform(.update, on: [Self.wget.id])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map { $0.userEnvironment["HOMEBREW_NO_AUTOREMOVE"] } == [nil])

        // Asked for (not a dependency): nothing to keep, and pipx isn't even asked.
        let onRequest = Self.formula("python@3.15", "3.15.2")
        let other = FakeLanguageEngine(.pipx, uses: [RuntimeUse(formula: "python@3.15", tools: ["black"])])
        let asked = await model([other], outdated: [Self.wget], installed: [onRequest, Self.wget],
                                executor: FakeRunExecutor())
        #expect(asked.keptRuntimes.isEmpty)
        #expect(other.usesAsked == 0)
    }

    /// The warning's title names each runtime once, and the versions only when two of one kind differ.
    @Test func runtimeWarningTitleNamesEachRuntimeOnce() throws {
        func hold(_ runtime: String, _ version: String) -> RuntimeHold {
            RuntimeHold(hold: UpdateHold(reason: "r", blocksAutomatic: true, blocksManual: false),
                        noticeTitle: "\(runtime) \(version) is ready", runtime: runtime, version: version,
                        engines: [.pipx: []])
        }
        let python13 = Self.formula("python@3.13", "3.13.8", "3.13.9")
        let python14 = Self.formula("python@3.14", "3.14.0", "3.14.1")
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let requests = [python13, python14].map { ActionRequest(operation: .upgrade, package: $0) }
        let two = try #require(RuntimeWarning(requests, holds: [python13.id: hold("Python", "3.13.9"),
                                                                python14.id: hold("Python", "3.14.1")]))
        #expect(two.title == "Update Python 3.13.9 and Python 3.14.1?")
        let mixed = try #require(RuntimeWarning(requests + [ActionRequest(operation: .upgrade, package: ruby)],
                                                holds: [python13.id: hold("Python", "3.13.9"),
                                                        ruby.id: hold("Ruby", "4.1")]))
        #expect(mixed.title == "Update Python and Ruby?")
        #expect(RuntimeWarning([ActionRequest(operation: .upgrade, package: Self.wget)],
                               holds: [ruby.id: hold("Ruby", "4.1")]) == nil)
    }

    /// Repair tools is on the page of each engine that has it (npm, pipx, uv, RubyGems), whenever nothing else is
    /// going and the engine can change its tools.
    @Test func repairToolsFromTheEnginePage() async {
        let npm = FakeLanguageEngine(.npm)
        let cargo = FakeLanguageEngine(.cargo)
        let executor = FakeRunExecutor()
        let model = await model([npm, cargo], outdated: [], executor: executor)
        #expect(model.canRepair(.npm))
        #expect(!model.canRepair(.cargo))
        #expect(!model.canRepair(.homebrew))
        model.repairTools(.npm)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.spec.arguments) == [["repair-all"]])
        #expect(executor.runs[0].steps.map(\.title) == ["npm: all tools"])
        #expect(await waitUntil { !model.run.isRunning })
        npm.readOnlyReason = "npm installs tools into /usr/local, which your account can't change."
        #expect(!model.canRepair(.npm))
        model.repairTools(.npm)
        #expect(executor.runs.count == 1)
    }

    /// A tool the engine won't repair automatically (R28: uv's tool installed from git) is named in the run panel with
    /// why, and the others are repaired.
    @Test func repairNamesWhatItLeavesOut() async {
        let reason = "fromgit was installed from a URL, a path or git, so BrewxPort doesn't repair it by name."
        let uv = FakeLanguageEngine(.uv, repairsOneAtATime: true)
        uv.refusals = ["fromgit": reason]
        let executor = FakeRunExecutor()
        let model = await model([uv], outdated: [],
                                installed: [Self.tool(.uv, "fromgit", latest: nil), Self.tool(.uv, "ruff", latest: nil)],
                                executor: executor)
        model.repairTools(.uv)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.spec.arguments) == [["repair", "ruff"]])
        #expect(model.run.problems == [reason])
    }

    // MARK: Uninstall

    /// Removing a Homebrew python@3.x that pipx's and uv's tools run on: the sheet names the tools that will break
    /// before anything runs, and once it's gone, their pages offer Repair tools.
    @Test func uninstallWarnsBeforeRemovingAPythonToolsUse() async throws {
        let python = Self.formula("python@3.15", "3.15.2")
        let jq = Self.formula("jq", "1.8.1")
        let pipx = FakeLanguageEngine(.pipx, uses: [RuntimeUse(formula: "python@3.15", tools: ["black", "cowsay"])])
        let uv = FakeLanguageEngine(.uv, uses: [RuntimeUse(formula: "python@3.15", tools: ["ruff"])],
                                    repairsOneAtATime: true)
        let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        let catalog = FakeCatalog(engines: [.homebrew: .present(path: URL(fileURLWithPath: PlanFixtures.brewPath),
                                                                version: "4")])
        for name in ["python@3.15", "jq"] {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: []))))
        }
        let executor = FakeRunExecutor(events: [], hang: true)
        let system: [any Engine] = [brew] + PlanFixtures.engines.dropFirst()
        let model = await model([pipx, uv], outdated: [], installed: [python, jq], executor: executor,
                                catalog: catalog, engines: system)
        model.perform(.uninstall, on: [python.id])
        #expect(await waitUntil { if case .ready = model.uninstall.state { true } else { false } })
        #expect(model.uninstall.runtimeWarning == "black and cowsay (pipx) and ruff (uv) run on python@3.15 and "
                + "will stop working. Afterwards, use Repair tools on the pipx and uv pages.")
        model.uninstall.cancel()

        // Removing something else says nothing.
        model.perform(.uninstall, on: [jq.id])
        #expect(await waitUntil { if case .ready = model.uninstall.state { true } else { false } })
        #expect(model.uninstall.runtimeWarning == nil)
        model.uninstall.cancel()

        model.perform(.uninstall, on: [python.id])
        #expect(await waitUntil { if case .ready = model.uninstall.state { true } else { false } })
        model.uninstall.confirm()
        #expect(await waitUntil { executor.runs.count == 1 })
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { model.repairOffer(for: .uv) != nil })
        #expect(model.repairOffer(for: .pipx) == "python@3.15 was removed, so your pipx tools need reinstalling. "
                + "Repair tools does that.")
        #expect(model.repairOffer(for: .gem) == nil)
        model.repairTools(.uv)
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(executor.runs[1].steps.map(\.spec.arguments) == [["repair", "ruff"]])
    }
}
