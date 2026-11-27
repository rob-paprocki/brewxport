import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// Background update checks and automatic updates. A check is the Updates page's own refresh, run without the
/// window: on the schedule (`scheduleFromSettings()`), or now (`checkNow()`). After it:
///
/// - Notify me: one notification when the check found a version it hasn't told the person about (`NotifyLedger`).
/// - Update what doesn't need a password: those rows run at once as a background run; the rest are notified.
/// - Update everything: the same background run first; then, once the person is at the Mac, the window opens on
///   Updates and the rest runs as their run, with the usual password sheet. The sheet only comes up once BrewxPort
///   is the active app with its window key (`presentForPassword`); when macOS won't make it active, one "N updates
///   need your password" notification asks for a click, which starts the run. A standard account gets the
///   password-free mode, since nothing it can run needs the password.
///
/// Ignored and skipped rows are never notified or run. Nor is, automatically, an update that would also update one
/// (`HiddenRelations`: Homebrew and MacPorts bring outdated dependencies and dependents along); those get a "need your
/// attention" notification instead. Nor is a Homebrew runtime update that would break language tools
/// (`UpdatesModel.runtimeHolds`): with automatic updates on, each new version of one gets a notice of its own ("Ruby
/// 4.1 is ready") instead of counting as available. Nor, automatically, an update that `brew upgrade` would bring
/// such a runtime along with (`UpdatesModel.runtimesBroughtAlong`); those are in the "need your attention" notice. A check never runs during a run, and an automatic run never
/// starts during one: the check waits for the run to end and reads the lists its end reloaded. After an automatic
/// run, one notification says what was updated and what wasn't.
///
/// On low battery or in Low Power Mode, scheduled checks and every automatic update (the password sheet included)
/// wait until power is back; Check Now still checks and notifies. Automatic updates also wait while the person is
/// exporting or has a sheet up. After the person cancels an automatic run, checks only notify until the next scheduled
/// check; with checks off (Never) nothing runs by itself. The mode is read again before every automatic run.
@MainActor @Observable public final class BackgroundUpdater {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        /// An automatic run is going.
        case updating(runNumber: Int)
        /// "Update everything" has `count` updates that need the password, waiting for the person to be at the Mac.
        case waitingForUser(count: Int)
    }

    /// "At the Mac": keyboard or mouse input within the last 10 minutes, and the screen unlocked.
    static let activeWithin: TimeInterval = 600
    /// Every "N updates available" uses this id, so the latest replaces the last one.
    static let availableID = "updates-available"
    static let passwordID = "updates-need-password"
    /// "N updates need your attention": updates an automatic run left out because they'd also update an ignored or
    /// skipped package.
    static let attentionID = "updates-need-attention"

    /// A Homebrew runtime update held back from automatic updates because language tools run on it (design option A)
    /// is told in a notice of its own, under this prefix and the formula's name.
    static let runtimeIDPrefix = "runtime-held-"

    static func attentionBody(count: Int) -> String {
        attentionBody(count: count, ignoredOrSkipped: true, runtimes: [])
    }

    /// Why they were left out: they'd also update a package the person ignored or skipped, and/or a runtime language
    /// tools run on (`runtimes`: "Ruby", "Node", "Python"; `UpdatesModel.runtimesBroughtAlong`).
    /// `maybeRuntimes` are the runtimes they may bring along: Homebrew couldn't say what's related, so it's possible,
    /// not known ("may also update Node", as the manual warning says).
    static func attentionBody(count: Int, ignoredOrSkipped: Bool, runtimes: [String],
                              maybeRuntimes: [String] = []) -> String {
        let start = count == 1 ? "Updating it" : "Updating them"
        let maybe = maybeRuntimes.filter { !runtimes.contains($0) }
        var known: [String] = []
        if ignoredOrSkipped { known.append("a package you ignored or skipped") }
        known += runtimes
        guard !known.isEmpty || !maybe.isEmpty else { return start + " would also update a package you ignored or skipped." }
        var text = start
        if !known.isEmpty {
            // "a package you ignored or skipped, or Ruby": the runtimes after the ignored package with "or".
            text += " would also update " + (ignoredOrSkipped && !runtimes.isEmpty
                ? known[0] + ", or " + RuntimeHolds.list(runtimes) : RuntimeHolds.list(known))
        }
        if !maybe.isEmpty {
            text += (known.isEmpty ? "" : ", and") + " may also update " + RuntimeHolds.list(maybe)
        }
        let tools = !runtimes.isEmpty || !maybe.isEmpty ? ", which your language tools run on" : ""
        return text + tools + "."
    }

    /// Where `lastChecked` is kept, as seconds since 1970 in UTF-8 text.
    static let lastCheckedKey = "lastUpdateCheck"

    public let settings: BackgroundSettings
    /// When the last check finished reading the lists, kept across launches. Nil until one has.
    public private(set) var lastChecked: Date? {
        didSet {
            services.store.set(lastChecked.map { Data(String($0.timeIntervalSince1970).utf8) },
                               forKey: Self.lastCheckedKey)
        }
    }
    /// When the next scheduled check is due (the system may run it a little later). Nil when none is scheduled.
    public private(set) var nextCheck: Date?

    /// An automatic run that's going comes first, then a check, then the wait for the person.
    public var state: State {
        if let autoRun, let run = model?.run, run.isRunning, run.runNumber == autoRun.runNumber {
            return .updating(runNumber: autoRun.runNumber)
        }
        if checking { return .checking }
        if let waiting { return .waitingForUser(count: waiting.count) }
        return .idle
    }

    private var checking = false
    /// The automatic run that's going (or just ended, until its end is handled).
    private var autoRun: AutoRun?
    /// The password-needing updates "Update everything" waits to run, by ref.
    private var waiting: Set<PackageRef>?

    /// Weak: the model owns the updater, and the updater's tasks (a check, a run's end, a poll) can outlive it, as
    /// when the app quits or a test ends. Every task reads it again after each wait and does nothing once it's gone;
    /// none holds it across a wait. When the model goes, `stop()` ends what's left.
    @ObservationIgnored private weak var model: BrewxPortAppModel?
    @ObservationIgnored private let services: Services
    @ObservationIgnored private let ledger: NotifyLedger
    /// The clock. Tests pin it.
    @ObservationIgnored var now: @MainActor () -> Date
    /// How often the wait for the person asks whether they're back (there's no system event for input). Tests
    /// shorten it.
    @ObservationIgnored var userPollInterval: Duration = .seconds(60)
    @ObservationIgnored private var userPoll: Task<Void, Never>?
    /// `presentForPassword` is putting the window up for the password run.
    @ObservationIgnored private var presenting: Task<Void, Never>?
    /// "N updates need your password" went out for the current check's wait (ruling R14: once per wait a check
    /// starts, whatever the notify-once ledger says). A check clears it.
    @ObservationIgnored private var passwordNoticePosted = false
    /// While the automatic password run is going: polls whether the person is still at the Mac, so a prompt they
    /// left unanswered ends (`endPromptForNow`).
    @ObservationIgnored private var promptWatch: Task<Void, Never>?
    /// The automatic password run is being ended as "not now" (`endPromptForNow`): its end isn't a cancel.
    @ObservationIgnored private var endingForNow = false
    /// BrewxPort couldn't be made the active app for the password run, so it waits for a click on the "need your
    /// password" notification.
    @ObservationIgnored private var awaitingClick = false
    /// Awaited once an automatic run's end has reloaded the lists, before anything is posted. Tests hold it to put
    /// events in a chosen order.
    @ObservationIgnored var autoRunEndPause: @MainActor () async -> Void = {}
    /// A scheduled check came on low battery or in Low Power Mode; it runs once power is back.
    @ObservationIgnored private var deferredCheck = false
    /// A check that was due at launch waits for the one-time sheet to close (`introClosed()`).
    @ObservationIgnored private var overdueWaitsForIntro = false
    /// A check's automatic updates waited for power (low battery or Low Power Mode); a check runs them once it's back.
    @ObservationIgnored private var heldForPower = false
    /// A check's automatic updates waited for the person to finish something (`personBusy`); a check runs them once
    /// they have (`watchPerson`).
    @ObservationIgnored private var heldForPerson = false
    /// Counts the waits for the person to finish, so only the latest one's watch acts.
    @ObservationIgnored private var personWatch = 0
    /// The person cancelled an automatic run (its password sheet, or the run). Until the next scheduled check, checks
    /// only notify: nothing runs by itself and no sheet comes back.
    @ObservationIgnored private var heldAfterCancel = false
    @ObservationIgnored private var runEndWaiters: [CheckedContinuation<Void, Never>] = []

    /// Counts checks; an automatic run remembers the count it started under.
    @ObservationIgnored private var checksStarted = 0
    /// This launch's own, for the summaries' ids (`summaryID`).
    @ObservationIgnored private let launchID = UUID().uuidString
    /// What an automatic run leaves out because it would also update an ignored or skipped package, as the last
    /// check read it. The password part is filtered with it again when it runs.
    @ObservationIgnored private var relations = HiddenRelations.none
    /// The updates the last check's automatic run left out that way. They get their own notice ("need your
    /// attention"), so "available" doesn't count them too.
    @ObservationIgnored private var heldByRelations: Set<PackageRef> = []
    /// The runtime updates the last check's automatic updates left out because language tools run on them. They get
    /// their own notice too.
    @ObservationIgnored private var heldForTools: Set<PackageRef> = []

    private struct AutoRun {
        let runNumber: Int
        /// What it was asked to update, in list order, with the version each was to be updated to.
        let requested: [(ref: PackageRef, name: String, target: String?)]
        /// "Update everything": the password-needing refs to run after this one.
        let passwordPart: Set<PackageRef>?
        /// `checksStarted` when it started. A check that started since decides the password part itself.
        let check: Int
        /// Update everything's password run (the person's run, started without them clicking): its prompt can end
        /// "for now" (`endPromptForNow`).
        let asksPassword: Bool
    }

    /// Created by the model at the end of its init. Takes the notification clicks and the system's condition changes
    /// (both seams have one handler, and this is it), and follows every run's end.
    public init(model: BrewxPortAppModel, settings: BackgroundSettings, services: Services,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.model = model
        self.settings = settings
        self.services = services
        self.now = now
        ledger = NotifyLedger(store: services.store)
        lastChecked = services.store.data(forKey: Self.lastCheckedKey)
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        services.notifier.onOpen = { [weak self] target, id in self?.open(target, id: id) }
        services.conditions.onChange = { [weak self] in self?.conditionsChanged() }
        model.addRunEndedObserver { [weak self] in self?.runEnded() }
        model.run.onPromptWaitingForFocus = { [weak self] in self?.promptWaitingForFocus() }
    }

    // MARK: Schedule

    /// Replaces the schedule with the settings' interval (the hidden test interval when it's set), counted from the
    /// last check, which is kept across launches: checked 2 hours ago on a 12-hour interval, the next check is due in
    /// 10 hours. A check that's due already (never checked, or the last one an interval or more ago, as after a
    /// relaunch) runs soon, as a scheduled one, and the schedule counts from now. Nothing is scheduled when checks are
    /// off (Never) or in demo mode, where Check Now still works. Checks off also drops whatever was still to happen by
    /// itself: a check or automatic updates waiting for power or for the person to finish something, and the password
    /// part waiting for them.
    ///
    /// `afterLaunchLoad`: the app is launching and has just started loading the lists (`BrewxPortAppModel.start()`),
    /// so a check that's due reads that load rather than loading them again.
    public func scheduleFromSettings(afterLaunchLoad: Bool = false) {
        services.scheduler.cancel()
        nextCheck = nil
        overdueWaitsForIntro = false
        guard let seconds = settings.effectiveInterval else {
            deferredCheck = false
            heldForPower = false
            heldForPerson = false
            stopWaiting()
            return
        }
        guard !services.isDemo else {
            deferredCheck = false
            return
        }
        let now = now()
        let left = lastChecked.map { min(seconds, $0.addingTimeInterval(seconds).timeIntervalSince(now)) } ?? 0
        let firstAfter = left > 0 ? left : seconds
        services.scheduler.schedule(every: seconds, firstAfter: firstAfter) { [weak self] in
            await self?.scheduledCheck()
        }
        nextCheck = now.addingTimeInterval(firstAfter)
        if left <= 0 { checkOverdue(reload: !afterLaunchLoad) }
    }

    /// The check that fell due while BrewxPort wasn't running (or while checks were off). It waits for the one-time
    /// sheet when that hasn't been closed yet: the sheet is where notifications are turned on and macOS asked, so a
    /// notice posted before would be lost and its versions still count as told.
    private func checkOverdue(reload: Bool) {
        guard settings.introShown else {
            overdueWaitsForIntro = true
            return
        }
        Task { [weak self] in await self?.check(.scheduled, reload: reload) }
    }

    /// The one-time sheet closed (the model calls it): a check that was due when it came up runs now, unless one has
    /// run since.
    public func introClosed() {
        guard overdueWaitsForIntro else { return }
        overdueWaitsForIntro = false
        guard !services.isDemo, let seconds = settings.effectiveInterval,
              lastChecked.map({ $0.addingTimeInterval(seconds) <= now() }) ?? true else { return }
        Task { [weak self] in await self?.check(.scheduled) }
    }

    /// `nextCheck` is then about an interval on; the system decides the exact moment.
    private func scheduledCheck() async {
        await check(.scheduled)
        if !services.isDemo, let seconds = settings.effectiveInterval {
            nextCheck = now().addingTimeInterval(seconds)
        }
    }

    // MARK: Open at login

    /// The Open at login switch: registers or unregisters BrewxPort's login item, then sets `settings.openAtLogin`
    /// from what the system then says (`readLoginItem()`), whether or not that worked. The system's error is thrown
    /// on, for Settings to show.
    public func setOpenAtLogin(_ on: Bool) throws {
        defer { readLoginItem() }
        try services.loginItem.setEnabled(on)
    }

    /// `settings.openAtLogin` follows the system's login item: on while it's registered (enabled, or waiting for the
    /// person's approval in System Settings, which Settings asks for), off otherwise, as after it's been removed in
    /// System Settings > General > Login Items. Called at launch and when Settings appears; it only reads, never
    /// registering anything.
    public func readLoginItem() {
        let item = services.loginItem
        let registered = item.isEnabled || item.needsApproval
        if settings.openAtLogin != registered { settings.openAtLogin = registered }
    }

    // MARK: Notifications switch

    /// Turns notifications on and asks macOS for permission (it asks the person only the first time; after that it
    /// answers with their choice in System Settings > Notifications). Refused: they're turned off again. True when
    /// allowed. Only Settings and the one-time sheet call it, never a check: nobody is asked by surprise.
    @discardableResult
    public func turnOnNotifications() async -> Bool {
        settings.notificationsOn = true
        let allowed = await services.notifier.requestPermission()
        if !allowed { settings.notificationsOn = false }
        return allowed
    }

    // MARK: Check

    /// Checks now, whatever the battery says (the person asked). Returns once the check is done, after the run
    /// that's going when there is one; at once when another check is already going (it covers this one). Its
    /// automatic updates still wait for power, and after a cancel it only notifies.
    ///
    /// In demo mode the fixtures' inventory is put back first (not during a run, which is still changing it), so
    /// the check finds the fixture updates again after a demo run updated them.
    public func checkNow() async {
        if !checking, model?.run.isRunning == false, let inventory = demoInventory { await inventory.reset() }
        await check(.now)
    }

    /// The demo's shared inventory (every demo engine has the same one); nil outside demo mode.
    private var demoInventory: DemoInventory? {
        guard services.isDemo else { return nil }
        return services.engines.lazy.compactMap { ($0 as? DemoEngine)?.inventory }.first
    }

    private enum CheckKind {
        /// The schedule's (or one it deferred). Waits for power; ends the hold after a cancel.
        case scheduled
        /// The person's Check Now. Never waits.
        case now
        /// Power is back for automatic updates that waited for it. Waits for power.
        case resume
    }

    private var onLowPower: Bool { services.conditions.batteryLow || services.conditions.lowPowerMode }

    /// `reload`: false when the lists are loading already for it (at launch), so the check reads that load.
    private func check(_ kind: CheckKind, reload: Bool = true) async {
        guard model != nil else { return }
        if kind != .now, onLowPower {
            if kind == .scheduled { deferredCheck = true } else { heldForPower = true }
            return
        }
        // A check that comes due ends an automatic password prompt nobody answered (one still to come included),
        // rather than wait behind it (and keep a check going meanwhile from passing the guard below). The person
        // asking (Check Now) doesn't.
        if kind != .now { endPromptForNow() }
        guard !checking else { return }
        checking = true
        checksStarted += 1
        defer { checking = false }
        if kind == .scheduled {
            deferredCheck = false
            heldAfterCancel = false
        }
        // This check decides the password part again, and a wait it starts may post its own "need your password".
        stopWaiting()
        passwordNoticePosted = false
        // Never during a run: its end reloads the lists, and the check reads that reload. The model is read again
        // after every wait, and the check stops once it's gone.
        var reloadStarted = !reload
        while true {
            guard let runBefore = model?.run.isRunning else { return }
            if runBefore {
                await nextRunEnd()
                reloadStarted = true
                continue
            }
            if !reloadStarted { model?.refreshLists() }
            guard let updates = model?.updates else { return }
            await updates.reloaded()
            reloadStarted = false
            // A run the person started while the lists loaded: wait for it, then read its reload.
            guard let runAfter = model?.run.isRunning, let reloads = model?.listReloadCount else { return }
            if runAfter { continue }
            relations = await gatherRelations()
            // The same when a run started while the relations were read, or the lists were reloaded meanwhile.
            guard let model else { return }
            if model.run.isRunning || model.listReloadCount != reloads {
                reloadStarted = true
                continue
            }
            break
        }
        guard let model else { return }
        lastChecked = now()
        let list = model.updates.list
        ledger.prune(outdated: list.all, unanswered: list.failedEngines, unchecked: list.unchecked)
        act()
    }

    private func nextRunEnd() async {
        await withCheckedContinuation { runEndWaiters.append($0) }
    }

    private func resumeRunEndWaiters() {
        let waiters = runEndWaiters
        runEndWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: The model going away

    /// The model has gone away (its `UpdaterStopper` calls this): nothing of the updater's runs on without it. The
    /// schedule stops, the polls and waits end, and a check waiting for a run's end goes on, finds the model gone and
    /// returns, so no task keeps the updater (or a check) waiting forever.
    func stop() {
        services.scheduler.cancel()
        nextCheck = nil
        deferredCheck = false
        overdueWaitsForIntro = false
        heldForPower = false
        heldForPerson = false
        personWatch += 1
        stopWaiting()
        promptWatch?.cancel()
        promptWatch = nil
        resumeRunEndWaiters()
    }

    /// What the check's result leads to, by mode. Only rows an automatic update may take (`automaticRequests()`: Update
    /// all's, less those held from automatic updates, which wait for the person like any update that waits), less
    /// the ones that would also update an ignored or skipped package (`relations`) or a held runtime
    /// (`UpdatesModel.runtimesBroughtAlong`), which get their own notice.
    /// Automatic updates wait while power is low, or while the person is in the middle of something the run would stop
    /// or that no run starts under (`personBusy`); they don't happen at all with checks off (Never), or after a cancel
    /// until the next scheduled check. When they wait or don't happen, everything is notified instead.
    private func act() {
        guard let model else { return }
        let mode = effectiveMode
        let automatic = mode != .notify && settings.checksOn && !heldAfterCancel
        heldForPower = automatic && onLowPower
        heldForPerson = false
        heldByRelations = []
        heldForTools = []
        if automatic {
            // Held whether or not power lets anything run now: what would break tools is told as itself.
            let runtimes = model.updates.runtimeHolds
            let rows = model.updates.updateAllRequests().map(\.package.id).filter { runtimes[$0] != nil }
            heldForTools = Set(rows)
            postRuntimeHeld(rows)
        }
        if automatic, !heldForPower {
            let hidden = hiddenRefs
            var clear: [ActionRequest] = []
            var held: [ActionRequest] = []
            var ignoredOrSkipped = false
            var runtimes: [String] = []
            var maybeRuntimes: [String] = []
            for request in model.updates.automaticRequests() {
                let ref = request.package.id
                // `brew upgrade` would bring an ignored or skipped package along, or a runtime language tools run on
                // (or may: Homebrew couldn't say what's related).
                let related = relations.holds(ref, hidden: hidden)
                let broughtAlong = model.updates.broughtAlong(by: ref)
                guard related || !broughtAlong.isEmpty else {
                    clear.append(request)
                    continue
                }
                held.append(request)
                ignoredOrSkipped = ignoredOrSkipped || related
                for (runtime, certain) in broughtAlong {
                    guard let name = model.updates.runtimeHolds[runtime]?.runtime else { continue }
                    if certain, !runtimes.contains(name) { runtimes.append(name) }
                    if !certain, !maybeRuntimes.contains(name) { maybeRuntimes.append(name) }
                }
            }
            heldByRelations = Set(held.map(\.package.id))
            let (free, needing) = split(clear)
            let passwordPart = mode == .everything && !needing.isEmpty ? Set(needing.map(\.package.id)) : nil
            if !free.isEmpty, personBusy {
                // The run would stop an export being read, or can't start under a sheet: it waits for the person to
                // finish, and the password part after it. (A password part alone waits for them anyway.)
                heldForPerson = true
                watchPerson()
            } else if !startAutoRun(free, origin: .background, passwordPart: passwordPart), let passwordPart {
                waitForUser(passwordPart)
            }
            postNeedsAttention(held, ignoredOrSkipped: ignoredOrSkipped, runtimes: runtimes.sorted(),
                               maybeRuntimes: maybeRuntimes.sorted())
        }
        postAvailable()
    }

    /// The person is in the middle of something an automatic run would stop (an export being read: it gives up when
    /// a run starts) or that no run starts under (a sheet or panel, `modalUp`).
    private var personBusy: Bool { model.map { $0.exporting || $0.modalUp } ?? false }

    /// Follows `personBusy` while automatic updates wait for it, and runs a check for them once it's over. A newer
    /// wait, or checks turned off, ends this one.
    private func watchPerson() {
        personWatch += 1
        watchPerson(personWatch)
    }

    private func watchPerson(_ token: Int) {
        guard heldForPerson, token == personWatch, model != nil else { return }
        let busy = withObservationTracking { personBusy } onChange: { [weak self] in
            // Called before the change lands: read it again once it has.
            Task { @MainActor in self?.watchPerson(token) }
        }
        guard !busy else { return }
        heldForPerson = false
        Task { [weak self] in await self?.check(.resume) }
    }

    /// The ignored and skipped rows on Updates.
    private var hiddenRefs: Set<PackageRef> {
        guard let updates = model?.updates else { return [] }
        return Set(updates.list.all.filter { updates.hiddenReason($0) != nil }.map(\.id))
    }

    /// What this check's automatic run would have to leave out (`HiddenRelations`). Read only when it could start one
    /// (Notify me, a cancel's hold and low power never do) and a package manager has both an ignored or skipped row
    /// and an update to run; otherwise nothing is asked, and if an automatic run comes after all (the mode changed
    /// meanwhile), every update from a package manager with a hidden row is left out.
    private func gatherRelations() async -> HiddenRelations {
        guard effectiveMode != .notify, settings.checksOn, !heldAfterCancel, !onLowPower,
              let updates = model?.updates, let installedModel = model?.installed else { return .none }
        let list = updates.list
        let hidden = list.all.filter { updates.hiddenReason($0) != nil }
        let engines = Set(updates.updateAllRequests().map(\.package.id.engine))
            .intersection(hidden.map(\.id.engine))
        guard !engines.isEmpty else { return .none }
        let outdated = list.all.map(\.id)
        await installedModel.settled()
        let installed = installedModel.list
        return await HiddenRelations.gather(for: engines, hidden: hidden.map(\.package), outdated: outdated,
                                           installed: installed.all.map(\.package),
                                           installedFailed: installed.failedEngines,
                                           engines: services.engines, catalog: services.catalog)
    }

    /// A standard account can't run anything that needs the password, so "Update everything" is the password-free
    /// mode there. An account the check couldn't read (nil) keeps the setting.
    private var effectiveMode: AutoUpdateMode {
        settings.mode == .everything && services.isAdministrator() == false ? .passwordFree : settings.mode
    }

    /// True when every step this update plans runs as a plain user step (Homebrew formulae and nanobrew today):
    /// no password sheet. Casks, MacPorts and the Mac App Store need it.
    public func isPasswordFree(_ request: ActionRequest) -> Bool {
        guard let model else { return false }
        let steps = ActionPlanner.make([request], engines: services.engines, order: model.engineOrder).steps
        return !steps.isEmpty && steps.allSatisfy { RunRouting.route(for: $0) == .user }
    }

    private func split(_ requests: [ActionRequest]) -> (free: [ActionRequest], needing: [ActionRequest]) {
        var free: [ActionRequest] = []
        var needing: [ActionRequest] = []
        for request in requests {
            if isPasswordFree(request) { free.append(request) } else { needing.append(request) }
        }
        return (free, needing)
    }

    /// True when the run started. Never during a run, while something modal is up, or when this copy can't run.
    private func startAutoRun(_ requests: [ActionRequest], origin: RunOrigin, passwordPart: Set<PackageRef>?) -> Bool {
        guard !requests.isEmpty, let model, model.installRequests(requests, origin: origin), model.run.isRunning else {
            return false
        }
        autoRun = AutoRun(runNumber: model.run.runNumber,
                          requested: requests.map { ($0.package.id, $0.package.displayName, $0.package.latestVersion) },
                          passwordPart: passwordPart, check: checksStarted, asksPassword: origin == .user)
        return true
    }

    // MARK: Run ends

    /// Every run's end, right after the model started reloading the lists. Never starts a run from here: the app's
    /// own observers (the window coming back after the person's run) come after this one and read the last run's
    /// origin.
    private func runEnded() {
        resumeRunEndWaiters()
        promptWatch?.cancel()
        promptWatch = nil
        let forNow = endingForNow
        endingForNow = false
        guard let model else { return }
        guard let ended = autoRun, ended.runNumber == model.run.runNumber else {
            // The person's own run replaces a password run that was waiting for them. What it didn't update waits
            // like any update that waits, and is told once its end has reloaded the lists (a check going meanwhile
            // decides that itself).
            guard waiting != nil else { return }
            stopWaiting()
            let updates = model.updates
            Task { [weak self] in
                await updates.reloaded()
                guard let self, self.model != nil, !self.checking, self.waiting == nil, self.autoRun == nil else {
                    return
                }
                self.postAvailable()
            }
            return
        }
        autoRun = nil
        // A prompt ended "for now" isn't the person cancelling: nothing is held, and the wait goes on.
        let cancelled = model.run.cancelled && !forNow
        // Set now, before a check waiting for this end acts on it.
        if cancelled { heldAfterCancel = true }
        // Read now: a run the person starts while the lists reload replaces these steps.
        let results = Self.stepResults(model.run.steps)
        Task { [weak self] in
            await self?.autoRunEnded(ended, cancelled: cancelled, forNow: forNow, results: results)
        }
    }

    /// What a run's step says about one package it named (`RunStep.refs`).
    enum StepResult: Equatable, Sendable {
        /// The step finished with exit code 0.
        case succeeded
        /// The step ran and didn't finish with 0 (or was stopped), and it named other packages too: some of them may
        /// have been updated (Homebrew carries on past a formula that fails). The reload decides (R27).
        case failedWithOthers
        /// The step didn't finish with 0 and named only this package, or never ran.
        case failed
    }

    /// Each package the run's steps named, with what its step says.
    static func stepResults(_ steps: [RunStepRow]) -> [PackageRef: StepResult] {
        var results: [PackageRef: StepResult] = [:]
        for step in steps {
            let result: StepResult
            switch step.state {
            case .succeeded: result = .succeeded
            case .failed, .stopped: result = step.refs.count > 1 ? .failedWithOthers : .failed
            case .waiting, .running, .skipped: result = .failed
            }
            for ref in step.refs { results[ref] = result }
        }
        return results
    }

    private func autoRunEnded(_ ended: AutoRun, cancelled: Bool, forNow: Bool,
                              results: [PackageRef: StepResult]) async {
        guard let updates = model?.updates else { return }
        await updates.reloaded()
        await autoRunEndPause()
        // Gone meanwhile (the app quitting, a test ending): nothing is left to tell or to wait for.
        guard model != nil else { return }
        if forNow {
            // The prompt nobody answered ended quietly: back to waiting for the person, unless a check started since
            // (it decides the password part itself). Nothing ran, so nothing is posted.
            if ended.check == checksStarted { waitForUser(Set(ended.requested.map(\.ref))) }
            return
        }
        if cancelled {
            // The person cancelled (the password sheet, or the run). What it didn't get to, and a password part that
            // was to follow, wait for the next scheduled check like any update that waits.
            postAvailable()
            return
        }
        postSummary(ended, results: results)
        // A check that started since this run did (one that waited for its end) decides the password part itself,
        // whether it has finished by now or not. The wait re-reads the mode and the power first.
        if let passwordPart = ended.passwordPart, ended.check == checksStarted { waitForUser(passwordPart) }
    }

    /// What the run was asked to update, sorted by the run's own results (R6, R27), then by the reloaded Updates list.
    /// Still offered after the run is failed, whatever the step said (the update didn't take; `stillOffered`).
    /// Otherwise:
    /// - a package whose step finished with 0 is updated;
    /// - one whose step failed alone, or never ran or was never planned, failed;
    /// - one whose failed step named other packages too (`failedWithOthers`) is updated when its engine answered the
    ///   reload and checked everything; when it didn't answer, or couldn't check something, BrewxPort can't tell, so
    ///   it's "not confirmed".
    /// A row vanishing from the list never counts as updated by itself.
    private func postSummary(_ ended: AutoRun, results: [PackageRef: StepResult]) {
        guard let model else { return }
        let updates = model.updates
        let list = updates.list
        let answered = list.answeredEngines.subtracting(list.failedEngines)
        var updated: [String] = [], failed: [String] = [], notConfirmed: [String] = []
        for (ref, name, target) in ended.requested {
            if let row = list.all.first(where: { $0.id == ref }),
               Self.stillOffered(row.package, held: updates.hold(for: row) != nil, target: target) {
                failed.append(name)
                continue
            }
            switch results[ref] ?? .failed {
            case .succeeded:
                updated.append(name)
            case .failed:
                failed.append(name)
            case .failedWithOthers:
                let checkedAll = answered.contains(ref.engine) && list.unchecked[ref.engine]?.isEmpty != false
                if checkedAll { updated.append(name) } else { notConfirmed.append(name) }
            }
        }
        guard settings.notificationsOn else { return }
        services.notifier.post(id: summaryID(run: ended.runNumber),
                               title: Self.summaryTitle(updated: updated.count, failed: failed,
                                                        notConfirmed: notConfirmed),
                               body: updated.joined(separator: ", "), target: .runLog)
    }

    /// A package the reload still lists shows its update didn't take, unless it's held and offers a version newer than
    /// the one the run targeted: then the run updated it, and the newer version waits for its own reason (a crate
    /// updated to 15 whose 16 needs a newer Rust). A held row offering the targeted version or older still counts.
    /// Versions are compared by the engine's own rules; for an engine without them (or a version they can't read),
    /// only a different version counts as newer.
    static func stillOffered(_ row: Package, held: Bool, target: String?) -> Bool {
        guard held, let offered = row.latestVersion, let target, offered != target else { return true }
        guard let scheme = EcosystemVersion.scheme(for: row.id.engine),
              EcosystemVersion.isValid(offered, scheme: scheme), EcosystemVersion.isValid(target, scheme: scheme)
        else { return false }
        return EcosystemVersion.compare(offered, target, scheme: scheme) != .orderedDescending
    }

    /// Run numbers start again at every launch, so a summary's id names the launch too: one still unread from an
    /// earlier launch is never replaced, and a click knows which run it's about.
    private func summaryID(run: Int) -> String { "updated-\(launchID)-\(run)" }

    /// "Updated 3", "Updated 2. 1 failed: jq", "Updates failed: jq, wget", each followed by ". 1 not confirmed: a"
    /// when a failed step's package may or may not have been updated.
    static func summaryTitle(updated: Int, failed: [String], notConfirmed: [String]) -> String {
        var parts: [String] = []
        if updated > 0 { parts.append("Updated \(updated)") }
        if !failed.isEmpty {
            let names = failed.joined(separator: ", ")
            parts.append(updated > 0 ? "\(failed.count) failed: \(names)" : "Updates failed: \(names)")
        }
        if !notConfirmed.isEmpty {
            parts.append("\(notConfirmed.count) not confirmed: \(notConfirmed.joined(separator: ", "))")
        }
        return parts.isEmpty ? "Updated 0" : parts.joined(separator: ". ")
    }

    // MARK: Waiting for the person

    /// Runs the password part now if the person is at the Mac, else waits: every `userPollInterval`, and whenever
    /// the system says something changed (unlock, wake). The next check, or a run the person starts meanwhile, ends
    /// the wait.
    private func waitForUser(_ refs: Set<PackageRef>) {
        stopWaiting()
        waiting = refs
        if tryPasswordRun() { return }
        startPoll()
    }

    private func startPoll() {
        userPoll?.cancel()
        userPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.userPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if self.tryPasswordRun() { return }
            }
        }
    }

    private func stopWaiting() {
        waiting = nil
        awaitingClick = false
        presenting?.cancel()
        presenting = nil
        userPoll?.cancel()
        userPoll = nil
    }

    /// The waited-for updates as they are now: still on Updates, not ignored, skipped or held from automatic updates
    /// since, still needing the password, and not updating an ignored or skipped package (one ignored or skipped since
    /// included).
    private func waitingRequests(_ refs: Set<PackageRef>) -> [ActionRequest] {
        guard let updates = model?.updates else { return [] }
        let hidden = hiddenRefs
        return updates.automaticRequests().filter {
            refs.contains($0.package.id) && !isPasswordFree($0) && !relations.holds($0.package.id, hidden: hidden)
        }
    }

    private var atTheMac: Bool {
        services.conditions.userIsActive(within: Self.activeWithin) && !services.conditions.screenLocked
    }

    /// True when the poll can stop: the window is being put up for the password run, or the wait won't lead to a
    /// run before the next check (the mode was changed from Update everything, or nothing is left to run). Waits on
    /// while power is low, and, once BrewxPort couldn't be made the active app, until the person clicks the
    /// notification (`awaitingClick`; the poll then only notices a mode or list change).
    @discardableResult
    private func tryPasswordRun() -> Bool {
        guard let refs = waiting, let model else { return true }
        guard effectiveMode == .everything, settings.checksOn, !heldAfterCancel else {
            // No sheet: the updates wait for the next check like any that wait.
            stopWaiting()
            postAvailable()
            return true
        }
        guard !waitingRequests(refs).isEmpty else {
            stopWaiting()
            return true
        }
        if presenting != nil { return true }
        if awaitingClick { return false }
        guard atTheMac, !onLowPower, model.canRun, !model.busy, !personBusy else { return false }
        // Nobody clicked anything of BrewxPort's, so the sheet may only come up once BrewxPort is the active app
        // with its window key: shown over another app without the keyboard, it could take a password typed there.
        // The page changes to Updates only once it's up (`startPasswordRun`).
        userPoll?.cancel()
        userPoll = nil
        let present = model.presentForPassword
        presenting = Task { [weak self] in
            let presented = await present?() ?? false
            guard !Task.isCancelled, let self, self.model != nil else { return }
            self.presenting = nil
            self.windowPresented(presented, for: refs)
        }
        return true
    }

    /// After `presentForPassword`. Up and key: the password run starts. Not: the person gets one notification to
    /// click (a click makes BrewxPort active), and the wait goes on.
    private func windowPresented(_ presented: Bool, for refs: Set<PackageRef>) {
        guard waiting == refs else { return }
        guard presented else {
            awaitingClick = true
            postPasswordNeeded(waitingRequests(refs).map(\.package.id))
            startPoll()
            return
        }
        // Something came up meanwhile (a sheet, a run): try again later.
        if !startPasswordRun(refs) { startPoll() }
    }

    /// The waited-for password run, the window being up for its sheet. False when it can't start now (a run is
    /// going, a sheet is up), so the wait goes on; true when the wait is over, whether it started or not.
    private func startPasswordRun(_ refs: Set<PackageRef>) -> Bool {
        guard let model else { return true }
        let requests = waitingRequests(refs)
        guard effectiveMode == .everything, settings.checksOn, !heldAfterCancel, !requests.isEmpty else {
            tryPasswordRun()
            return true
        }
        guard model.canRun, !model.busy, !personBusy else { return false }
        model.sidebar = .updates
        stopWaiting()
        // Its sheet comes later (after the helper check), by when the person may be in another app: it shows only
        // once BrewxPort is active with its window key (`RunController.promptNeedsFocus`). Taken by this start; cleared
        // in case nothing reached it.
        model.run.nextRunPromptNeedsFocus = true
        defer { model.run.nextRunPromptNeedsFocus = false }
        // Nothing stood in its way, so trying again wouldn't help (no step for it, say): the panel says why, and
        // the updates wait for the next check like any that wait.
        if startAutoRun(requests, origin: .user, passwordPart: nil) {
            watchPrompt()
        } else {
            postAvailable()
        }
        return true
    }

    /// The automatic password run asked for the password while BrewxPort wasn't active with its window key: the
    /// sheet waits, and the person gets the "need your password" notification (unless this check's wait posted it
    /// already) to click.
    private func promptWaitingForFocus() {
        guard let model, let autoRun, autoRun.runNumber == model.run.runNumber else { return }
        postPasswordNeeded(autoRun.requested.map(\.ref))
    }

    /// While the automatic password run goes, asks every `userPollInterval` whether the person is still at the Mac
    /// (there's no system event for input stopping); the lock is a system change (`conditionsChanged`).
    private func watchPrompt() {
        promptWatch?.cancel()
        promptWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.userPollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.model != nil else { return }
                if !self.atTheMac { self.endPromptForNow() }
            }
        }
    }

    /// Rulings R15 and R21. The automatic password run's prompt, while it's unanswered (still to come in the run's
    /// helper check, its sheet waiting for the focus, or the sheet up), ends as a quiet "not now" when the person has
    /// left (idle for 10 minutes, or the screen locked) or a check comes due: the run stops before its first step,
    /// nothing is held as after a cancel, and the password part goes back to waiting for them (`autoRunEnded`). So
    /// nothing stays locked behind a prompt nobody is there to answer, and a check that comes due just before the
    /// sheet shows doesn't wait behind it (holding every later scheduled check back too). A run the person started is
    /// never ended this way. True when it did.
    @discardableResult
    private func endPromptForNow() -> Bool {
        guard let model, let autoRun, autoRun.asksPassword, model.run.isRunning,
              model.run.runNumber == autoRun.runNumber, !model.run.hasPassword else { return false }
        endingForNow = true
        model.run.cancel()
        return true
    }

    // MARK: System changes and clicks

    /// Power back: a deferred scheduled check runs, or else a check for the automatic updates that waited. Any
    /// change can also end the wait for the person (unlocked, woke), and the screen locking ends an automatic password
    /// prompt nobody answered (`endPromptForNow`).
    private func conditionsChanged() {
        guard model != nil else { return }
        if !atTheMac { endPromptForNow() }
        if !onLowPower {
            if deferredCheck {
                deferredCheck = false
                Task { [weak self] in await self?.check(.scheduled) }
            } else if heldForPower {
                heldForPower = false
                Task { [weak self] in await self?.check(.resume) }
            }
        }
        if waiting != nil { tryPasswordRun() }
    }

    /// A click on one of BrewxPort's notifications. It's the person's own action, so the window comes forward
    /// (`openMainWindow`); and a password run waiting for them (Update everything) starts, with its sheet. An
    /// automatic run's summary shows the run panel only while that run is still the last one (the panel shows the
    /// last run); otherwise, as after a relaunch, it opens Updates.
    private func open(_ target: NotificationTarget, id: String) {
        guard let model else { return }
        model.sidebar = .updates
        if target == .runLog, !model.run.isRunning, id == summaryID(run: model.run.runNumber) {
            model.run.showPanel()
        }
        model.openMainWindow?()
        guard target == .updates, let refs = waiting else { return }
        presenting?.cancel()
        presenting = nil
        guard !startPasswordRun(refs) else { return }
        // A run is going or a sheet is up: the wait goes on, putting the window up again (safely) once it can.
        awaitingClick = false
        startPoll()
    }

    // MARK: Notifications

    /// The updates being handled without the person: the automatic run that's going, the password part to follow
    /// it, and the password part waiting for them.
    private var handledRefs: Set<PackageRef> {
        var refs = waiting ?? []
        if let autoRun {
            refs.formUnion(autoRun.requested.map(\.ref))
            refs.formUnion(autoRun.passwordPart ?? [])
        }
        return refs
    }

    /// One "N updates available" for every update that waits for the person: on Updates, neither ignored nor
    /// skipped, not being handled automatically (`handledRefs`) and not left out of the last automatic run for an
    /// ignored or skipped package (`heldByRelations`, told by `postNeedsAttention`). Posted when one of them is a
    /// version not told before; N always counts them all (with a per-manager breakdown), so the notice that replaces
    /// the last one never drops a row. Recorded as told even with notifications off, so turning them on doesn't
    /// replay old news; the badge shows them either way.
    private func postAvailable() {
        guard let updates = model?.updates else { return }
        let left = handledRefs.union(heldByRelations).union(heldForTools)
        let rows = updates.updateAllRequests().compactMap { request -> PackageRow? in
            left.contains(request.package.id) ? nil : updates.list.byRef[request.package.id]
        }
        guard !ledger.newOnes(in: rows).isEmpty else { return }
        ledger.record(rows)
        guard settings.notificationsOn else { return }
        services.notifier.post(id: Self.availableID,
                               title: rows.count == 1 ? "1 update available" : "\(rows.count) updates available",
                               body: breakdown(rows), target: .updates)
    }

    /// "N updates need your attention": the updates an automatic run left out because they'd also update an ignored
    /// or skipped package, or a Homebrew runtime held back for language tools (`attentionBody` says which). Like
    /// `postAvailable`, posted when one of them is a version not told before, counting them all, and recorded even
    /// with notifications off. Clicking it opens Updates.
    private func postNeedsAttention(_ requests: [ActionRequest], ignoredOrSkipped: Bool, runtimes: [String],
                                    maybeRuntimes: [String]) {
        guard let updates = model?.updates else { return }
        let rows = requests.compactMap { updates.list.byRef[$0.package.id] }
        guard !ledger.newOnes(in: rows).isEmpty else { return }
        ledger.record(rows)
        guard settings.notificationsOn else { return }
        services.notifier.post(id: Self.attentionID,
                               title: rows.count == 1
                                   ? "1 update needs your attention" : "\(rows.count) updates need your attention",
                               body: Self.attentionBody(count: rows.count, ignoredOrSkipped: ignoredOrSkipped,
                                                        runtimes: runtimes, maybeRuntimes: maybeRuntimes),
                               target: .updates)
    }

    /// One notice per Homebrew runtime update held back because language tools run on it, in the design's words: title
    /// "Ruby 4.1 is ready", body "Updating it needs your gems reinstalled." Like `postAvailable`, once per version
    /// (`NotifyLedger`, in its own namespace: a version already told as available is still told this way once),
    /// recorded even with notifications off; each runtime has its own id, so a newer version of it
    /// replaces the last. Clicking it opens Updates.
    private func postRuntimeHeld(_ refs: [PackageRef]) {
        guard let updates = model?.updates else { return }
        for ref in refs {
            guard let row = updates.list.byRef[ref], let held = updates.runtimeHolds[ref],
                  !ledger.newOnes(in: [row], namespace: .runtime).isEmpty else { continue }
            ledger.record([row], namespace: .runtime)
            guard settings.notificationsOn else { continue }
            services.notifier.post(id: Self.runtimeIDPrefix + ref.name, title: held.noticeTitle,
                                   body: held.hold.reason, target: .updates)
        }
    }

    /// "N updates need your password": the password run is waiting for a click, because BrewxPort couldn't be made
    /// the active app to show its sheet (before the run, or when the run asked). Posted once per wait a check starts
    /// (ruling R14), even for versions "available" told already: without it the run would wait for a click nobody
    /// was asked for. Under one id, so each replaces the last. It stays out of the notify-once ledger: if the person
    /// then cancels, those updates wait for the next scheduled check and are told as available (once), as any that
    /// wait. Clicking it opens Updates and starts the run (`open`), or shows the waiting sheet once the window is key.
    private func postPasswordNeeded(_ refs: [PackageRef]) {
        guard let updates = model?.updates else { return }
        let rows = refs.compactMap { updates.list.byRef[$0] }
        guard !rows.isEmpty, !passwordNoticePosted else { return }
        passwordNoticePosted = true
        guard settings.notificationsOn else { return }
        services.notifier.post(id: Self.passwordID,
                               title: rows.count == 1
                                   ? "1 update needs your password" : "\(rows.count) updates need your password",
                               body: breakdown(rows), target: .updates)
    }

    /// "Homebrew 2, MacPorts 1", in the engine order.
    private func breakdown(_ rows: [PackageRow]) -> String {
        guard let model else { return "" }
        let counts = Dictionary(grouping: rows, by: \.id.engine).mapValues(\.count)
        return model.engineOrder.compactMap { engine in counts[engine].map { "\(engine.displayName) \($0)" } }
            .joined(separator: ", ")
    }
}
