import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

@MainActor @Suite struct GroupingTests {
    typealias P = PreviewFixtures

    private func ref(_ engine: EngineID, _ name: String) -> PackageRef {
        PackageRef(engine: engine, kind: engine == .macports ? .port : .formula, name: name)
    }

    private func model(store: MemoryStore = MemoryStore()) -> BrewxPortAppModel {
        BrewxPortAppModel(services: AppFixtures.services(catalog: FakeCatalog(engines: P.allPresent), store: store))
    }

    @Test func groupingDefaultsOn() {
        #expect(model().groupByPackageManager)
    }

    @Test func groupingPersists() {
        let store = MemoryStore()
        let first = model(store: store)
        first.groupByPackageManager = false
        #expect(model(store: store).groupByPackageManager == false)
        first.groupByPackageManager = true
        #expect(model(store: store).groupByPackageManager)
    }

    @Test func collapseDropsHighlightNotChecks() {
        let m = model()
        let brew = ref(.homebrew, "jq"), port = ref(.macports, "curl")
        m.updates.list.selection = PackageSelection(selected: [brew, port], checked: [brew, port])
        m.setCollapsed(true, .homebrew, on: .updates)
        #expect(m.isCollapsed(.homebrew, on: .updates))
        #expect(m.updates.list.selection.selected == [port])
        #expect(m.updates.list.selection.checked == [brew, port])
    }

    @Test func toggleKeepsSelection() {
        let m = model()
        let brew = ref(.homebrew, "jq")
        m.installed.list.selection = PackageSelection(selected: [brew], checked: [brew])
        m.groupByPackageManager = false
        m.groupByPackageManager = true
        #expect(m.installed.list.selection == PackageSelection(selected: [brew], checked: [brew]))
    }

    @Test func collapseIsPerPage() {
        let m = model()
        let brew = ref(.homebrew, "jq")
        m.installed.list.selection = PackageSelection(selected: [brew])
        m.setCollapsed(true, .homebrew, on: .updates)
        #expect(m.isCollapsed(.homebrew, on: .updates))
        #expect(!m.isCollapsed(.homebrew, on: .installed))
        #expect(!m.isCollapsed(.macports, on: .updates))
        #expect(m.installed.list.selection.selected == [brew])
        m.setCollapsed(false, .homebrew, on: .updates)
        #expect(!m.isCollapsed(.homebrew, on: .updates))
    }

    // MARK: Updates: a section's Update N

    private typealias F = AppFixtures

    private static func arguments(_ executor: FakeRunExecutor, run: Int = 0) -> [String] {
        executor.runs[run].steps.flatMap(\.spec.arguments)
    }

    private let wget = F.package(.homebrew, .formula, "wget", installed: "1")
    private let jq = F.package(.homebrew, .formula, "jq", installed: "1")
    private let curl = F.package(.macports, .port, "curl", installed: "1")
    private let zlib = F.package(.macports, .port, "zlib", installed: "1")

    @Test func updateNOnlyThatManager() async {
        let executor = FakeRunExecutor()
        let m = await F.updatesModel([wget, jq, curl], executor: executor)
        #expect(Set(m.updates.updateAllRequests(for: .homebrew).map(\.package.id)) == [wget.id, jq.id])
        #expect(m.updates.updateAllRequests(for: .homebrew).allSatisfy { $0.operation == .upgrade })
        #expect(m.updates.updateCount(for: .homebrew) == 2)
        #expect(m.updates.updateCount(for: .macports) == 1)
        m.updateAll(engine: .homebrew)
        #expect(await waitUntil { executor.runs.count == 1 && !m.run.isRunning })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        let arguments = Self.arguments(executor)
        #expect(arguments.contains("wget") && arguments.contains("jq") && !arguments.contains("curl"))
    }

    @Test func updateNSkipsIgnoredShown() async {
        let m = await F.updatesModel([wget, jq, curl])
        m.perform(.ignore, on: [wget.id])
        m.updates.showHidden = true
        // Shown in its section, but neither counted nor updated.
        #expect(m.updates.list.rows.contains { $0.id == wget.id })
        #expect(m.updates.updateCount(for: .homebrew) == 1)
        #expect(m.updates.updateAllRequests(for: .homebrew).map(\.package.id) == [jq.id])
        m.perform(.skipVersion("2"), on: [jq.id])
        #expect(m.updates.updateCount(for: .homebrew) == 0)
        #expect(m.updates.updateAllRequests(for: .homebrew).isEmpty)
    }

