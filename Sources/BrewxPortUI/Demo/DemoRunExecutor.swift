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
    private let runs = Mutex<[UUID: Task<Void, Never>]>([:])

    /// `delay` is the pause before each output line. Tests pass `.zero`.
    public init(provider: PromptPasswordProvider, inventory: DemoInventory, delay: Duration = .milliseconds(400)) {
        self.provider = provider
        self.inventory = inventory
        self.delay = delay
    }

    public func run(_ steps: [RunStep], reason: String) -> AsyncStream<RunEvent> {
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream()
        let id = UUID()
        let task = runs.withLock { runs in
            let task = Task { [self] in
                await execute(steps, reason: reason) { continuation.yield($0) }
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

    private func execute(_ steps: [RunStep], reason: String, emit: @escaping @Sendable (RunEvent) -> Void) async {
        switch await perform(steps, reason: reason, emit) {
        case .done: break
        case .rejected: emit(.passwordRejected)
        case .cancelled: emit(.cancelled)
        }
        emit(.done)
    }

    private func perform(_ steps: [RunStep], reason: String,
                         _ emit: @escaping @Sendable (RunEvent) -> Void) async -> Ending {
        if steps.contains(where: { RunRouting.route(for: $0) != .user }) {
            emit(.needsPassword)
            guard let secret = await provider.password(reason: reason) else { return .cancelled }
            let empty = secret.withBytes { $0.isEmpty }
            secret.wipe()
            if empty { return .rejected }
        }
        for (index, step) in steps.enumerated() {
            if Task.isCancelled { return .cancelled }
            emit(.started(index))
            for line in Self.lines(for: step) {
                do { try await Task.sleep(for: delay) } catch { return .cancelled }
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
