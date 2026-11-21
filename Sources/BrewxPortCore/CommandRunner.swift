import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct RunOptions: Sendable {
    /// `nil` uses the runner's base environment; a value replaces it entirely.
    public var environment: [String: String]?
    /// `nil` means no timeout.
    public var timeout: Duration?
    /// Absolute directory the child starts in. `nil` inherits the caller's. A missing directory is `launchFailed`.
    public var workingDirectory: String?
    /// Start the child in a new session with no controlling terminal, instead of only a new process group. For a
    /// child that would otherwise touch the terminal BrewxPort was started from: an interactive shell in a background
    /// process group on that terminal is stopped by SIGTTIN/SIGTTOU and never answers.
    public var newSession: Bool

    public init(environment: [String: String]? = nil, timeout: Duration? = nil, workingDirectory: String? = nil,
                newSession: Bool = false) {
        self.environment = environment
        self.timeout = timeout
        self.workingDirectory = workingDirectory
        self.newSession = newSession
    }
}

/// One complete line of child output, without its trailing newline.
public enum OutputEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(Duration)
    case readFailed(String)
}

public protocol CommandRunning: Sendable {
    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult
    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32
}

extension CommandRunning {
    public func run(_ executable: URL, _ arguments: [String]) async throws -> CommandResult {
        try await run(executable, arguments, options: RunOptions())
    }
}

public struct ProcessRunner: CommandRunning {
    /// A GUI app inherits a minimal launchd PATH, so we pin a known one and
    /// silence Homebrew's interactive behaviour.
    public static let baseEnvironment: [String: String] = {
        var env: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            // No `brew update` of Homebrew itself or its taps behind the user's back...
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            // ...but keep the package data fresh: on its own, NO_AUTO_UPDATE stops Homebrew 7 ever re-downloading
            // it, so `outdated` and `upgrade` would work from the copy fetched the last time brew ran in Terminal.
            // With this, install/outdated/upgrade refresh data older than HOMEBREW_API_AUTO_UPDATE_SECS (450 s).
            "HOMEBREW_FORCE_API_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NONINTERACTIVE": "1",
        ]
        let current = ProcessInfo.processInfo.environment
        for key in ["HOME", "USER"] {
            if let value = current[key] { env[key] = value }
        }
        return env
    }()

    private let environment: [String: String]

    public init(environment: [String: String] = ProcessRunner.baseEnvironment) {
        self.environment = environment
    }

    public func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        let out = DataBox(), err = DataBox()
        let status = try await execute(executable, arguments, options,
                                       onStdout: { out.append($0) }, onStderr: { err.append($0) })
        return CommandResult(
            exitCode: status,
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self))
    }

    public func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                       onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let outLines = LineSplitter { onOutput(.stdout($0)) }
        let errLines = LineSplitter { onOutput(.stderr($0)) }
        let status = try await execute(executable, arguments, options,
                                       onStdout: { outLines.feed($0) }, onStderr: { errLines.feed($0) })
        outLines.flush()
        errLines.flush()
        return status
    }

    /// How long, after a stopped child has exited, to keep waiting for its pipes to close.
    /// A descendant that escaped the child's process group can hold them open indefinitely.
    private static let stopGrace: Double = 2

    private func execute(
        _ executable: URL, _ arguments: [String], _ options: RunOptions,
        onStdout: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void
    ) async throws -> Int32 {
        guard !Task.isCancelled else { throw CancellationError() }

        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else {
            throw CommandRunnerError.launchFailed("\(executable.path): \(String(cString: strerror(errno)))")
        }
        guard pipe(&errFds) == 0 else {
            let reason = String(cString: strerror(errno))
            close(outFds[0]); close(outFds[1])
            throw CommandRunnerError.launchFailed("\(executable.path): \(reason)")
        }

        let control = ProcessControl()
        // The readers own (and close) the read ends.
        let outReader = PipeReader(fd: outFds[0], onData: onStdout, onFailure: { _ in control.stop(.readFailed) })
        let errReader = PipeReader(fd: errFds[0], onData: onStderr, onFailure: { _ in control.stop(.readFailed) })
        // Once a stop is requested (even after the child has exited), stop waiting for the pipes soon.
        control.onFirstStop = {
            outReader.expire(after: Self.stopGrace)
            errReader.expire(after: Self.stopGrace)
        }

        do {
            try control.spawn(
                executable.path, arguments, options.environment ?? environment,
                workingDirectory: options.workingDirectory, newSession: options.newSession,
                stdout: outFds[1], stderr: errFds[1])
        } catch {
            // Drop the write ends so the readers see EOF, then let them finish and close.
            close(outFds[1]); close(errFds[1])
            _ = await outReader.result()
            _ = await errReader.result()
            throw CommandRunnerError.launchFailed("\(executable.path): \(error.localizedDescription)")
        }
        // Drop our copies of the write ends so the readers see EOF when the child (and any descendants) exit.
        close(outFds[1]); close(errFds[1])

        var timer: DispatchWorkItem?
        if let timeout = options.timeout {
            let item = DispatchWorkItem { control.stop(.timedOut) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: item)
            timer = item
        }

        // Cancellation and the timeout stay active through the reader wait: a descendant that
        // still holds a pipe after the child exits must not be able to hang the call. A normal
        // run still waits for full EOF so no output is lost; a stopped one gives up after a grace.
        let (status, outFailure, errFailure) = await withTaskCancellationHandler {
            let status = await control.waitExit()
            let outFailure = await outReader.result()
            let errFailure = await errReader.result()
            return (status, outFailure, errFailure)
        } onCancel: {
            control.stop(.cancelled)
        }
        timer?.cancel()
        let reason = control.stopReason
        if reason != nil { outReader.abandon(); errReader.abandon() }
        // Last use of the pid: kills any remaining group members if stopped, then reaps.
        control.reap()

        switch reason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw CommandRunnerError.timedOut(options.timeout ?? .zero)
        default: break
        }
        if let failure = outFailure ?? errFailure { throw CommandRunnerError.readFailed(failure) }
        return status
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Spawns one child in its own process group (or its own session, which is also its own group) and owns the
/// stop/kill logic. Safe to call from any thread, at any point.
///
/// The child is not reaped until `reap()`, so its pid (which is also the process group id)
/// stays reserved while we may still signal it. Every signal is sent under the lock and only
/// while `reaped` is false, so a recycled pid or group id is never signalled.
private final class ProcessControl: @unchecked Sendable {
    enum Reason { case cancelled, timedOut, readFailed }
    struct SpawnError: Error, LocalizedError {
        let code: Int32
        var errorDescription: String? { String(cString: strerror(code)) }
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var exited = false
    private var exitCode: Int32?
    private var exitWaiter: CheckedContinuation<Int32, Never>?
    private var reason: Reason?
    private var signalled = false
    private var reaped = false
    private var escalation: DispatchWorkItem?
    /// Called once, outside the lock, when the first stop is requested.
    var onFirstStop: (@Sendable () -> Void)?

