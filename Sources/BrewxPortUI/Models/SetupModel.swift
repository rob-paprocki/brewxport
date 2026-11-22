import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// The first-launch setup screen's state. It decides at launch whether to offer a package manager, waits for the
/// helper to be approved when it must, and hands the actual setup to the app model's run. A setup never disappears
/// silently: every way it can stop ends in a stage the screen shows, with "Not now" available in all of them.
@MainActor @Observable public final class SetupModel {
    public enum Stage: Equatable {
        case hidden
        case offer(recommended: EngineID, others: [EngineID])
        case needsHelperApproval
        case running
        case finished
        /// The run ended and the engine still isn't there (failed or cancelled). "Try again" or "Not now".
        case failed(engine: EngineID, reason: String)
        /// The run couldn't even start. "Try again" (when it was busy) or "Not now".
        case cannotSetUp(engine: EngineID, reason: String)
    }

    /// When "Not now" (or a finished setup) was last chosen, as seconds since 1970. An older plain flag reads as
    /// "a long time ago".
    public static let dismissedKey = "setupDismissed"

    /// The install date of the installer-choice marker whose setup was already started, as seconds since 1970.
    public static let choiceHandledKey = "setupChoiceHandled"

    public private(set) var stage: Stage = .hidden {
        didSet { if stage != oldValue { stageChanged?(stage) } }
    }
    /// Told about every stage change; the app model polls the helper while the stage is `.needsHelperApproval`.
    @ObservationIgnored var stageChanged: (@MainActor (Stage) -> Void)?

    @ObservationIgnored private let services: Services
    @ObservationIgnored private var statuses: @MainActor () -> [EngineID: EngineStatus] = { [:] }
    /// Starts a setup run; false when it didn't start.
    @ObservationIgnored private var runSetup: @MainActor (EngineID) -> Bool = { _ in false }
    /// Why the last setup didn't start when its plan had nothing to run (mas with no Homebrew or MacPorts).
    @ObservationIgnored private var planProblem: @MainActor () -> String? = { nil }
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored private var helperState: HelperState?
    /// The engine waiting for the helper, and the one the current run is setting up.
    @ObservationIgnored private var pending: EngineID?
    /// True while a setup waits for the helper's first answer. The offer shows "Checking BrewxPort's helper…".
    public private(set) var waitingForHelper = false
    @ObservationIgnored private var current: EngineID?
    @ObservationIgnored private var runEndedAwaitingCheck = false
    @ObservationIgnored private var started = false

    public init(services: Services) { self.services = services }

    func connect(statuses: @escaping @MainActor () -> [EngineID: EngineStatus],
                 runSetup: @escaping @MainActor (EngineID) -> Bool,
                 planProblem: @escaping @MainActor () -> String? = { nil }) {
        self.statuses = statuses
        self.runSetup = runSetup
        self.planProblem = planProblem
    }

    private var dismissalDate: Date? {
        guard let data = services.store.data(forKey: Self.dismissedKey) else { return nil }
        if let text = String(data: data, encoding: .utf8), let seconds = Double(text) {
            return Date(timeIntervalSince1970: seconds)
        }
        return .distantPast
    }

    private var choiceHandledDate: Date? {
        services.store.data(forKey: Self.choiceHandledKey)
            .flatMap { String(data: $0, encoding: .utf8) }.flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
    }

    private func markDismissed() {
        services.store.set(Data(String(now().timeIntervalSince1970).utf8), forKey: Self.dismissedKey)
    }

    private func status(_ id: EngineID) -> EngineStatus? { statuses()[id] }
    private func present(_ id: EngineID) -> Bool {
        if case .present? = status(id) { return true }
        return false
    }

    /// Decide at launch, once the first engine check has answered. Never shows anything in demo mode. After "Not now"
    /// it stays quiet, unless the installer's "Set up …" box was ticked in an install newer than that. Runs once.
    public func start() async {
        guard !started, !services.isDemo else { return }
        let choiceDate = await InstallerReceipt.setupChoiceDate(services.receipts)
        guard !started, stage == .hidden else { return }
        started = true
        let host = services.hostInfo
        let recommended = EngineSetupPlanner.recommended(host: host)
        let dismissedAt = dismissalDate
        let handledAt = choiceHandledDate
        if let choiceDate, dismissedAt.map({ choiceDate > $0 }) ?? true, handledAt.map({ choiceDate > $0 }) ?? true {
            // They ticked the box: no screen to click through, and this install's choice starts a setup only once.
            // Nothing to do when it's already there.
            services.store.set(Data(String(choiceDate.timeIntervalSince1970).utf8), forKey: Self.choiceHandledKey)
            if present(recommended) { markDismissed() } else { begin(recommended) }
        } else if dismissedAt == nil, noEnginePresent {
            let others = Self.withoutMasIfNoSource(EngineSetupPlanner.offered(host: host), present: present)
                .filter { $0 != recommended && !present($0) }
            stage = .offer(recommended: recommended, others: others)
        }
    }

    /// Absent means every one of the four answered "missing". An unusable or unanswered probe isn't absence.
    private var noEnginePresent: Bool {
        [EngineID.homebrew, .macports, .nanobrew, .mas].allSatisfy { status($0) == .missing }
    }

