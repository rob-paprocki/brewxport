import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// Uninstall: gathers each package manager's facts for the picked packages, works out what goes
/// (`UninstallPlanner`), and starts the run through the app's one run path (password sheet, step rows, log).
///
/// - Picks are the rows the entry point named, replaced by Installed's row for the same package once Installed has
///   settled (it carries what was asked for).
/// - Each package manager with picks is asked through `DependencyGatherer`, all at once. Homebrew and MacPorts walk
///   their dependencies even when what was asked for isn't known for every package, since the planner reads it
///   package by package; nanobrew only needs its dependents; the Mac App Store isn't asked. A gather that throws
///   counts as that manager's facts failing (the planner fails closed), and the other managers are unaffected. A
///   Homebrew or MacPorts that Installed couldn't list gets no leftovers, and the sheet says they couldn't be worked out.
/// - Works in demo mode too: the demo's engines answer from captured output and its runs change nothing.
@MainActor @Observable public final class UninstallModel {
    public enum State: Equatable, Sendable {
        case hidden
        case checking
        case ready(UninstallPlan)
        case running
    }

    public private(set) var state: State = .hidden

    /// The sheet is up: checking or showing the plan. Not while the uninstall runs.
    public var sheetShown: Bool {
        switch state {
        case .checking, .ready: return true
        case .hidden, .running: return false
        }
    }

    /// How long one dependents call may take. Tests shorten it.
    @ObservationIgnored var queryTimeout: Duration = BrewxPortTimeouts.engineQuery
    @ObservationIgnored private let services: Services
    @ObservationIgnored private let installed: InstalledModel
    @ObservationIgnored private weak var app: BrewxPortAppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so an answer for an earlier start is dropped.
    @ObservationIgnored private var generation = 0
    /// The facts behind the plan on screen, the managers whose gather worked; `UninstallRunBuilder` orders with them.
    @ObservationIgnored private var facts: [EngineID: DependencyFacts] = [:]
    /// Whether this account is an administrator (nil when the check failed), asked once per start with the same
    /// check the run makes.
    @ObservationIgnored private var isAdministrator: Bool?
    /// The uninstall that's running: its steps and the run's number.
    @ObservationIgnored private var running: (UninstallRun, Int)?

    init(services: Services, installed: InstalledModel) {
        self.services = services
        self.installed = installed
    }

    /// Called once by the app model after it's set up: the run state and the run path come from it.
    func connect(_ app: BrewxPortAppModel) {
        self.app = app
        app.addRunEndedObserver { [weak self] in self?.runEnded() }
    }

    /// Gathers the facts for removing `refs` and shows the plan. Does nothing when this copy can't run anything,
    /// during a run (or while an uninstall is running), or when none of `refs` is a row the lists know. A start while
    /// checking replaces that check.
    public func start(_ refs: Set<PackageRef>) {
        guard state != .running, let app, app.canRun, !app.busy else { return }
        let picks = refs.compactMap(app.package(for:))
        guard !picks.isEmpty else { return }
        task?.cancel()
        generation += 1
        let mine = generation
        isAdministrator = services.isAdministrator()
        state = .checking
        task = Task { [weak self] in
            guard let self else { return }
            let (picks, outcomes) = await self.gather(picks)
            guard !Task.isCancelled, self.generation == mine else { return }
            self.facts = outcomes.compactMapValues { try? $0.get() }
            self.state = .ready(UninstallPlanner.plan(picks: picks, facts: outcomes))
        }
    }

    /// One manager's "Also remove leftovers" box. A manager with no leftovers has no box, so it stays unticked.
    public func setRemoveLeftovers(_ on: Bool, engine: EngineID) {
        guard case .ready(var plan) = state,
              let index = plan.sections.firstIndex(where: { $0.engine == engine }),
              !plan.sections[index].leftovers.isEmpty else { return }
        plan.sections[index].removeLeftovers = on
        state = .ready(plan)
    }

    /// The steps confirming `plan` would run, before the run's preflight.
    func steps(for plan: UninstallPlan) -> [RunStep] {
        UninstallRunBuilder.steps(for: plan, engines: services.engines, facts: facts).steps
    }

    /// The bottom of the sheet for a plan: the password (or administrator) line, the Uninstall button's words and
    /// whether it's on, and the managers whose removals this account can't run, which the sheet dims.
    struct Confirmation: Equatable {
        let line: String?
        let button: String
        let enabled: Bool
        let skipped: Set<EngineID>
    }

