import Foundation
import BrewxPortCore
import BrewxPortRun
import Testing
@testable import BrewxPortUI

/// Captured engine output shared with the Core tests.
enum UIFixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // BrewxPortUITests
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("BrewxPortCoreTests/Fixtures")
}

/// `CommandRunning` with canned responses keyed by argv (arguments only). Unknown argv exits 127.
final class UIFakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[String]: CommandResult]
    private var _calls: [[String]] = []
    private var _options: [RunOptions] = []
    private var _executables: [URL] = []
    /// Runs before each call returns, with its argv. Use it to delay, block or throw.
    var block: (@Sendable ([String]) async throws -> Void)?

    init(_ responses: [[String]: CommandResult] = [:]) { self.responses = responses }

    func respond(_ argv: [String], _ result: CommandResult) { lock.withLock { responses[argv] = result } }

    var calls: [[String]] { lock.withLock { _calls } }
    var optionsCalls: [RunOptions] { lock.withLock { _options } }
    var executables: [URL] { lock.withLock { _executables } }

    private func record(_ executable: URL, _ arguments: [String], _ options: RunOptions) -> CommandResult {
        lock.withLock {
            _executables.append(executable)
            _calls.append(arguments)
            _options.append(options)
            return responses[arguments] ?? CommandResult(exitCode: 127, stdout: "", stderr: "unknown command")
        }
    }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        let result = record(executable, arguments, options)
        try await block?(arguments)
        return result
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let result = record(executable, arguments, options)
        try await block?(arguments)
        for line in result.stdout.split(separator: "\n") { onOutput(.stdout(String(line))) }
        for line in result.stderr.split(separator: "\n") { onOutput(.stderr(String(line))) }
        return result.exitCode
    }
}

