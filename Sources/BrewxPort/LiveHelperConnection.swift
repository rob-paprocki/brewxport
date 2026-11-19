import Foundation
import BrewxPortCore
import BrewxPortRun

/// A helper call that failed for a reason other than the authorization. Its text is what the log shows.
struct LiveHelperError: Error, CustomStringConvertible {
    let description: String

    static func unreachable(_ error: Error) -> LiveHelperError {
        LiveHelperError(description: "Couldn't reach BrewxPort's helper: \(error.localizedDescription)")
    }
}

/// The app's end of the BrewxPortHelper XPC connection.
///
/// - One `NSXPCConnection` to `brewxPortHelperMachService` with `.privileged`, made on first use and dropped when it's
///   invalidated or interrupted, so the next call reconnects. Its code-signing requirement pins the helper
///   (`identifier "com.brewxport.helper"` and this app's own team), so nothing else answering on the Mach service is
///   ever talked to.
/// - Every call goes through `remoteObjectProxyWithErrorHandler`, and every continuation through `Once`, so an
///   invalidated connection fails the call instead of hanging, and the reply, the error handler and
///   cancellation can't resume twice.
/// - `authorize` asks the helper's version first, within `BrewxPortTimeouts.helperCall`, and refuses a helper whose
///   version isn't the bundled one. That call launches the helper, which installs the `com.brewxport.run`
///   definition at start (R8/R18), before `AppAuthorization.acquire` asks authd for the right. `acquire` blocks
///   in authd, so it runs on a private dispatch queue, never on Swift's cooperative pool.
final class LiveHelperConnection: HelperConnecting, VersionReporting, @unchecked Sendable {
    private let helperRequirement: String
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let sink = OutputSink()
    private let authorization = AppAuthorization()
    private let authorizationQueue = DispatchQueue(label: "com.brewxport.app.authorization")

    /// `helperRequirement` is `CodeIdentity.requirement(identifier: CodeIdentity.helperIdentifier, team:)`.
    init(helperRequirement: String) {
        self.helperRequirement = helperRequirement
    }

    deinit {
        lock.withLock { connection }?.invalidate()
    }

    // MARK: VersionReporting

