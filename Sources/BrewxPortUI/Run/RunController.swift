import Foundation
import Observation
import BrewxPortCore
import BrewxPortRun

/// Where one step of the current run is.
public enum StepState: Sendable, Equatable { case waiting, running, succeeded, failed(Int32), stopped, skipped }

/// One step as the run panel lists it. `id` is the step's index in the run.
public struct RunStepRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let operation: PackageOperation
    public var state: StepState

    public init(id: Int, title: String, operation: PackageOperation, state: StepState = .waiting) {
        self.id = id
        self.title = title
        self.operation = operation
        self.state = state
    }
}

/// What quitting does: quit at once, or ask first because a run is going.
public enum QuitDecision: Equatable { case now, confirm }

/// One run at a time: the helper check, the preflight, the run itself, its log and step states, the password
/// sheet, and quitting during a run.
@MainActor @Observable
public final class RunController: PasswordPrompting {
    public private(set) var isRunning = false
    public private(set) var log = RunLog()
    public private(set) var steps: [RunStepRow] = []
    /// The last run ended with `.passwordRejected`. Cleared when a run gets past the password.
    public private(set) var passwordRejected = false
    /// Why the last run couldn't make admin changes for a reason other than the password, or nil.
    public private(set) var privilegeProblem: String?

    public var showingPasswordSheet = false
    public private(set) var passwordReason = ""

    /// Why something the user asked for won't run: the plan's problems and the preflight's notes. The panel shows
    /// these without the log being opened.
    public private(set) var problems: [String] = []

    /// The panel's header: "Running", "Nothing ran" when the plan and preflight left no step, else "Finished".
    public var headline: String {
        if isRunning { return "Running" }
        return steps.isEmpty ? "Nothing ran" : "Finished"
    }

    /// Shown from `start` until `dismissPanel()`, which is a no-op mid-run.
    public private(set) var panelVisible = false

    /// Called every time a started run ends, including a run the helper check left with nothing to do. Not called
    /// when `start` returns false.
    @ObservationIgnored public var onRunEnded: (@MainActor () -> Void)?

    @ObservationIgnored private let executor: (any RunExecuting)?
    @ObservationIgnored private let isAdministrator: AdminCheck
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Counts runs, so events from a run that already ended can't touch the next one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var pendingPassword: (token: Int, continuation: CheckedContinuation<SecretBuffer?, Never>)?
    /// The token of the latest prompt. Internal for tests.
    @ObservationIgnored private(set) var promptToken = 0
    @ObservationIgnored private var quitWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(executor: (any RunExecuting)?, isAdministrator: @escaping AdminCheck) {
        self.executor = executor
        self.isAdministrator = isAdministrator
    }

    public func dismissPanel() {
        guard !isRunning else { return }
        panelVisible = false
    }

    // MARK: Run

    /// False (and nothing starts) when a run is already going, there's no executor, or no step is left after the
    /// preflight. `isRunning` is set before the first await, so a second call during `ensureHelper` returns false.
    ///
    /// `ensureHelper` is called only when a step routes to the helper. `helperUnavailableReason` replaces the
    /// helper-state text in the preflight's note (Task 6 passes `services.setupProblem` when there's no helper).
    /// When the helper check leaves nothing to run, the run ends with the preflight's note in the log.
    @discardableResult
    public func start(_ plan: ActionPlan, helperUnavailableReason: String? = nil,
                      ensureHelper: @escaping @MainActor () async -> HelperState?) -> Bool {
        guard !isRunning, let executor else { return false }
        // Before any await, so a second click can't start a second run.
        isRunning = true
        panelVisible = true
        cancelRequested = false
        privilegeProblem = nil
        generation += 1
        let run = generation

        // The account check needs no helper, so it's applied first: a standard account never registers it.
        let admin = isAdministrator()
        let (runnable, adminNotes) = RunPreflight.filter(plan.steps, helperState: .enabled, isAdministrator: admin)
        guard !runnable.isEmpty else {
            prepare([], plan: plan, notes: adminNotes)
            isRunning = false
            return false
        }
        prepare(runnable, plan: plan, notes: adminNotes)

        guard runnable.contains(where: { RunRouting.route(for: $0) == .helper }) else {
            launch(runnable, reason: plan.reason, executor: executor, run: run)
            return true
        }
        runTask = Task {
            let state = await ensureHelper()
            guard run == generation else { return }
            let (kept, helperNotes) = RunPreflight.filter(runnable, helperState: state, isAdministrator: admin,
                                                          helperUnavailableReason: helperUnavailableReason)
            prepare(kept, plan: plan, notes: adminNotes + helperNotes)
            if cancelRequested {
                apply(.cancelled)
                apply(.done)
                endRun()
            } else if kept.isEmpty {
                endRun()
            } else {
                launch(kept, reason: plan.reason, executor: executor, run: run)
            }
        }
        return true
    }