/// A language engine whose every step runs as the user, with settable answers for what Task 10b reads: where it writes
/// and whether this account can (`readOnlyReason`), the runtimes its tools run on, its repair steps (`repair <tool>`,
/// or one `repair-all` when `repairsOneAtATime` is false) and its tools' commands. Its commands are
/// `<verb> <names>` at `/opt/homebrew/bin/<id>`.
final class FakeLanguageEngine: Engine, InstallLocationReporting, RuntimeReporting, ToolRepairing, ExecutableNaming,
                                @unchecked Sendable {
    let id: EngineID
    let capabilities: EngineCapabilities = []
    private let lock = NSLock()
    private var _installLocation: URL?
    private var _binLocation: URL?
    private var _readOnlyReason: String?
    private var _uses: Result<[RuntimeUse], EngineError> = .success([])
    private var _commands: [String: [String]] = [:]
    private var _usesAsked = 0
    private var _refusals: [String: String] = [:]
    let repairsOneAtATime: Bool
    /// Like a real language engine's `LanguageTool`: no executable until a detect has finished (R44).
    private let executableOnlyOnceDetected: Bool
    private var _detected = false

    init(_ id: EngineID, installLocation: URL? = nil, binLocation: URL? = nil, readOnlyReason: String? = nil,
         uses: [RuntimeUse] = [], commands: [String: [String]] = [:], repairsOneAtATime: Bool = false,
         executableOnlyOnceDetected: Bool = false) {
        self.id = id
        _installLocation = installLocation
        _binLocation = binLocation
        _readOnlyReason = readOnlyReason
        _uses = .success(uses)
        _commands = commands
        self.repairsOneAtATime = repairsOneAtATime
        self.executableOnlyOnceDetected = executableOnlyOnceDetected
    }

    var installLocation: URL? { lock.withLock { _installLocation } }
    var binLocation: URL? { lock.withLock { _binLocation } }
    var readOnlyReason: String? {
        get { lock.withLock { _readOnlyReason } }
        set { lock.withLock { _readOnlyReason = newValue } }
    }
    /// What `runtimeUses()` answers.
    var uses: Result<[RuntimeUse], EngineError> {
        get { lock.withLock { _uses } }
        set { lock.withLock { _uses = newValue } }
    }
    /// How often `runtimeUses()` was asked.
    var usesAsked: Int { lock.withLock { _usesAsked } }
    /// Tools `repairCommands` leaves out, with why (`repairRefusals`).
    var refusals: [String: String] {
        get { lock.withLock { _refusals } }
        set { lock.withLock { _refusals = newValue } }
    }

    var executableURL: URL? {
        guard !executableOnlyOnceDetected || lock.withLock({ _detected }) else { return nil }
        return URL(fileURLWithPath: "/opt/homebrew/bin/\(id.rawValue)")
    }

    /// When set, `detect()` answers only once it's released (a login shell that doesn't answer), or gives up, still
    /// undetected, when its task is cancelled (the catalog's timer), as a real engine's command ends.
    var detectGate: Gate? {
        get { lock.withLock { _detectGate } }
        set { lock.withLock { _detectGate = newValue } }
    }
    private var _detectGate: Gate?

    func detect() async -> EngineStatus {
        if let gate = detectGate {
            await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.release() }
            if Task.isCancelled { return .unusable(path: URL(fileURLWithPath: "/"), reason: "cancelled") }
        }
        lock.withLock { _detected = true }
        return .present(path: executableURL!, version: "1")
    }
    func search(_ query: String) async throws -> [Package] { [] }
    func listInstalled() async throws -> [Package] { [] }
    func listOutdated() async throws -> [Package] { [] }
    func info(_ ref: PackageRef) async throws -> PackageDetails { PackageDetails(ref: ref) }
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        if let reason = readOnlyReason { throw EngineError(engine: id, message: reason) }
        let verb: String
        switch op {
        case .install: verb = "install"
        case .upgrade: verb = "upgrade"
        case .remove: verb = "uninstall"
        case .repair, .markRequested, .markDependency: throw EngineError(engine: id, message: "no")
        }
        return CommandSpec(executable: executableURL!, arguments: [verb] + refs.map(\.name), needsRoot: false)
    }

    /// When set, `runtimeUses()` answers only once it's released.
    var usesGate: Gate? {
        get { lock.withLock { _usesGate } }
        set { lock.withLock { _usesGate = newValue } }
    }
    private var _usesGate: Gate?

    func runtimeUses() async throws -> [RuntimeUse] {
        let (answer, gate) = lock.withLock { () -> (Result<[RuntimeUse], EngineError>, Gate?) in
            _usesAsked += 1
            return (_uses, _usesGate)
        }
        if let gate { await gate.wait() }
        return try answer.get()
    }

    func repairCommands(for tools: [String]) throws -> [RepairCommand] {
        if let reason = readOnlyReason { throw EngineError(engine: id, message: reason) }
        guard repairsOneAtATime else {
            return [RepairCommand(tool: nil, spec: CommandSpec(executable: executableURL!, arguments: ["repair-all"],
                                                               needsRoot: false))]
        }
        guard !tools.isEmpty else { throw EngineError(engine: id, message: "nothing to repair") }
        let refused = refusals
        return Set(tools).subtracting(refused.keys).sorted().map {
            RepairCommand(tool: $0, spec: CommandSpec(executable: executableURL!, arguments: ["repair", $0],
                                                      needsRoot: false))
        }
    }

    func repairRefusals(for tools: [String]) -> [String: String] { refusals.filter { tools.contains($0.key) } }

    func executables(of name: String) -> [String]? { lock.withLock { _commands[name] } }
}

