import AppKit
import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// The window's state: the sidebar, the engines, the helper, the run, the inspector, and the one entry point for
/// every row action. Views bind to it and call its methods; they never build a step or decide what's allowed.
@MainActor @Observable public final class BrewxPortAppModel {
    /// Switching pages points an open inspector at the new page's selection, never at a row from the last page.
    public var sidebar: SidebarItem = .updates {
        didSet { if sidebar != oldValue { selectionChanged(selectedOnScreen) } }
    }
    public private(set) var engineStatuses: [EngineID: EngineStatus] = [:]
    public private(set) var checkingEngines = false
    /// Nil until the first answer, and always nil when this copy has no helper (demo mode, or unsigned).
    public private(set) var helperState: HelperState?
    public private(set) var checkingHelper = false
    public let run: RunController
    public let details: DetailsModel
    public let preferences: UpdatePreferences
    public let discover: DiscoverModel
    public let updates: UpdatesModel
    public let installed: InstalledModel
    public var inspectorOpen = false
    /// Bumped by Find (Cmd-F); DiscoverView maps it to `.searchFocused`.
    public var focusSearchRequest = 0
    @ObservationIgnored private var searchFocusPending = false
    /// nanobrew cask route lookups in flight before `run.start`.
    public private(set) var preparing = false
    /// Non-nil shows the uninstall confirmation.
    public var pendingUninstall: Set<PackageRef>?

    @ObservationIgnored public let services: Services

    public var engineOrder: [EngineID] { PackageCatalog.defaultOrder(for: services.host) }
    /// False when this copy can't run anything (`services.setupProblem` says why).
    public var canRun: Bool { services.executor != nil }
    public var hasHelper: Bool { services.helper != nil }
    public var homebrewPresent: Bool {
        if case .present? = engineStatuses[.homebrew] { return true }
        return false
    }
    /// What the MacPorts page says about the helper.
    public var helperText: String {
        if hasHelper { return HelperStateDisplay.text(for: helperState) }
        if services.isDemo { return DemoServices.helperText }
        return services.setupProblem ?? "BrewxPort's helper isn't available."
    }
    /// Shown above the password field. Demo mode says the password isn't checked or kept.
    public var passwordNote: String? { services.isDemo ? DemoServices.passwordNote : nil }
    public var windowTitle: String { services.isDemo ? "BrewxPort (demo)" : "BrewxPort" }
    /// Closing the window quits BrewxPort, except during a run: then the window goes and the run carries on, rather
    /// than the quit confirmation's "Keep running" leaving BrewxPort without a window.
    public var quitsWhenLastWindowCloses: Bool { !run.isRunning }

    /// The lists `package(for:)` looks in, in order: Updates, then Installed, then Discover.
    @ObservationIgnored var packageSources: [PackageListState] = []
    /// How many times the lists were reloaded. Internal for tests.
    @ObservationIgnored private(set) var listReloadCount = 0
    /// Copy name's destination. Tests replace it so they never touch the user's clipboard.
    @ObservationIgnored var writeToPasteboard: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var helperFlight: (kind: HelperCall, task: Task<HelperState?, Never>)?

    private enum HelperCall { case refresh, ensure, reinstall }

