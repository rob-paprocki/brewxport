import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Polls on the main actor until `condition` holds or about 5 s pass.
@MainActor func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Lets a test hold `ensureHelper` open until it says so.
@MainActor final class HelperGate {
    private(set) var calls = 0
    private var waiting: CheckedContinuation<HelperState?, Never>?

    var isWaiting: Bool { waiting != nil }

    func ensure() async -> HelperState? {
        calls += 1
        return await withCheckedContinuation { waiting = $0 }
    }

    func open(_ state: HelperState?) {
        waiting?.resume(returning: state)
        waiting = nil
    }
}

/// `RunExecuting` whose stream never ends, even when cancelled.
final class StuckExecutor: RunExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelCount = 0
    private var held: [AsyncStream<RunEvent>.Continuation] = []
    var cancelCount: Int { lock.withLock { _cancelCount } }

    func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        AsyncStream { continuation in
            continuation.yield(.started(0))
            lock.withLock { held.append(continuation) }
        }
    }

    func cancel() { lock.withLock { _cancelCount += 1 } }

    /// Ends the streams so the test leaves nothing running.
    func release() {
        for continuation in lock.withLock({ held }) {
            continuation.yield(.done)
            continuation.finish()
        }
    }
}

/// `RunExecuting` that asks for the password the way RunSession does (through a `PasswordProviding`), then runs
/// every step successfully. Counts prompts.
final class PromptingExecutor: RunExecuting, @unchecked Sendable {
    private let passwords: any PasswordProviding
    private let lock = NSLock()
    private var _runs = 0
    private var _prompts = 0
    var runs: Int { lock.withLock { _runs } }
    var prompts: Int { lock.withLock { _prompts } }

    init(passwords: any PasswordProviding) { self.passwords = passwords }

    func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        lock.withLock { _runs += 1 }
        return AsyncStream { continuation in
            Task {
                continuation.yield(.needsPassword)
                self.lock.withLock { self._prompts += 1 }
                let secret = await self.passwords.password(reason: reason, previousAttemptFailed: false)
                secret?.wipe()
                for index in steps.indices {
                    continuation.yield(.started(index))
                    continuation.yield(.finished(index, 0))
                }
                continuation.yield(.done)
                continuation.finish()
            }
        }
    }

    func cancel() {}
}

/// `RunExecuting` that plays one script per run, in order: asks for the password once per flag in `asks` (the flag
/// is `previousAttemptFailed`), stopping when the answer is nil, then yields `events`. Records what each ask returned.
final class AskingExecutor: RunExecuting, @unchecked Sendable {
    struct Script { var asks: [Bool]; var events: [RunEvent] }
    private let passwords: any PasswordProviding
    private let lock = NSLock()
    private var scripts: [Script]
    init(passwords: any PasswordProviding, scripts: [Script]) {
        self.passwords = passwords
        self.scripts = scripts
    }

    func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        let script = lock.withLock { scripts.isEmpty ? Script(asks: [], events: [.done]) : scripts.removeFirst() }
        return AsyncStream { continuation in
            Task {
                continuation.yield(.needsPassword)
                for retry in script.asks {
                    guard let secret = await self.passwords.password(reason: reason, previousAttemptFailed: retry)
                    else { break }
                    secret.wipe()
                }
                for event in script.events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    func cancel() {}
}

/// `start` with a helper answer that isn't a closure literal, so it can sit inside `#expect`.
extension RunController {
    func start(_ plan: ActionPlan, helperUnavailableReason: String? = nil, gate: HelperGate) -> Bool {
        start(plan, helperUnavailableReason: helperUnavailableReason) { await gate.ensure() }
    }

    func start(_ plan: ActionPlan, helperUnavailableReason: String? = nil, helper state: HelperState?) -> Bool {
        start(plan, helperUnavailableReason: helperUnavailableReason) { state }
    }
}

@MainActor @Suite struct RunControllerTests {
    typealias F = PlanFixtures

    static func plan(_ steps: [RunStep], problems: [String] = [], notes: [String] = []) -> ActionPlan {
        ActionPlan(steps: steps, problems: problems, notes: notes,
                   reason: "BrewxPort needs an administrator password to update these packages.")
    }

    static func controller(_ executor: (any RunExecuting)?, admin: Bool? = true) -> RunController {
        RunController(executor: executor, isAdministrator: { admin })
    }

    static let enabled: @MainActor () async -> HelperState? = { .enabled }

    // MARK: One run at a time

    @Test func oneRunAtATime() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(run.isRunning)
        #expect(!run.start(Self.plan([F.formula("jq")]), ensureHelper: Self.enabled))
        #expect(await waitUntil { run.steps.first?.state == .running })
        #expect(executor.runs.count == 1)
        run.cancel()
        #expect(await waitUntil { !run.isRunning })
    }

    @Test func secondStartWhileEnsureHelperPending() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let run = Self.controller(executor)
        let gate = HelperGate()
        #expect(run.start(Self.plan([F.port()]), gate: gate))
        #expect(await waitUntil { gate.isWaiting })
        #expect(!run.start(Self.plan([F.port()]), gate: gate))
        gate.open(.enabled)
        #expect(await waitUntil { !run.isRunning })
        #expect(gate.calls == 1)
        #expect(executor.runs.count == 1)
    }