    public func cancel() {
        // Covers a cancel that comes while the run is still waiting on the helper check.
        if isRunning { cancelRequested = true }
        executor?.cancel()
        finishPassword(nil)
    }

    /// Fresh log and rows for `steps`, with the plan's problems and notes and the preflight's notes first.
    private func prepare(_ steps: [RunStep], plan: ActionPlan, notes: [String]) {
        var log = RunLog(steps: steps)
        for problem in plan.problems { log.note(problem, isError: true) }
        for note in plan.notes { log.note(note) }
        for note in notes { log.note(note, isError: true) }
        self.log = log
        problems = plan.problems + notes
        self.steps = steps.enumerated().map { RunStepRow(id: $0.offset, title: $0.element.title,
                                                         operation: $0.element.operation) }
    }

    /// Starts the executor at once (so a `cancel()` right after reaches it) and follows its events.
    private func launch(_ steps: [RunStep], reason: String, executor: any RunExecuting, run: Int) {
        let events = executor.run(steps, reason: reason)
        runTask = Task {
            for await event in events {
                guard run == generation else { return }
                apply(event)
                if event == .done { endRun() }
            }
            // A stream that ended without `.done` still ends the run.
            if run == generation, isRunning { endRun() }
        }
    }

    private func apply(_ event: RunEvent) {
        log.apply(event)
        switch event {
        case .started(let index):
            setState(index, .running)
            passwordRejected = false
            privilegeProblem = nil
        case .finished(let index, let code):
            setState(index, code == 0 ? .succeeded : .failed(code))
        case .cancelled:
            for index in steps.indices {
                switch steps[index].state {
                case .running: steps[index].state = .stopped
                case .waiting: steps[index].state = .skipped
                default: break
                }
            }
        case .passwordRejected:
            passwordRejected = true
        case .privilegeUnavailable(let reason):
            privilegeProblem = reason
        case .done:
            // Anything still waiting never ran (a rejected password, for one).
            for index in steps.indices where steps[index].state == .waiting { steps[index].state = .skipped }
        case .needsPassword, .output:
            break
        }
    }

    private func setState(_ index: Int, _ state: StepState) {
        guard steps.indices.contains(index) else { return }
        steps[index].state = state
    }

    private func endRun() {
        guard isRunning else { return }
        isRunning = false
        runTask = nil
        let waiters = quitWaiters
        quitWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: true) }
        onRunEnded?()
    }

    // MARK: Password

    public func askForPassword(reason: String) async -> SecretBuffer? {
        finishPassword(nil)  // never two prompts at once
        promptToken += 1
        let token = promptToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingPassword = (token, continuation)
                passwordReason = reason
                showingPasswordSheet = true
            }
        } onCancel: {
            Task { @MainActor in self.endPrompt(token: token) }
        }
    }

    /// Ends the prompt with `secret` (nil means cancelled). A secret nobody is waiting for is wiped.
    public func finishPassword(_ secret: SecretBuffer?) {
        showingPasswordSheet = false
        guard let pending = pendingPassword else {
            secret?.wipe()
            return
        }
        pendingPassword = nil
        pending.continuation.resume(returning: secret)
    }

    /// Cancels the prompt with `token`, and only that one: a late cancellation never ends a newer prompt.
    func endPrompt(token: Int) {
        guard pendingPassword?.token == token else { return }
        finishPassword(nil)
    }

    // MARK: Quit

    public func quitDecision() -> QuitDecision {
        isRunning ? .confirm : .now
    }

    /// Cancels and waits for `.done`. False if the run hadn't ended within `bound`.
    public func cancelForQuit(bound: Duration = BrewxPortTimeouts.quitCancel) async -> Bool {
        cancel()
        guard isRunning else { return true }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: bound)
            self?.giveUpWaiting(id)
        }
        let ended = await withCheckedContinuation { quitWaiters[id] = $0 }
        timer.cancel()
        return ended
    }

    private func giveUpWaiting(_ id: UUID) {
        quitWaiters.removeValue(forKey: id)?.resume(returning: false)
    }
}