    public init(services: Services) {
        self.services = services
        run = RunController(executor: services.executor, isAdministrator: services.isAdministrator)
        details = DetailsModel(catalog: services.catalog)
        preferences = UpdatePreferences(store: services.store)
        let engines = services.engines
        let order = PackageCatalog.defaultOrder(for: services.host)
        let host = services.host
        let archFor: (EngineID) -> Arch = { id in engines.first { $0.id == id }?.runArch ?? host }
        let discoverList = PackageListState(order: order, archFor: archFor)
        discover = DiscoverModel(catalog: services.catalog, list: discoverList)
        let updatesList = PackageListState(order: order, archFor: archFor)
        updates = UpdatesModel(catalog: services.catalog, preferences: preferences, list: updatesList)
        let installedList = PackageListState(order: order, archFor: archFor)
        installed = InstalledModel(catalog: services.catalog, path: services.path, engines: engines,
                                   fileExists: services.fileExists, list: installedList)
        // Updates and Installed come ahead of Discover: their rows carry installed versions.
        packageSources = [updatesList, installedList, discoverList]
        // Discover's installed marks come from the Installed list and nowhere else.
        // Updates rows show the installed copy's arch, which only Installed's answer carries.
        let discover = discover
        installed.onLoaded = { refs in
            discover.markInstalled(refs)
            updatesList.borrowedArchs = Dictionary(
                installedList.all.compactMap { row in row.package.installedArchs.map { (row.id, $0) } },
                uniquingKeysWith: { first, _ in first })
        }
        services.passwords.prompter = run
        // Every run end reloads the lists, a run that ran nothing included (the helper check or the preflight
        // can leave nothing to do, and a refresh asked for during the run must still happen).
        run.onRunEnded = { [weak self] in self?.runEnded() }
    }

    /// Once, when the window appears: detect engines, make sure the helper is registered (live only), load lists.
    /// A standard account only reads the helper's state: registering asks for an administrator, and nothing it can
    /// run uses the helper.
    public func start() {
        guard !started else { return }
        started = true
        checkEnginesAgain()
        if !services.isDemo, services.helper != nil {
            let call: HelperCall = services.isAdministrator() == false ? .refresh : .ensure
            Task { _ = await self.helper(call) }
        }
        refreshLists()
    }

    // MARK: Engines

    public func checkEnginesAgain() {
        guard !checkingEngines else { return }
        checkingEngines = true
        let catalog = services.catalog
        Task {
            let statuses = await catalog.presentEngines()
            engineStatuses = statuses
            checkingEngines = false
        }
    }

    // MARK: Helper

    /// "Check again": `HelperManaging.refresh()`, which only reads. Ignored during a run or another helper call.
    public func checkHelper() {
        guard mayTouchHelper else { return }
        Task { _ = await helper(.refresh) }
    }

    /// "Reinstall helper". Ignored during a run, and while another helper call is in flight, so the click is never
    /// absorbed by a registration that's already going.
    public func reinstallHelper() {
        guard mayTouchHelper else { return }
        Task { _ = await helper(.reinstall) }
    }

    /// Ignored during a run.
    public func openLoginItems() {
        guard !run.isRunning else { return }
        services.helper?.openLoginItems()
    }

    private var mayTouchHelper: Bool {
        services.helper != nil && !checkingHelper && !run.isRunning
    }

    /// One helper call at a time, so `checkingHelper` and `helperState` follow every call, the run's included.
    /// An ensure that finds a registration (ensure or reinstall) in flight takes its answer; one that finds a
    /// read-only refresh in flight waits for it and then registers.
    private func helper(_ kind: HelperCall) async -> HelperState? {
        guard let manager = services.helper else { return nil }
        while let flight = helperFlight {
            let state = await flight.task.value
            if kind != .ensure || flight.kind != .refresh { return state }
        }
        checkingHelper = true
        let task = Task<HelperState?, Never> {
            let state: HelperState
            switch kind {
            case .refresh: state = await manager.refresh()
            case .ensure: state = await manager.ensureRegistered()
            case .reinstall: state = await manager.reinstall()
            }
            helperState = state
            checkingHelper = false
            helperFlight = nil
            return state
        }
        helperFlight = (kind, task)
        return await task.value
    }

    // MARK: Find

    /// Find (Cmd-F): shows Discover and asks its search field for focus.
    public func find() {
        sidebar = .discover
        focusSearchRequest += 1
        searchFocusPending = true
    }

    /// True once per Find: Discover focuses its field when this says so, on appear or when the request changes,
    /// and not when the user just clicks Discover in the sidebar.
    public func takeSearchFocusRequest() -> Bool {
        defer { searchFocusPending = false }
        return searchFocusPending
    }

