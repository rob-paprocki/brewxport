import Foundation
import BrewxPortCore
import Synchronization
import Testing
@testable import BrewxPortRun

private final class FakeService: DaemonService {
    private let state: Mutex<(status: DaemonStatus, calls: [String])>
    /// Status after register() succeeds.
    let statusAfterRegister: DaemonStatus
    /// When set, register() throws it (after recording the call).
    let registerError: (any Error)?
    /// The status after register() throws; nil leaves it unchanged.
    let statusAfterThrow: DaemonStatus?
    /// When set, unregister() throws it (after recording the call and changing nothing).
    let unregisterError: (any Error)?
    /// How long register() blocks before the status changes, so concurrent callers overlap.
    let registerDelay: TimeInterval
    init(_ status: DaemonStatus, afterRegister: DaemonStatus = .enabled, registerError: (any Error)? = nil,
         afterThrow: DaemonStatus? = nil, unregisterError: (any Error)? = nil, registerDelay: TimeInterval = 0) {
        state = Mutex((status, []))
        self.registerDelay = registerDelay
        statusAfterRegister = afterRegister
        self.registerError = registerError
        statusAfterThrow = afterThrow
        self.unregisterError = unregisterError
    }
    var calls: [String] { state.withLock { $0.calls } }
    var status: DaemonStatus { state.withLock { $0.status } }
    func register() throws {
        let after = statusAfterRegister
        state.withLock { $0.calls.append("register") }
        if registerDelay > 0 { Thread.sleep(forTimeInterval: registerDelay) }
        if let registerError {
            if let statusAfterThrow { state.withLock { $0.status = statusAfterThrow } }
            throw registerError
        }
        state.withLock { $0.status = after }
    }
    func unregister() async throws {
        state.withLock { $0.calls.append("unregister") }
        if let unregisterError { throw unregisterError }
        state.withLock { $0.status = .notRegistered }
    }
    func openSystemSettingsLoginItems() { state.withLock { $0.calls.append("open") } }
}

