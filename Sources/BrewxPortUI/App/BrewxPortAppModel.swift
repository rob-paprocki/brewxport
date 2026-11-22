import AppKit
import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// The window's state: the sidebar, the engines, the helper, the run, the inspector, and the one entry point for
/// every row action. Views bind to it and call its methods; they never build a step or decide what's allowed.
@MainActor @Observable public final class BrewxPortAppModel {
    /// Switching pages points an open inspector at the new page's selection, never at a row from the last page.
    /// Leaving the Helper page stops its approval poll.
    public var sidebar: SidebarItem = .updates {
        didSet {
            guard sidebar != oldValue else { return }
            selectionChanged(selectedOnScreen)
            if sidebar != .helper { stopHelperPagePoll() }
        }
    }
    public private(set) var engineStatuses: [EngineID: EngineStatus] = [:]
    public private(set) var checkingEngines = false
    /// True once engine detection has answered (`presentEngines()` returned) at least once.
    public private(set) var enginesChecked = false
    /// Nil until the first answer, and always nil when this copy has no helper (demo mode, or unsigned).
    public private(set) var helperState: HelperState?
    public private(set) var checkingHelper = false
    public let run: RunController
    public let details: DetailsModel
    public let preferences: UpdatePreferences
    public let discover: DiscoverModel
    public let updates: UpdatesModel
    public let installed: InstalledModel
    public let bundles: BundlesModel
    public let setup: SetupModel
    public let move: MoveModel
    public var inspectorOpen = false
    /// Bumped by Find (Cmd-F); DiscoverView maps it to `.searchFocused`.
    public var focusSearchRequest = 0
    @ObservationIgnored private var searchFocusPending = false
    /// nanobrew cask route lookups in flight before `run.start`.
    public private(set) var preparing = false
    /// Non-nil shows the uninstall confirmation.
    public var pendingUninstall: Set<PackageRef>? {
        didSet { openPendingFile() }
    }

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
    @ObservationIgnored private var setupDecided = false
    @ObservationIgnored private var runEndedObservers: [@MainActor () -> Void] = []
    @ObservationIgnored private var enginesCheckedObservers: [@MainActor ([EngineID: EngineStatus]) -> Void] = []
    @ObservationIgnored private var helperFlight: (kind: HelperCall, task: Task<HelperState?, Never>)?

    private enum HelperCall { case refresh, ensure, reinstall }

    /// `notifications`: where "the app became active" is posted; tests pass their own center.
    public init(services: Services, notifications: NotificationCenter = .default) {
        self.services = services
        self.notifications = notifications
        run = RunController(executor: services.executor, isAdministrator: services.isAdministrator)
        details = DetailsModel(catalog: services.catalog)
        preferences = UpdatePreferences(store: services.store)
        exportIncludesDependencies = services.store.data(forKey: Self.exportIncludesDependenciesKey) != Data("0".utf8)
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
        bundles = BundlesModel(catalog: services.catalog, installed: installed, order: order, archFor: archFor,
                               host: host, appVersion: BundleFile.appVersion(Bundle.main.infoDictionary))
        setup = SetupModel(services: services)
        move = MoveModel(services: services, installed: installed)
        // Updates and Installed come ahead of Discover: their rows carry installed versions. Bundles' rows are
        // built from a file and never looked up from here (see `listRow(for:)`).
        packageSources = [updatesList, installedList, discoverList]
        // Discover's installed marks come from the Installed list and nowhere else, so this observer is first.
        // Updates rows show the installed copy's arch, which only Installed's answer carries.
        let discover = discover
        installed.addLoadedObserver { refs in
            discover.markInstalled(refs)
            updatesList.borrowedArchs = Dictionary(
                installedList.all.compactMap { row in row.package.installedArchs.map { (row.id, $0) } },
                uniquingKeysWith: { first, _ in first })
        }
        services.passwords.prompter = run
        // Every run end reloads the lists, a run that ran nothing included (the helper check or the preflight
        // can leave nothing to do, and a refresh asked for during the run must still happen).
        run.onRunEnded = { [weak self] in self?.runEnded() }
        run.onPasswordSheetClosed = { [weak self] in self?.openPendingFile() }
        bundles.connect(self)
        move.connect(self)
        setup.stageChanged = { [weak self] in self?.setupStageChanged($0) }
        activeObserver = NotificationToken(center: notifications, name: NSApplication.didBecomeActiveNotification) {
            [weak self] in MainActor.assumeIsolated { self?.appBecameActive() }
        }
        setup.connect(statuses: { [weak self] in self?.engineStatuses ?? [:] },
                      runSetup: { [weak self] in self?.setUpEngine($0) ?? false },
                      planProblem: { [weak self] in self?.lastSetupPlanProblem })
    }

