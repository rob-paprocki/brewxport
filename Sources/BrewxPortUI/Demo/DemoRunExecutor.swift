import Foundation
import BrewxPortCore
import BrewxPortRun
import Synchronization

/// Plays a run without running anything.
///
/// When any step would need root it emits `.needsPassword` and asks the provider once. Any non-empty password is
/// accepted and wiped at once; an empty one is rejected and nothing runs. Each step then emits `.started`, two output
/// lines `delay` apart and `.finished(i, 0)`, and changes the inventory the way the step would have. Cancelling
/// (through `cancel()` or by dropping the stream) stops after the current output line with `.cancelled`. Every run
/// ends with `.done`.
public final class DemoRunExecutor: RunExecuting {
    public static let note = "(demo mode: nothing was changed on this Mac)"

    private let provider: PromptPasswordProvider
    private let inventory: DemoInventory
    private let delay: Duration
    private let pause: Pause
    private let runs = Mutex<[UUID: Task<Void, Never>]>([:])

    /// Waits out `delay` before an output line, and throws once the run is cancelled.
    typealias Pause = @Sendable (Duration) async throws -> Void
    /// What the app pauses with.
    static let taskSleep: Pause = { try await Task.sleep(for: $0) }

    /// `delay` is the pause before each output line. Tests pass `.zero`.
    public convenience init(provider: PromptPasswordProvider, inventory: DemoInventory,
                            delay: Duration = .milliseconds(400)) {
        self.init(provider: provider, inventory: inventory, delay: delay, pause: Self.taskSleep)
    }

    /// `pause` replaces the sleep, so a test can hold a line until it cancels the run instead of racing a timer.
    init(provider: PromptPasswordProvider, inventory: DemoInventory, delay: Duration, pause: @escaping Pause) {
        self.provider = provider
        self.inventory = inventory
        self.delay = delay
        self.pause = pause
    }

    public func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let id = UUID()
        let task = runs.withLock { runs in
            let task = Task { [self] in
                await execute(steps, reason: reason, verify: verify) { continuation.yield($0) }
                continuation.finish()
                _ = self.runs.withLock { $0.removeValue(forKey: id) }
            }
            runs[id] = task
            return task
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel() {
        for task in runs.withLock({ Array($0.values) }) { task.cancel() }
    }

    /// The two lines a simulated step prints.
    static func lines(for step: RunStep) -> [String] {
        let command = ([step.spec.executable.lastPathComponent] + step.spec.arguments).joined(separator: " ")
        return ["Simulated: \(command)", note]
    }

    private enum Ending { case done, rejected, cancelled }

    private func execute(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier,
                         emit: @escaping @Sendable (RunEvent) -> Void) async {
        switch await perform(steps, reason: reason, verify: verify, emit) {
        case .done: break
        case .rejected: emit(.passwordRejected)
        case .cancelled: emit(.cancelled)
        }
        emit(.done)
    }

    private func perform(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier,
                         _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending {
        if steps.contains(where: { RunRouting.route(for: $0) != .user }) {
            emit(.needsPassword)
            guard let secret = await provider.password(reason: reason, previousAttemptFailed: false) else {
                return .cancelled
            }
            let empty = secret.withBytes { $0.isEmpty }
            secret.wipe()
            if empty { return .rejected }
        }
        var allEarlierSucceeded = true
        var failedGroups: Set<String> = []
        var checksPassed: Bool?
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            // Demo steps all succeed, so only a failed check stops a gated step: a step with a `gateGroup` waits only
            // on its own group, as in RunSession.
            let earlierFailed = step.gateGroup.map { failedGroups.contains($0) } ?? !allEarlierSucceeded
            if (step.requiresAllEarlier && earlierFailed) || (step.requiresPassedCheck && checksPassed != true) {
                allEarlierSucceeded = false
                if let group = step.gateGroup { failedGroups.insert(group) }
                continue
            }
            emit(.started(index))
            if let refs = step.verifyInstalled {
                // Asks the app, as RunSession does, and prints no "Simulated" line: a check runs nothing. A check
                // over no packages fails, as in RunSession.
                let missing = refs.isEmpty ? [] : await verify(refs)
                if Task.isCancelled { return .cancelled }
                let passed = !refs.isEmpty && missing.isEmpty
                if !missing.isEmpty {
                    let names = missing.map(\.name).joined(separator: ", ")
                    emit(.output(index, .stderr("Not found on \(step.engine.displayName): \(names)")))
                }
                if !passed {
                    allEarlierSucceeded = false
                    if let group = step.gateGroup { failedGroups.insert(group) }
                }
                checksPassed = passed && checksPassed != false
                emit(.finished(index, passed ? 0 : 1))
                continue
            }
            for line in Self.lines(for: step) {
                do { try await pause(delay) } catch { return .cancelled }
                if Task.isCancelled { return .cancelled }
                emit(.output(index, .stdout(line)))
            }
            if Task.isCancelled { return .cancelled }
            await inventory.apply(step)
            emit(.finished(index, 0))
        }
        return .done
    }
}
