import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

/// Every test runs against a fake runner; no real shell is ever started.
@Suite struct LoginShellPathTests {
    static let shell = "/bin/zsh"
    static let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Every allowlisted location variable (each on its own marked line), then PATH between its markers.
    static let script = #"printf '__BREWXPORT_VAR_BEGIN__%s=%s__BREWXPORT_VAR_END__\n'"#
        + #" NVM_DIR "${NVM_DIR-}" NPM_CONFIG_PREFIX "${NPM_CONFIG_PREFIX-}" npm_config_prefix "${npm_config_prefix-}""#
        + #" PIPX_HOME "${PIPX_HOME-}" PIPX_BIN_DIR "${PIPX_BIN_DIR-}" UV_TOOL_DIR "${UV_TOOL_DIR-}""#
        + #" UV_TOOL_BIN_DIR "${UV_TOOL_BIN_DIR-}" CARGO_HOME "${CARGO_HOME-}""#
        + #" CARGO_INSTALL_ROOT "${CARGO_INSTALL_ROOT-}" RUSTUP_HOME "${RUSTUP_HOME-}" GEM_HOME "${GEM_HOME-}""#
        + #" GEM_PATH "${GEM_PATH-}" BUN_INSTALL "${BUN_INSTALL-}" BUN_INSTALL_GLOBAL_DIR "${BUN_INSTALL_GLOBAL_DIR-}""#
        + #" BUN_INSTALL_BIN "${BUN_INSTALL_BIN-}" MINT_PATH "${MINT_PATH-}" MINT_LINK_PATH "${MINT_LINK_PATH-}""#
        + #" XDG_DATA_HOME "${XDG_DATA_HOME-}" XDG_BIN_HOME "${XDG_BIN_HOME-}" XDG_CONFIG_HOME "${XDG_CONFIG_HOME-}""#
        + #" XDG_CACHE_HOME "${XDG_CACHE_HOME-}""#
        + #"; printf '%s%s%s\n' __BREWXPORT_PATH_BEGIN__ "$PATH" __BREWXPORT_PATH_END__"#
    static let argv = ["-i", "-l", "-c", script]

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

