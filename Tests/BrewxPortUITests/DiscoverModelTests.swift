import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor @Suite struct DiscoverModelTests {
    static let order: [EngineID] = [.nanobrew, .homebrew, .macports, .mas]

    static func package(_ engine: EngineID, _ name: String, kind: PackageKind? = nil) -> Package {
        let kind = kind ?? (engine == .macports ? .port : engine == .mas ? .app : .formula)
        return Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                       installedVersion: nil, latestVersion: "14.1.1")
    }

    static func model(_ catalog: FakeCatalog) -> DiscoverModel {
        let list = PackageListState(order: order, archFor: { $0 == .macports ? .x86_64 : .arm64 })
        return DiscoverModel(catalog: catalog, list: list)
    }

    @Test func submitSearchesAllEngines() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .macports, packages: [Self.package(.macports, "ripgrep")])
        catalog.script(.search("ripgrep"), .mas, packages: [])
        let model = Self.model(catalog)
        model.query = "  ripgrep "
        model.submit()
        #expect(model.searching)
        #expect(await waitUntil { !model.searching })
        #expect(catalog.queries == [.search("ripgrep")])
        #expect(Set(model.list.rows.map(\.id.engine)) == [.nanobrew, .homebrew, .macports])
        #expect(model.list.rows.first { $0.id.engine == .macports }?.arch == .x86_64)
        #expect(model.list.errors.isEmpty)
    }

    @Test func sameNameRowsAreAdjacentInEngineOrder() async {
        let catalog = FakeCatalog()
        catalog.script(.search("rg"), .homebrew, packages: [Self.package(.homebrew, "ripgrep-all"),
                                                            Self.package(.homebrew, "ripgrep")])
        catalog.script(.search("rg"), .macports, packages: [Self.package(.macports, "ripgrep")])
        catalog.script(.search("rg"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep"),
                                                            Self.package(.nanobrew, "rga")])
        let model = Self.model(catalog)
        model.query = "rg"
        model.submit()
        #expect(await waitUntil { !model.searching })
        let rows = model.list.rows
        #expect(rows.map(\.name) == ["rga", "ripgrep", "ripgrep", "ripgrep", "ripgrep-all"])
        #expect(rows.filter { $0.name == "ripgrep" }.map(\.id.engine) == [.nanobrew, .homebrew, .macports])
    }

    @Test func engineFilterLimitsRows() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")])
        let model = Self.model(catalog)
        model.query = "ripgrep"
        model.submit()
        #expect(await waitUntil { !model.searching })
        let homebrew = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        let nanobrew = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        model.list.selection.checked = [homebrew, nanobrew]

        model.engineFilter = .homebrew
        #expect(model.list.rows.map(\.id) == [homebrew])
        #expect(model.list.all.count == 2)
        // A checked row the filter hides isn't acted on.
        #expect(model.list.selection.checked == [homebrew])

        model.engineFilter = nil
        #expect(model.list.rows.count == 2)
    }

    /// Post-VM fix: the search field names the engine the filter shows ("Search npm"), and every engine without one.
    @Test func searchPromptNamesTheFilteredEngine() {
        let model = Self.model(FakeCatalog())
        #expect(model.searchPrompt == "Search all engines")
        model.engineFilter = .npm
        #expect(model.searchPrompt == "Search npm")
        model.engineFilter = .gem
        #expect(model.searchPrompt == "Search RubyGems")
        model.engineFilter = nil
        #expect(model.searchPrompt == "Search all engines")
    }

    @Test func newSearchCancelsOlder() async {
        let catalog = FakeCatalog()
        // The first search: Homebrew answers late, MacPorts never does.
        catalog.script(.search("old"), .homebrew, packages: [Self.package(.homebrew, "old")], delay: .milliseconds(300))
        catalog.script(.search("old"), .macports, FakeCatalog.Script(result: .success([]), hang: true))
        catalog.script(.search("new"), .homebrew, packages: [Self.package(.homebrew, "new")])
        let model = Self.model(catalog)
        model.query = "old"
        model.submit()
        #expect(await waitUntil { catalog.queries.count == 1 })
        model.query = "new"
        model.submit()
        // The new search doesn't wait behind the hung one.
        #expect(await waitUntil { !model.searching && model.list.rows.map(\.name) == ["new"] })
        // The first search's late answer never shows.
        for _ in 0..<40 {
            #expect(!model.list.rows.contains { $0.name == "old" })
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.list.rows.map(\.name) == ["new"])
        #expect(!model.searching)
    }

    @Test func searchShowsOtherEnginesWhenOneFails() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")])
        let failure = EngineError(engine: .macports, message: "MacPorts couldn't read its port index")
        catalog.script(.search("ripgrep"), .macports, FakeCatalog.Script(result: .failure(failure)))
        let model = Self.model(catalog)
        model.query = "ripgrep"
        model.submit()
        #expect(await waitUntil { !model.searching })
        #expect(Set(model.list.rows.map(\.id.engine)) == [.nanobrew, .homebrew])
        #expect(model.list.errors == [EngineErrorText.line(failure)])
        #expect(model.list.errors == ["MacPorts couldn't read its port index"])
    }

    @Test func searchShowsOtherEnginesWhileOneHangs() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")],
                       delay: .milliseconds(20))
        catalog.script(.search("ripgrep"), .macports,
                       FakeCatalog.Script(result: .success([]), timeout: .milliseconds(600)))
        let model = Self.model(catalog)
        model.query = "ripgrep"
        model.submit()
        #expect(await waitUntil { model.list.rows.count == 2 })
        #expect(model.searching)
        #expect(model.list.errors.isEmpty)
        #expect(Set(model.list.rows.map(\.id.engine)) == [.nanobrew, .homebrew])

        #expect(await waitUntil { !model.searching })
        #expect(model.list.rows.count == 2)
        #expect(model.list.errors == ["MacPorts didn't answer within 60 seconds"])
    }

    @Test func emptyQueryDoesNothing() async {
        let catalog = FakeCatalog()
        let model = Self.model(catalog)
        model.query = "   "
        model.submit()
        #expect(!model.searching)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(catalog.queries.isEmpty)
        #expect(model.submittedQuery == nil)
    }

    @Test func installedRowsMarked() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")])
        let model = Self.model(catalog)
        let homebrew = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        model.markInstalled([homebrew])
        model.query = "ripgrep"
        model.submit()
        #expect(await waitUntil { !model.searching })
        #expect(model.list.byRef[homebrew]?.isInstalled == true)
        #expect(model.list.rows.filter(\.isInstalled).map(\.id) == [homebrew])

        // Marking again after the search (Installed reloaded) updates the rows in place.
        model.markInstalled([])
        #expect(model.list.rows.filter(\.isInstalled).isEmpty)
    }

    @Test func homebrewCaskMarksNanobrewsRowToo() async {
        // blackhole-64ch from nanobrew needs root, so BrewxPort installs it through Homebrew (VM round 3): afterwards
        // only `brew list --cask` has it, and nanobrew's Discover row must not offer Install again.
        let catalog = FakeCatalog()
        let nb = Package(id: PackageRef(engine: .nanobrew, kind: .cask, name: "blackhole-64ch"), displayName: "blackhole-64ch",
                         latestVersion: "0.7.1")
        let brew = Package(id: PackageRef(engine: .homebrew, kind: .cask, name: "blackhole-64ch"),
                           displayName: "blackhole-64ch", latestVersion: "0.7.1")
        let formula = Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: "blackhole-64ch"),
                              displayName: "blackhole-64ch", latestVersion: "1")
        catalog.script(.search("blackhole"), .nanobrew, packages: [nb, formula])
        catalog.script(.search("blackhole"), .homebrew, packages: [brew])
        let model = Self.model(catalog)
        model.markInstalled([brew.id])
        model.query = "blackhole"
        model.submit()
        #expect(await waitUntil { !model.searching })
        #expect(model.list.byRef[brew.id]?.isInstalled == true)
        #expect(model.list.byRef[nb.id]?.isInstalled == true)
        #expect(model.list.byRef[formula.id]?.isInstalled == false)   // only casks share the name
        // A Homebrew formula doesn't mark anything else.
        model.markInstalled([PackageRef(engine: .homebrew, kind: .formula, name: "blackhole-64ch")])
        #expect(model.list.byRef[nb.id]?.isInstalled == false)
    }

    @Test func spaceTogglesChecksOfSelectedVisibleRows() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .nanobrew, packages: [Self.package(.nanobrew, "ripgrep")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [Self.package(.homebrew, "ripgrep")])
        let model = Self.model(catalog)
        model.query = "ripgrep"
        model.submit()
        #expect(await waitUntil { !model.searching })
        let homebrew = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        let nanobrew = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        model.list.selection.selected = [homebrew, nanobrew]
        model.list.toggleSelectedChecks()
        #expect(model.list.selection.checked == [homebrew, nanobrew])
        #expect(model.installTitle == "Install 2")
        model.list.toggleSelectedChecks()
        #expect(model.list.selection.checked.isEmpty)
        #expect(model.installTitle == "Install")
    }
}
