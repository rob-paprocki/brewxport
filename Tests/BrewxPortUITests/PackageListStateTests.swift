import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor
struct PackageListStateTests {
    private func package(_ name: String, engine: EngineID = .homebrew, installed: String? = nil,
                         latest: String? = nil) -> Package {
        Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name,
                installedVersion: installed, latestVersion: latest)
    }

    private func state() -> PackageListState {
        PackageListState(order: [.nanobrew, .homebrew, .macports, .mas], archFor: { _ in .arm64 })
    }

    @Test func rowsAppearPerEngine() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .nanobrew, packages: [package("jq", engine: .nanobrew)])
        catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([]), hang: true))
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { state.rows.map(\.name) == ["jq"] })
        #expect(state.loading)
        #expect(state.byRef.count == 1)
    }

    @Test func reloadRequestedDuringLoadRunsAfter() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [package("wget")], delay: .milliseconds(150))
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { catalog.queries.count == 1 })
        state.load { catalog.stream(.installed) }
        state.load { catalog.stream(.installed) }
        #expect(catalog.queries.count == 1)
        #expect(await waitUntil { catalog.queries.count == 2 && !state.loading && state.rows.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(catalog.queries.count == 2)
        #expect(state.rows.map(\.name) == ["wget"])
    }

    @Test func refreshKeepsStaleRowsUntilEngineAnswers() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .nanobrew, packages: [package("jq", engine: .nanobrew)])
        catalog.script(.installed, .homebrew, packages: [package("wget")])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading && state.rows.count == 2 })
        let wget = PackageRef(engine: .homebrew, kind: .formula, name: "wget")
        state.selection.checked = [wget]

        catalog.script(.installed, .nanobrew, packages: [package("jq2", engine: .nanobrew)])
        catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([]), hang: true))
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { state.rows.map(\.name).contains("jq2") })
        // Homebrew hasn't answered: its old row stays, and so does the selection on it.
        #expect(state.loading)
        #expect(state.rows.map(\.name).sorted() == ["jq2", "wget"])
        #expect(state.selection.checked == [wget])
    }

    @Test func refreshDropsEngineThatNoLongerAnswers() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .nanobrew, packages: [package("jq", engine: .nanobrew)])
        catalog.script(.installed, .homebrew, packages: [package("wget")])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading && state.rows.count == 2 })
        let wget = PackageRef(engine: .homebrew, kind: .formula, name: "wget")
        state.selection.checked = [wget]
        // Homebrew is gone on the next run: no outcome at all.
        catalog.script(.outdated, .nanobrew, packages: [package("jq", engine: .nanobrew)])
        state.load { catalog.stream(.outdated) }
        #expect(await waitUntil { !state.loading })
        #expect(state.rows.map(\.name) == ["jq"])
        #expect(state.selection.checked.isEmpty)
    }

    @Test func replacingAllStartsEmpty() async {
        let catalog = FakeCatalog()
        catalog.script(.search("a"), .homebrew, packages: [package("apple")])
        catalog.script(.search("b"), .homebrew, FakeCatalog.Script(result: .success([]), hang: true))
        let state = state()
        state.load(replacingAll: true) { catalog.stream(.search("a")) }
        #expect(await waitUntil { !state.loading && state.rows.count == 1 })
        state.selection.selected = [PackageRef(engine: .homebrew, kind: .formula, name: "apple")]
        state.load(replacingAll: true) { catalog.stream(.search("b")) }
        #expect(await waitUntil { state.loading && state.rows.isEmpty })
        #expect(state.selection == PackageSelection())
    }

    @Test func installedRefsMarkDiscoverRowsInstalled() async {
        let catalog = FakeCatalog()
        catalog.script(.search("w"), .homebrew, packages: [package("wget"), package("wire")])
        catalog.script(.search("w"), .nanobrew, packages: [package("wget", engine: .nanobrew)])
        let state = state()
        let wget = PackageRef(engine: .homebrew, kind: .formula, name: "wget")
        state.installedRefs = [wget]
        state.load(replacingAll: true) { catalog.stream(.search("w")) }
        #expect(await waitUntil { !state.loading && state.rows.count == 3 })
        #expect(state.byRef[wget]?.isInstalled == true)
        #expect(state.rows.filter(\.isInstalled).count == 1)
        // Changing the set re-marks existing rows.
        state.installedRefs = []
        #expect(state.rows.filter(\.isInstalled).isEmpty)
    }

    @Test func knownDropsVanishedRefs() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [package("a")])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading })
        let a = PackageRef(engine: .homebrew, kind: .formula, name: "a")
        let ghost = PackageRef(engine: .homebrew, kind: .formula, name: "ghost")
        #expect(state.known([a, ghost]) == [a])
    }

    @Test func sortByVersionNumeric() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [
            package("a", installed: "1", latest: "10.0"), package("b", installed: "1", latest: "9.0"),
        ])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading })
        state.sortOrder = [KeyPathComparator(\PackageRow.latest, comparator: .localizedStandard)]
        #expect(state.rows.map(\.latest) == ["9.0", "10.0"])
        state.sortOrder = [KeyPathComparator(\PackageRow.latest, comparator: .localizedStandard, order: .reverse)]
        #expect(state.rows.map(\.latest) == ["10.0", "9.0"])
        state.sortOrder = []
        #expect(state.rows.map(\.name) == ["a", "b"])
    }

    @Test func isVisibleFiltersRowsButNotAll() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [package("a"), package("b")])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading })
        state.selection.selected = [PackageRef(engine: .homebrew, kind: .formula, name: "a")]
        state.isVisible = { $0.name == "b" }
        state.recompute()
        #expect(state.rows.map(\.name) == ["b"])
        #expect(state.all.count == 2)
        #expect(state.selection.selected.isEmpty)
    }

    @Test func endOfStreamPrunesSelectionAndKeepsErrors() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [package("a")])
        catalog.script(.installed, .macports,
                       FakeCatalog.Script(result: .failure(EngineError(engine: .macports, message: "boom"))))
        let state = state()
        let gone = PackageRef(engine: .homebrew, kind: .formula, name: "gone")
        let kept = PackageRef(engine: .homebrew, kind: .formula, name: "a")
        state.selection = PackageSelection(selected: [gone, kept], checked: [gone])
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { !state.loading })
        #expect(state.selection.selected == [kept])
        #expect(state.selection.checked.isEmpty)
        #expect(state.errors == ["MacPorts: boom"])
    }

    @Test func missingSearchVersionExplainsItself() {
        // brew search returns names only: the row shows a dash, and its tooltip says where the version is.
        let named = Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep"), displayName: "ripgrep")
        let row = PackageRow(package: named, arch: .arm64)
        #expect(row.latest == "—")
        #expect(row.latestHelp == "Version shown in details")
        let versioned = Package(id: PackageRef(engine: .macports, kind: .port, name: "ripgrep"), displayName: "ripgrep",
                                latestVersion: "15.2.0")
        #expect(PackageRow(package: versioned, arch: .arm64).latestHelp == nil)
    }

    @Test func errorLineDoesNotRepeatEngineName() {
        let own = EngineError(engine: .macports, message: "MacPorts didn't answer within 60 seconds")
        #expect(EngineErrorText.line(own) == "MacPorts didn't answer within 60 seconds")
        #expect(EngineErrorText.line(EngineError(engine: .macports, message: "boom")) == "MacPorts: boom")
        #expect(!EngineErrorText.line(EngineError(engine: .mas, message: "")).isEmpty)
    }

    @Test func restartDropsPendingLoadAndRunningStream() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([]), hang: true))
        catalog.script(.outdated, .homebrew, packages: [package("old")])
        catalog.script(.search("x"), .homebrew, packages: [package("new")])
        let state = state()
        state.load { catalog.stream(.installed) }
        #expect(await waitUntil { catalog.queries.count == 1 })
        state.load { catalog.stream(.outdated) }  // pending behind the hung load
        state.restart { catalog.stream(.search("x")) }
        #expect(await waitUntil { !state.loading && state.rows.map(\.name) == ["new"] })
        try? await Task.sleep(for: .milliseconds(100))
        // The pending load never ran.
        #expect(catalog.queries == [.installed, .search("x")])
        #expect(state.rows.map(\.name) == ["new"])
    }

    @Test func settledReturnsAtOnceWhenIdle() async {
        let state = state()
        await state.settled()
        #expect(!state.loading)
    }

    @Test func settledResumesEveryWaiterAfterPendingLoad() async {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [package("wget")], delay: .milliseconds(80))
        let state = state()
        state.load { catalog.stream(.installed) }
        state.load { catalog.stream(.installed) }  // pending: settled waits for this one too
        async let first: Void = state.settled()
        async let second: Void = state.settled()
        _ = await (first, second)
        #expect(!state.loading)
        #expect(catalog.queries.count == 2)
        #expect(state.rows.map(\.name) == ["wget"])
    }

    /// R34: a language tool's row shows no arch unless its engine reports the installed copy's. Its engine's own arch
    /// says nothing about the tool (an npm package is JavaScript; a crate is built for whatever Rust targets). System
    /// engines' rows still show the arch they run as.
    @Test func languageToolRowsShowNoArchUnlessKnown() {
        let tool = Package(id: PackageRef(engine: .npm, kind: .tool, name: "cowsay"), displayName: "cowsay",
                           installedVersion: "1.5.0")
        #expect(PackageRow(package: tool, arch: .arm64).archName == "")
        #expect(PackageRow(package: tool, arch: .arm64, installedArchs: [.x86_64]).archName == "x86_64")
        #expect(PackageRow(package: package("jq", installed: "1.8"), arch: .arm64).archName == "arm64")
    }
}