    @Test func updateNActsOnCollapsedSection() async {
        let executor = FakeRunExecutor()
        let m = await F.updatesModel([wget, jq, curl], executor: executor)
        m.updates.list.selection = PackageSelection(selected: [wget.id], checked: [wget.id, curl.id])
        m.setCollapsed(true, .homebrew, on: .updates)
        // Collapsing hides rows; it doesn't take them out of the list, the counts or the checked Update.
        #expect(m.updates.list.rows.count == 3)
        #expect(m.updates.updateCount(for: .homebrew) == 2)
        #expect(Set(m.updates.updateAllRequests().map(\.package.id)) == [wget.id, jq.id, curl.id])
        #expect(Set(m.updates.checkedRequests().map(\.package.id)) == [wget.id, curl.id])
        m.updateAll(engine: .homebrew)
        #expect(await waitUntil { executor.runs.count == 1 && !m.run.isRunning })
        let arguments = Self.arguments(executor)
        #expect(arguments.contains("wget") && arguments.contains("jq") && !arguments.contains("curl"))
    }

    @Test func updateNHiddenAtZero() async {
        let executor = FakeRunExecutor()
        let m = await F.updatesModel([wget, curl], executor: executor)
        m.perform(.ignore, on: [curl.id])
        #expect(m.updates.updateCount(for: .macports) == 0)
        #expect(m.updates.updateCount(for: .nanobrew) == 0)
        #expect(m.updates.updateCount(for: .homebrew) == 1)
        // Nothing to update: no run starts.
        m.updateAll(engine: .macports)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
    }