    // MARK: Actions

    /// The one entry for actions. Install, Update and Uninstall do nothing when this copy can't run anything
    /// (`canRun`), while `run.isRunning` or `preparing` (no dialog, no lookup) or while the remove confirmation is
    /// up, so the refs it names never change under it; Ignore, Skip, Show details and Copy name don't start a run and
    /// always work.
    public func perform(_ action: RowAction, on refs: Set<PackageRef>) {
        switch action {
        case .install, .update:
            guard canRun, !busy, !confirmingRemoval else { return }
            startChange(action == .install ? .install : .upgrade, on: refs)
        case .uninstall:
            guard canRun, !busy, !confirmingRemoval else { return }
            let known = refs.filter { row(for: $0) != nil }
            guard !known.isEmpty else { return }
            pendingUninstall = known
        case .ignore:
            preferences.ignore(refs)
            recomputeUpdates()
        case .stopIgnoring:
            preferences.unignore(refs)
            recomputeUpdates()
        case .skipVersion(let version):
            for ref in refs { preferences.skip(ref, version: version) }
            recomputeUpdates()
        case .showDetails:
            guard refs.count == 1, let ref = refs.first, let row = row(for: ref) else { return }
            details.show(row)
            inspectorOpen = true
        case .copyName:
            var rows: [PackageRef: PackageRow] = [:]
            for ref in refs { rows[ref] = row(for: ref) }
            let text = RowActions.copyText(for: refs, rows: rows)
            guard !text.isEmpty else { return }
            writeToPasteboard(text)
        }
    }

    /// The toolbar's Install: enabled when a checked, uninstalled row is there and nothing is running.
    public var canInstallChecked: Bool {
        canRun && !busy && !discover.checkedRefs.isEmpty
    }

    public func installChecked() {
        perform(.install, on: discover.checkedRefs)
    }

    /// The toolbar's Update all: every Updates row that's neither ignored nor skipped.
    public var canUpdateAll: Bool {
        canRun && updates.canUpdateAll(isRunning: busy)
    }

    public func updateAll() {
        updateRefs(updates.updateAllRequests())
    }

    /// The toolbar's "Update N": the checked rows on screen that aren't ignored or skipped.
    public var canUpdateChecked: Bool {
        canRun && !busy && !updates.checkedRequests().isEmpty
    }

    public func updateChecked() {
        updateRefs(updates.checkedRequests())
    }

    /// Return in Updates: the selected rows on screen that aren't ignored or skipped.
    public func updateSelected() {
        updateRefs(updates.requests(for: updates.list.selection.selected))
    }

    private func updateRefs(_ requests: [ActionRequest]) {
        guard !requests.isEmpty else { return }
        perform(.update, on: Set(requests.map(\.package.id)))
    }

    /// The toolbar's "Remove N" in Installed: the checked rows on screen, after the confirmation.
    public var canRemoveChecked: Bool {
        canRun && !busy && !installed.checkedRefs.isEmpty
    }

    public func removeChecked() {
        perform(.uninstall, on: installed.checkedRefs)
    }

    /// Delete in Installed: the selected rows on screen, after the confirmation.
    public func removeSelected() {
        let list = installed.list
        perform(.uninstall, on: list.onScreen(list.selection.selected))
    }

    /// Return in Discover: installs the selected rows that are on screen.
    public func installSelected() {
        let list = discover.list
        perform(.install, on: list.onScreen(list.selection.selected))
    }

    // MARK: Keyboard and menu

    /// The package table on screen, or nil on Bundles and the engine pages. The Package menu and the tables' keys
    /// (Return, Space, Delete) act on it, so each key does the same thing from the table and from the menu.
    public var currentView: PackageView? {
        switch sidebar {
        case .discover: .discover
        case .updates: .updates
        case .installed: .installed
        case .bundles, .engine: nil
        }
    }

