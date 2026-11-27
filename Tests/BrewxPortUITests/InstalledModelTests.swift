import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor @Suite struct InstalledModelTests {
    typealias P = PlanFixtures

    struct FixedPath: PathResolving {
        var entries = ["/usr/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin", "/opt/homebrew/bin"]
        func resolve() async -> ResolvedPath { ResolvedPath(entries: entries, source: .loginShell) }
    }

    struct SystemPathWithNote: PathResolving {
        func resolve() async -> ResolvedPath {
            ResolvedPath(entries: ["/usr/bin", "/bin"], source: .systemDefault,
                         note: "Based on the system PATH: your login shell didn't answer within 5 seconds.")
        }
    }

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String, display: String? = nil) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: display ?? name,
                installedVersion: "1")
    }

    static func catalog(_ packages: [Package]) -> FakeCatalog {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.installed, engine, packages: found)
        }
        return catalog
    }

    static func model(_ catalog: FakeCatalog, path: any PathResolving = FixedPath(),
                      files: Set<String> = []) -> InstalledModel {
        let list = PackageListState(order: P.order, archFor: { _ in .arm64 })
        return InstalledModel(catalog: catalog, path: path, engines: P.engines, fileExists: { files.contains($0) },
                              list: list)
    }

    static let nbFiglet = package(.nanobrew, .formula, "figlet")
    static let portFiglet = package(.macports, .port, "figlet")
    static let brewRipgrep = package(.homebrew, .formula, "ripgrep")
    static let nbRipgrep = package(.nanobrew, .formula, "ripgrep")
    static let jq = package(.homebrew, .formula, "jq")

    @Test func duplicatesAcrossEngines() async {
        let catalog = Self.catalog([Self.nbFiglet, Self.portFiglet, Self.brewRipgrep, Self.nbRipgrep, Self.jq])
        let model = Self.model(catalog, files: ["/opt/local/bin/figlet", "/opt/nanobrew/prefix/bin/figlet",
                                                "/opt/homebrew/bin/jq", "/opt/homebrew/bin/rg"])
        model.reload()
        await model.settled()
        #expect(model.duplicates == ["figlet": [Self.nbFiglet.id, Self.portFiglet.id],
                                     "ripgrep": [Self.nbRipgrep.id, Self.brewRipgrep.id]])
        // MacPorts' bin directory comes first on the PATH and holds figlet. ripgrep's command is rg: no winner.
        #expect(model.winners["figlet"] == .macports)
        #expect(model.winners["ripgrep"] == nil)
        #expect(model.winners["jq"] == .homebrew)
        #expect(model.pathNote == nil)

        let rows = model.list.byRef
        #expect(model.duplicateHelp(rows[Self.nbFiglet.id]!)
                == "Also installed by MacPorts. MacPorts' copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[Self.portFiglet.id]!)
                == "Also installed by nanobrew. MacPorts' copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[Self.brewRipgrep.id]!) == "Also installed by nanobrew.")
        #expect(model.duplicateHelp(rows[Self.jq.id]!) == nil)
        #expect(model.runsFirst(rows[Self.portFiglet.id]!))
        #expect(!model.runsFirst(rows[Self.nbFiglet.id]!))
        #expect(model.whichCopyRunsNote(rows[Self.brewRipgrep.id]!)
                == "BrewxPort can't tell which copy runs: its command has a different name.")
        #expect(model.whichCopyRunsNote(rows[Self.nbFiglet.id]!) == nil)
        #expect(model.whichCopyRunsNote(rows[Self.jq.id]!) == nil)
    }

    /// The same tool from two managers (ripgrep from Homebrew and Cargo, typescript from npm and Bun) is a duplicate,
    /// and the copy the login shell runs is the one whose bin folder comes first on its PATH with the tool's command
    /// in it: `rg` and `tsc`, which the language engines name. Two copies in one shared folder (npm's globals in
    /// Homebrew's bin) can't be told apart.
    @Test func sameToolFromTwoManagersWarns() async {
        let cargoBin = "/Users/someone/.cargo/bin"
        let bunBin = "/Users/someone/.bun/bin"
        let cargo = FakeLanguageEngine(.cargo, binLocation: URL(fileURLWithPath: cargoBin, isDirectory: true),
                                       commands: ["ripgrep": ["rg"]])
        let npm = FakeLanguageEngine(.npm, binLocation: URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                                     commands: ["typescript": ["tsc", "tsserver"]])
        let bun = FakeLanguageEngine(.bun, binLocation: URL(fileURLWithPath: bunBin, isDirectory: true),
                                     commands: ["typescript": ["tsc", "tsserver"]])
        let brewRipgrep = Self.brewRipgrep
        let cargoRipgrep = Self.package(.cargo, .tool, "ripgrep")
        let npmTypescript = Self.package(.npm, .tool, "typescript")
        let bunTypescript = Self.package(.bun, .tool, "typescript")
        let list = PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 })
        let files: Set<String> = ["/opt/homebrew/bin/rg", cargoBin + "/rg", "/opt/homebrew/bin/tsc", bunBin + "/tsc"]
        let model = InstalledModel(
            catalog: Self.catalog([brewRipgrep, cargoRipgrep, npmTypescript, bunTypescript]),
            path: FixedPath(entries: [cargoBin, "/opt/homebrew/bin", bunBin, "/usr/bin"]),
            engines: P.engines + [cargo, npm, bun], fileExists: { files.contains($0) }, list: list)
        model.reload()
        await model.settled()
        #expect(model.duplicates["ripgrep"] == [brewRipgrep.id, cargoRipgrep.id])
        #expect(model.duplicates["typescript"] == [npmTypescript.id, bunTypescript.id])
        #expect(model.winners["ripgrep"] == .cargo)
        #expect(model.winners["typescript"] == .npm)
        let rows = model.list.byRef
        #expect(model.duplicateHelp(rows[brewRipgrep.id]!) == "Also installed by Cargo. Cargo's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[cargoRipgrep.id]!)
                == "Also installed by Homebrew. Cargo's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[bunTypescript.id]!) == "Also installed by npm. npm's copy runs first on your PATH.")
        #expect(model.runsFirst(rows[cargoRipgrep.id]!))
        #expect(!model.runsFirst(rows[brewRipgrep.id]!))

        // Homebrew's typescript formula and npm's typescript both put tsc in /opt/homebrew/bin.
        let brewTypescript = Self.package(.homebrew, .formula, "typescript")
        let shared = InstalledModel(
            catalog: Self.catalog([brewTypescript, npmTypescript]),
            path: FixedPath(entries: ["/opt/homebrew/bin", "/usr/bin"]),
            engines: P.engines + [npm], fileExists: { files.contains($0) },
            list: PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 }))
        shared.reload()
        await shared.settled()
        #expect(shared.winners["typescript"] == nil)
        #expect(shared.whichCopyRunsNote(shared.list.byRef[npmTypescript.id]!)
                == "These copies share /opt/homebrew/bin, so BrewxPort can't tell which one runs.")
    }

    /// Final review: copies are matched by the commands they put on the PATH, where the engine names them (a crate's
    /// binaries, a Mint tool's executables, an npm or Bun global's `bin`), with a formula's or port's own name as its
    /// command and the package name as the fallback. So Cargo's fd-find (`fd`) is Homebrew's fd, and Mint's
    /// realm/SwiftLint (`swiftlint`) is Homebrew's swiftlint, though their package names differ; ripgrep still pairs
    /// by name, and its copy is found by `rg`. A copy's row is found by its group, whatever its own name.
    @Test func sameCommandFromTwoManagersWarns() async {
        let cargoBin = "/Users/someone/.cargo/bin"
        let mintBin = "/Users/someone/.mint/bin"
        let cargo = FakeLanguageEngine(.cargo, binLocation: URL(fileURLWithPath: cargoBin, isDirectory: true),
                                       commands: ["fd-find": ["fd"], "ripgrep": ["rg"]])
        let mint = FakeLanguageEngine(.mint, binLocation: URL(fileURLWithPath: mintBin, isDirectory: true),
                                      commands: ["realm/SwiftLint": ["swiftlint"]])
        let brewFd = Self.package(.homebrew, .formula, "fd")
        let fdFind = Self.package(.cargo, .tool, "fd-find")
        let brewSwiftlint = Self.package(.homebrew, .formula, "swiftlint")
        let mintSwiftlint = Self.package(.mint, .tool, "realm/SwiftLint")
        let brewRipgrep = Self.brewRipgrep
        let cargoRipgrep = Self.package(.cargo, .tool, "ripgrep")
        let files: Set<String> = ["/opt/homebrew/bin/fd", cargoBin + "/fd", "/opt/homebrew/bin/swiftlint",
                                  mintBin + "/swiftlint", "/opt/homebrew/bin/rg", cargoBin + "/rg"]
        let model = InstalledModel(
            catalog: Self.catalog([brewFd, fdFind, brewSwiftlint, mintSwiftlint, brewRipgrep, cargoRipgrep, Self.jq]),
            path: FixedPath(entries: [cargoBin, "/opt/homebrew/bin", mintBin, "/usr/bin"]),
            engines: P.engines + [cargo, mint], fileExists: { files.contains($0) },
            list: PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 }))
        model.reload()
        await model.settled()
        // Copies in list order (by name); a group is keyed by its first plain name.
        #expect(model.duplicates == ["fd": [brewFd.id, fdFind.id], "swiftlint": [mintSwiftlint.id, brewSwiftlint.id],
                                     "ripgrep": [brewRipgrep.id, cargoRipgrep.id]])
        #expect(model.winners["fd"] == .cargo)
        #expect(model.winners["swiftlint"] == .homebrew)
        #expect(model.winners["ripgrep"] == .cargo)
        let rows = model.list.byRef
        #expect(model.duplicateHelp(rows[fdFind.id]!) == "Also installed by Homebrew. Cargo's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[brewFd.id]!) == "Also installed by Cargo. Cargo's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[mintSwiftlint.id]!)
                == "Also installed by Homebrew. Homebrew's copy runs first on your PATH.")
        #expect(model.runsFirst(rows[fdFind.id]!))
        #expect(!model.runsFirst(rows[brewFd.id]!))
        #expect(model.runsFirst(rows[brewSwiftlint.id]!))
        #expect(!model.runsFirst(rows[mintSwiftlint.id]!))
        #expect(model.duplicateHelp(rows[Self.jq.id]!) == nil)
        #expect(model.winners["jq"] == nil)  // jq's command isn't in any folder here
        #expect(model.whichCopyRunsNote(rows[mintSwiftlint.id]!) == nil)
    }

    /// npm and Bun name the commands a package.json declares: corepack (Node 24 and earlier) declares pnpm, pnpx,
    /// yarn and yarnpkg, which aren't in npm's bin folder until `corepack enable`. A command counts for grouping only
    /// when it's a file in its engine's bin folder, so corepack isn't Homebrew's pnpm or yarn. Once enabled, corepack's
    /// pnpm is: the copy that runs is the one whose folder comes first on the PATH with a command both copies hold
    /// (pnpm), never `corepack`, which only npm has. Not captures: the bin folders, made up for this model test.
    @Test func commandsCountOnlyWhenInTheBinFolder() async {
        let nvmBin = "/Users/someone/.nvm/versions/node/v24.11.0/bin"
        let npm = FakeLanguageEngine(.npm, binLocation: URL(fileURLWithPath: nvmBin, isDirectory: true),
                                     commands: ["corepack": ["corepack", "pnpm", "pnpx", "yarn", "yarnpkg"]])
        let corepack = Self.package(.npm, .tool, "corepack")
        let pnpm = Self.package(.homebrew, .formula, "pnpm")
        let yarn = Self.package(.homebrew, .formula, "yarn")
        func model(_ files: Set<String>) async -> InstalledModel {
            let model = InstalledModel(
                catalog: Self.catalog([corepack, pnpm, yarn]),
                path: FixedPath(entries: ["/opt/homebrew/bin", nvmBin, "/usr/bin"]),
                engines: P.engines + [npm], fileExists: { files.contains($0) },
                list: PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 }))
            model.reload()
            await model.settled()
            return model
        }
        let homebrew: Set<String> = ["/opt/homebrew/bin/pnpm", "/opt/homebrew/bin/yarn"]
        let plain = await model(homebrew.union([nvmBin + "/corepack"]))
        #expect(plain.duplicates.isEmpty)
        #expect(plain.duplicateHelp(plain.list.byRef[pnpm.id]!) == nil)

        let enabled = await model(homebrew.union([nvmBin + "/corepack", nvmBin + "/pnpm", nvmBin + "/pnpx"]))
        #expect(enabled.duplicates.values.map { Set($0) } == [[corepack.id, pnpm.id]])
        let rows = enabled.list.byRef
        #expect(enabled.runsFirst(rows[pnpm.id]!))
        #expect(!enabled.runsFirst(rows[corepack.id]!))
        #expect(enabled.duplicateHelp(rows[corepack.id]!)
                == "Also installed by Homebrew. Homebrew's copy runs first on your PATH.")
        #expect(enabled.duplicateHelp(rows[yarn.id]!) == nil)
    }

    @Test func masAppsNeverDuplicates() async {
        let app = Self.package(.mas, .app, "figlet", display: "figlet")
        let cask = Self.package(.homebrew, .cask, "firefox")
        let nbCask = Self.package(.nanobrew, .cask, "firefox")
        let model = Self.model(Self.catalog([app, Self.portFiglet, cask, nbCask]),
                               files: ["/opt/homebrew/bin/figlet", "/opt/local/bin/figlet",
                                       "/opt/homebrew/bin/firefox", "/opt/nanobrew/prefix/bin/firefox"])
        model.reload()
        await model.settled()
        // Casks count as copies, but neither casks nor mas apps ever win.
        #expect(model.duplicates == ["firefox": [nbCask.id, cask.id]])
        #expect(model.winners["firefox"] == nil)
        #expect(model.winners["figlet"] == .macports)
        #expect(model.duplicateHelp(model.list.byRef[app.id]!) == nil)
        #expect(model.whichCopyRunsNote(model.list.byRef[cask.id]!) == nil)
    }

    @Test func systemPathNoteShown() async {
        let model = Self.model(Self.catalog([Self.jq]), path: SystemPathWithNote())
        model.reload()
        await model.settled()
        #expect(model.pathNote == "Based on the system PATH: your login shell didn't answer within 5 seconds.")
    }

    @Test func refreshPrunesChecks() async {
        let catalog = Self.catalog([Self.jq, Self.brewRipgrep])
        let model = Self.model(catalog)
        model.reload()
        await model.settled()
        model.list.selection.checked = [Self.jq.id, Self.brewRipgrep.id]
        model.list.selection.selected = [Self.brewRipgrep.id]
        #expect(model.removeTitle == "Remove 2")
        catalog.script(.installed, .homebrew, packages: [Self.jq])
        model.reload()
        await model.settled()
        #expect(model.list.rows.map(\.id) == [Self.jq.id])
        #expect(model.list.selection.checked == [Self.jq.id])
        #expect(model.list.selection.selected.isEmpty)
        #expect(model.checkedRefs == [Self.jq.id])
        #expect(model.removeTitle == "Remove 1")
    }

    @Test func onLoadedGetsEveryInstalledRefBeforeThePath() async {
        let model = Self.model(Self.catalog([Self.jq, Self.portFiglet]), path: SlowPath())
        var loaded: [Set<PackageRef>] = []
        model.addLoadedObserver { loaded.append($0) }
        #expect(!model.hasLoaded)
        model.reload()
        #expect(await waitUntil { loaded.count == 1 })
        #expect(loaded == [[Self.jq.id, Self.portFiglet.id]])
        #expect(model.hasLoaded)
        #expect(model.analyzing)
        await model.settled()
        #expect(!model.analyzing)
    }

    @Test func loadedObserversAllCalled() async {
        // Through the app model, whose Discover feed is the first observer: it still marks Discover's rows.
        let catalog = Self.catalog([Self.jq, Self.portFiglet])
        let app = BrewxPortAppModel(services: AppFixtures.services(catalog: catalog))
        var order: [String] = []
        var first: Set<PackageRef> = [], second: Set<PackageRef> = []
        app.installed.addLoadedObserver { refs in
            first = refs
            order.append("first")
        }
        app.installed.addLoadedObserver { refs in
            second = refs
            order.append("second")
        }
        app.installed.reload()
        #expect(await waitUntil { order.count == 2 })
        #expect(order == ["first", "second"])
        #expect(first == [Self.jq.id, Self.portFiglet.id])
        #expect(second == first)
        #expect(app.discover.list.installedRefs == first)
        // A second load calls each observer again.
        app.installed.reload()
        #expect(await waitUntil { order.count == 4 })
    }

    struct SlowPath: PathResolving {
        var entries = ["/usr/bin"]
        func resolve() async -> ResolvedPath {
            try? await Task.sleep(for: .milliseconds(300))
            return ResolvedPath(entries: entries, source: .loginShell)
        }
    }

    static let figletFiles: Set = ["/opt/local/bin/figlet", "/opt/nanobrew/prefix/bin/figlet"]

    @Test func noCopyOnThePathSaysSo() async {
        // The system PATH fallback has none of the engines' bin directories, so nothing wins; the command's name
        // isn't the reason.
        let model = Self.model(Self.catalog([Self.nbFiglet, Self.portFiglet]), path: SystemPathWithNote(),
                               files: Self.figletFiles)
        model.reload()
        await model.settled()
        #expect(model.winners.isEmpty)
        let row = model.list.byRef[Self.nbFiglet.id]!
        #expect(model.whichCopyRunsNote(row) == "None of these copies is on your PATH.")
        #expect(model.duplicateHelp(row) == "Also installed by MacPorts.")
    }

    @Test func systemCopyFirstMeansNoTick() async {
        let files = Self.figletFiles.union(["/usr/bin/figlet", "/usr/bin/jq", "/opt/homebrew/bin/jq"])
        let model = Self.model(Self.catalog([Self.nbFiglet, Self.portFiglet, Self.jq]), files: files)
        model.reload()
        await model.settled()
        // /usr/bin comes first on the PATH and holds both commands: no engine's copy runs, single copies included.
        #expect(model.winners.isEmpty)
        #expect(model.rows.allSatisfy { !$0.runsFirst })
        #expect(model.whichCopyRunsNote(model.list.byRef[Self.portFiglet.id]!)
                == "Another copy, in /usr/bin, runs first on your PATH.")
    }

    @Test func rowsCarryTheirMarksAndChangeWhenWinnersArrive() async {
        let path = SlowPath(entries: ["/opt/local/bin", "/opt/nanobrew/prefix/bin"])
        let model = Self.model(Self.catalog([Self.nbFiglet, Self.portFiglet, Self.jq]), path: path,
                               files: Self.figletFiles)
        model.reload()
        await model.list.settled()
        #expect(await waitUntil { !model.duplicates.isEmpty })
        // The list has loaded but the PATH hasn't answered: the rows have no tick yet.
        let before = model.rows
        #expect(model.analyzing)
        #expect(before.allSatisfy { !$0.runsFirst })
        #expect(before.first { $0.id == Self.portFiglet.id }?.duplicateHelp == "Also installed by nanobrew.")
        await model.settled()
        // New row values once the winners arrive, so the table sees the change.
        let after = model.rows
        #expect(after != before)
        #expect(after.first { $0.id == Self.portFiglet.id }?.runsFirst == true)
        #expect(after.first { $0.id == Self.portFiglet.id }?.duplicateHelp
                == "Also installed by nanobrew. MacPorts' copy runs first on your PATH.")
        #expect(after.map(\.name) == ["figlet", "figlet", "jq"])
        model.sortOrder = [KeyPathComparator(\InstalledRow.name, order: .reverse)]
        #expect(model.rows.map(\.name) == ["jq", "figlet", "figlet"])
        model.sortOrder = [KeyPathComparator(\InstalledRow.engineName)]
        #expect(model.rows.map(\.engineName) == ["Homebrew", "MacPorts", "nanobrew"])
    }
}
