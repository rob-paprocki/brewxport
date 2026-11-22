import Foundation
import BrewxPortCore
@testable import BrewxPortRun

/// One recorded runner call.
struct RunnerCall: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]?
    let streamed: Bool
}

/// Scriptable `CommandRunning` for RunSession tests. Responses are keyed by the full argv (executable path first);
/// anything unknown exits 0 with no output. A `blocking` argv waits until the task is cancelled, then throws
/// `CancellationError`, the way `ProcessRunner` does after killing the child.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Response: Sendable {
        var code: Int32 = 0
        var stdout: [String] = []
        var stderr = ""
        var error: CommandRunnerError?
    }

    private let lock = NSLock()
    private var responses: [[String]: Response] = [:]
    private var onceResponses: [[String]: [Response]] = [:]
    private var blocking: Set<[String]> = []
    private var _calls: [RunnerCall] = []
    private var startedBlocking: [CheckedContinuation<Void, Never>] = []
    private var didStartBlocking = false
    private var _onStream: (@Sendable (Int) async -> Void)?
    private var streamCount = 0

    /// Called with each stream call's index (0 for the first) before that call returns.
    var onStream: (@Sendable (Int) async -> Void)? {
        get { lock.withLock { _onStream } }
        set { lock.withLock { _onStream = newValue } }
    }

    func respond(_ argv: [String], code: Int32 = 0, stdout: [String] = [], stderr: String = "",
                 error: CommandRunnerError? = nil) {
        lock.withLock { responses[argv] = Response(code: code, stdout: stdout, stderr: stderr, error: error) }
    }

    /// A response used once, before any `respond` one for the same argv. Several queue up in order.
    func respondOnce(_ argv: [String], code: Int32 = 0, stdout: [String] = [], stderr: String = "") {
        lock.withLock { onceResponses[argv, default: []].append(Response(code: code, stdout: stdout, stderr: stderr)) }
    }

    func block(_ argv: [String]) { _ = lock.withLock { blocking.insert(argv) } }

    var calls: [RunnerCall] { lock.withLock { _calls } }
    var streamedCalls: [RunnerCall] { calls.filter(\.streamed) }

    /// Returns once a blocking call has started.
    func waitForBlockingCall() async {
        await withCheckedContinuation { c in
            let now = lock.withLock { () -> Bool in
                if didStartBlocking { return true }
                startedBlocking.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        let response = record(executable, arguments, options, streamed: false)
        if let error = response.error { throw error }
        return CommandResult(exitCode: response.code, stdout: response.stdout.joined(separator: "\n"),
                             stderr: response.stderr)
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let argv = [executable.path] + arguments
        let response = record(executable, arguments, options, streamed: true)
        let (hook, index) = lock.withLock { () -> ((@Sendable (Int) async -> Void)?, Int) in
            defer { streamCount += 1 }
            return (_onStream, streamCount)
        }
        if let hook { await hook(index) }
        if lock.withLock({ blocking.contains(argv) }) {
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                didStartBlocking = true
                defer { startedBlocking = [] }
                return startedBlocking
            }
            waiters.forEach { $0.resume() }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        if let error = response.error { throw error }
        for line in response.stdout { onOutput(.stdout(line)) }
        return response.code
    }

    private func record(_ executable: URL, _ arguments: [String], _ options: RunOptions, streamed: Bool) -> Response {
        lock.withLock {
            _calls.append(RunnerCall(executable: executable, arguments: arguments,
                                     environment: options.environment, streamed: streamed))
            let argv = [executable.path] + arguments
            if var queued = onceResponses[argv], !queued.isEmpty {
                let first = queued.removeFirst()
                onceResponses[argv] = queued
                return first
            }
            return responses[argv] ?? Response()
        }
    }
}

/// Scriptable `HelperConnecting`. `authorizeResults` and `runResults` are consumed in order; when empty,
/// authorize succeeds and runPort exits 0.
final class FakeHelper: HelperConnecting, @unchecked Sendable {
    enum RunResult { case code(Int32), fail(Error) }

    static let token = Data(repeating: 0xA5, count: 32)

    private let lock = NSLock()
    var authorizeResults: [Error?] {
        get { lock.withLock { _authorizeResults } }
        set { lock.withLock { _authorizeResults = newValue } }
    }
    var runResults: [RunResult] {
        get { lock.withLock { _runResults } }
        set { lock.withLock { _runResults = newValue } }
    }
    var setupResults: [RunResult] {
        get { lock.withLock { _setupResults } }
        set { lock.withLock { _setupResults = newValue } }
    }
    private var _setupResults: [RunResult] = []
    private var _setupCalls: [(authorization: Data, target: SetupTarget)] = []
    var setupCalls: [(authorization: Data, target: SetupTarget)] { lock.withLock { _setupCalls } }
    private var _authorizeResults: [Error?] = []
    private var _runResults: [RunResult] = []
    private var _authorizeCalls = 0
    private var _runCalls: [(authorization: Data, arguments: [String])] = []
    private var _endCalls = 0
    private var _secretsSeen: [[UInt8]] = []

    var authorizeCalls: Int { lock.withLock { _authorizeCalls } }
    var runCalls: [(authorization: Data, arguments: [String])] { lock.withLock { _runCalls } }
    var endCalls: Int { lock.withLock { _endCalls } }
    var secretsSeen: [[UInt8]] { lock.withLock { _secretsSeen } }

    func authorize(_ secret: SecretBuffer) async throws -> Data {
        let bytes = secret.withBytes { Array($0) }
        let result = lock.withLock { () -> Error? in
            _authorizeCalls += 1
            _secretsSeen.append(bytes)
            return _authorizeResults.isEmpty ? nil : _authorizeResults.removeFirst()
        }
        if let result { throw result }
        return Self.token
    }

    func runPort(authorization: Data, arguments: [String],
                 onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let result = lock.withLock { () -> RunResult in
            _runCalls.append((authorization, arguments))
            return _runResults.isEmpty ? .code(0) : _runResults.removeFirst()
        }
        switch result {
        case .code(let code):
            onOutput(.stdout("port \(arguments.joined(separator: " "))"))
            return code
        case .fail(let error): throw error
        }
    }

    func setUpEngine(authorization: Data, target: SetupTarget,
                     onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let result = lock.withLock { () -> RunResult in
            _setupCalls.append((authorization, target))
            return _setupResults.isEmpty ? .code(0) : _setupResults.removeFirst()
        }
        switch result {
        case .code(let code):
            onOutput(.stdout("set up \(target.rawValue)"))
            return code
        case .fail(let error): throw error
        }
    }

    func endAuthorization() async {
        lock.withLock { _endCalls += 1 }
    }
}

/// Hands out scripted answers in order, the last one again once they run out (nil: the user cancelled). Counts
/// calls and records each call's `previousAttemptFailed`.
final class FakePasswords: PasswordProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String?]
    private var _calls = 0
    private var _given: [SecretBuffer] = []
    private var _reasons: [String] = []
    private var _retries: [Bool] = []
    private var _earlierWiped: [Bool] = []
    private var _onAsk: (@Sendable () -> Bool)?

    init(_ password: String?) { answers = [password] }
    init(answers: [String?]) { self.answers = answers }

    var calls: Int { lock.withLock { _calls } }
    /// Every `reason` the session asked with, in order.
    var reasons: [String] { lock.withLock { _reasons } }
    /// Every buffer handed to the session, so tests can check it was wiped.
    var given: [SecretBuffer] { lock.withLock { _given } }
    /// Each call's `previousAttemptFailed`, in order.
    var retries: [Bool] { lock.withLock { _retries } }
    /// For each call: whether every buffer handed out before it had been wiped by then.
    var earlierWiped: [Bool] { lock.withLock { _earlierWiped } }
    /// Called at the start of each ask; its answers are kept in `onAskResults`.
    var onAsk: (@Sendable () -> Bool)? {
        get { lock.withLock { _onAsk } }
        set { lock.withLock { _onAsk = newValue } }
    }
    private var _onAskResults: [Bool] = []
    var onAskResults: [Bool] { lock.withLock { _onAskResults } }

    func password(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer? {
        if let hook = onAsk {
            let result = hook()
            lock.withLock { _onAskResults.append(result) }
        }
        return lock.withLock {
            _calls += 1
            _reasons.append(reason)
            _retries.append(previousAttemptFailed)
            _earlierWiped.append(_given.allSatisfy(\.isWiped))
            let password = answers.count > 1 ? answers.removeFirst() : answers.first ?? nil
            guard let password else { return nil }
            let buffer = SecretBuffer(copying: Array(password.utf8))
            _given.append(buffer)
            return buffer
        }
    }
}

/// An askpass server that never listens; records `stop()`.
final class FakeAskpassServer: AskpassServing, @unchecked Sendable {
    let environment: [String: String] = [
        "SUDO_ASKPASS": "/fake/brewxport-askpass",
        "HOMEBREW_BREWXPORT_ASKPASS_SOCKET": "/tmp/brewxport-fake/askpass.sock",
        "HOMEBREW_BREWXPORT_ASKPASS_NONCE": String(repeating: "ab", count: 32),
    ]
    private let lock = NSLock()
    private var _stops = 0
    var stops: Int { lock.withLock { _stops } }
    func stop() { lock.withLock { _stops += 1 } }
}

/// Collects a stream's events.
func collect(_ stream: AsyncStream<RunEvent>) async -> [RunEvent] {
    var events: [RunEvent] = []
    for await event in stream { events.append(event) }
    return events
}

/// Polls until `condition` holds or about 5 s pass.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