    private func list(for view: PackageView) -> PackageListState {
        switch view {
        case .discover: discover.list
        case .updates: updates.list
        case .installed: installed.list
        }
    }

    /// The selected rows on screen in the current table.
    private var selectedOnScreen: Set<PackageRef> {
        guard let view = currentView else { return [] }
        let list = list(for: view)
        return list.onScreen(list.selection.selected)
    }

    /// The Package menu's first item: Install on Discover, Update on Updates and Installed.
    public var primaryActionTitle: String {
        currentView == .discover ? "Install Selected" : "Update Selected"
    }

    /// What Return (and ⌘↩) would act on: the selected rows on screen that the action applies to. Discover's
    /// not-installed rows; Updates' rows that aren't ignored or skipped; Installed's rows that have an update.
    private var primaryRefs: Set<PackageRef> {
        let selected = selectedOnScreen
        switch currentView {
        case .discover?:
            return selected.filter { discover.list.byRef[$0]?.isInstalled == false }
        case .updates?:
            return Set(updates.requests(for: selected).map(\.package.id))
        case .installed?:
            return selected.intersection(outdatedRefs)
        case nil:
            return []
        }
    }

    public var canPerformPrimary: Bool { canRun && !busy && !confirmingRemoval && !primaryRefs.isEmpty }

    /// Return and ⌘↩: installs (Discover) or updates (Updates, Installed) the selected rows.
    public func performPrimary() {
        guard !confirmingRemoval else { return }
        switch currentView {
        case .discover?: installSelected()
        case .updates?: updateSelected()
        case .installed?:
            let refs = primaryRefs
            guard !refs.isEmpty else { return }
            perform(.update, on: refs)
        case nil: break
        }
    }

    /// Delete and ⌘⌫ remove after the confirmation, on Updates and Installed (every row there is installed).
    public var canRemoveSelection: Bool {
        (currentView == .updates || currentView == .installed) && canRun && !busy && !confirmingRemoval
            && !selectedOnScreen.isEmpty
    }

    public func removeSelection() {
        guard let view = currentView, view != .discover, !confirmingRemoval else { return }
        perform(.uninstall, on: selectedOnScreen)
    }

    public var canToggleChecks: Bool { !confirmingRemoval && !selectedOnScreen.isEmpty }

    /// Space: checks the selected rows, or unchecks them when they're all checked.
    public func toggleChecks() {
        guard let view = currentView, !confirmingRemoval else { return }
        list(for: view).toggleSelectedChecks()
    }

    /// Show Details (⌘I) opens or closes the inspector. Opening it shows the one selected row, if there is one.
    /// Show Details needs a package page; Hide Details works wherever the inspector is open.
    public var canToggleInspector: Bool { currentView != nil || inspectorOpen }

    public func toggleInspector() {
        if inspectorOpen {
            inspectorOpen = false
            return
        }
        inspectorOpen = true
        let selected = selectedOnScreen
        if selected.count == 1, let ref = selected.first, let row = row(for: ref) {
            details.show(row)
        } else {
            details.show(nil)
        }
    }

    /// While the inspector is open it follows the selection: one selected row shows its details, and zero or
    /// several leave it empty.
    public func selectionChanged(_ refs: Set<PackageRef>) {
        guard inspectorOpen else { return }
        if refs.count == 1, let ref = refs.first, let row = row(for: ref) {
            details.show(row)
        } else {
            details.show(nil)
        }
    }

    /// Which option fields the inspector shows for its package. Nil when there's nothing to install.
    public var inspectorOptions: InspectorOptionFields? {
        guard let row = details.row, !row.isInstalled,
              let engine = services.engines.first(where: { $0.id == row.id.engine }) else { return nil }
        return InspectorOptionFields(version: engine.capabilities.contains(.versionPinning),
                                     extraArgs: row.id.engine != .mas,
                                     variants: row.id.engine == .macports ? (details.details?.variants ?? []).sorted() : [])
    }