    func helperVersion() async throws -> Int {
        let connection = current()
        let once = Once<Int>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                guard let helper = proxy(connection, once) else { return }
                helper.version { once.resume(.success($0)) }
            }
        } onCancel: {
            once.resume(.failure(CancellationError()))
        }
    }

    func resetConnection() {
        let dropped: NSXPCConnection? = lock.withLock {
            defer { connection = nil }
            return connection
        }
        // Outside the lock: invalidating runs the invalidation handler, which takes the lock in `forget`.
        dropped?.invalidate()
    }

    /// Asks the helper's version, bounded by `BrewxPortTimeouts.helperCall`, and throws unless it's the bundled one.
    /// A helper that never answers or is out of date fails the helper steps with a clear message instead of
    /// hanging the run or running an old helper.
    private func checkVersion() async throws {
        let installed: Int
        do {
            installed = try await firstResult(within: BrewxPortTimeouts.helperCall) { [self] in try await helperVersion() }
        } catch let timedOut as CallTimedOut {
            throw LiveHelperError(description:
                "BrewxPort's helper didn't answer within \(timedOut.timeout.components.seconds) seconds. Click Check again.")
        }
        guard HelperCompatibility.check(installed: installed, bundled: brewxPortHelperVersion) else {
            throw LiveHelperError(description: "BrewxPort's helper is out of date. Click Check again.")
        }
    }

    // MARK: HelperConnecting

    func authorize(_ secret: SecretBuffer) async throws -> Data {
        try await checkVersion()
        let authorization = self.authorization
        return try await withCheckedThrowingContinuation { continuation in
            authorizationQueue.async {
                continuation.resume(with: Result { try authorization.acquire(secret) })
            }
        }
    }

    func endAuthorization() async {
        let authorization = self.authorization
        await withCheckedContinuation { continuation in
            authorizationQueue.async {
                authorization.end()
                continuation.resume()
            }
        }
    }

    /// Output order: the helper sends each line to our exported `OutputSink` and replies only after `port` has
    /// exited and its last line was sent, all on this one connection. NSXPC delivers a connection's incoming
    /// messages, exported-object calls and reply blocks alike, in order on that connection's serial queue, so by
    /// the time the reply block runs every line before it has already gone through `onOutput`. Nothing is
    /// buffered here, so there's nothing left to drain when this returns.
    ///
    /// Cancelling the calling task invalidates the connection. The helper sees that and kills `port` (its
    /// whole process group); the call ends with `CancellationError`.
    func runPort(authorization: Data, arguments: [String],
                 onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let connection = current()
        sink.attach(onOutput)
        defer { sink.detach() }
        let once = Once<(Int32, String?)>()
        let (code, text) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.install(continuation)
                guard let helper = proxy(connection, once) else { return }
                helper.runPort(authorization: authorization, arguments: arguments) { code, text in
                    once.resume(.success((code, text)))
                }
            }
        } onCancel: { [handle = ConnectionHandle(connection: connection)] in
            handle.connection.invalidate()
            once.resume(.failure(CancellationError()))
        }
        guard let text, code == -1 else { return code }
        // The helper's refusal text for an expired or missing right is `HelperError.notAuthorized.message`
        // (HelperService.refusal); RunSession re-authorizes once on that error.
        if text == HelperError.notAuthorized.message { throw HelperError.notAuthorized }
        throw LiveHelperError(description: text)
    }

    // MARK: Connection

    private func current() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(machServiceName: brewxPortHelperMachService, options: .privileged)
            made.remoteObjectInterface = HelperInterfaces.helper()
            made.exportedInterface = HelperInterfaces.client()
            made.exportedObject = sink
            made.setCodeSigningRequirement(helperRequirement)
            let id = ObjectIdentifier(made)
            made.invalidationHandler = { [weak self] in self?.forget(id) }
            // The helper went away (crashed, or launchd restarted it). Pending calls get their error handlers;
            // start the next call on a fresh connection.
            made.interruptionHandler = { [weak self] in self?.forget(id, invalidate: true) }
            made.resume()
            connection = made
            return made
        }
    }

    private func forget(_ id: ObjectIdentifier, invalidate: Bool = false) {
        let dropped: NSXPCConnection? = lock.withLock {
            guard let connection, ObjectIdentifier(connection) == id else { return nil }
            self.connection = nil
            return connection
        }
        if invalidate { dropped?.invalidate() }
    }

    private func proxy<T>(_ connection: NSXPCConnection, _ once: Once<T>) -> BrewxPortHelperProtocol? {
        let object = connection.remoteObjectProxyWithErrorHandler { error in
            once.resume(.failure(LiveHelperError.unreachable(error)))
        }
        guard let helper = object as? BrewxPortHelperProtocol else {
            once.resume(.failure(LiveHelperError(description: "BrewxPort's helper connection has the wrong interface.")))
            return nil
        }
        return helper
    }
}

/// `NSXPCConnection` is thread-safe (invalidate may be called from anywhere) but not marked `Sendable`.
private struct ConnectionHandle: @unchecked Sendable {
    let connection: NSXPCConnection
}

/// The exported `BrewxPortHelperClientProtocol` object: hands each output line to the current run's `onOutput`.
final class OutputSink: NSObject, BrewxPortHelperClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (OutputEvent) -> Void)?

    func attach(_ handler: @escaping @Sendable (OutputEvent) -> Void) { lock.withLock { self.handler = handler } }
    func detach() { lock.withLock { handler = nil } }

    func output(line: String, isError: Bool) {
        let handler = lock.withLock { self.handler }
        handler?(isError ? .stderr(line) : .stdout(line))
    }
}

/// Resumes a continuation exactly once. A result that arrives before the continuation is installed (a task
/// cancelled before the call started) is kept and delivered on install.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let ready: Result<T, Error>? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(with: ready) }
    }

    func resume(_ result: Result<T, Error>) {
        let target: CheckedContinuation<T, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            guard let continuation else {
                early = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        target?.resume(with: result)
    }
}