    public func setUp(_ engine: EngineID) {
        guard case .offer = stage else { return }
        begin(engine)
    }

    /// From `.failed` or `.cannotSetUp`: run the same setup again.
    public func retry() {
        switch stage {
        case .failed(let engine, _), .cannotSetUp(let engine, _): begin(engine)
        default: break
        }
    }

    /// mas installs through Homebrew or MacPorts, so it isn't offered while neither is there.
    private static func withoutMasIfNoSource(_ engines: [EngineID], present: (EngineID) -> Bool) -> [EngineID] {
        present(.homebrew) || present(.macports) ? engines : engines.filter { $0 != .mas }
    }

    /// The package managers that are missing (not "not working") and that this Mac can set up, in offer order.
    private var missingOffers: [EngineID] {
        Self.withoutMasIfNoSource(EngineSetupPlanner.offered(host: services.hostInfo), present: present)
            .filter { status($0) == .missing }
    }

    /// True when File > "Set Up Package Manager…" has something to show: nothing is on screen, running or waiting for
    /// the helper (the installer's choice waits without a screen), and a package manager is still missing. Never in
    /// demo mode.
    public var canShowOffer: Bool {
        !services.isDemo && stage == .hidden && !waitingForHelper && !missingOffers.isEmpty
    }

    /// The menu item: shows the offer again, even after "Not now". Doesn't change what "Not now" remembers.
    public func showOffer() {
        guard canShowOffer else { return }
        makeOffer()
    }

    /// The offer as on a Mac with nothing installed, whatever the demo has: for the snapshot only.
    public func previewOffer() {
        guard stage == .hidden else { return }
        makeOffer(from: EngineSetupPlanner.offered(host: services.hostInfo))
    }

    private func makeOffer(from missing: [EngineID]? = nil) {
        let missing = Self.withoutMasIfNoSource(missing ?? missingOffers, present: present)
        let preferred = EngineSetupPlanner.recommended(host: services.hostInfo)
        guard let recommended = missing.contains(preferred) ? preferred : missing.first else { return }
        stage = .offer(recommended: recommended, others: missing.filter { $0 != recommended })
    }

    /// The window shows the setup sheet in every stage but these two.
    public var sheetShown: Bool { stage != .hidden && stage != .running }

    /// The engine the current or last setup is for. The finished screen names it.
    public var engineBeingSetUp: EngineID? { current }

    /// The sheet was closed some other way (Esc): "Done" on the finished screen, "Not now" anywhere else.
    public func dismiss() {
        switch stage {
        case .hidden, .running: break
        case .finished: done()
        default: notNow()
        }
    }

    public func notNow() {
        markDismissed()
        pending = nil
        waitingForHelper = false
        stage = .hidden
    }

    /// The app model reports every helper answer here, after the helper call is over.
    public func helperStateChanged(_ state: HelperState?) {
        helperState = state
        if state != nil { waitingForHelper = false }
        guard let state, let engine = pending else { return }
        switch stage {
        case .needsHelperApproval:
            if state == .enabled {
                pending = nil
                begin(engine)
            }
        case .hidden, .offer:
            // The first answer arrived while a setup was waiting for it.
            pending = nil
            begin(engine)
        default: break
        }
    }

    /// The app model reports each run end here. The verdict waits for the engine check that follows.
    func runEnded() {
        guard stage == .running else { return }
        runEndedAwaitingCheck = true
    }

    /// The app model reports each finished engine check here (after the first one's `start()`).
    func enginesRechecked() {
        guard stage == .running, runEndedAwaitingCheck, let engine = current else { return }
        runEndedAwaitingCheck = false
        if present(engine) {
            markDismissed()
            stage = .finished
        } else {
            stage = .failed(engine: engine,
                            reason: "\(engine.displayName) wasn't set up. The run panel shows what went wrong.")
        }
    }

    /// Closes the finished screen.
    public func done() {
        if stage == .finished { stage = .hidden }
    }

    /// A standard account can't set anything up. Then the helper does the work, so it has to be approved first; until
    /// its first answer arrives nothing is decided or shown. With no helper at all the run reports why itself.
    private func begin(_ engine: EngineID) {
        if services.isAdministrator() == false {
            current = engine
            stage = .cannotSetUp(engine: engine, reason: cannotReason(engine))
            return
        }
        if services.helper != nil {
            guard let state = helperState else {
                pending = engine
                waitingForHelper = true
                return
            }
            if state != .enabled {
                pending = engine
                stage = .needsHelperApproval
                return
            }
        }
        current = engine
        runEndedAwaitingCheck = false
        if runSetup(engine) {
            stage = .running
        } else {
            stage = .cannotSetUp(engine: engine, reason: cannotReason(engine))
        }
    }

    private func cannotReason(_ engine: EngineID) -> String {
        if services.isAdministrator() == false { return "Setting up \(engine.displayName) needs an administrator account." }
        if let problem = services.setupProblem { return problem }
        if let problem = planProblem() { return problem }
        return "Another task is in progress. Try again in a moment."
    }
}