    @Test func updateNDisabledWhileRunning() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let m = await F.updatesModel([wget, curl], executor: executor)
        #expect(m.canUpdateAll)
        m.updateAll(engine: .homebrew)
        #expect(await waitUntil { m.run.isRunning && executor.runs.count == 1 })
        // Update N follows Update all: off while a run goes, and a click then does nothing.
        #expect(!m.canUpdateAll)
        m.updateAll(engine: .macports)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        m.run.cancel()
        #expect(await waitUntil { !m.run.isRunning })
    }

    @Test func updateNOnePassword() async {
        let executor = FakeRunExecutor()
        let m = await F.updatesModel([wget, curl, zlib], executor: executor)
        m.updateAll(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 1 && !m.run.isRunning })
        try? await Task.sleep(for: .milliseconds(50))
        // One run for the whole MacPorts section, so at most one password.
        #expect(executor.runs.count == 1)
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.macports])
        let arguments = Self.arguments(executor)
        #expect(arguments.contains("curl") && arguments.contains("zlib") && !arguments.contains("wget"))
    }

    // MARK: Installed and Discover: sections

    private func installedPackage(_ engine: EngineID, _ name: String) -> Package {
        Package(id: ref(engine, name), displayName: name, installedVersion: "1")
    }

    /// A model whose Installed page holds `packages`, loaded and settled.
    private func installedModel(_ packages: [Package]) async -> BrewxPortAppModel {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.installed, engine, packages: found)
        }
        let m = BrewxPortAppModel(services: F.services(catalog: catalog, isDemo: true))
        m.installed.reload()
        await m.installed.settled()
        return m
    }

    /// A model whose Discover page holds `packages` as the results of searching "x".
    private func searchModel(_ packages: [Package]) async -> BrewxPortAppModel {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.search("x"), engine, packages: found)
        }
        let m = BrewxPortAppModel(services: F.services(catalog: catalog, isDemo: true))
        m.discover.query = "x"
        m.discover.submit()
        _ = await waitUntil { !m.discover.searching }
        return m
    }

    @Test func installedSectionsSortWithinSection() async {
        let m = await installedModel([installedPackage(.homebrew, "b"), installedPackage(.macports, "z"),
                                      installedPackage(.homebrew, "c"), installedPackage(.macports, "y"),
                                      installedPackage(.homebrew, "a")])
        m.installed.sortOrder = [KeyPathComparator(\InstalledRow.name, order: .reverse)]
        let sections = m.installedSections ?? []
        // Sections stay in engine order; the sort only orders rows inside each one.
        #expect(sections.map(\.engine) == m.engineOrder.filter { [.homebrew, .macports].contains($0) })
        #expect(sections.first { $0.engine == .homebrew }?.rows.map(\.name) == ["c", "b", "a"])
        #expect(sections.first { $0.engine == .macports }?.rows.map(\.name) == ["z", "y"])
    }

    @Test func installedDuplicateAppearsInBothSections() async {
        let m = await installedModel([installedPackage(.homebrew, "figlet"), installedPackage(.macports, "figlet"),
                                      installedPackage(.homebrew, "jq")])
        let sections = m.installedSections ?? []
        let brew = sections.first { $0.engine == .homebrew }
        let port = sections.first { $0.engine == .macports }
        #expect(brew?.rows.map(\.name).sorted() == ["figlet", "jq"])
        #expect(port?.rows.map(\.name) == ["figlet"])
        // Each copy keeps its warning.
        #expect(brew?.rows.first { $0.name == "figlet" }?.duplicateHelp != nil)
        #expect(port?.rows.first?.duplicateHelp != nil)
        #expect(brew?.rows.first { $0.name == "jq" }?.duplicateHelp == nil)
    }

    @Test func collapsingKeepsEveryRowAndCheck() async {
        let m = await installedModel([installedPackage(.homebrew, "a"), installedPackage(.macports, "b")])
        let a = ref(.homebrew, "a")
        m.installed.list.selection = PackageSelection(selected: [], checked: [a])
        m.setCollapsed(true, .homebrew, on: .installed)
        #expect(m.installed.list.rows.count == 2)
        #expect(m.installedSections?.first { $0.engine == .homebrew }?.rows.count == 1)
        #expect(m.installed.checkedRefs == [a])
    }

    @Test func discoverOneManagerOneSection() async {
        let m = await searchModel([installedPackage(.homebrew, "ripgrep"), installedPackage(.macports, "ripgrep"),
                                   installedPackage(.homebrew, "rg")])
        m.discover.engineFilter = .macports
        let sections = m.discoverSections ?? []
        #expect(sections.map(\.engine) == [.macports])
        #expect(sections[0].rows.map(\.name) == ["ripgrep"])
    }

    @Test func discoverAllManagersSections() async {
        let m = await searchModel([installedPackage(.macports, "ripgrep"), installedPackage(.homebrew, "ripgrep"),
                                   installedPackage(.homebrew, "rg")])
        let sections = m.discoverSections ?? []
        #expect(sections.map(\.engine) == m.engineOrder.filter { [.homebrew, .macports].contains($0) })
        #expect(sections.first { $0.engine == .homebrew }?.rows.count == 2)
        #expect(sections.first { $0.engine == .macports }?.rows.count == 1)
        // Sorting is the shared list's, applied inside each section.
        m.discover.list.sortOrder = [KeyPathComparator(\PackageRow.name, order: .reverse)]
        #expect(m.discoverSections?.first { $0.engine == .homebrew }?.rows.map(\.name) == ["ripgrep", "rg"])
    }

    @Test func flatWhenGroupingOff() async {
        let m = await installedModel([installedPackage(.homebrew, "a"), installedPackage(.macports, "b")])
        #expect(m.installedSections != nil)
        m.groupByPackageManager = false
        #expect(m.installedSections == nil)
        #expect(m.discoverSections == nil)
        #expect(m.installed.rows.count == 2)
    }

    // MARK: Grouping back on with a section still collapsed

    @Test func groupingOnWithCollapsedSectionDropsHiddenHighlight() async {
        let executor = FakeRunExecutor()
        let m = await F.updatesModel([wget, jq, curl], executor: executor)
        m.sidebar = .updates
        m.setCollapsed(true, .homebrew, on: .updates)
        m.groupByPackageManager = false
        m.updates.list.selection = PackageSelection(selected: [wget.id], checked: [curl.id])
        #expect(m.canPerformPrimary)
        m.groupByPackageManager = true
        #expect(m.isCollapsed(.homebrew, on: .updates))
        #expect(m.updates.list.selection.selected.isEmpty)
        #expect(m.updates.list.selection.checked == [curl.id])
        #expect(!m.canPerformPrimary)
        #expect(!m.canRemoveSelection)
        m.performPrimary()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
    }

    @Test func groupingOnPrunesCollapsedHighlightOnInstalled() async {
        let m = await installedModel([installedPackage(.homebrew, "a"), installedPackage(.macports, "b")])
        let a = ref(.homebrew, "a"), b = ref(.macports, "b")
        m.setCollapsed(true, .homebrew, on: .installed)
        m.groupByPackageManager = false
        m.installed.list.selection = PackageSelection(selected: [a, b], checked: [a])
        m.groupByPackageManager = true
        #expect(m.installed.list.selection == PackageSelection(selected: [b], checked: [a]))
    }

    @Test func groupingOnPrunesCollapsedHighlightOnDiscover() async {
        let m = await searchModel([installedPackage(.homebrew, "a"), installedPackage(.macports, "b")])
        let a = ref(.homebrew, "a"), b = ref(.macports, "b")
        m.setCollapsed(true, .homebrew, on: .discover)
        m.groupByPackageManager = false
        m.discover.list.selection = PackageSelection(selected: [a, b], checked: [])
        m.groupByPackageManager = true
        #expect(m.discover.list.selection.selected == [b])
    }
}