/// `RunExecuting` that replays scripted events.
final class FakeRunExecutor: RunExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RunEvent]
    private var _hang: Bool
    private var _cancelCount = 0
    private var _runs: [(steps: [RunStep], reason: String)] = []
    private var _verifiers: [InstalledVerifier] = []
    private var continuation: AsyncStream<RunEvent>.Continuation?

    /// `hang`: after the scripted events the stream stays open until `cancel()` (which ends it with
    /// `.cancelled` then `.done`).
    init(events: [RunEvent] = [.done], hang: Bool = false) {
        _events = events
        _hang = hang
    }

    var events: [RunEvent] {
        get { lock.withLock { _events } }
        set { lock.withLock { _events = newValue } }
    }
    var hang: Bool {
        get { lock.withLock { _hang } }
        set { lock.withLock { _hang = newValue } }
    }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var runs: [(steps: [RunStep], reason: String)] { lock.withLock { _runs } }
    /// The verifier each run got, in the order of `runs`.
    var verifiers: [InstalledVerifier] { lock.withLock { _verifiers } }

    /// When set, each run first asks its verifier about every check step, as a real run would, then replays the events.
    var asksVerifier: Bool {
        get { lock.withLock { _asksVerifier } }
        set { lock.withLock { _asksVerifier = newValue } }
    }
    private var _asksVerifier = false

    func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent> {
        let (events, hang, asks) = lock.withLock { () -> ([RunEvent], Bool, Bool) in
            _runs.append((steps, reason))
            _verifiers.append(verify)
            return (_events, _hang, _asksVerifier)
        }
        if asks {
            let checks = steps.compactMap(\.verifyInstalled)
            return AsyncStream { continuation in
                Task {
                    for refs in checks { _ = await verify(refs) }
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                }
            }
        }
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            if hang {
                lock.withLock { self.continuation = continuation }
            } else {
                continuation.finish()
            }
        }
    }

    func cancel() {
        let pending = lock.withLock { () -> AsyncStream<RunEvent>.Continuation? in
            _cancelCount += 1
            defer { continuation = nil }
            return continuation
        }
        pending?.yield(.cancelled)
        pending?.yield(.done)
        pending?.finish()
    }

    /// Ends a hanging run the way it would end on its own: yields `events`, then finishes its stream. Later runs
    /// still hang while `hang` is set.
    func finish(_ events: [RunEvent] = [.done]) {
        let pending = lock.withLock { () -> AsyncStream<RunEvent>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        for event in events { pending?.yield(event) }
        pending?.finish()
    }
}

/// Holds async work until the test releases it, so a test orders events without racing sleeps. `release()` lets
/// go of the callers waiting at that moment; wait for `waiting` to reach the count you expect before releasing.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.withLock { waiters.append(waiter) }
        }
    }

    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

/// `PackageQuerying` with scripted outcomes per query. A query can delay or hang per engine.
final class FakeCatalog: PackageQuerying, @unchecked Sendable {
    struct Script: Sendable {
        var result: Result<[Package], EngineError>
        /// An outdated check's packages that couldn't be checked, and its held updates (`EngineOutcome`).
        var unchecked = UncheckedPackages.none
        var held: [HeldUpdate] = []
        var delay: Duration = .zero
        /// Answers only once the gate is released. With `timeout`, the timeout's wait starts only then.
        var gate: Gate?
        /// Never answers (until the consumer stops iterating).
        var hang = false
        /// Hangs, then after this long answers the way `PackageCatalog` does when an engine runs out its time:
        /// "<Engine> didn't answer within 60 seconds".
        var timeout: Duration?
    }

    struct InfoScript: Sendable {
        var result: Result<PackageDetails, EngineError>
        var delay: Duration = .zero
        var hang = false
    }

    private let lock = NSLock()
    private var _engines: [EngineID: EngineStatus]
    private var scripts: [String: [EngineID: Script]] = [:]
    private var infoScripts: [PackageRef: InfoScript] = [:]
    private var _queries: [CatalogQuery] = []
    private var _infoCalls: [PackageRef] = []
    private var _taps: Result<[String], EngineError> = .success([])

    /// What `installedTaps()` answers.
    var taps: Result<[String], EngineError> {
        get { lock.withLock { _taps } }
        set { lock.withLock { _taps = newValue } }
    }

    private static func key(_ query: CatalogQuery) -> String { String(describing: query) }

    init(engines: [EngineID: EngineStatus] = [:]) { _engines = engines }

    func setEngines(_ engines: [EngineID: EngineStatus]) { lock.withLock { _engines = engines } }

    func script(_ query: CatalogQuery, _ engine: EngineID, _ script: Script) {
        lock.withLock { scripts[Self.key(query), default: [:]][engine] = script }
    }

    func script(_ query: CatalogQuery, _ engine: EngineID, packages: [Package], delay: Duration = .zero) {
        script(query, engine, Script(result: .success(packages), delay: delay))
    }

    /// Scripts `query` to answer with no engine outcomes at all, unless it's already scripted (a later `script` call
    /// still adds engines to it).
    func scriptEmpty(_ query: CatalogQuery) {
        lock.withLock { scripts[Self.key(query), default: [:]] = scripts[Self.key(query)] ?? [:] }
    }

    func scriptInfo(_ ref: PackageRef, _ script: InfoScript) {
        lock.withLock { infoScripts[ref] = script }
    }

    var queries: [CatalogQuery] { lock.withLock { _queries } }
    var infoCalls: [PackageRef] { lock.withLock { _infoCalls } }

