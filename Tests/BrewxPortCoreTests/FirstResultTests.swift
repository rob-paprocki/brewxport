import Foundation
import Testing
@testable import BrewxPortCore

@Suite struct FirstResultTests {
    @Test func returnsTheResult() async throws {
        #expect(try await firstResult(within: .seconds(5)) { 42 } == 42)
    }

    @Test func passesTheOperationsErrorThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await firstResult(within: .seconds(5)) { () async throws -> Int in throw Boom() } }
    }

    @Test(.timeLimit(.minutes(1))) func timesOutEvenWhenTheOperationIgnoresCancellation() async {
        let start = ContinuousClock.now
        await #expect(throws: CallTimedOut(timeout: .milliseconds(200))) {
            try await firstResult(within: .milliseconds(200)) { () async -> Int in
                // Never returns, and ignores cancellation on purpose (an XPC call to a helper that never replies).
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 0
            }
        }
        // Guards against waiting for the operation (a hang, cut off at the 60 s time limit); CI took up to 2.3 s here.
        #expect(ContinuousClock.now - start < .seconds(11))
    }

    @Test(.timeLimit(.minutes(1))) func cancellingTheCallerEndsTheWait() async {
        let waiter = Task {
            try await firstResult(within: .seconds(30)) { () async -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 0
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        waiter.cancel()
        let result = await waiter.result
        // Guards against waiting for the 30 s timeout (or the operation); CI took up to 2.2 s here.
        #expect(ContinuousClock.now - start < .seconds(8))
        guard case .failure(let error) = result else { Issue.record("expected a failure"); return }
        #expect(error is CancellationError)
    }
}