    var stopReason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return reason
    }

    func spawn(_ path: String, _ arguments: [String], _ environment: [String: String],
               workingDirectory: String?, newSession: Bool, stdout: Int32, stderr: Int32) throws {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if let workingDirectory {
            // Applied in the child before exec; a failed chdir makes posix_spawn fail.
            let rc = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
            if rc != 0 { throw SpawnError(code: rc) }
        }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderr, 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        // Own process group, so we can signal descendants. A new session is also a new group whose id is the child's
        // pid, so killpg(pid) works the same; the two flags are never combined, because setpgid on a session
        // leader fails with EPERM and posix_spawn would fail with it.
        let group: Int32
        if newSession {
            group = Int32(POSIX_SPAWN_SETSID)
        } else {
            posix_spawnattr_setpgroup(&attr, 0)
            group = Int32(POSIX_SPAWN_SETPGROUP)
        }
        // CLOEXEC_DEFAULT: the child gets only fds 0, 1 and 2.
        let flags = group | Int32(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }

        lock.lock()
        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &fileActions, &attr, argv, envp)
        if rc != 0 {
            lock.unlock()
            throw SpawnError(code: rc)
        }
        pid = child
        lock.unlock()

        // Wait for the exit WITHOUT reaping (WNOWAIT): the zombie keeps pid and group id reserved.
        DispatchQueue.global().async { [self] in
            var info = siginfo_t()
            var ok = false
            while true {
                if waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == 0 { ok = true; break }
                if errno != EINTR { break }
            }
            let code: Int32
            if !ok { code = 255 }
            else if info.si_code == CLD_EXITED { code = info.si_status }
            else { code = 128 + info.si_status }  // killed or dumped: si_status is the signal
            lock.lock()
            exited = true
            exitCode = code
            let w = exitWaiter
            exitWaiter = nil
            lock.unlock()
            w?.resume(returning: code)
        }
        // A stop that raced the spawn.
        lock.lock()
        let pending = reason != nil
        lock.unlock()
        if pending { terminate() }
    }

    func waitExit() async -> Int32 {
        await withCheckedContinuation { c in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                c.resume(returning: code)
            } else {
                exitWaiter = c
                lock.unlock()
            }
        }
    }

    func stop(_ why: Reason) {
        lock.lock()
        if reaped { lock.unlock(); return }
        let first = reason == nil
        if first { reason = why }
        let go = pid > 0
        lock.unlock()
        if first { onFirstStop?() }
        if go { terminate() }
    }

    /// SIGTERM now (child and its process group), then SIGCONT so a stopped member (an interactive shell stopped
    /// by SIGTTIN, say) wakes up to handle it; SIGKILL after 5 s unless reaped first.
    private func terminate() {
        lock.lock()
        defer { lock.unlock() }
        if reaped || signalled { return }
        signalled = true
        sendLocked(SIGTERM)
        sendLocked(SIGCONT)
        let item = DispatchWorkItem { [self] in
            lock.lock()
            if !reaped { sendLocked(SIGKILL) }
            lock.unlock()
        }
        escalation = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: item)
    }

    /// Must hold the lock and have checked `!reaped`. The child itself first (a root child such
    /// as sudo relays the signal), then its group; EPERM and ESRCH are fine. While the child is
    /// an unreaped zombie its group id is still ours.
    private func sendLocked(_ sig: Int32) {
        if !exited { kill(pid, sig) }
        killpg(pid, sig)
    }

    /// Ends signalling for good: after a stop, SIGKILLs whatever is left of the group, cancels
    /// the escalation, then reaps the child. The child has exited by the time this is called.
    func reap() {
        lock.lock()
        if reaped || pid == 0 { lock.unlock(); return }
        if reason != nil { killpg(pid, SIGKILL) }
        reaped = true
        escalation?.cancel()
        escalation = nil
        let child = pid
        lock.unlock()
        var st: Int32 = 0
        while waitpid(child, &st, 0) < 0 && errno == EINTR {}
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// Splits a byte stream into lines on \n. `flush()` emits a final unterminated line.
///
/// No emitted line is longer than `maxLineBytes`: a longer line, with or without its newline yet, is emitted in
/// pieces as soon as a piece is full, so a child that writes megabytes without a newline can't grow `pending`
/// (or one log line, or one XPC message from the helper) without bound. Each cut is moved back to a UTF-8
/// character boundary, so a multibyte character is never split across two pieces.
final class LineSplitter: @unchecked Sendable {
    static let maxLineBytes = 65_536

    private let lock = NSLock()
    private var pending = Data()
    private let maxLine: Int
    private let emit: @Sendable (String) -> Void

    init(maxLineBytes: Int = LineSplitter.maxLineBytes, _ emit: @escaping @Sendable (String) -> Void) {
        precondition(maxLineBytes >= 4, "a piece must hold any one UTF-8 character")
        self.maxLine = maxLineBytes
        self.emit = emit
    }

    func feed(_ chunk: Data) {
        lock.lock()
        pending.append(chunk)
        var lines: [String] = []
        while true {
            if let nl = pending.firstIndex(of: 0x0A), nl - pending.startIndex <= maxLine {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            } else if pending.count > maxLine {
                // A full piece and more is waiting with no newline inside the first maxLine bytes.
                let cut = Self.boundary(in: pending, atMost: maxLine)
                lines.append(String(decoding: pending[pending.startIndex..<cut], as: UTF8.self))
                pending.removeSubrange(pending.startIndex..<cut)
            } else {
                break
            }
        }
        lock.unlock()
        for line in lines { emit(line) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if !rest.isEmpty { emit(String(decoding: rest, as: UTF8.self)) }
    }

    /// The index `limit` bytes into `data`, moved back so it doesn't fall before a UTF-8 continuation byte
    /// (`10xxxxxx`). Never moves back more than 3 bytes, so invalid input still makes progress.
    private static func boundary(in data: Data, atMost limit: Int) -> Data.Index {
        let hard = data.startIndex + limit
        var cut = hard
        while cut > hard - 3, data[cut] & 0xC0 == 0x80 { cut -= 1 }
        return cut
    }
}

/// Starts a blocking read-to-EOF on a background queue immediately, so the pipe
/// is drained concurrently with the child process and can never fill and stall it.
/// A read error is reported rather than treated as empty output. Owns `fd` and closes
/// it when the read ends.
final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var abandoned = false
    private var expired = false
    private var failure: String?
    private var waiter: CheckedContinuation<String?, Never>?

    init(fd: Int32, onData: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        DispatchQueue.global().async { [self] in
            var message: String?
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    if !isAbandoned { onData(Data(buffer[0..<n])) }
                } else if n == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    message = String(cString: strerror(errno))
                    break
                }
            }
            close(fd)
            if let message, !isAbandoned { onFailure(message) }
            lock.lock()
            done = true
            failure = message
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: message)
        }
    }

    private var isAbandoned: Bool {
        lock.lock(); defer { lock.unlock() }
        return abandoned
    }

    /// Stops delivering data. The background read ends on its own when the pipe closes.
    func abandon() {
        lock.lock(); abandoned = true; lock.unlock()
    }

    /// After `seconds`, any pending or later `result()` returns immediately (nil) even if the
    /// pipe is still open. Used once a stop was requested and a descendant may hold the pipe.
    func expire(after seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.lock()
            expired = true
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: nil)
        }
    }

    /// Waits for EOF (or expiry). Returns the failure message, or nil on a clean EOF or expiry.
    func result() async -> String? {
        await withCheckedContinuation { c in
            lock.lock()
            if done || expired {
                let f = failure
                lock.unlock()
                c.resume(returning: f)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func finish() async throws {
        if let message = await result() { throw CommandRunnerError.readFailed(message) }
    }
}