    /// Called after every run ends, after the lists' reload has started, in the order added. Bundles marks its
    /// preview stale; the app reopens the window if it was closed during the run.
    public func addRunEndedObserver(_ observer: @escaping @MainActor () -> Void) {
        runEndedObservers.append(observer)
    }

    /// Called with the statuses each time engine detection answers, after `engineStatuses` is set, in the order added.
    public func addEnginesCheckedObserver(_ observer: @escaping @MainActor ([EngineID: EngineStatus]) -> Void) {
        enginesCheckedObservers.append(observer)
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
        openPendingFile()
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
            enginesChecked = true
            for observer in enginesCheckedObservers { observer(statuses) }
            // The first answer decides whether the setup screen shows; later checks never reopen it.
            if !setupDecided {
                setupDecided = true
                await setup.start()
            } else {
                setup.enginesRechecked()
            }
        }
    }

    // MARK: Helper

    /// How the poll waits between reads. Tests shorten it.
    @ObservationIgnored var pollSleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    @ObservationIgnored private var approvalPoll: Task<Void, Never>?
    /// The Helper page's poll, after its Open Login Items. Separate from the setup's, so neither stops the other.
    @ObservationIgnored private var helperPagePoll: Task<Void, Never>?
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private var activeObserver: NotificationToken?

    /// While the setup sheet waits for the helper's approval in System Settings, nothing else would notice it
    /// happen, so read the state (read-only, never registering) every couple of seconds until the stage moves on.
    private func setupStageChanged(_ stage: SetupModel.Stage) {
        approvalPoll?.cancel()
        approvalPoll = nil
        guard stage == .needsHelperApproval, services.helper != nil else { return }
        approvalPoll = pollHelper { $0.setup.stage == .needsHelperApproval }
    }

    /// Reads the helper's state (read-only, never registering) every `helperApprovalPoll` while `condition` holds.
    private func pollHelper(while condition: @escaping @MainActor (BrewxPortAppModel) -> Bool) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollSleep(BrewxPortTimeouts.helperApprovalPoll)
                guard !Task.isCancelled, condition(self) else { return }
                // A helper call already in flight will deliver its own answer; skip this tick.
                guard !self.checkingHelper else { continue }
                _ = await self.helper(.refresh)
            }
        }
    }

    /// The helper still waits on the person: not registered, or not yet approved in Login Items.
    private var helperAwaitsApproval: Bool {
        helperState == .requiresApproval || helperState == .notRegistered
    }

    /// Coming back from System Settings: read the helper's state once, if the setup is waiting for it or the helper
    /// still needs approval (the sidebar's Helper row would otherwise keep saying so until the next run checks).
    private func appBecameActive() {
        guard services.helper != nil, setup.stage == .needsHelperApproval || helperAwaitsApproval,
              !checkingHelper else { return }
        Task { _ = await helper(.refresh) }
    }

    private func stopHelperPagePoll() {
        helperPagePoll?.cancel()
        helperPagePoll = nil
    }

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

    /// Ignored during a run. From the Helper page, while the helper waits on approval, it also reads the helper's
    /// state every couple of seconds (as the setup sheet does) until it's approved or the page is left. The setup
    /// sheet's own button relies on the setup's poll.
    public func openLoginItems() {
        guard !run.isRunning else { return }
        services.helper?.openLoginItems()
        guard sidebar == .helper, helperAwaitsApproval, services.helper != nil else { return }
        stopHelperPagePoll()
        helperPagePoll = pollHelper { $0.sidebar == .helper && $0.helperAwaitsApproval }
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
            // After the flight is cleared: a setup waiting on the helper starts its run right away, and that run
            // asks the helper again.
            Task { @MainActor in self.setup.helperStateChanged(state) }
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
    /// (`canRun`), while `run.isRunning` or `preparing` (no dialog, no lookup) or while anything modal is up
    /// (`modalUp`: the remove confirmation, so the refs it names never change under it, and the password sheet,
    /// open panel, export review and save panel, so nothing starts behind them). Ignore, Skip, Show details and
    /// Copy name don't start a run and always work.
    ///
    /// On Bundles, Install builds its requests from the preview (`BundlesModel.install`), and Update and Uninstall do
    /// nothing. Move to starts the move check for one row (`MoveModel.start`) under the same conditions as Install.
    public func perform(_ action: RowAction, on refs: Set<PackageRef>) {
        switch action {
        case .install where currentView == .bundles:
            guard canRun, !busy, !modalUp else { return }
            bundles.install(refs.filter { bundles.rowsByRef[$0] != nil })
        case .update where currentView == .bundles, .uninstall where currentView == .bundles:
            return
        case .install, .update:
            guard canRun, !busy, !modalUp else { return }
            startChange(action == .install ? .install : .upgrade, on: refs)
        case .uninstall:
            guard canRun, !busy, !modalUp else { return }
            let known = refs.filter { row(for: $0) != nil }
            guard !known.isEmpty else { return }
            pendingUninstall = known
        case .moveTo(let target):
            guard canRun, !busy, !modalUp, refs.count == 1, let ref = refs.first, let row = row(for: ref) else { return }
            move.start(row.package, to: target)
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
        canRun && !busy && !modalUp && !discover.checkedRefs.isEmpty
    }

    public func installChecked() {
        guard canRun, !busy, !modalUp else { return }
        startChange(.install, on: discover.checkedRefs)
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
        guard canRun, !busy, !modalUp else { return }
        let list = discover.list
        startChange(.install, on: list.onScreen(list.selection.selected))
    }

    // MARK: Keyboard and menu

    /// The package table on screen, or nil on the engine pages. The Package menu and the tables' keys
    /// (Return, Space, Delete) act on it, so each key does the same thing from the table and from the menu.
    public var currentView: PackageView? {
        switch sidebar {
        case .discover: .discover
        case .updates: .updates
        case .installed: .installed
        case .bundles: .bundles
        case .engine, .helper: nil
        }
    }

    private func list(for view: PackageView) -> PackageListState {
        switch view {
        case .discover: discover.list
        case .updates: updates.list
        case .installed: installed.list
        case .bundles: bundles.list
        }
    }

    /// The selected rows on screen in the current table. On Bundles, the rows of the current preview: none while
    /// it's checking, when the table is hidden.
    private var selectedOnScreen: Set<PackageRef> {
        guard let view = currentView else { return [] }
        let list = list(for: view)
        if view == .bundles { return list.selection.selected.filter { bundles.rowsByRef[$0] != nil } }
        return list.onScreen(list.selection.selected)
    }

    /// The right-click menu for `refs` in a table: `RowActions` over that page's rows. On Bundles, Install shows
    /// for the rows the preview can install, and a menu opened while it's checking is empty. "Move to" items are off
    /// while anything modal is up (the move sheet included), as `perform` ignores them then.
    public func rowMenuItems(for refs: Set<PackageRef>, in view: PackageView) -> [RowActionItem] {
        let rows = view == .bundles ? bundles.rowsByRef : list(for: view).byRef
        let items = RowActions.items(for: refs, in: view, rows: rows, outdated: outdatedRefs, prefs: preferences,
                                     isRunning: busy, canRun: canRun,
                                     installable: view == .bundles ? bundles.installableRefs : [],
                                     moveTargets: moveTargets, isDemo: services.isDemo)
        return modalUp ? items.map { $0.isMove ? $0.disabled() : $0 } : items
    }

    /// The Package menu's "Move to" submenu: the right-click menu's Move items for the selection on Installed.
    public var moveMenuItems: [RowActionItem] {
        guard currentView == .installed else { return [] }
        return rowMenuItems(for: selectedOnScreen, in: .installed).filter(\.isMove)
    }

    /// The Package menu's "Move to" items: the move for the one selected Installed row.
    public func moveSelection(_ action: RowAction) {
        guard currentView == .installed, case .moveTo = action else { return }
        perform(action, on: selectedOnScreen)
    }

    /// The package managers a package can move to: present, and able to list what depends on a package.
    private var moveTargets: [EngineID] {
        [EngineID.homebrew, .nanobrew, .macports].filter { id in
            guard case .present? = engineStatuses[id] else { return false }
            return services.engines.contains { $0.id == id && $0 is any DependentsListing }
        }
    }

    /// The Package menu's first item: Install on Discover and Bundles, Update on Updates and Installed.
    public var primaryActionTitle: String {
        currentView == .discover || currentView == .bundles ? "Install Selected" : "Update Selected"
    }

    /// What Return (and ⌘↩) would act on: the selected rows on screen that the action applies to. Discover's
    /// not-installed rows; Updates' rows that aren't ignored or skipped; Installed's rows that have an update;
    /// Bundles' rows that can be installed.
    private var primaryRefs: Set<PackageRef> {
        let selected = selectedOnScreen
        switch currentView {
        case .discover?:
            return selected.filter { discover.list.byRef[$0]?.isInstalled == false }
        case .updates?:
            return Set(updates.requests(for: selected).map(\.package.id))
        case .installed?:
            return selected.intersection(outdatedRefs)
        case .bundles?:
            return selected.intersection(bundles.installableRefs)
        case nil:
            return []
        }
    }

    public var canPerformPrimary: Bool { canRun && !busy && !modalUp && !primaryRefs.isEmpty }

    /// Return and ⌘↩: installs (Discover) or updates (Updates, Installed) the selected rows.
    public func performPrimary() {
        guard !modalUp else { return }
        switch currentView {
        case .discover?: installSelected()
        case .updates?: updateSelected()
        case .installed?:
            let refs = primaryRefs
            guard !refs.isEmpty else { return }
            perform(.update, on: refs)
        case .bundles?:
            let refs = primaryRefs
            guard canRun, !busy, !refs.isEmpty else { return }
            bundles.install(refs)
        case nil: break
        }
    }

    /// Delete and ⌘⌫ remove after the confirmation, on Updates and Installed (every row there is installed).
    public var canRemoveSelection: Bool {
        (currentView == .updates || currentView == .installed) && canRun && !busy && !modalUp
            && !selectedOnScreen.isEmpty
    }

    public func removeSelection() {
        guard let view = currentView, view == .updates || view == .installed, !modalUp else { return }
        perform(.uninstall, on: selectedOnScreen)
    }

    public var canToggleChecks: Bool { !modalUp && !selectedOnScreen.isEmpty }

    /// Space: checks the selected rows, or unchecks them when they're all checked.
    public func toggleChecks() {
        guard let view = currentView, !modalUp else { return }
        if view == .bundles, bundles.preview == nil { return }
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

    /// Bundles' preview went to checking, or came back: the inspector shows nothing while it's checking and the
    /// fresh row after.
    func bundlesStateChanged() {
        guard currentView == .bundles else { return }
        selectionChanged(selectedOnScreen)
    }

    /// The inspector's Install button. On Bundles only for a row the preview can install (not one already
    /// installed or whose engine is missing); elsewhere for a row that isn't installed.
    public var canInstallFromInspector: Bool {
        guard canRun, !busy, !modalUp, let row = details.row else { return false }
        if currentView == .bundles { return bundles.installableRefs.contains(row.id) }
        return !row.isInstalled
    }

    /// Which option fields the inspector shows for its package. Nil when there's nothing to install.
    /// Nil on Bundles too: an install there takes only the options the file's checked entry carries.
    public var inspectorOptions: InspectorOptionFields? {
        guard currentView != .bundles, let row = details.row, !row.isInstalled,
              let engine = services.engines.first(where: { $0.id == row.id.engine }) else { return nil }
        return InspectorOptionFields(version: engine.capabilities.contains(.versionPinning),
                                     extraArgs: row.id.engine != .mas,
                                     variants: row.id.engine == .macports
                                        ? (details.details?.variants ?? []).sorted() : [])
    }

    /// The inspector's own Install: the shown package with the inspector's options. An option the engine won't take
    /// shows as `details.optionsError` and starts nothing.
    public func installFromInspector() {
        if currentView == .bundles {
            guard canRun, !busy, !modalUp, let row = details.row else { return }
            bundles.install([row.id])
            return
        }
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

    /// A run is going, or nanobrew cask routes are being looked up before one.
    var busy: Bool { run.isRunning || preparing }

    /// Something modal is up: the password sheet, the remove confirmation, the open panel, the export review sheet,
    /// the save panel or the move sheet. The menu's Open Bundle, exports and package items are off meanwhile, and a
    /// file the Finder opens waits until it's gone (`openFromFinder`). The move sheet's own Move button doesn't check
    /// this (`MoveModel.confirm`), and the sheet is gone once the move runs.
    public var modalUp: Bool {
        run.showingPasswordSheet || confirmingRemoval || showingOpenPanel || exportReview != nil
            || exportToSave != nil || move.sheetShown
    }

    /// True while the remove confirmation is up. The menu's Find, Refresh and package items are off then, and
    /// nothing else can start a run or replace the refs the confirmation names.
    public var confirmingRemoval: Bool { pendingUninstall != nil }

    /// Discover, Updates, Installed and the inspector: requests from the rows the lists know.
    private func startChange(_ operation: PackageOperation, on refs: Set<PackageRef>,
                             options: [PackageRef: InstallOptions] = [:]) {
        var rows = refs.compactMap(listRow(for:))
        // An install leaves out rows that are already installed (Discover marks them).
        if operation == .install { rows.removeAll(where: \.isInstalled) }
        rows.sort { ($0.engineName, $0.name) < ($1.engineName, $1.name) }
        guard !rows.isEmpty else { return }
        installRequests(rows.map {
            ActionRequest(operation: operation, package: $0.package, options: options[$0.id] ?? InstallOptions())
        })
    }

    /// The one way a run starts from a page: nanobrew cask installs get their routes looked up first (`preparing`),
    /// then the plan runs. Does nothing when this copy can't run anything, while a run or a lookup is going, or while
    /// the remove confirmation is up (a confirmed uninstall clears it before calling this).
    public func installRequests(_ requests: [ActionRequest]) {
        guard canRun, !busy, !modalUp, !requests.isEmpty else { return }
        let casks = requests.filter { $0.operation == .install }.map(\.package.id)
            .filter { $0.engine == .nanobrew && $0.kind == .cask }
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
        requestedUpgrades = requests.filter { $0.operation == .upgrade }
            .map { (ref: $0.package.id, name: $0.package.displayName) }
        start(plan)
    }

    // MARK: Engine setup

    /// False in demo mode (nothing is set up there), while a run or a lookup is going, or while a dialog is up.
    public var canSetUpEngines: Bool { canRun && !services.isDemo && !busy && !modalUp }

    /// Plans "set up this engine" and runs it through the same run controller as every other change. Once the run
    /// ends, however it ends, the engines are detected again, so a new one shows up without "Check again".
    /// False when nothing started (not allowed now, or the run had nothing it could do).
    @discardableResult
    public func setUpEngine(_ engine: EngineID) -> Bool {
        lastSetupPlanProblem = nil
        guard canSetUpEngines else { return false }
        let plan = EngineSetupPlanner.plan(
            engine, statuses: engineStatuses, host: services.hostInfo, cltPresent: services.cltPresent(),
            engines: services.engines)
        if plan.steps.isEmpty { lastSetupPlanProblem = plan.problems.first }
        requestedUpgrades = []
        // Only a run that started will end, so the flag is never left set for an unrelated later run.
        guard start(plan) else { return false }
        recheckEnginesAfterRun = true
        return true
    }

    @ObservationIgnored private var recheckEnginesAfterRun = false
    /// The first problem of the last setup plan that had nothing to run; the setup screen words it.
    @ObservationIgnored private(set) var lastSetupPlanProblem: String?

    /// True when a run started. `verify` answers the plan's check steps (only a move has any).
    @discardableResult
    private func start(_ plan: ActionPlan, verify: @escaping InstalledVerifier = RunSession.failClosed) -> Bool {
        if services.isDemo {
            return run.start(plan, verify: verify) { .enabled }
        } else if services.helper == nil {
            return run.start(plan, helperUnavailableReason: services.setupProblem, verify: verify) { nil }
        } else {
            return run.start(plan, verify: verify) { [weak self] in await self?.helper(.ensure) }
        }
    }

    // MARK: Move to

    /// `MoveModel.confirm`'s way into the one run path, with `missingOnTarget` answering the check step. The run's end
    /// reloads Installed (and Discover's installed marks) like every other run. `checked` gets what each check found
    /// missing. False when nothing started.
    func startMove(_ plan: ActionPlan, checked: @escaping @Sendable ([PackageRef]) -> Void = { _ in }) -> Bool {
        guard canRun, !busy else { return false }
        requestedUpgrades = []
        let engines = services.engines
        return start(plan) { refs in
            let missing = await Self.missing(refs, engines: engines)
            checked(missing)
            return missing
        }
    }

    /// The move's check step: the refs a fresh `listInstalled()` on their engine doesn't list with the same kind and
    /// name (names compared ignoring case, so a same-named cask never stands in for a formula). Fails closed: every ref counts as missing when any engine's listing throws, takes longer than
    /// the engine timeout, or the engine isn't there.
    public func missingOnTarget(_ refs: [PackageRef]) async -> [PackageRef] {
        await Self.missing(refs, engines: services.engines)
    }

    nonisolated static func missing(_ refs: [PackageRef], engines: [any Engine],
                                    timeout: Duration = BrewxPortTimeouts.engineQuery) async -> [PackageRef] {
        struct Key: Hashable { let engine: EngineID; let kind: PackageKind; let name: String }
        var present: Set<Key> = []
        for id in Set(refs.map(\.engine)) {
            guard let engine = engines.first(where: { $0.id == id }),
                  let listed = try? await firstResult(within: timeout, { try await engine.listInstalled() }) else {
                return refs
            }
            for package in listed { present.insert(Key(engine: id, kind: package.id.kind, name: package.id.name.lowercased())) }
        }
        return refs.filter { !present.contains(Key(engine: $0.engine, kind: $0.kind, name: $0.name.lowercased())) }
    }

    // MARK: Lists

    /// Reloads Updates and Installed now, or right after the current run when one is going (every run end
    /// reloads them, so a refresh asked for during the run is never lost and never doubled).
    public func refreshLists() {
        guard !run.isRunning else { return }
        reloadListsNow()
    }

    private func runEnded() {
        setup.runEnded()
        reloadListsNow()
        if recheckEnginesAfterRun {
            recheckEnginesAfterRun = false
            checkEnginesAgain()
        }
        checkUpdatesTookEffect()
        for observer in runEndedObservers { observer() }
    }

    /// The packages the last run was asked to update, by ref with the name to show. Set by `startRun`.
    @ObservationIgnored private var requestedUpgrades: [(ref: PackageRef, name: String)] = []

    /// After an update run, once Updates has reloaded: any package the run was asked to update that the engine still
    /// lists as outdated is named in the run panel. That covers every way an update can quietly not happen (a step
    /// the preflight skipped, a failed one, Homebrew printing "Not upgrading …" and exiting 0).
    private func checkUpdatesTookEffect() {
        let asked = requestedUpgrades
        requestedUpgrades = []
        guard !asked.isEmpty else { return }
        let runNumber = run.runNumber
        Task { [weak self] in
            guard let self else { return }
            await self.updates.list.settled()
            let still = Set(self.updates.list.all.map(\.id))
            let names = asked.filter { still.contains($0.ref) }.map(\.name)
            guard !names.isEmpty else { return }
            self.run.addProblem("Still out of date after the update: \(names.joined(separator: ", ")).", run: runNumber)
        }
    }

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
        listRow(for: ref)?.package
    }

    /// The row a menu, key or the inspector acts on: on Bundles the file's row, elsewhere `listRow(for:)`.
    private func row(for ref: PackageRef) -> PackageRow? {
        currentView == .bundles ? bundles.rowsByRef[ref] : listRow(for: ref)
    }

    /// Updates, then Installed, then Discover. Never Bundles: a file's rows don't reach Discover's install path.
    private func listRow(for ref: PackageRef) -> PackageRow? {
        for list in packageSources {
            if let row = list.byRef[ref] { return row }
        }
        return nil
    }

    // MARK: Bundles (File menu)

    /// File › Open Bundle… and the open panel's buttons: off while something modal is up, and while a run is
    /// preparing or going, since its password sheet can come up at any moment and mustn't stack on a panel.
    /// Off too while an export is being gathered: its review sheet or save panel comes up when it's done and mustn't
    /// meet an open panel.
    public var canOpenFile: Bool { !modalUp && !busy && !exporting }

    /// File > Open Bundle…: shows Bundles and its open panel. Nothing when `canOpenFile` is false.
    public func showOpenPanel() {
        guard canOpenFile else { return }
        sidebar = .bundles
        exportMessage = nil
        exportSaved = nil
        showingOpenPanel = true
    }

    /// The open panel (`fileImporter`) is up.
    public var showingOpenPanel = false { didSet { openPendingFile() } }
    /// A file the Finder opened while something modal was up, or before the window started: opened once neither
    /// holds. The latest one wins.
    public private(set) var pendingOpenURL: URL?
    /// An export is being gathered (the engines' installed lists). The File menu's exports are off meanwhile.
    public private(set) var exporting = false
    /// Shown before the save panel when the export leaves something out: the sheet lists it, and Save goes on.
    public var exportReview: PendingExport? { didSet { openPendingFile() } }
    /// The save panel (`fileExporter`) is up for this export.
    public var exportToSave: PendingExport? { didSet { openPendingFile() } }
    /// Why the last export stopped or its save failed.
    public var exportMessage: String?
    /// After a save: "Saved 42 entries to “Brewfile”." Cleared by the next export, open or close.
    public private(set) var exportSaved: String?

    /// File > Export Bundle… and Export Brewfile…: gathers the file, then shows what it leaves out (failed engines,
    /// refused names and, for a Brewfile, everything `brew bundle` can't read) for confirmation before the save
    /// panel. When nothing is left out, the save panel comes straight away.
    public func export(_ kind: ExportKind) async {
        guard canExport else { return }
        exporting = true
        exportMessage = nil
        exportSaved = nil
        closedExport = nil
        defer { exporting = false }
        let pending: PendingExport
        switch kind {
        case .bundle:
            let made = await exportBundle()
            pending = PendingExport(kind: .bundle, data: made.data, defaultName: PendingExport.bundleName,
                                    leftOut: [], summary: made.summary)
        case .brewfile:
            let made = await exportBrewfile()
            pending = PendingExport(kind: .brewfile, data: Data(made.text.utf8), defaultName: "Brewfile",
                                    leftOut: made.leftOut, summary: made.summary)
        }
        // A run that started while the lists were read can ask for its password at any moment: no sheet or panel
        // on top of it.
        guard !busy, !modalUp else {
            exportMessage = busy
                ? "BrewxPort stopped the export because a run started. Export again when the run ends."
                : "BrewxPort stopped the export because another dialog opened. Export again once it's closed."
            return
        }
        if pending.needsReview {
            exportReview = pending
        } else {
            exportToSave = pending
        }
    }

    /// The File menu's exports: off while one is being gathered, while anything modal is up (its own review sheet
    /// and save panel included), and while a run is preparing or going (its password sheet mustn't stack on them).
    public var canExport: Bool { !exporting && !modalUp && !busy }

    /// The review sheet's Save…: on to the save panel.
    public func confirmExport() {
        guard let pending = exportReview else { return }
        exportReview = nil
        exportToSave = pending
    }

    public func cancelExport() {
        exportReview = nil
        exportToSave = nil
    }

    /// The export the save panel was last up for, kept after the panel closes: SwiftUI clears `isPresented` (the view
    /// calls `exportFinished(nil)`) before it calls the completion with `.success`, and the message needs its counts.
    /// Cleared when a new export starts and once a result arrives.
    @ObservationIgnored private var closedExport: PendingExport?

    /// The save panel closed: saved, cancelled (nil) or failed. A nil may be followed by the save's own result.
    public func exportFinished(_ result: Result<URL, any Error>?) {
        let saved = exportToSave ?? closedExport
        exportToSave = nil
        closedExport = result == nil ? saved : nil
        switch result {
        case .failure(let error):
            exportMessage = "BrewxPort couldn't save the file: \(error.localizedDescription)"
        case .success(let url):
            let count = saved?.savedCount ?? 0
            let name = BundleRules.shownFileName(url.lastPathComponent)
            exportSaved = "Saved \(count == 1 ? "1 entry" : "\(count) entries") to “\(name)”."
                + (saved.flatMap { Self.dependenciesNote($0.summary) }.map { " " + $0 } ?? "")
        case nil:
            break
        }
    }

    /// The open panel's pick. The user's own choice wins over a file the Finder sent earlier that's still held.
    public func openPicked(_ url: URL) {
        pendingOpenURL = nil
        openBundle(url)
    }

    /// File > Open: shows Bundles and opens the file there.
    public func openBundle(_ url: URL) {
        sidebar = .bundles
        exportMessage = nil
        exportSaved = nil
        bundles.open(url)
    }

    /// The header's Close: closes the file and clears an export's error or saved message.
    public func closeBundle() {
        exportMessage = nil
        exportSaved = nil
        bundles.close()
    }

    /// A file from the Finder (double-click, the Dock icon). Opened now when the window has started and nothing
    /// modal is up; otherwise held in `pendingOpenURL` and opened when that clears, so nothing is swapped behind a
    /// confirmation or the password sheet.
    public func openFromFinder(_ url: URL) {
        pendingOpenURL = url
        openPendingFile()
    }

    /// Opens `pendingOpenURL` once the window has started and nothing modal is up.
    func openPendingFile() {
        guard started, !modalUp, let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        openBundle(url)
    }

    /// File > Export Bundle: shows Bundles and exports everything installed (dependencies per
    /// `exportIncludesDependencies`).
    public func exportBundle() async -> (data: Data, summary: ExportSummary) {
        sidebar = .bundles
        return await bundles.exportBundle(includeDependencies: exportIncludesDependencies)
    }

    /// File > Export Brewfile: shows Bundles and exports what `brew bundle` can read.
    public func exportBrewfile() async -> (text: String, leftOut: [LeftOut], summary: ExportSummary) {
        sidebar = .bundles
        return await bundles.exportBrewfile(includeDependencies: exportIncludesDependencies)
    }

    static let exportIncludesDependenciesKey = "exportIncludesDependencies"

    /// File > Include Dependencies in Exports. On (the default) exports list every installed package; off, they leave
    /// out what came in as another package's dependency, so installing the file elsewhere pulls those in again.
    /// Remembered across launches. Read when an export starts gathering, so changing it mid-export doesn't change
    /// that file.
    public var exportIncludesDependencies: Bool = true {
        didSet {
            services.store.set(Data((exportIncludesDependencies ? "1" : "0").utf8),
                               forKey: Self.exportIncludesDependenciesKey)
        }
    }

    /// The saved-file message's second sentence for an export without dependencies; nil when there's nothing to say.
    static func dependenciesNote(_ summary: ExportSummary) -> String? {
        var parts: [String] = []
        switch summary.dependenciesLeftOut {
        case 0: break
        case 1: parts.append("It leaves out 1 dependency.")
        case let n: parts.append("It leaves out \(n) dependencies.")
        }
        let unknown = EngineID.allCases.filter { summary.dependenciesUnknown.contains($0) }.map(\.displayName)
        if !unknown.isEmpty {
            let names = unknown.count == 1 ? unknown[0]
                : unknown.dropLast().joined(separator: ", ") + " and " + unknown[unknown.count - 1]
            // Covers nanobrew (never says), an old Homebrew receipt and a failed MacPorts query alike: only the
            // packages BrewxPort couldn't tell about were kept, not necessarily all of the engine's.
            parts.append("BrewxPort couldn't tell which \(names) packages are dependencies, so it kept them.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
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
        case .bundles:
            // The sample (`snapshotSample`), its preview built: engines checked, Installed and the taps read. The
            // inspector is closed so the table has the room. A file that didn't open has nothing to wait for.
            start()
            inspectorOpen = false
            if bundles.state == .empty { await openDemoSample(snapshotSample) }
            for _ in 0..<200 {
                if bundles.preview != nil || bundles.openError != nil || bundles.state == .empty { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        default:
            break
        }
    }

    /// For the setup snapshot only: the window as on a first launch, with no engine installed.
    public func previewFirstLaunch() {
        guard services.isDemo else { return }
        engineStatuses = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing, .mas: .missing]
        setup.previewOffer()
    }

    // MARK: Demo samples

    /// The sample `prepareSnapshot(.bundles)` opens: `--demo-bundle` when given, else the inventory.
    public var snapshotSample = "inventory"

    /// `--demo-bundle NAME`: shows Bundles and opens that `DemoSamples` file. Demo mode only; a name it doesn't
    /// know does nothing.
    public func openDemoSample(_ name: String) async {
        guard services.isDemo else { return }
        let fixtures = services.engines.lazy.compactMap { ($0 as? DemoEngine)?.runner.fixtures }.first
        guard let sample = await DemoSamples.data(name, catalog: services.catalog, fixtures: fixtures,
                                                  host: services.host) else { return }
        sidebar = .bundles
        bundles.open(data: sample.data, name: sample.fileName)
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

/// Which file File › Export… writes.
public enum ExportKind: Sendable { case bundle, brewfile }

/// An export gathered and waiting for its review sheet or save panel.
public struct PendingExport: Equatable, Sendable {
    /// The save panel's starting name, without the extension: generic, never the Mac's or the user's name.
    public static let bundleName = "BrewxPort bundle"

    public var kind: ExportKind
    /// The file's bytes: the encoded bundle, or the Brewfile's UTF-8 text.
    public var data: Data
    public var defaultName: String
    /// Brewfile only: what `brew bundle` can't read, by name with the reason.
    public var leftOut: [LeftOut]
    public var summary: ExportSummary

    public init(kind: ExportKind, data: Data, defaultName: String, leftOut: [LeftOut], summary: ExportSummary) {
        self.kind = kind
        self.data = data
        self.defaultName = defaultName
        self.leftOut = leftOut
        self.summary = summary
    }

    /// The review sheet's "Couldn't list what's installed": "Homebrew: <error>", one per engine, by engine id.
    public var failedEngineLines: [String] {
        summary.failedEngines.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.displayName): \($0.value)" }
    }

    /// How many entries the saved file holds: every entry of the bundle, less what a Brewfile leaves out.
    /// Assumes every left-out item is a whole entry: exports carry no pins or options that could be dropped alone.
    public var savedCount: Int {
        summary.counts.values.reduce(0, +) - leftOut.count
    }

    /// Something isn't in the file: an engine that failed to list, a refused name, or a left-out entry.
    public var needsReview: Bool {
        !leftOut.isEmpty || !summary.failedEngines.isEmpty || !summary.refused.isEmpty
    }
}

/// A notification observer that removes itself when it goes away with its owner.
private final class NotificationToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in handler() }
    }

    deinit { center.removeObserver(token) }
}