    private var _enginesAsked = 0
    private var _enginesGate: Gate?

    /// How often `presentEngines()` was asked.
    var enginesAsked: Int { lock.withLock { _enginesAsked } }
    /// When set, `presentEngines()` reads the engines at once but answers only once the gate is released (a check
    /// still going after the engines changed).
    var enginesGate: Gate? {
        get { lock.withLock { _enginesGate } }
        set { lock.withLock { _enginesGate = newValue } }
    }

    func presentEngines() async -> [EngineID: EngineStatus] {
        let (answer, gate) = lock.withLock { () -> ([EngineID: EngineStatus], Gate?) in
            _enginesAsked += 1
            return (_engines, _enginesGate)
        }
        if let gate { await gate.wait() }
        return answer
    }

    func stream(_ query: CatalogQuery) -> AsyncStream<EngineOutcome> {
        let plan = lock.withLock { () -> [EngineID: Script]? in
            _queries.append(query)
            return scripts[Self.key(query)]
        }
        // A query no test scripted is a bug in the test or the code under test, never a silent empty answer. A
        // query that should come back empty is scripted with `scriptEmpty(_:)`.
        if plan == nil { Issue.record("FakeCatalog: unscripted query \(query)") }
        let engines = plan ?? [:]
        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for (engine, script) in engines {
                        group.addTask {
                            if script.hang {
                                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                                return
                            }
                            if let timeout = script.timeout {
                                if let gate = script.gate { await gate.wait() }
                                try? await Task.sleep(for: timeout)
                                guard !Task.isCancelled else { return }
                                let message = "\(engine.displayName) didn't answer within 60 seconds"
                                continuation.yield(EngineOutcome(engine: engine,
                                                                 result: .failure(EngineError(engine: engine, message: message))))
                                return
                            }
                            if script.delay > .zero { try? await Task.sleep(for: script.delay) }
                            if let gate = script.gate { await gate.wait() }
                            guard !Task.isCancelled else { return }
                            continuation.yield(EngineOutcome(engine: engine, result: script.result,
                                                             unchecked: script.unchecked, held: script.held))
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func installedTaps() async throws -> [String] { try taps.get() }

    func info(_ ref: PackageRef) async throws -> PackageDetails {
        let script = lock.withLock { () -> InfoScript? in
            _infoCalls.append(ref)
            return infoScripts[ref]
        }
        guard let script else { throw EngineError(engine: ref.engine, message: "no scripted info") }
        if script.hang {
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
            throw CancellationError()
        }
        if script.delay > .zero { try await Task.sleep(for: script.delay) }
        return try script.result.get()
    }
}

/// `HelperManaging` with scripted states and call counts. Each call returns the next state; the last repeats.
final class FakeHelperManager: HelperManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var refreshStates: [HelperState]
    private var ensureStates: [HelperState]
    private var reinstallStates: [HelperState]
    private var _refreshCount = 0, _ensureCount = 0, _reinstallCount = 0, _openCount = 0
    private var _holdEnsure = false
    private var ensureWaiters: [CheckedContinuation<Void, Never>] = []

    init(refresh: [HelperState] = [.enabled], ensure: [HelperState] = [.enabled],
         reinstall: [HelperState] = [.enabled]) {
        refreshStates = refresh
        ensureStates = ensure
        reinstallStates = reinstall
    }

    var refreshCount: Int { lock.withLock { _refreshCount } }
    var ensureCount: Int { lock.withLock { _ensureCount } }
    var reinstallCount: Int { lock.withLock { _reinstallCount } }
    var openCount: Int { lock.withLock { _openCount } }

    private static func next(_ states: inout [HelperState]) -> HelperState {
        states.count > 1 ? states.removeFirst() : (states.first ?? .notRegistered)
    }

    func refresh() async -> HelperState {
        lock.withLock { _refreshCount += 1; return Self.next(&refreshStates) }
    }
    func ensureRegistered() async -> HelperState {
        let state = lock.withLock { _ensureCount += 1; return Self.next(&ensureStates) }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let held = lock.withLock { () -> Bool in
                if _holdEnsure { ensureWaiters.append(waiter) }
                return _holdEnsure
            }
            if !held { waiter.resume() }
        }
        return state
    }

    /// While true, `ensureRegistered()` doesn't answer until `releaseEnsure()`.
    var holdEnsure: Bool {
        get { lock.withLock { _holdEnsure } }
        set { lock.withLock { _holdEnsure = newValue } }
    }

    func releaseEnsure() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _holdEnsure = false
            defer { ensureWaiters = [] }
            return ensureWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func reinstall() async -> HelperState {
        lock.withLock { _reinstallCount += 1; return Self.next(&reinstallStates) }
    }
    func openLoginItems() { lock.withLock { _openCount += 1 } }
}

/// `PasswordPrompting` that answers with a scripted password (nil cancels) and records the reasons.
@MainActor final class FakePrompter: PasswordPrompting {
    var password: String?
    private(set) var reasons: [String] = []
    private(set) var retries: [Bool] = []