    @Test func doubleClickGivesOneRunAndOnePrompt() async {
        let passwords = PromptPasswordProvider()
        let executor = PromptingExecutor(passwords: passwords)
        let run = Self.controller(executor)
        passwords.prompter = run
        let gate = HelperGate()
        let plan = Self.plan([F.port()])
        #expect(run.start(plan, gate: gate))
        #expect(!run.start(plan, gate: gate))
        #expect(await waitUntil { gate.isWaiting })
        gate.open(.enabled)
        #expect(await waitUntil { run.showingPasswordSheet })
        #expect(!run.start(plan, gate: gate))
        run.finishPassword(SecretBuffer(copying: Array("pw".utf8)))
        #expect(await waitUntil { !run.isRunning })
        #expect(executor.runs == 1)
        #expect(executor.prompts == 1)
        #expect(gate.calls == 1)
    }

    // MARK: Nothing to run

    @Test func emptyPlanShowsProblemsAndDoesNotRun() async {
        let executor = FakeRunExecutor()
        let run = Self.controller(executor)
        var ended = 0
        run.onRunEnded = { ended += 1 }
        let started = run.start(Self.plan([], problems: ["zoom needs Homebrew."], notes: ["A note."]),
                                ensureHelper: Self.enabled)
        #expect(!started)
        #expect(!run.isRunning)
        #expect(run.panelVisible)
        #expect(run.steps.isEmpty)
        #expect(run.log.lines.map(\.text) == ["zoom needs Homebrew.", "A note."])
        #expect(run.log.lines.map(\.isError) == [true, false])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        #expect(ended == 0)
    }