    /// The inspector's own Install: the shown package with the inspector's options. An option the engine won't take
    /// shows as `details.optionsError` and starts nothing.
    public func installFromInspector() {
        guard !busy, let row = details.row, !row.isInstalled,
              let engine = services.engines.first(where: { $0.id == row.id.engine }) else { return }
        do {
            let options = try details.options.options(for: engine.id, capabilities: engine.capabilities)
            details.optionsError = nil
            startChange(.install, on: [row.id], options: [row.id: options])
        } catch let error as EngineError {
            details.optionsError = error.message
        } catch {
            details.optionsError = "\(error)"
        }
    }

    /// The inspector's Update: the same path as the row menu's Update.
    public func updateFromInspector() {
        guard let row = details.row, row.isInstalled else { return }
        perform(.update, on: [row.id])
    }

    /// The confirmation's title, naming what goes: "Remove figlet (nanobrew)?", "Remove jq (Homebrew) and wget
    /// (Homebrew)?", or the first five in name order and "and 3 more".
    public var uninstallTitle: String {
        let names = (pendingUninstall ?? []).map { ref in
            (name: row(for: ref)?.name ?? ref.name, engine: ref.engine.displayName)
        }
        .sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.engine < b.engine : order == .orderedAscending
        }
        .map { "\($0.name) (\($0.engine))" }
        guard let last = names.last else { return "Remove?" }
        if names.count == 1 { return "Remove \(last)?" }
        if names.count <= 5 { return "Remove \(names.dropLast().joined(separator: ", ")) and \(last)?" }
        return "Remove \(names.prefix(5).joined(separator: ", ")) and \(names.count - 5) more?"
    }

    public func confirmUninstall() {
        guard let refs = pendingUninstall else { return }
        pendingUninstall = nil
        guard !busy else { return }
        startChange(.remove, on: refs)
    }

    public func cancelUninstall() {
        pendingUninstall = nil
    }

    private var busy: Bool { run.isRunning || preparing }

    /// True while the remove confirmation is up. The menu's Find, Refresh and package items are off then, and
    /// nothing else can start a run or replace the refs the confirmation names.
    public var confirmingRemoval: Bool { pendingUninstall != nil }

    private func startChange(_ operation: PackageOperation, on refs: Set<PackageRef>,
                             options: [PackageRef: InstallOptions] = [:]) {
        var rows = refs.compactMap(row(for:))
        // An install leaves out rows that are already installed (Discover marks them).
        if operation == .install { rows.removeAll(where: \.isInstalled) }
        rows.sort { ($0.engineName, $0.name) < ($1.engineName, $1.name) }
        guard !rows.isEmpty else { return }
        let requests = rows.map {
            ActionRequest(operation: operation, package: $0.package, options: options[$0.id] ?? InstallOptions())
        }
        let casks = operation == .install
            ? rows.map(\.id).filter { $0.engine == .nanobrew && $0.kind == .cask } : []
        guard !casks.isEmpty else {
            startRun(requests, caskRoutes: [:])
            return
        }
        preparing = true
        Task {
            let routes = await caskRoutes(for: casks)
            preparing = false
            guard !run.isRunning else { return }
            startRun(requests, caskRoutes: routes)
        }
    }

    /// Where each nanobrew cask install goes. Homebrew's own cask info when Homebrew is there (it's what would
    /// install it), otherwise nanobrew's. A lookup that fails counts as "needs root".
    private func caskRoutes(for casks: [PackageRef]) async -> [PackageRef: CaskRoute] {
        let homebrewPresent = homebrewPresent
        let catalog = services.catalog
        return await withTaskGroup(of: (PackageRef, CaskRoute).self) { group in
            for ref in casks {
                group.addTask {
                    let asked = homebrewPresent ? PackageRef(engine: .homebrew, kind: .cask, name: ref.name) : ref
                    let needsRoot = (try? await catalog.info(asked))?.installerNeedsRoot
                    return (ref, CaskRouting.route(needsRoot: needsRoot, homebrewPresent: homebrewPresent))
                }
            }
            var routes: [PackageRef: CaskRoute] = [:]
            for await (ref, route) in group { routes[ref] = route }
            return routes
        }
    }

    private func startRun(_ requests: [ActionRequest], caskRoutes: [PackageRef: CaskRoute]) {
        let plan = ActionPlanner.make(requests, engines: services.engines, order: engineOrder, caskRoutes: caskRoutes)
        if services.isDemo {
            run.start(plan) { .enabled }
        } else if services.helper == nil {
            run.start(plan, helperUnavailableReason: services.setupProblem) { nil }
        } else {
            run.start(plan) { [weak self] in await self?.helper(.ensure) }
        }
    }

    // MARK: Lists

    /// Reloads Updates and Installed now, or right after the current run when one is going (every run end
    /// reloads them, so a refresh asked for during the run is never lost and never doubled).
    public func refreshLists() {
        guard !run.isRunning else { return }
        reloadListsNow()
    }

    private func runEnded() {
        reloadListsNow()
        onRunEnded?()
    }

    /// Called after every run ends. The app reopens the window if it was closed during the run.
    @ObservationIgnored public var onRunEnded: (@MainActor () -> Void)?

    private func reloadListsNow() {
        listReloadCount += 1
        updates.reload()
        installed.reload()
    }

    /// Re-applies the ignore and skip preferences to Updates.
    private func recomputeUpdates() {
        updates.preferencesChanged()
    }

    /// Looks a ref up in Updates, then Installed, then Discover.
    public func package(for ref: PackageRef) -> Package? {
        row(for: ref)?.package
    }

    private func row(for ref: PackageRef) -> PackageRow? {
        for list in packageSources {
            if let row = list.byRef[ref] { return row }
        }
        return nil
    }

    /// Updates' rows including hidden ones.
    public var outdatedRefs: Set<PackageRef> { Set(updates.list.all.map(\.id)) }

    /// Puts the window in the state Task 7's Snapshotter photographs and waits until that view's list isn't loading.
    public func prepareSnapshot(_ item: SidebarItem) async {
        sidebar = item
        switch item {
        case .discover:
            discover.query = "ripgrep"
            discover.submit()
            await discover.list.settled()
        case .updates:
            // Two rows checked, the first selected and its details in the inspector.
            if updates.reloadCount == 0 { updates.reload() }
            await updates.list.settled()
            let rows = updates.list.rows
            updates.list.selection.checked = Set(rows.prefix(2).map(\.id))
            updates.list.selection.selected = rows.first.map { [$0.id] } ?? []
            if let first = rows.first {
                inspectorOpen = true
                details.show(first)
            }
        case .installed:
            // The first duplicate selected, with its details (which copy runs) in the inspector.
            if installed.reloadCount == 0 { installed.reload() }
            await installed.settled()
            let rows = installed.rows
            let duplicate = rows.first { $0.duplicateHelp != nil } ?? rows.first
            installed.list.selection.selected = duplicate.map { [$0.id] } ?? []
            if let duplicate {
                inspectorOpen = true
                details.show(duplicate.row)
            }
        default:
            break
        }
    }
}

/// The install option fields the inspector shows for one package.
public struct InspectorOptionFields: Equatable, Sendable {
    /// Only for an engine with `.versionPinning` (none today).
    public let version: Bool
    /// Every engine but mas.
    public let extraArgs: Bool
    /// MacPorts' variants, by name; empty for other engines.
    public let variants: [String]

    public init(version: Bool, extraArgs: Bool, variants: [String]) {
        self.version = version
        self.extraArgs = extraArgs
        self.variants = variants
    }
}
