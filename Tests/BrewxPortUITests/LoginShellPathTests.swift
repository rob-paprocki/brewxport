import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

/// Every test runs against a fake runner; no real shell is ever started.
@Suite struct LoginShellPathTests {
    static let shell = "/bin/zsh"
    static let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let argv = ["-i", "-l", "-c", "printf '%s%s%s\\n' __BREWXPORT_PATH_BEGIN__ \"$PATH\" __BREWXPORT_PATH_END__"]

    /// What the app's own process environment would hold (BrewxPort's pinned PATH and Homebrew settings included).
    static let processEnvironment = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": "/Users/someone", "USER": "someone", "LOGNAME": "someone", "LANG": "de_DE.UTF-8",
        "TMPDIR": "/var/folders/xy/T/", "HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1", "SHELL": "/bin/sh",
    ]

    static func resolver(_ runner: UIFakeRunner, shell: String? = shell, allowed: Set<String> = [shell],
                         timeout: Duration = BrewxPortTimeouts.loginShell) -> LoginShellPath {
        LoginShellPath(runner: runner, shell: shell, allowedShells: allowed, systemPaths: { Self.system },
                       timeout: timeout, processEnvironment: Self.processEnvironment)
    }

    static func runner(stdout: String, exitCode: Int32 = 0) -> UIFakeRunner {
        UIFakeRunner([argv: CommandResult(exitCode: exitCode, stdout: stdout, stderr: "")])
    }

    @Test func loginShellPathParsesBetweenMarkers() async {
        let runner = Self.runner(stdout: "Welcome!\n__BREWXPORT_PATH_BEGIN__/opt/homebrew/bin:/usr/bin__BREWXPORT_PATH_END__\n")
        let resolved = await Self.resolver(runner).resolve()
        #expect(resolved == ResolvedPath(entries: ["/opt/homebrew/bin", "/usr/bin"], source: .loginShell))
        #expect(resolved.note == nil)
    }

    @Test func loginShellNoiseIgnored() async {
        let noise = "Last login: Tue Nov 17 on ttys001\nPATH=/nope\n"
            + "__BREWXPORT_PATH_BEGIN__/opt/local/bin:/opt/homebrew/bin:/bin__BREWXPORT_PATH_END__\n"
            + "logout banner /also/not/a/path\n"
        let resolved = await Self.resolver(Self.runner(stdout: noise)).resolve()
        #expect(resolved.entries == ["/opt/local/bin", "/opt/homebrew/bin", "/bin"])
        #expect(resolved.source == .loginShell)
    }

    @Test func hungLoginShellFallsBack() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/opt/homebrew/bin__BREWXPORT_PATH_END__\n")
        // Blocks for 3 s and ignores both the timeout it was given and cancellation.
        runner.block = { _ in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done.resume() }
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let resolved = await Self.resolver(runner, timeout: .milliseconds(200)).resolve()
        #expect(clock.now - start < .seconds(1))
        #expect(resolved.source == .systemDefault)
        #expect(resolved.entries == Self.system)
        #expect(runner.optionsCalls.map(\.timeout) == [.milliseconds(200)])
        #expect(resolved.note == "Based on the system PATH: your login shell didn't answer within 0.2 seconds.")
    }

    @Test func defaultNoteSaysFiveSeconds() {
        #expect(LoginShellPath.timeoutNote(BrewxPortTimeouts.loginShell)
                == "Based on the system PATH: your login shell didn't answer within 5 seconds.")
    }

    @Test func runnerTimeoutFallsBack() async {
        let runner = Self.runner(stdout: "")
        runner.block = { _ in throw CommandRunnerError.timedOut(.seconds(5)) }
        let resolved = await Self.resolver(runner).resolve()
        #expect(resolved.source == .systemDefault)
        #expect(resolved.note == "Based on the system PATH: your login shell didn't answer within 5 seconds.")
    }

    @Test func resolvedOncePerLaunch() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        runner.block = { _ in try await Task.sleep(for: .milliseconds(50)) }
        let resolver = Self.resolver(runner)
        async let first = resolver.resolve()
        async let second = resolver.resolve()
        let (a, b) = await (first, second)
        let c = await resolver.resolve()
        #expect(a == b && b == c)
        #expect(runner.calls.count == 1)
    }

    @Test func forgetAsksAgain() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        let resolver = Self.resolver(runner)
        _ = await resolver.resolve()
        await resolver.forget()
        _ = await resolver.resolve()
        #expect(runner.calls.count == 2)
    }

    /// The PATH fix uses the shell this resolver asks, and only one listed in /etc/shells; nothing is run to find it.
    @Test func loginShellIsTheListedShell() {
        let runner = Self.runner(stdout: "")
        #expect(Self.resolver(runner).loginShell == "/bin/zsh")
        #expect(Self.resolver(runner, shell: "/usr/local/bin/fish", allowed: ["/bin/zsh"]).loginShell == nil)
        #expect(Self.resolver(runner, shell: nil).loginShell == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func unlistedShellFallsBack() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        let unlisted = await Self.resolver(runner, shell: "/usr/local/bin/fish", allowed: ["/bin/zsh", "/bin/bash"]).resolve()
        let missing = await Self.resolver(runner, shell: nil).resolve()
        #expect(runner.calls.isEmpty)
        for resolved in [unlisted, missing] {
            #expect(resolved.source == .systemDefault)
            #expect(resolved.entries == Self.system)
            #expect(resolved.note
                    == "Based on the system PATH: your login shell isn't zsh, bash or another shell listed in /etc/shells.")
        }
    }

    @Test func relativeEntryRejected() async {
        for path in ["bin:/usr/bin", "", ":", "~/bin:/usr/bin"] {
            let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__\(path)__BREWXPORT_PATH_END__\n")
            let resolved = await Self.resolver(runner).resolve()
            #expect(resolved.source == .systemDefault, "\(path)")
            #expect(resolved.entries == Self.system)
            #expect(resolved.note == "Based on the system PATH: your login shell didn't print a usable PATH.")
        }
    }

    @Test func emptyEntriesDropped() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__:/usr/local/bin::/usr/bin:__BREWXPORT_PATH_END__\n")
        let resolved = await Self.resolver(runner).resolve()
        #expect(resolved == ResolvedPath(entries: ["/usr/local/bin", "/usr/bin"], source: .loginShell))
    }

    @Test func onlyPosixShellsAreAsked() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        let fish = "/opt/homebrew/bin/fish"
        let resolved = await Self.resolver(runner, shell: fish, allowed: [fish, "/bin/zsh"]).resolve()
        #expect(runner.calls.isEmpty)
        #expect(resolved.source == .systemDefault)
        #expect(resolved.entries == Self.system)
        #expect(resolved.note == "Based on the system PATH: BrewxPort asks only sh, bash, zsh, dash or ksh for the PATH, "
                + "and your login shell is fish.")
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/opt/homebrew/bin/bash"] {
            let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
            let resolved = await Self.resolver(runner, shell: shell, allowed: [shell]).resolve()
            #expect(resolved.source == .loginShell, "\(shell)")
        }
    }

    @Test func shellGetsAPlainLoginEnvironment() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        _ = await Self.resolver(runner).resolve()
        // Like Terminal: the system PATH for path_helper to start from, the user's identity, SHELL = the login
        // shell. Nothing of BrewxPort's own PATH or Homebrew settings.
        #expect(runner.optionsCalls.first?.environment == [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/someone", "USER": "someone",
            "LOGNAME": "someone", "SHELL": "/bin/zsh", "LANG": "de_DE.UTF-8", "TMPDIR": "/var/folders/xy/T/",
        ])
        let sparse = LoginShellPath.shellEnvironment(shell: "/bin/bash", from: ["HOME": "/Users/x"])
        #expect(sparse == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/x", "SHELL": "/bin/bash",
                           "LANG": "en_US.UTF-8"])
    }

    @Test func failedOrUnmarkedAnswerFallsBack() async {
        let failed = await Self.resolver(Self.runner(stdout: "", exitCode: 1)).resolve()
        let unmarked = await Self.resolver(Self.runner(stdout: "/usr/bin:/bin\n")).resolve()
        let unended = await Self.resolver(Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin\n")).resolve()
        #expect([failed, unmarked, unended].allSatisfy { $0.source == .systemDefault && $0.entries == Self.system })
    }

    @Test func markedAnswerCountsWhateverTheExitCode() async {
        // The PATH is printed after the rc files have run; a failing .zlogout (or a shell stopped once the marker
        // arrived) doesn't make it wrong.
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/opt/local/bin:/usr/bin__BREWXPORT_PATH_END__\n", exitCode: 1)
        let resolved = await Self.resolver(runner).resolve()
        #expect(resolved == ResolvedPath(entries: ["/opt/local/bin", "/usr/bin"], source: .loginShell))
    }

    @Test func answerCountsWhenTheEndMarkerArrives() async {
        // The shell prints the markers, then never exits and never closes its output (a background job from an rc
        // file holding the pipe). The answer is in at once, not after the 5 s timeout.
        let runner = MarkerThenHangRunner()
        let resolver = LoginShellPath(runner: runner, shell: Self.shell, allowedShells: [Self.shell],
                                      systemPaths: { Self.system }, processEnvironment: Self.processEnvironment)
        let clock = ContinuousClock()
        let start = clock.now
        let resolved = await resolver.resolve()
        #expect(clock.now - start < .seconds(1))
        #expect(resolved == ResolvedPath(entries: ["/opt/local/bin", "/bin"], source: .loginShell))
        #expect(await waitUntil { runner.cancelled })
    }

    @Test func shellStartsInANewSession() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        _ = await Self.resolver(runner).resolve()
        #expect(runner.optionsCalls.map(\.newSession) == [true])
    }

    @Test func timeoutIsAskedAgainNextTime() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/opt/local/bin__BREWXPORT_PATH_END__\n")
        let calls = CallCount()
        runner.block = { _ in
            if calls.next() == 1 { throw CommandRunnerError.timedOut(.seconds(5)) }
        }
        let resolver = Self.resolver(runner)
        let first = await resolver.resolve()
        #expect(first.source == .systemDefault)
        #expect(first.note == "Based on the system PATH: your login shell didn't answer within 5 seconds.")
        let second = await resolver.resolve()
        #expect(second == ResolvedPath(entries: ["/opt/local/bin"], source: .loginShell))
        let third = await resolver.resolve()
        #expect(third == second)
        #expect(runner.calls.count == 2)
    }

    @Test func otherFallbacksAreKeptForTheLaunch() async {
        let runner = Self.runner(stdout: "no markers\n")
        let resolver = Self.resolver(runner)
        _ = await resolver.resolve()
        _ = await resolver.resolve()
        #expect(runner.calls.count == 1)
    }

    @Test func argvIsTheFixedConstant() async {
        #expect(LoginShellPath.markers.0 == "__BREWXPORT_PATH_BEGIN__")
        #expect(LoginShellPath.markers.1 == "__BREWXPORT_PATH_END__")
        #expect(LoginShellPath.arguments == Self.argv)
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n")
        _ = await Self.resolver(runner).resolve()
        #expect(runner.calls == [Self.argv])
        #expect(runner.executables.map(\.path) == [Self.shell])
        #expect(runner.optionsCalls.first?.timeout == BrewxPortTimeouts.loginShell)
    }
}

