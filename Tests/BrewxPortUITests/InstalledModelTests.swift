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
                == "Also installed by MacPorts. MacPorts's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[Self.portFiglet.id]!)
                == "Also installed by nanobrew. MacPorts's copy runs first on your PATH.")
        #expect(model.duplicateHelp(rows[Self.brewRipgrep.id]!) == "Also installed by nanobrew.")
        #expect(model.duplicateHelp(rows[Self.jq.id]!) == nil)
        #expect(model.runsFirst(rows[Self.portFiglet.id]!))
        #expect(!model.runsFirst(rows[Self.nbFiglet.id]!))
        #expect(model.whichCopyRunsNote(rows[Self.brewRipgrep.id]!)
                == "BrewxPort can't tell which copy runs: its command has a different name.")
        #expect(model.whichCopyRunsNote(rows[Self.nbFiglet.id]!) == nil)
        #expect(model.whichCopyRunsNote(rows[Self.jq.id]!) == nil)
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
        model.onLoaded = { loaded.append($0) }
        model.reload()
        #expect(await waitUntil { loaded.count == 1 })
        #expect(loaded == [[Self.jq.id, Self.portFiglet.id]])
        #expect(model.analyzing)
        await model.settled()
        #expect(!model.analyzing)
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
                == "Also installed by nanobrew. MacPorts's copy runs first on your PATH.")
        #expect(after.map(\.name) == ["figlet", "figlet", "jq"])
        model.sortOrder = [KeyPathComparator(\InstalledRow.name, order: .reverse)]
        #expect(model.rows.map(\.name) == ["jq", "figlet", "figlet"])
        model.sortOrder = [KeyPathComparator(\InstalledRow.engineName)]
        #expect(model.rows.map(\.engineName) == ["Homebrew", "MacPorts", "nanobrew"])
    }
}