private final class FakeConnection: HelperConnecting, VersionReporting {
    /// `neverUntilReset(v)`: never answers on the first connection; answers `v` once the connection was reset.
    enum Mode: Sendable { case version(Int), fail, never, neverUntilReset(Int) }
    let mode: Mode
    let asked = Mutex(0)
    let resets = Mutex(0)
    init(_ mode: Mode) { self.mode = mode }
    func resetConnection() { resets.withLock { $0 += 1 } }
    func helperVersion() async throws -> Int {
        asked.withLock { $0 += 1 }
        switch mode {
        case .version(let v): return v
        case .fail: throw HelperError.notAuthorized
        case .neverUntilReset(let v) where resets.withLock({ $0 }) > 0: return v
        case .never, .neverUntilReset:
            // Never replies, and ignores cancellation on purpose.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 0
        }
    }
    func authorize(_ secret: SecretBuffer) async throws -> Data { Data() }
    func runPort(authorization: Data, arguments: [String],
                 onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 { 0 }
    func setUpEngine(authorization: Data, target: SetupTarget,
                     onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 { 0 }
    func endAuthorization() async {}
}

@Suite struct HelperRegistrationTests {
    @Test func unapprovedHelperReportsRequiresApproval() async throws {
        let service = FakeService(.requiresApproval)
        let connection = FakeConnection(.version(brewxPortHelperVersion))
        let registration = HelperRegistration(service: service, connection: connection)
        #expect(await registration.refresh() == .requiresApproval)
        #expect(connection.asked.withLock { $0 } == 0)
        #expect(await registration.ensureRegistered() == .requiresApproval)
        #expect(service.calls.isEmpty)
        registration.openLoginItems()
        #expect(service.calls == ["open"])
    }

    @Test func reRegistersOnVersionMismatch() async throws {
        let service = FakeService(.enabled)
        let connection = FakeConnection(.version(brewxPortHelperVersion - 1))
        let registration = HelperRegistration(service: service, connection: connection)
        #expect(await registration.refresh() == .outdated)
        _ = await registration.ensureRegistered()
        #expect(service.calls == ["unregister", "register"])
    }

    @Test func matchingVersionIsEnabled() async throws {
        let service = FakeService(.enabled)
        let registration = HelperRegistration(service: service, connection: FakeConnection(.version(brewxPortHelperVersion)))
        #expect(await registration.ensureRegistered() == .enabled)
        #expect(service.calls.isEmpty)
    }

    @Test func notRegisteredRegisters() async throws {
        let service = FakeService(.notRegistered)
        let registration = HelperRegistration(service: service, connection: FakeConnection(.version(brewxPortHelperVersion)))
        #expect(await registration.ensureRegistered() == .enabled)
        #expect(service.calls == ["register"])
        let needs = FakeService(.notRegistered, afterRegister: .requiresApproval)
        let r2 = HelperRegistration(service: needs, connection: FakeConnection(.fail))
        #expect(await r2.ensureRegistered() == .requiresApproval)
    }

    @Test func notFoundMeansNotRegistered() async {
        let registration = HelperRegistration(service: FakeService(.notFound), connection: FakeConnection(.fail))
        #expect(await registration.refresh() == .notRegistered)
    }

    @Test func unknownStatusIsFailed() async {
        let registration = HelperRegistration(service: FakeService(.unknown), connection: FakeConnection(.fail))
        #expect(await registration.refresh() == .failed("Unknown helper status"))
    }

    @Test func notFoundRegistersThenRefreshes() async throws {
        let service = FakeService(.notFound, afterRegister: .requiresApproval)
        let registration = HelperRegistration(service: service, connection: FakeConnection(.fail))
        #expect(await registration.ensureRegistered() == .requiresApproval)
        #expect(service.calls == ["register"])
    }

    @Test func registerFailureReportsFailed() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "plist missing" } }
        let service = FakeService(.notFound, registerError: Boom())
        let registration = HelperRegistration(service: service, connection: FakeConnection(.fail))
        let state = await registration.ensureRegistered()
        guard case .failed(let message) = state else { Issue.record("expected .failed, got \(state)"); return }
        #expect(message.contains("plist missing"))
        #expect(service.calls == ["register"])
    }

    /// First launch (spike: before approval, register() throws "Operation not permitted" and the status becomes
    /// requiresApproval). The window must offer "Open Login Items", not report a failure.
    @Test func firstLaunchRegisterThrowsThenRequiresApproval() async {
        let eperm = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM),
                            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        let service = FakeService(.notFound, registerError: eperm, afterThrow: .requiresApproval)
        let registration = HelperRegistration(service: service, connection: FakeConnection(.fail))
        #expect(await registration.ensureRegistered() == .requiresApproval)
        #expect(service.calls == ["register"])
    }

    @Test func registerThrowsButHelperIsEnabledReportsEnabled() async {
        struct Boom: Error {}
        let service = FakeService(.notRegistered, registerError: Boom(), afterThrow: .enabled)
        let registration = HelperRegistration(service: service, connection: FakeConnection(.version(brewxPortHelperVersion)))
        #expect(await registration.ensureRegistered() == .enabled)
    }

    @Test func failedReRegisters() async {
        // .unknown status reads as .failed; ensureRegistered unregisters, registers and reads the status again.
        let service = FakeService(.unknown, afterRegister: .enabled)
        let connection = FakeConnection(.version(brewxPortHelperVersion))
        let registration = HelperRegistration(service: service, connection: connection)
        #expect(await registration.refresh() == .failed("Unknown helper status"))
        #expect(await registration.ensureRegistered() == .enabled)
        #expect(service.calls == ["unregister", "register"])
        #expect(connection.resets.withLock { $0 } >= 1)
    }

    @Test func failedReRegistersEvenWhenUnregisterThrows() async {
        struct Stuck: Error {}
        let service = FakeService(.unknown, afterRegister: .requiresApproval, unregisterError: Stuck())
        let registration = HelperRegistration(service: service, connection: FakeConnection(.fail))
        #expect(await registration.ensureRegistered() == .requiresApproval)
        #expect(service.calls == ["unregister", "register"])
    }

    @Test(.timeLimit(.minutes(1))) func timeoutThenFreshConnectionSucceedsWithoutUnregister() async {
        // A cold launch: the first version call times out, the retry on a fresh connection answers.
        let service = FakeService(.enabled)
        let connection = FakeConnection(.neverUntilReset(brewxPortHelperVersion))
        // The retry's answer has to beat its own fresh timer, so give it 1 s: a loaded CI runner has delayed
        // in-process work by up to 1.65 s, and 200 ms only won by queue order.
        let registration = HelperRegistration(service: service, connection: connection,
                                              bundledVersion: brewxPortHelperVersion, timeout: .seconds(1))
        #expect(await registration.ensureRegistered() == .enabled)
        #expect(service.calls.isEmpty)
        #expect(connection.resets.withLock { $0 } == 1)
        #expect(connection.asked.withLock { $0 } == 2)
    }

    @Test func failedStaysFailedWithoutUnregister() async {
        // Enabled and approved, but the helper won't answer even on a fresh connection: report it, don't touch it.
        let service = FakeService(.enabled)
        let connection = FakeConnection(.fail)
        let registration = HelperRegistration(service: service, connection: connection)
        guard case .failed = await registration.ensureRegistered() else { Issue.record("expected .failed"); return }
        #expect(service.calls.isEmpty)
        #expect(service.status == .enabled)
        #expect(connection.asked.withLock { $0 } == 2)
        #expect(HelperStateDisplay.offersReinstall(.failed("x")))
        #expect(!HelperStateDisplay.offersReinstall(.enabled))
        #expect(!HelperStateDisplay.offersReinstall(nil))
    }

    @Test func reinstallUnregistersAndRegisters() async {
        let service = FakeService(.enabled, afterRegister: .enabled)
        let connection = FakeConnection(.version(brewxPortHelperVersion))
        let registration = HelperRegistration(service: service, connection: connection)
        #expect(await registration.reinstall() == .enabled)
        #expect(service.calls == ["unregister", "register"])
        #expect(connection.resets.withLock { $0 } == 2)
    }

    @Test func reRegisteringDropsTheOldConnection() async {
        let service = FakeService(.enabled)
        let connection = FakeConnection(.version(brewxPortHelperVersion - 1))
        let registration = HelperRegistration(service: service, connection: connection)
        _ = await registration.ensureRegistered()
        // After unregister and again after register, before the version is asked of the new helper.
        #expect(connection.resets.withLock { $0 } == 2)
    }

    @Test func versionErrorIsFailed() async {
        let registration = HelperRegistration(service: FakeService(.enabled), connection: FakeConnection(.fail))
        guard case .failed = await registration.refresh() else { Issue.record("expected .failed"); return }
    }

    @Test(.timeLimit(.minutes(1))) func versionCallTimesOut() async {
        // The production timeout is pinned here, and a short one is timed below, so the test doesn't wait 5 s.
        #expect(HelperRegistration.defaultTimeout == BrewxPortTimeouts.helperCall)
        let registration = HelperRegistration(service: FakeService(.enabled), connection: FakeConnection(.never),
                                              bundledVersion: brewxPortHelperVersion, timeout: .milliseconds(200))
        let start = ContinuousClock.now
        let state = await registration.refresh()
        let elapsed = ContinuousClock.now - start
        guard case .failed = state else { Issue.record("expected .failed, got \(state)"); return }
        // Guards against waiting for a call that never answers (a hang, cut off at the 60 s time limit); CI took
        // up to 2.3 s for the same 200 ms firstResult timeout.
        #expect(elapsed < .seconds(11))
    }

    @Test func concurrentEnsureRegisteredRegistersOnce() async {
        let service = FakeService(.notRegistered, registerDelay: 0.2)
        let connection = FakeConnection(.version(brewxPortHelperVersion))
        let registration = HelperRegistration(service: service, connection: connection)
        async let first = registration.ensureRegistered()
        async let second = registration.ensureRegistered()
        let (a, b) = await (first, second)
        #expect(service.calls == ["register"])
        #expect(a == .enabled)
        #expect(a == b)
    }
}