    @Test func standardUserWithOnlyRootStepsDoesNotRun() async {
        let executor = FakeRunExecutor()
        let run = Self.controller(executor, admin: false)
        let gate = HelperGate()
        #expect(!run.start(Self.plan([F.port("curl")]), gate: gate))
        #expect(!run.isRunning)
        #expect(gate.calls == 0)
        #expect(run.log.lines.map(\.text) == [
            "Skipped Upgrade curl: they need an administrator account, and this one isn't."
        ])
        #expect(executor.runs.isEmpty)
    }

    @Test func noExecutorStartsNothing() {
        let run = Self.controller(nil)
        #expect(!run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(!run.isRunning)
    }

    @Test func missingHelperUsesSetupProblemText() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula("wget"), F.port("curl")]),
                          helperUnavailableReason: "This copy of BrewxPort isn't signed.", helper: nil))
        #expect(await waitUntil { !run.isRunning })
        #expect(executor.runs.map { $0.steps } == [[F.formula("wget")]])
        #expect(run.steps.map(\.title) == ["Upgrade wget"])
        #expect(run.log.lines.first?.text
                == "Skipped Upgrade curl. MacPorts updates need BrewxPort's helper, and it isn't ready: "
                    + "This copy of BrewxPort isn't signed.")
    }

    @Test func helperOnlyRunWithoutHelperEndsWithoutRunning() async {
        let executor = FakeRunExecutor()
        let run = Self.controller(executor)
        var ended = 0
        run.onRunEnded = { ended += 1 }
        #expect(run.start(Self.plan([F.port("curl")]), helper: .requiresApproval))
        #expect(await waitUntil { !run.isRunning })
        #expect(executor.runs.isEmpty)
        #expect(run.log.lines.count == 1)
        #expect(ended == 1)    // the lists still reload after a run that ran nothing
    }

    // MARK: Step states

    @Test func stepStatesFollowEvents() async {
        let executor = FakeRunExecutor(events: [.started(0), .output(0, .stdout("ok")), .finished(0, 0), .started(1)],
                                       hang: true)
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula("wget"), F.formula("jq"), F.cask()]), ensureHelper: Self.enabled))
        #expect(run.steps.map(\.state) == [.waiting, .waiting, .waiting])
        #expect(run.steps.map(\.id) == [0, 1, 2])
        #expect(run.steps.map(\.operation) == [.upgrade, .upgrade, .upgrade])
        #expect(await waitUntil { run.steps.map(\.state) == [.succeeded, .running, .waiting] })
        run.cancel()
        #expect(await waitUntil { !run.isRunning })

        let failing = FakeRunExecutor(events: [.started(0), .finished(0, 0), .started(1), .finished(1, 3), .done])
        let second = Self.controller(failing)
        #expect(second.start(Self.plan([F.formula("wget"), F.formula("jq")]), ensureHelper: Self.enabled))
        #expect(await waitUntil { !second.isRunning })
        #expect(second.steps.map(\.state) == [.succeeded, .failed(3)])
        #expect(second.log.lines.last?.text == "Done.")
    }

    @Test func cancelledClosesOpenStepAsStopped() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula("wget"), F.formula("jq")]), ensureHelper: Self.enabled))
        #expect(await waitUntil { run.steps.first?.state == .running })
        run.cancel()
        #expect(await waitUntil { !run.isRunning })
        #expect(run.steps.map(\.state) == [.stopped, .skipped])
        #expect(executor.cancelCount == 1)
    }

    @Test func cancelWhileEnsureHelperPendingRunsNothing() async {
        let executor = FakeRunExecutor()
        let run = Self.controller(executor)
        let gate = HelperGate()
        #expect(run.start(Self.plan([F.port(), F.formula()]), gate: gate))
        #expect(await waitUntil { gate.isWaiting })
        run.cancel()
        gate.open(.enabled)
        #expect(await waitUntil { !run.isRunning })
        #expect(executor.runs.isEmpty)
        #expect(run.steps.map(\.state) == [.skipped, .skipped])
        #expect(run.log.lines.map(\.text).suffix(2) == ["Cancelled. Nothing more will run.", "Done."])
    }

    // MARK: Password

    @Test func passwordGoesToTheWaitingPrompt() async {
        let run = Self.controller(FakeRunExecutor())
        let ask = Task { await run.askForPassword(reason: "Because.") }
        #expect(await waitUntil { run.showingPasswordSheet })
        #expect(run.passwordReason == "Because.")
        let secret = SecretBuffer(copying: Array("pw".utf8))
        run.finishPassword(secret)
        let got = await ask.value
        #expect(got === secret)
        #expect(!run.showingPasswordSheet)
        #expect(!secret.isWiped)
    }

    @Test func latePromptCancelDoesNotEndNewerPrompt() async {
        let run = Self.controller(FakeRunExecutor())
        let first = Task { await run.askForPassword(reason: "first") }
        #expect(await waitUntil { run.showingPasswordSheet })
        let firstToken = run.promptToken
        let second = Task { await run.askForPassword(reason: "second") }
        #expect(await waitUntil { run.passwordReason == "second" && run.showingPasswordSheet })
        #expect(await first.value == nil)  // a new prompt ends the old one
        // The first prompt's cancellation handler lands late: it must not end the second prompt.
        run.endPrompt(token: firstToken)
        #expect(run.showingPasswordSheet)
        let secret = SecretBuffer(copying: Array("pw".utf8))
        run.finishPassword(secret)
        #expect(await second.value === secret)
    }

    @Test func cancellingThePromptTaskEndsItsPrompt() async {
        let run = Self.controller(FakeRunExecutor())
        let ask = Task { await run.askForPassword(reason: "r") }
        #expect(await waitUntil { run.showingPasswordSheet })
        ask.cancel()
        #expect(await ask.value == nil)
        #expect(await waitUntil { !run.showingPasswordSheet })
    }

    @Test func secretWipedWhenNobodyWaits() {
        let run = Self.controller(FakeRunExecutor())
        let secret = SecretBuffer(copying: Array("pw".utf8))
        run.finishPassword(secret)
        #expect(secret.isWiped)
        #expect(!run.showingPasswordSheet)
    }

    @Test func passwordRejectedThenStartedClearsFlag() async {
        let executor = FakeRunExecutor(events: [.needsPassword, .passwordRejected, .done])
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        #expect(run.passwordRejected)
        #expect(run.steps.map(\.state) == [.skipped])

        executor.events = [.needsPassword, .privilegeUnavailable("No admin."), .done]
        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        #expect(run.privilegeProblem == "No admin.")

        executor.events = [.needsPassword, .started(0), .finished(0, 0), .done]
        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        #expect(!run.passwordRejected)
        #expect(run.privilegeProblem == nil)
        #expect(executor.runs.map(\.reason).allSatisfy {
            $0 == "BrewxPort needs an administrator password to update these packages."
        })
    }

    @Test func retryPromptSaysTryAgain() async {
        let run = Self.controller(FakeRunExecutor())
        let first = Task { await run.askForPassword(reason: "r", previousAttemptFailed: false) }
        #expect(await waitUntil { run.showingPasswordSheet })
        #expect(!run.passwordRetry)
        run.finishPassword(SecretBuffer(copying: Array("wrong".utf8)))
        _ = await first.value
        let second = Task { await run.askForPassword(reason: "r", previousAttemptFailed: true) }
        #expect(await waitUntil { run.showingPasswordSheet })
        #expect(run.passwordRetry)
        #expect(PasswordSheet.retryLine == "That password didn't work. Try again.")
        run.finishPassword(nil)
        #expect(await second.value == nil)
    }

    @Test func providerPassesTheRetryFlag() async {
        let prompter = FakePrompter(password: "pw")
        let provider = PromptPasswordProvider()
        provider.prompter = prompter
        _ = await provider.password(reason: "a", previousAttemptFailed: false)
        _ = await provider.password(reason: "b", previousAttemptFailed: true)
        #expect(prompter.retries == [false, true])
    }

    @Test func newRunPasswordSheetStartsClean() async {
        let provider = PromptPasswordProvider()
        let executor = AskingExecutor(passwords: provider, scripts: [
            .init(asks: [false, true, true], events: [.passwordRejected, .done]),
            .init(asks: [false], events: [.started(0), .finished(0, 0), .done]),
        ])
        let run = Self.controller(executor)
        provider.prompter = run
        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        for attempt in 0..<3 {
            #expect(await waitUntil { run.showingPasswordSheet })
            #expect(run.passwordRetry == (attempt > 0))
            run.finishPassword(SecretBuffer(copying: Array("wrong".utf8)))
        }
        #expect(await waitUntil { !run.isRunning })
        #expect(run.passwordRejected)

        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        // The panel and the headline drop the last run's rejection as soon as the new run starts.
        #expect(!run.passwordRejected)
        #expect(await waitUntil { run.showingPasswordSheet })
        #expect(!run.passwordRetry)
        #expect(!run.passwordRejected)
        run.finishPassword(SecretBuffer(copying: Array("right".utf8)))
        #expect(await waitUntil { !run.isRunning })
        #expect(run.headline == "Finished")
    }

    @Test func lateSheetDismissalDoesNotCancelTheRetry() async {
        let run = Self.controller(FakeRunExecutor())
        let first = Task { await run.askForPassword(reason: "r", previousAttemptFailed: false) }
        #expect(await waitUntil { run.showingPasswordSheet })
        run.finishPassword(SecretBuffer(copying: Array("wrong".utf8)))
        _ = await first.value
        let second = Task { await run.askForPassword(reason: "r", previousAttemptFailed: true) }
        #expect(await waitUntil { run.showingPasswordSheet })
        // The first sheet's dismissal finishes after the retry's sheet was asked for: it must not end the retry.
        run.sheetDismissed()
        #expect(run.showingPasswordSheet)
        let secret = SecretBuffer(copying: Array("right".utf8))
        run.finishPassword(secret)
        #expect(await second.value === secret)

        // Esc on a showing sheet: SwiftUI clears the binding, then the dismissal cancels the prompt.
        let third = Task { await run.askForPassword(reason: "r", previousAttemptFailed: false) }
        #expect(await waitUntil { run.showingPasswordSheet })
        run.showingPasswordSheet = false
        run.sheetDismissed()
        #expect(await third.value == nil)
    }

    @Test func lateSheetDismissalDoesNotCancelARetryWaitingForFocus() async {
        // A run nobody clicked for (the automatic password run): its sheet shows only while BrewxPort has the focus.
        let executor = FakeRunExecutor(events: [], hang: true)
        let run = Self.controller(executor)
        let focus = BackgroundUpdaterTests.Focus()
        run.canPresentPasswordSheet = { focus.value }
        run.nextRunPromptNeedsFocus = true
        #expect(run.start(Self.plan([F.cask()]), ensureHelper: Self.enabled))
        let first = Task { await run.askForPassword(reason: "r", previousAttemptFailed: false) }
        #expect(await waitUntil { run.showingPasswordSheet })
        run.finishPassword(SecretBuffer(copying: Array("wrong".utf8)))
        _ = await first.value
        // The person is in another app when the retry asks, so its sheet waits for the focus.
        focus.value = false
        let retry = Task { await run.askForPassword(reason: "r", previousAttemptFailed: true) }
        #expect(await waitUntil { run.passwordWaitsForFocus })
        // The first sheet's dismissal finishes only now: it must not cancel the retry that's waiting.
        run.sheetDismissed()
        #expect(run.passwordWaitsForFocus)
        focus.value = true
        run.presentWaitingPrompt()
        #expect(run.showingPasswordSheet)
        let secret = SecretBuffer(copying: Array("right".utf8))
        run.finishPassword(secret)
        #expect(await retry.value === secret)
        run.cancel()
        #expect(await waitUntil { !run.isRunning })
    }

    // MARK: Helper and finish

    @Test func ensureHelperOnlyForHelperSteps() async {
        let executor = FakeRunExecutor()
        let run = Self.controller(executor)
        let gate = HelperGate()
        #expect(run.start(Self.plan([F.formula(), F.cask(), F.mas()]), gate: gate))
        #expect(await waitUntil { !run.isRunning })
        #expect(gate.calls == 0)

        #expect(run.start(Self.plan([F.formula(), F.port()]), gate: gate))
        #expect(await waitUntil { gate.isWaiting })
        gate.open(.enabled)
        #expect(await waitUntil { !run.isRunning })
        #expect(gate.calls == 1)
        #expect(executor.runs.last?.steps == [F.formula(), F.port()])
    }

    @Test func verifierReachesTheExecutor() async {
        let missing: InstalledVerifier = { refs in refs.filter { $0.name == "gone" } }
        let refs = [PackageRef(engine: .homebrew, kind: .formula, name: "gone"),
                    PackageRef(engine: .homebrew, kind: .formula, name: "here")]
        // Without the helper.
        let executor = FakeRunExecutor()
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula()]), verify: missing, ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        // Through the helper check (a MacPorts step).
        #expect(run.start(Self.plan([F.port()]), verify: missing, ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        #expect(executor.verifiers.count == 2)
        for verify in executor.verifiers {
            #expect(await verify(refs).map(\.name) == ["gone"])
        }
        // No verifier passed: fail closed.
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { !run.isRunning })
        let last = executor.verifiers.last
        #expect(await last?(refs).map(\.name) == ["gone", "here"])
    }

    @Test func onRunEndedFiresOnce() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let run = Self.controller(executor)
        var ended = 0
        run.onRunEnded = {
            #expect(!run.isRunning)
            ended += 1
        }
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { ended > 0 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ended == 1)
    }

    @Test func panelStaysUntilDismissedAfterTheRun() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let run = Self.controller(executor)
        #expect(!run.panelVisible)
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(run.panelVisible)
        run.dismissPanel()
        #expect(run.panelVisible)  // no-op mid-run
        run.cancel()
        #expect(await waitUntil { !run.isRunning })
        #expect(run.panelVisible)
        run.dismissPanel()
        #expect(!run.panelVisible)
    }

    // MARK: Quit

    @Test func quitWhileIdleIsImmediate() async {
        let run = Self.controller(FakeRunExecutor())
        #expect(run.quitDecision() == .now)
        #expect(await run.cancelForQuit(bound: .milliseconds(200)))
    }

    @Test func quitMidRunCancelsAndWaitsForDone() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(run.quitDecision() == .confirm)
        // Nothing is timed: the bound only has to outlast a loaded runner (CI took up to 4.3 s for the whole test, near
        // the 10 s default). A run that ignored the cancel still makes it return false.
        #expect(await run.cancelForQuit(bound: .seconds(60)))
        #expect(executor.cancelCount == 1)
        #expect(!run.isRunning)
        #expect(run.log.lines.last?.text == "Done.")
    }

    @Test func quitGivesUpAfterBound() async {
        let executor = StuckExecutor()
        let run = Self.controller(executor)
        #expect(run.start(Self.plan([F.formula()]), ensureHelper: Self.enabled))
        #expect(await waitUntil { run.steps.first?.state == .running })
        let clock = ContinuousClock()
        let began = clock.now
        #expect(await run.cancelForQuit(bound: .milliseconds(200)) == false)
        #expect(clock.now - began >= .milliseconds(200))
        #expect(executor.cancelCount == 1)
        #expect(run.isRunning)
        executor.release()
        #expect(await waitUntil { !run.isRunning })
    }
}

@Suite struct RunStepSymbolTests {
    @Test func everyStateHasItsOwnSpokenLabel() {
        let states: [StepState] = [.waiting, .running, .succeeded, .failed(1), .stopped, .skipped]
        let labels = states.map(RunStepSymbol.label)
        #expect(labels == ["Waiting", "Running", "Done", "Failed", "Stopped", "Skipped"])
        #expect(Set(labels).count == states.count)
    }
}