/// Counts calls from any thread.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A shell that prints the markers and then hangs, ignoring cancellation, until 10 s pass. Records the cancel.
private final class MarkerThenHangRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.withLock { _cancelled } }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        Issue.record("the probe streams")
        return CommandResult(exitCode: 1, stdout: "", stderr: "")
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        onOutput(.stdout("Welcome"))
        onOutput(.stdout("__BREWXPORT_PATH_BEGIN__/opt/local/bin:/bin__BREWXPORT_PATH_END__"))
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { done.resume() }
            }
        } onCancel: {
            lock.withLock { _cancelled = true }
        }
        return 0
    }

    @Test func etcFilesParsedLikePathHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-etc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let pathsD = root.appendingPathComponent("paths.d")
        try FileManager.default.createDirectory(at: pathsD, withIntermediateDirectories: true)
        try "/usr/local/bin\n/usr/bin\n\n/bin\n".write(to: root.appendingPathComponent("paths"), atomically: true, encoding: .utf8)
        try "/opt/b\n".write(to: pathsD.appendingPathComponent("20-b"), atomically: true, encoding: .utf8)
        try "/opt/a\n/usr/bin\n".write(to: pathsD.appendingPathComponent("10-a"), atomically: true, encoding: .utf8)
        try "# shells\n/bin/zsh\n/bin/bash\n\n".write(to: root.appendingPathComponent("shells"), atomically: true,
                                                      encoding: .utf8)
        #expect(LoginShellPath.systemPaths(etc: root) == ["/usr/local/bin", "/usr/bin", "/bin", "/opt/a", "/opt/b"])
        #expect(LoginShellPath.allowedShells(etc: root) == ["/bin/zsh", "/bin/bash"])
        let empty = root.appendingPathComponent("missing")
        #expect(LoginShellPath.systemPaths(etc: empty) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        #expect(LoginShellPath.allowedShells(etc: empty).isEmpty)
    }
}
