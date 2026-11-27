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

    static func tool(_ engine: EngineID, _ name: String, installed: String = "1.0", latest: String = "2.0") -> Package {
        Package(id: PackageRef(engine: engine, kind: .tool, name: name), displayName: name,
                installedVersion: installed, latestVersion: latest)
    }

    static func languageModel(_ catalog: FakeCatalog) -> UpdatesModel {
        let list = PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 })
        return UpdatesModel(catalog: catalog, preferences: UpdatePreferences(store: MemoryStore()), list: list)
    }

    /// R6: an engine whose check couldn't look some packages up says how many on its section, with or without rows
    /// of its own, and names them for the tooltip and the page; it isn't a failed engine.
    @Test func partialCheckShowsCountOnSection() async {
        let catalog = FakeCatalog()
        catalog.script(.outdated, .pipx, FakeCatalog.Script(
            result: .success([Self.tool(.pipx, "cowsay")]),
            unchecked: UncheckedPackages(reasons: ["black": "PyPI didn't answer", "ruff": "PyPI didn't answer"])))
        catalog.script(.outdated, .uv, FakeCatalog.Script(
            result: .success([]), unchecked: UncheckedPackages(reasons: ["isort": "PyPI didn't answer"])))
        catalog.script(.outdated, .bun, FakeCatalog.Script(result: .success([]),
                                                          unchecked: UncheckedPackages(unnamed: true)))
        catalog.script(.outdated, .homebrew, packages: [Self.wget])
        let model = Self.languageModel(catalog)
        await Self.reload(model)
        #expect(model.uncheckedNote(for: .pipx) == "2 tools couldn't be checked")
        #expect(model.uncheckedNote(for: .uv) == "1 tool couldn't be checked")
        #expect(model.uncheckedNote(for: .bun) == "Some tools couldn't be checked")
        #expect(model.uncheckedNote(for: .homebrew) == nil)
        #expect(model.uncheckedDetail(for: .pipx) == "2 tools couldn't be checked: black, ruff")
        #expect(model.uncheckedDetail(for: .bun) == "Some tools couldn't be checked")
        // uv has no rows, so no section: the line above the list still says it.
        #expect(model.uncheckedLines == ["pipx: 2 tools couldn't be checked: black, ruff",
                                         "uv: 1 tool couldn't be checked: isort",
                                         "Bun: Some tools couldn't be checked"])
        #expect(model.list.failedEngines.isEmpty)
        #expect(model.list.errors.isEmpty)
        #expect(Set(model.updateAllRequests().map(\.package.id)) == [Self.wget.id, Self.tool(.pipx, "cowsay").id])
        // A later check that answers in full clears it.
        catalog.script(.outdated, .pipx, packages: [Self.tool(.pipx, "cowsay")])
        await Self.reload(model)
        #expect(model.uncheckedNote(for: .pipx) == nil)
    }

    /// The empty page says "Everything is up to date" only when every check answered in full and nothing is held back;
    /// otherwise "Nothing else to update", with a line about what couldn't be checked or how many are hidden.
    @Test func emptyPageDoesntClaimEverythingIsUpToDate() async {
        let catalog = FakeCatalog()
        catalog.script(.outdated, .homebrew, packages: [])
        let model = Self.languageModel(catalog)
        await Self.reload(model)
        #expect(model.emptyTitle == "Everything is up to date")
        #expect(model.emptyNote == "No engine has a newer version of anything you installed.")

        catalog.script(.outdated, .pipx, FakeCatalog.Script(
            result: .success([]), unchecked: UncheckedPackages(reasons: ["black": "PyPI didn't answer"])))
        await Self.reload(model)
        #expect(model.list.rows.isEmpty)
        #expect(model.emptyTitle == "Nothing else to update")
        #expect(model.emptyNote == "Some packages couldn't be checked, as the lines above say.")

        // A held row that's also ignored is off the page, but still not "up to date".
        let ripgrep = Self.tool(.cargo, "ripgrep")
        let preferences = UpdatePreferences(store: MemoryStore())
        preferences.ignore([ripgrep.id])
        let heldCatalog = FakeCatalog()
        heldCatalog.script(.outdated, .cargo, FakeCatalog.Script(result: .success([]), held: [HeldUpdate(
            package: ripgrep, hold: UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true))]))
        let list = PackageListState(order: PackageCatalog.defaultOrder(for: .arm64), archFor: { _ in .arm64 })
        let held = UpdatesModel(catalog: heldCatalog, preferences: preferences, list: list)
        await Self.reload(held)
        #expect(held.list.rows.isEmpty)
        #expect(held.emptyTitle == "Nothing else to update")
        #expect(held.emptyNote == "1 update is ignored or skipped.")
    }

    /// R26: a check that answered but can't tell some installs apart (npm without its list of globals) says so in its
    /// own words, on its section, above the list and on its page; it isn't a failed engine.
    @Test func checkNoteShowsWithoutNames() async {
        let note = "Couldn't read npm's list of globals; folder and linked installs can't be told apart until it works"
        let catalog = FakeCatalog()
        catalog.script(.outdated, .npm, FakeCatalog.Script(result: .success([Self.tool(.npm, "cowsay")]),
                                                          unchecked: UncheckedPackages(note: note)))
        let model = Self.languageModel(catalog)
        await Self.reload(model)
        #expect(model.uncheckedNote(for: .npm) == note)
        #expect(model.uncheckedDetail(for: .npm) == note)
        #expect(model.uncheckedLines == ["npm: " + note])
        #expect(model.list.failedEngines.isEmpty)
        #expect(model.updateAllRequests().map(\.package.id) == [Self.tool(.npm, "cowsay").id])
    }

    /// A held runtime whose relations couldn't be worked out counts as brought along by every update from its package
    /// manager (never a guess); not by itself, and not by another manager's.
    @Test func runtimeBroughtAlongWithoutRelationsCountsEveryUpdate() async {
        let ruby = Self.package(.homebrew, "ruby", installed: "4.0.10", latest: "4.1.0")
        let model = Self.languageModel(Self.catalog([ruby, Self.wget, Self.figlet]))
        await Self.reload(model)
        model.runtimeHolds = [ruby.id: RuntimeHold(
            hold: UpdateHold(reason: "Updating it needs your gems reinstalled.", blocksAutomatic: true,
                             blocksManual: false),
            noticeTitle: "Ruby 4.1 is ready", runtime: "Ruby", version: "4.1", engines: [.gem: []])]
        #expect(model.runtimesBroughtAlong(by: Self.wget.id) == [ruby.id])
        #expect(model.runtimesBroughtAlong(by: ruby.id).isEmpty)
        #expect(model.runtimesBroughtAlong(by: Self.figlet.id).isEmpty)
        // Worked out, with nothing depending on Ruby or needed by it: wget doesn't bring it along.
        let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        let infos = FakeCatalog()
        infos.scriptInfo(ruby.id, .init(result: .success(PackageDetails(ref: ruby.id, dependencies: []))))
        var installed = [ruby, Self.wget]
        for index in installed.indices { installed[index].installedOnRequest = true }
        model.runtimeRelations = [ruby.id: await HiddenRelations.gather(
            for: [.homebrew], hidden: [ruby], outdated: [ruby.id, Self.wget.id], installed: installed,
            installedFailed: [], engines: [brew], catalog: infos)]
        #expect(model.runtimesBroughtAlong(by: Self.wget.id).isEmpty)
    }

    /// Held rows show with their reason. One held from every update ("Needs Rust 1.96") is out of Update all, the
    /// toolbar's Update, the badge and automatic updates; one held only from automatic updates (a gem that came with
    /// Ruby) can still be updated by hand. An app-level hold works the same way.
    @Test func heldRowReasonVisible() async {
        let ripgrep = Self.tool(.cargo, "ripgrep", installed: "14.1.0", latest: "16.0.0")
        let rake = Self.tool(.gem, "rake", installed: "13.3.1", latest: "13.4.2")
        let rust = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        let ruby = UpdateHold(reason: "Came with Ruby, so BrewxPort updates it only when you ask.",
                              blocksAutomatic: true, blocksManual: false)
        let catalog = FakeCatalog()
        catalog.script(.outdated, .cargo, FakeCatalog.Script(result: .success([]),
                                                            held: [HeldUpdate(package: ripgrep, hold: rust)]))
        catalog.script(.outdated, .gem, FakeCatalog.Script(result: .success([rake]),
                                                          held: [HeldUpdate(package: rake, hold: ruby)]))
        catalog.script(.outdated, .homebrew, packages: [Self.wget])
        let model = Self.languageModel(catalog)
        await Self.reload(model)
        #expect(model.list.rows.map(\.id) == [rake.id, ripgrep.id, Self.wget.id])
        let byRef = model.list.byRef
        #expect(byRef[ripgrep.id].flatMap(model.hold(for:))?.reason == "Needs Rust 1.96")
        #expect(byRef[rake.id].flatMap(model.hold(for:)) == ruby)
        #expect(byRef[Self.wget.id].flatMap(model.hold(for:)) == nil)
        #expect(model.blocksManual(ripgrep.id) && !model.blocksManual(rake.id))
        #expect(model.updateAllRequests().map(\.package.id) == [rake.id, Self.wget.id])
        #expect(model.automaticRequests().map(\.package.id) == [Self.wget.id])
        #expect(model.updateAllRequests(for: .cargo).isEmpty)
        #expect(model.requests(for: [ripgrep.id, rake.id]).map(\.package.id) == [rake.id])
        #expect(model.badgeCount == 2)
        #expect(model.hiddenCount == 0)
        // The app's own hold (Task 10b's runtime hold-back) on a row no engine holds.
        model.appHolds = [Self.wget.id: UpdateHold(reason: "Ruby 4.1 is ready", blocksAutomatic: true,
                                                   blocksManual: false)]
        #expect(model.automaticRequests().isEmpty)
        #expect(model.updateAllRequests().map(\.package.id) == [rake.id, Self.wget.id])
        #expect(byRef[Self.wget.id].flatMap(model.hold(for:))?.reason == "Ruby 4.1 is ready")
    }

    @Test func reloadedWaitsForLoadAndPrune() async {
        let gate = Gate()
        let catalog = FakeCatalog()
        catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .success([Self.wget]), gate: gate))
        let (model, _) = Self.model(catalog)
        // Nothing going: returns at once.
        await model.reloaded()
        model.reload()
        // A second reload while the first loads replaces the first one's prune.
        model.reload()
        let waiter = Task { await model.reloaded(); return (model.list.loading, model.pruning, model.list.all.count) }
        #expect(await waitUntil { gate.waiting == 1 })
        gate.release()
        // The queued reload.
        #expect(await waitUntil { gate.waiting == 1 })
        gate.release()
        let (loading, pruning, rows) = await waiter.value
        #expect(!loading && !pruning && rows == 1)
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
