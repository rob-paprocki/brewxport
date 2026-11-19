import Foundation
import Synchronization

/// The call didn't answer within the time `firstResult(within:_:)` allowed it.
public struct CallTimedOut: Error, Equatable, Sendable {
    public let timeout: Duration
    public init(timeout: Duration) { self.timeout = timeout }
}

/// Returns `operation`'s result, or throws `CallTimedOut` when `timeout` passes first, whichever happens first.
///
/// The operation runs in an unstructured task that is cancelled but never awaited, so an operation that ignores
/// cancellation (an XPC call to a helper that never replies) can't hold the caller up. Cancelling the caller ends
/// the wait at once with `CancellationError`.
public func firstResult<T: Sendable>(within timeout: Duration,
                                     _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = FirstResultRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let call = Task {
                do { race.finish(.success(try await operation())) }
                catch { race.finish(.failure(error)) }
            }
            race.setCall(call)
            Task {
                try? await Task.sleep(for: timeout)
                race.finish(.failure(CallTimedOut(timeout: timeout)))
                call.cancel()
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
        race.cancelCall()
    }
}

/// Resumes its continuation exactly once, for whichever result arrives first. A result that arrives before the
/// continuation is installed (the caller was already cancelled) is kept and delivered on install.
private final class FirstResultRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Error>?
        var early: Result<T, Error>?
        var finished = false
        var call: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func install(_ c: CheckedContinuation<T, Error>) {
        let ready = state.withLock { s -> Result<T, Error>? in
            if let early = s.early { s.early = nil; return early }
            s.continuation = c
            return nil
        }
        if let ready { c.resume(with: ready) }
    }

    func setCall(_ call: Task<Void, Never>) {
        let cancelNow = state.withLock { s -> Bool in
            s.call = call
            return s.finished
        }
        if cancelNow { call.cancel() }
    }

    func cancelCall() {
        state.withLock { $0.call }?.cancel()
    }

    func finish(_ result: Result<T, Error>) {
        let target = state.withLock { s -> CheckedContinuation<T, Error>? in
            guard !s.finished else { return nil }
            s.finished = true
            guard let c = s.continuation else {
                s.early = result
                return nil
            }
            s.continuation = nil
            return c
        }
        target?.resume(with: result)
    }
}