    /// A shell that didn't answer in time keeps its fallback: the language engines' detects that follow (seven of
    /// them on every check) get it at once instead of each waiting for the shell again. The person's Refresh or Check
    /// again (`askAgain`) or `forget()` asks again, an answer the shell gave included, so a PATH fixed meanwhile is
    /// read.
    @Test func timedOutShellKeepsItsFallbackUntilRefresh() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/opt/local/bin__BREWXPORT_PATH_END__\n")
        let calls = CallCount()
        runner.block = { _ in
            if calls.next() == 1 { throw CommandRunnerError.timedOut(.seconds(5)) }
        }
        let resolver = Self.resolver(runner)
        let first = await resolver.resolve()
        #expect(first.source == .systemDefault)
        #expect(first.note == "Based on the system PATH: your login shell didn't answer within 5 seconds.")
        #expect(await resolver.resolve() == first)
        #expect(await resolver.resolve() == first)
        #expect(runner.calls.count == 1)
        resolver.askAgain()
        let answered = await resolver.resolve()
        #expect(answered == ResolvedPath(entries: ["/opt/local/bin"], source: .loginShell))
        #expect(runner.calls.count == 2)
        #expect(await resolver.resolve() == answered)
        #expect(runner.calls.count == 2)
        resolver.askAgain()
        #expect(await resolver.resolve() == answered)
        #expect(runner.calls.count == 3)
        await resolver.forget()
        _ = await resolver.resolve()
        #expect(runner.calls.count == 4)
    }

    /// A PATH the person fixed after the shell answered (a Set Up added ~/.cargo/bin to .zprofile) is read on the next
    /// call after `askAgain()`.
    @Test func askAgainReadsAFixedPath() async {
        let before = "__BREWXPORT_PATH_BEGIN__/usr/bin__BREWXPORT_PATH_END__\n"
        let after = "__BREWXPORT_PATH_BEGIN__/Users/someone/.cargo/bin:/usr/bin__BREWXPORT_PATH_END__\n"
        let runner = Self.runner(stdout: before)
        let resolver = Self.resolver(runner)
        #expect(await resolver.resolve().entries == ["/usr/bin"])
        runner.respond(Self.argv, CommandResult(exitCode: 0, stdout: after, stderr: ""))
        #expect(await resolver.resolve().entries == ["/usr/bin"])
        resolver.askAgain()
        #expect(await resolver.resolve().entries == ["/Users/someone/.cargo/bin", "/usr/bin"])
    }

    /// With a fake slow shell: once it didn't answer within the timeout, the next calls don't wait for it again.
    @Test func slowShellIsWaitedForOnce() async {
        let runner = Self.runner(stdout: "__BREWXPORT_PATH_BEGIN__/opt/homebrew/bin__BREWXPORT_PATH_END__\n")
        runner.block = { _ in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done.resume() }
            }
        }
        let resolver = Self.resolver(runner, timeout: .milliseconds(200))
        let first = await resolver.resolve()
        #expect(first.source == .systemDefault)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<7 { #expect(await resolver.resolve() == first) }
        #expect(clock.now - start < .milliseconds(150))
        #expect(runner.calls.count == 1)
    }

    @Test func otherFallbacksAreKeptForTheLaunch() async {
        let runner = Self.runner(stdout: "no markers\n")
        let resolver = Self.resolver(runner)
        _ = await resolver.resolve()
        _ = await resolver.resolve()
        #expect(runner.calls.count == 1)
    }

    /// What the probe prints for each variable: its own line, between the variable markers.
    static func line(_ name: String, _ value: String) -> String {
        "__BREWXPORT_VAR_BEGIN__\(name)=\(value)__BREWXPORT_VAR_END__\n"
    }

    static let pathLine = "__BREWXPORT_PATH_BEGIN__/opt/homebrew/bin:/usr/bin__BREWXPORT_PATH_END__\n"

    @Test func capturesOnlyAllowlistedVariables() async {
        let stdout = "Welcome!\n"
            + Self.line("NVM_DIR", "/Users/someone/.nvm")
            + Self.line("CARGO_HOME", "/Users/someone/.cargo")
            + Self.line("GEM_PATH", "/Users/someone/.gem/ruby/4.0.0:/opt/homebrew/lib/ruby/gems/4.0.0")
            + Self.line("npm_config_prefix", "/Users/someone/.npm-global")
            + Self.line("PIPX_HOME", "")
            // Never captured, whatever the shell prints: tokens, index URLs, proxies, PATH itself.
            + Self.line("NPM_TOKEN", "/abc")
            + Self.line("UV_INDEX_URL", "/simple")
            + Self.line("HTTPS_PROXY", "/proxy")
            + Self.line("PATH", "/evil/bin")
            + Self.line("cargo_home", "/Users/someone/.cargo")
            + Self.pathLine
        let resolved = await Self.resolver(Self.runner(stdout: stdout)).resolve()
        #expect(resolved.entries == ["/opt/homebrew/bin", "/usr/bin"])
        #expect(resolved.environment == [
            "NVM_DIR": "/Users/someone/.nvm", "CARGO_HOME": "/Users/someone/.cargo",
            "GEM_PATH": "/Users/someone/.gem/ruby/4.0.0:/opt/homebrew/lib/ruby/gems/4.0.0",
            "npm_config_prefix": "/Users/someone/.npm-global",
        ])
        // The script asks for each allowlisted variable once and nothing else.
        let asked = LoginShellPath.script.components(separatedBy: CharacterSet(charactersIn: " ;"))
            .filter { $0.hasPrefix("\"${") }
        #expect(asked == ToolEnvironment.capturedVariables.map { "\"${\($0)-}\"" })
    }

    @Test func dropsRelativeAndCredentialValues() async {
        let stdout = Self.line("CARGO_HOME", ".cargo")
            + Self.line("RUSTUP_HOME", "~/.rustup")
            + Self.line("BUN_INSTALL", "$HOME/.bun")
            + Self.line("NPM_CONFIG_PREFIX", "https://someone:secret@registry.example.com/")
            + Self.line("npm_config_prefix", "//someone:secret@registry.example.com/")
            + Self.line("GEM_PATH", "/Users/someone/.gem:relative")
            + Self.line("GEM_HOME", "/Users/some\u{7}one")
            // A value with a line break spans two lines: neither half is taken.
            + "__BREWXPORT_VAR_BEGIN__MINT_PATH=/Users/someone/.mint\n/second__BREWXPORT_VAR_END__\n"
            + Self.line("XDG_DATA_HOME", "/Users/someone/.local/share")
            + Self.pathLine
        let resolved = await Self.resolver(Self.runner(stdout: stdout)).resolve()
        #expect(resolved.source == .loginShell)
        #expect(resolved.environment == ["XDG_DATA_HOME": "/Users/someone/.local/share"])
    }

    @Test func fallbackCapturesNothing() async {
        let stdout = Self.line("CARGO_HOME", "/Users/someone/.cargo") + "no PATH markers\n"
        let resolved = await Self.resolver(Self.runner(stdout: stdout)).resolve()
        #expect(resolved.source == .systemDefault)
        #expect(resolved.environment.isEmpty)
    }

    /// Printing, interpolating, debug-printing or dumping a ResolvedPath shows the variables' names and how many
    /// PATH entries there are, never a value or an entry.
    @Test func resolvedPathTextIsRedacted() {
        let resolved = ResolvedPath(entries: ["/opt/homebrew/bin", "/Users/someone/hidden-bin"], source: .loginShell,
                                    environment: ["NVM_DIR": "/Users/someone/hidden-nvm",
                                                  "CARGO_HOME": "/Users/someone/hidden-cargo"])
        var dumped = ""
        dump(resolved, to: &dumped)
        for text in [String(describing: resolved), String(reflecting: resolved), "\(resolved)", dumped] {
            #expect(!text.contains("hidden"), "\(text)")
            #expect(!text.contains("/opt/homebrew/bin"), "\(text)")
            #expect(text.contains("CARGO_HOME") && text.contains("NVM_DIR"), "\(text)")
        }
        #expect(String(describing: resolved)
                == "ResolvedPath(source: loginShell, PATH entries: 2, variables: CARGO_HOME NVM_DIR)")
        let fallback = ResolvedPath(entries: ["/usr/bin"], source: .systemDefault, note: "Based on the system PATH.")
        #expect(String(describing: fallback) == "ResolvedPath(source: systemDefault, PATH entries: 1, variables: none, "
                + "note: Based on the system PATH.)")
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
