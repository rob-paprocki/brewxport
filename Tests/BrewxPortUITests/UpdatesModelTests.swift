import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor @Suite struct UpdatesModelTests {
    static let order: [EngineID] = [.nanobrew, .homebrew, .macports, .mas]

    static func package(_ engine: EngineID, _ name: String, installed: String = "1.0", latest: String = "2.0") -> Package {
        let kind: PackageKind = engine == .macports ? .port : engine == .mas ? .app : .formula
        return Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                       installedVersion: installed, latestVersion: latest)
    }

    static func model(_ catalog: FakeCatalog, store: MemoryStore = MemoryStore()) -> (UpdatesModel, UpdatePreferences) {
        let list = PackageListState(order: order, archFor: { $0 == .macports ? .x86_64 : .arm64 })
        let preferences = UpdatePreferences(store: store)
        return (UpdatesModel(catalog: catalog, preferences: preferences, list: list), preferences)
    }

    /// Reloads and waits until the load and the preference prune after it are done.
    static func reload(_ model: UpdatesModel) async {
        model.reload()
        _ = await waitUntil { !model.list.loading && !model.pruning }
    }

    static let wget = package(.homebrew, "wget")
    static let jq = package(.homebrew, "jq")
    static let figlet = package(.macports, "figlet")

    static func catalog(_ packages: [Package]) -> FakeCatalog {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.outdated, engine, packages: found)
        }
        return catalog
    }

    @Test func ignoredRowsHiddenAndExcludedFromUpdateAll() async {
        let (model, preferences) = Self.model(Self.catalog([Self.wget, Self.jq, Self.figlet]))
        preferences.ignore([Self.wget.id])
        await Self.reload(model)
        #expect(Set(model.list.rows.map(\.id)) == [Self.jq.id, Self.figlet.id])
        #expect(model.list.all.count == 3)
        #expect(Set(model.updateAllRequests().map(\.package.id)) == [Self.jq.id, Self.figlet.id])
        #expect(model.updateAllRequests().allSatisfy { $0.operation == .upgrade })
        // Shown, it still isn't part of Update all, and checking it doesn't update it.
        model.showHidden = true
        #expect(model.list.rows.count == 3)
        #expect(Set(model.updateAllRequests().map(\.package.id)) == [Self.jq.id, Self.figlet.id])
        #expect(model.requests(for: [Self.wget.id, Self.jq.id]).map(\.package.id) == [Self.jq.id])
    }

    @Test func skippedVersionHiddenUntilNewerVersion() async {
        let catalog = Self.catalog([Self.wget, Self.jq])
        let (model, preferences) = Self.model(catalog)
        preferences.skip(Self.wget.id, version: "2.0")
        await Self.reload(model)
        #expect(model.list.rows.map(\.id) == [Self.jq.id])
        #expect(model.hiddenReason(model.list.byRef[Self.wget.id]!) == .skipped)

        // wget 2.1 comes out: the skip of 2.0 is forgotten and the row is back.
        catalog.script(.outdated, .homebrew, packages: [Self.package(.homebrew, "wget", latest: "2.1"), Self.jq])
        await Self.reload(model)
        #expect(Set(model.list.rows.map(\.id)) == [Self.wget.id, Self.jq.id])
        #expect(!preferences.isSkipped(Self.package(.homebrew, "wget", latest: "2.0")))
    }

    @Test func showHiddenRevealsBoth() async {
        let (model, preferences) = Self.model(Self.catalog([Self.wget, Self.jq, Self.figlet]))
        preferences.ignore([Self.wget.id])
        preferences.skip(Self.jq.id, version: "2.0")
        await Self.reload(model)
        #expect(model.list.rows.map(\.id) == [Self.figlet.id])
        model.showHidden = true
        #expect(Set(model.list.rows.map(\.id)) == [Self.wget.id, Self.jq.id, Self.figlet.id])
        #expect(model.hiddenReason(model.list.byRef[Self.wget.id]!) == .ignored)
        #expect(model.hiddenReason(model.list.byRef[Self.jq.id]!) == .skipped)
        #expect(model.hiddenReason(model.list.byRef[Self.figlet.id]!) == nil)
        model.showHidden = false
        #expect(model.list.rows.map(\.id) == [Self.figlet.id])
    }

    @Test func badgeCountsVisibleOnly() async {
        let (model, preferences) = Self.model(Self.catalog([Self.wget, Self.jq, Self.figlet]))
        await Self.reload(model)
        #expect(model.badgeCount == 3)
        preferences.ignore([Self.wget.id])
        preferences.skip(Self.jq.id, version: "2.0")
        model.list.recompute()
        #expect(model.badgeCount == 1)
        // Showing hidden rows doesn't count them.
        model.showHidden = true
        #expect(model.badgeCount == 1)
    }

    @Test func refreshAfterRunPrunesChecks() async {
        let catalog = Self.catalog([Self.wget, Self.jq, Self.figlet])
        let (model, _) = Self.model(catalog)
        await Self.reload(model)
        model.list.selection.checked = [Self.wget.id, Self.jq.id]
        model.list.selection.selected = [Self.wget.id]
        // wget was updated by the run and is gone from the next answer.
        catalog.script(.outdated, .homebrew, packages: [Self.jq])
        await Self.reload(model)
        #expect(model.list.selection.checked == [Self.jq.id])
        #expect(model.list.selection.selected.isEmpty)
        #expect(model.requests(for: model.list.selection.checked).map(\.package.id) == [Self.jq.id])
    }

    @Test func updateSelectedUsesCheckedNotHighlighted() async {
        let (model, _) = Self.model(Self.catalog([Self.wget, Self.jq, Self.figlet]))
        await Self.reload(model)
        model.list.selection.selected = [Self.wget.id]
        model.list.selection.checked = [Self.jq.id, Self.figlet.id]
        #expect(Set(model.checkedRequests().map(\.package.id)) == [Self.jq.id, Self.figlet.id])
        #expect(model.updateCheckedTitle == "Update 2")
        model.list.selection.checked = []
        #expect(model.checkedRequests().isEmpty)
        #expect(model.updateCheckedTitle == "Update")
    }

    @Test func updateAllDisabledWhileLoadingOrRunning() async {
        let catalog = FakeCatalog()
        catalog.script(.outdated, .homebrew, packages: [Self.wget], delay: .milliseconds(200))
        let (model, _) = Self.model(catalog)
        model.reload()
        #expect(model.list.loading)
        #expect(!model.canUpdateAll(isRunning: false))
        _ = await waitUntil { !model.list.loading && !model.pruning }
        #expect(model.canUpdateAll(isRunning: false))
        #expect(!model.canUpdateAll(isRunning: true))
    }

    @Test func updateAllDisabledWhenEverythingIsHidden() async {
        let (model, preferences) = Self.model(Self.catalog([Self.wget]))
        preferences.ignore([Self.wget.id])
        await Self.reload(model)
        #expect(!model.canUpdateAll(isRunning: false))
    }

    @Test func sortByEngine() async {
        let (model, _) = Self.model(Self.catalog([Self.package(.mas, "Xcode"), Self.wget,
                                                  Self.package(.nanobrew, "zstd"), Self.figlet]))
        await Self.reload(model)
        model.list.sortOrder = [KeyPathComparator(\PackageRow.engineName)]
        #expect(model.list.rows.map(\.engineName) == ["Homebrew", "Mac App Store", "MacPorts", "nanobrew"])
        model.list.sortOrder = [KeyPathComparator(\PackageRow.engineName, order: .reverse)]
        #expect(model.list.rows.map(\.engineName) == ["nanobrew", "MacPorts", "Mac App Store", "Homebrew"])
    }
}