    /// What confirming `plan` would do on this account. A standard account's run leaves out every step that needs
    /// root (`RunPreflight`, the same filter the run applies), so the button counts only what's left and is off when
    /// nothing is. An administrator, or a failed account check, gets the plan as it is.
    func confirmation(for plan: UninstallPlan) -> Confirmation {
        let steps = steps(for: plan)
        let line = UninstallSheetText.accountLine(steps, isAdministrator: isAdministrator)
        guard isAdministrator == false else {
            return Confirmation(line: line, button: UninstallSheetText.uninstallButton(plan),
                                enabled: UninstallSheetText.canUninstall(plan), skipped: [])
        }
        let kept = RunPreflight.filter(steps, helperState: .enabled, isAdministrator: false).steps
        let skipped = Set(steps.map(\.engine)).subtracting(kept.map(\.engine))
        return Confirmation(line: line, button: UninstallSheetText.uninstallButton(removing: kept.count),
                            enabled: !kept.isEmpty, skipped: skipped)
    }

    /// Starts the uninstall shown in the sheet. Does nothing unless a plan is showing, something in it would be
    /// removed, and nothing else is running.
    public func confirm() {
        guard case .ready(let plan) = state, let app, app.canRun, !app.busy else { return }
        let run = UninstallRunBuilder.run(for: plan, engines: services.engines, facts: facts)
        guard !run.actions.steps.isEmpty || !run.actions.problems.isEmpty else { return }
        state = .running
        // A run that had nothing it could do never started (the run panel says why), so there's nothing to wait for.
        guard app.startUninstall(run.actions) else {
            hide()
            return
        }
        running = (run, app.run.runNumber)
    }

    /// Closes the sheet. A check in flight is dropped. A running uninstall is the run panel's to cancel.
    public func cancel() {
        guard state != .running else { return }
        task?.cancel()
        task = nil
        generation += 1
        hide()
    }

    /// Back to hidden; a file the Finder opened while the sheet was up opens now.
    private func hide() {
        state = .hidden
        facts = [:]
        app?.openPendingFile()
    }

    /// After an uninstall's run: one line in the run panel for each manager whose removals didn't all work.
    private func runEnded() {
        guard state == .running else { return }
        hide()
        guard let (run, number) = running, let app else { return }
        running = nil
        if let note = UninstallRunSummary.note(for: run, rows: app.run.steps) {
            app.run.addProblem(note, run: number)
        }
    }

    // MARK: Gathering

    private typealias Outcome = Result<DependencyFacts, DependencyGatherer.Failure>

    private func gather(_ picked: [Package]) async -> ([Package], [EngineID: Outcome]) {
        await installed.settled()
        let rows = installed.list.all.map(\.package)
        let byRef = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picks = picked.map { byRef[$0.id] ?? $0 }

        let gatherer = DependencyGatherer(engines: services.engines, catalog: services.catalog, timeout: queryTimeout)
        let byEngine = Dictionary(grouping: picks, by: \.id.engine).filter { $0.key != .mas }
        let outcomes = await withTaskGroup(of: (EngineID, Outcome).self) { group in
            for (engine, enginePicks) in byEngine {
                let walk = engine == .homebrew || engine == .macports
                group.addTask {
                    do throws(DependencyGatherer.Failure) {
                        let facts = try await gatherer.facts(for: enginePicks, engine: engine, installed: rows,
                                                             walkDependenciesWhenRequestedUnknown: walk)
                        return (engine, .success(facts))
                    } catch {
                        return (engine, .failure(error))
                    }
                }
            }
            var outcomes: [EngineID: Outcome] = [:]
            for await (engine, outcome) in group { outcomes[engine] = outcome }
            return outcomes
        }
        // Leftovers are read from Installed's rows (what's installed, what was asked for). A manager Installed couldn't
        // list, or has no rows for, can't have its leftovers worked out: the sheet says so. Its dependents still order
        // the removals. (`dependencies` is empty whenever `dependenciesComplete` is false.)
        let listed = Set(rows.map(\.id.engine)).subtracting(installed.list.failedEngines)
        var checked = outcomes
        for (engine, outcome) in outcomes where (engine == .homebrew || engine == .macports) && !listed.contains(engine) {
            guard case .success(var facts) = outcome else { continue }
            facts.dependenciesComplete = false
            facts.dependencies = [:]
            checked[engine] = .success(facts)
        }
        return (picks, checked)
    }
}