    init(password: String? = nil) { self.password = password }

    func askForPassword(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer? {
        reasons.append(reason)
        retries.append(previousAttemptFailed)
        guard let password else { return nil }
        return SecretBuffer(copying: Array(password.utf8))
    }
}

// MARK: Background seams

/// `BackgroundScheduling` that keeps the schedule and runs it only when a test calls `fire()`.
@MainActor final class FakeScheduler: BackgroundScheduling {
    /// The current schedule's interval; nil when there's none.
    private(set) var interval: TimeInterval?
    /// How long after scheduling the current schedule's first run is due; nil when there's none.
    private(set) var firstDelay: TimeInterval?
    private(set) var work: (@MainActor () async -> Void)?
    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0

    func schedule(every seconds: TimeInterval, firstAfter delay: TimeInterval,
                  _ work: @escaping @MainActor () async -> Void) {
        scheduleCount += 1
        interval = seconds
        firstDelay = delay
        self.work = work
    }

    func cancel() {
        cancelCount += 1
        interval = nil
        firstDelay = nil
        work = nil
    }

    /// Runs the scheduled work once, as the system would when the interval is up.
    func fire() async { await work?() }
}

/// `UpdateNotifying` that answers `requestPermission()` with `permission` and keeps every post.
@MainActor final class FakeNotifier: UpdateNotifying {
    struct Post: Equatable {
        let id: String
        let title: String
        let body: String
        let target: NotificationTarget
    }

    var permission: Bool
    private(set) var permissionRequests = 0
    private(set) var posts: [Post] = []
    var onOpen: (@MainActor (NotificationTarget, String) -> Void)?

    init(permission: Bool = true) { self.permission = permission }

    func requestPermission() async -> Bool {
        permissionRequests += 1
        return permission
    }

    func post(id: String, title: String, body: String, target: NotificationTarget) {
        posts.append(Post(id: id, title: title, body: body, target: target))
    }

    /// The person clicks a notification with this target (and an id no post had).
    func click(_ target: NotificationTarget) { onOpen?(target, "") }

    /// The person clicks this post.
    func click(_ post: Post) { onOpen?(post.target, post.id) }
}

/// `LoginItemControlling` with a settable system state. `setEnabled` throws `error` when it's set (and then changes
/// nothing); otherwise it sets `isEnabled`, or, with `approvalNeededOnRegister`, registers it waiting for approval.
@MainActor final class FakeLoginItem: LoginItemControlling {
    var isEnabled: Bool
    var needsApproval: Bool
    var error: (any Error)?
    /// Registering leaves the item waiting for the person's approval in System Settings, not enabled.
    var approvalNeededOnRegister = false
    private(set) var changes: [Bool] = []

    init(isEnabled: Bool = false, needsApproval: Bool = false) {
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        changes.append(enabled)
        if let error { throw error }
        let waits = enabled && approvalNeededOnRegister
        isEnabled = enabled && !waits
        needsApproval = waits
    }
}

/// `SystemConditions` a test sets. `idleSeconds` is the time since the last input; `change()` sends `onChange`.
@MainActor final class FakeConditions: SystemConditions {
    var idleSeconds: TimeInterval = 0
    var screenLocked = false
    var batteryLow = false
    var lowPowerMode = false
    var onChange: (@MainActor () -> Void)?

    func userIsActive(within seconds: TimeInterval) -> Bool { idleSeconds < seconds }

    /// The system reports a change (lock, unlock, wake, power).
    func change() { onChange?() }
}
