import Foundation
import BrewxPortCore

/// The PATH the user's login shell sets up, which decides whose copy of a command runs when several engines
/// installed it. A GUI app doesn't inherit it, so BrewxPort asks the shell once.
///
/// The one recorded exception to "argument arrays, never shell strings": the shell runs `-i -l -c <script>` (an
/// interactive login shell, as Terminal opens, so PATH lines in .zshrc count too), where the script is a constant
/// compiled into BrewxPort with nothing interpolated into it. It starts from a plain login environment (the system
/// PATH, the user's identity, SHELL), never BrewxPort's own PATH or Homebrew settings. Only the text between the markers
/// counts, so rc-file banners and stderr don't matter.
///
/// The shell starts in a new session with no controlling terminal. When BrewxPort itself was started from a terminal
/// (`arch -x86_64 …/BrewxPort`, a `.command` file), an interactive shell on that terminal would sit in a background
/// process group and be stopped by SIGTTIN before it answered.
///
/// The answer counts as soon as the line with the end marker arrives. BrewxPort doesn't wait for the shell to exit or
/// for its output to close, which a background job started from an rc file can hold open; the shell is stopped then.
///
/// A shell that isn't listed in /etc/shells or isn't a POSIX shell (sh, bash, zsh, dash, ksh), doesn't answer in
/// time or prints no usable PATH gets the system PATH instead, with a note saying why.
///
/// An actor so the answer is cached: resolved once per launch, the first time Installed loads. A shell that didn't
/// answer in time is the exception: the next call (the next Refresh) asks it again.
public actor LoginShellPath: PathResolving {
    public static let markers = ("__BREWXPORT_PATH_BEGIN__", "__BREWXPORT_PATH_END__")
    /// The shell's whole argument list.
    public static let arguments = ["-i", "-l", "-c", "printf '%s%s%s\\n' __BREWXPORT_PATH_BEGIN__ \"$PATH\" __BREWXPORT_PATH_END__"]

    static let unlistedNote =
        "Based on the system PATH: your login shell isn't zsh, bash or another shell listed in /etc/shells."
    static let unusableNote = "Based on the system PATH: your login shell didn't print a usable PATH."
    static func notPosixNote(_ shell: String) -> String {
        "Based on the system PATH: BrewxPort asks only sh, bash, zsh, dash or ksh for the PATH, and your login shell is "
            + URL(fileURLWithPath: shell).lastPathComponent + "."
    }
    /// The shells whose `-i -l -c` and `$PATH` BrewxPort knows how to read.
    static let posixShells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]
    /// The PATH the shell starts from, before /etc/zprofile's path_helper and the user's files add to it.
    static let startingPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static func timeoutNote(_ timeout: Duration) -> String {
        "Based on the system PATH: your login shell " + BrewxPortTimeouts.didntAnswer(within: timeout) + "."
    }
    /// What `systemPaths(etc:)` gives when /etc/paths can't be read.
    static let fallbackSystemPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let runner: any CommandRunning
    private nonisolated let shell: String?
    private nonisolated let allowedShells: Set<String>
    private let systemPaths: @Sendable () -> [String]
    private let timeout: Duration
    private let processEnvironment: [String: String]
    private let newSession: Bool
    private var answer: Task<Answer, Never>?

    /// What one question to the shell gave, and whether a later call should ask again.
    struct Answer: Sendable {
        var path: ResolvedPath
        var askAgain = false
    }

    /// runner: the live ProcessRunner (BrewxPort target passes it). shell: the user's pw_shell, used only if it's
    /// listed in /etc/shells. systemPaths: reads /etc/paths and /etc/paths.d/* (what path_helper does).
    /// The timeout is passed to the runner AND raced with Core's `firstResult(within:)`, so a runner that ignores
    /// it still can't hang Installed. processEnvironment: where HOME, USER, LOGNAME, LANG and TMPDIR come from.
    /// newSession: always true in BrewxPort; false only for `brewxport-smoke login-path --same-session`, which
    /// Tests/scripts/test-login-shell.sh uses to show the probe hangs on a terminal without it.
    public init(runner: any CommandRunning, shell: String?, allowedShells: Set<String>,
                systemPaths: @escaping @Sendable () -> [String], timeout: Duration = BrewxPortTimeouts.loginShell,
                processEnvironment: [String: String] = ProcessInfo.processInfo.environment, newSession: Bool = true) {
        self.processEnvironment = processEnvironment
        self.newSession = newSession
        self.runner = runner
        self.shell = shell
        self.allowedShells = allowedShells
        self.systemPaths = systemPaths
        self.timeout = timeout
    }

    /// The login shell the PATH comes from: the user's pw_shell when it's listed in /etc/shells, else nil.
    public nonisolated var loginShell: String? {
        guard let shell, !shell.isEmpty, allowedShells.contains(shell) else { return nil }
        return shell
    }

    /// Drops the cached answer: the next call asks the shell again.
    public func forget() async { answer = nil }

    /// The first call asks the shell; every later call (and any call made while the first is waiting) gets the
    /// same answer, unless the shell didn't answer in time: then the next call asks again.
    public func resolve() async -> ResolvedPath {
        if let answer { return await answer.value.path }
        let runner = runner, shell = shell, allowed = allowedShells, systemPaths = systemPaths, timeout = timeout
        let environment = processEnvironment, newSession = newSession
        let task = Task {
            await Self.ask(runner: runner, shell: shell, allowed: allowed, systemPaths: systemPaths, timeout: timeout,
                           environment: environment, newSession: newSession)
        }
        answer = task
        let result = await task.value
        // Only forget this task's own answer: a call that came in meanwhile may already have started another.
        if result.askAgain, answer == task { answer = nil }
        return result.path
    }

    private static func ask(runner: any CommandRunning, shell: String?, allowed: Set<String>,
                            systemPaths: @Sendable () -> [String], timeout: Duration,
                            environment: [String: String], newSession: Bool) async -> Answer {
        func fallback(_ note: String, askAgain: Bool = false) -> Answer {
            Answer(path: ResolvedPath(entries: systemPaths(), source: .systemDefault, note: note), askAgain: askAgain)
        }
        guard let shell, !shell.isEmpty, allowed.contains(shell) else { return fallback(unlistedNote) }
        guard posixShells.contains(URL(fileURLWithPath: shell).lastPathComponent) else {
            return fallback(notPosixNote(shell))
        }
        let options = RunOptions(environment: shellEnvironment(shell: shell, from: environment), timeout: timeout,
                                 newSession: newSession)
        let output: String
        do {
            // The runner kills the shell's whole process group when its timeout passes.
            output = try await firstResult(within: timeout) {
                try await untilEndMarker(runner: runner, shell: shell, options: options)
            }
        } catch is CallTimedOut {
            return fallback(timeoutNote(timeout), askAgain: true)
        } catch CommandRunnerError.timedOut {
            return fallback(timeoutNote(timeout), askAgain: true)
        } catch {
            return fallback(unusableNote)
        }
        guard let entries = entries(in: output) else { return fallback(unusableNote) }
        return Answer(path: ResolvedPath(entries: entries, source: .loginShell))
    }

    /// The shell's stdout up to and including the first line that completes the markers, or all of it when the
    /// shell ends without one. The shell is stopped (in the background, never awaited) once the answer is in.
    private static func untilEndMarker(runner: any CommandRunning, shell: String,
                                       options: RunOptions) async throws -> String {
        let watch = MarkerWatch()
        let run = Task {
            do {
                _ = try await runner.stream(URL(fileURLWithPath: shell), arguments, options: options) { event in
                    if case .stdout(let line) = event { watch.add(line) }
                }
                watch.ended(nil)
            } catch {
                watch.ended(error)
            }
        }
        defer { run.cancel() }
        return try await withTaskCancellationHandler {
            try await watch.answer()
        } onCancel: {
            run.cancel()
        }
    }

    /// What the shell starts with, like a Terminal window: the system PATH, the user's identity and SHELL set to the
    /// login shell. Nothing else from BrewxPort's environment (its pinned PATH, Homebrew settings) reaches it.
    static func shellEnvironment(shell: String, from environment: [String: String]) -> [String: String] {
        var result = ["PATH": startingPath, "SHELL": shell, "LANG": environment["LANG"] ?? "en_US.UTF-8"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = environment[key], !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// The PATH between the markers, split on colons, with empty entries (a stray ':') dropped. Nil without both
    /// markers, when nothing is left, or when any entry isn't absolute.
    static func entries(in output: String) -> [String]? {
        guard let begin = output.range(of: markers.0),
              let end = output.range(of: markers.1, range: begin.upperBound..<output.endIndex) else { return nil }
        let entries = output[begin.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
        guard !entries.isEmpty, entries.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        return entries
    }

    /// Collects the shell's stdout lines and hands the text over once the end marker arrives or the shell ends.
    private final class MarkerWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var result: Result<String, Error>?
        private var waiter: CheckedContinuation<String, Error>?

        func add(_ line: String) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            text += line + "\n"
            let done = line.contains(markers.1) && entries(in: text) != nil
            lock.unlock()
            if done { finish(.success(text)) }
        }

        /// The stream ended: with an error, or (nil) normally, when the text so far is the whole answer.
        func ended(_ error: Error?) {
            lock.lock()
            let all = text
            lock.unlock()
            finish(error.map { .failure($0) } ?? .success(all))
        }

        private func finish(_ value: Result<String, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(with: value)
        }

        func answer() async throws -> String {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let result {
                    lock.unlock()
                    c.resume(with: result)
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        }
    }

    // MARK: Reading /etc (read-only)

    /// /etc/paths, then each file in /etc/paths.d in name order, one directory per line, the way path_helper
    /// builds the system PATH. Repeats are dropped. Nothing readable gives /usr/bin, /bin, /usr/sbin, /sbin.
    public static func systemPaths(etc: URL = URL(fileURLWithPath: "/etc")) -> [String] {
        var files = [etc.appendingPathComponent("paths")]
        let pathsD = etc.appendingPathComponent("paths.d")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pathsD.path)) ?? []
        files += names.sorted().map { pathsD.appendingPathComponent($0) }
        var seen = Set<String>()
        var entries: [String] = []
        for file in files {
            for line in lines(file) where line.hasPrefix("/") && seen.insert(line).inserted {
                entries.append(line)
            }
        }
        return entries.isEmpty ? fallbackSystemPaths : entries
    }

    /// The shells listed in /etc/shells, without comments and blank lines.
    public static func allowedShells(etc: URL = URL(fileURLWithPath: "/etc")) -> Set<String> {
        Set(lines(etc.appendingPathComponent("shells")).filter { $0.hasPrefix("/") })
    }

    /// The current user's login shell from the user database (pw_shell); nil when there's none.
    public static func userShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let text = String(cString: shell)
        return text.isEmpty ? nil : text
    }

    private static func lines(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
