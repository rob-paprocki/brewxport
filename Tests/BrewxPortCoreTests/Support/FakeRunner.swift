import Foundation
@testable import BrewxPortCore

/// Test double for `CommandRunning`. Responses are keyed by arguments only, unless `byExecutable` has an answer for
/// the executable's file name (cargo and the `rustc` beside it both answer `--version`).
/// Unknown argv yields exit code 127.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [[String]: CommandResult]
    private let byExecutable: [String: [[String]: CommandResult]]
    private var _calls: [[String]] = []
    private var _options: [RunOptions] = []
    private var _executables: [URL] = []

    init(_ responses: [[String]: CommandResult], byExecutable: [String: [[String]: CommandResult]] = [:]) {
        self.responses = responses
        self.byExecutable = byExecutable
    }

    var calls: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    /// Answers `arguments` with `result` from now on.
    func respond(_ arguments: [String], _ result: CommandResult) {
        lock.lock(); defer { lock.unlock() }
        responses[arguments] = result
    }

    /// The executable each call was made with, in call order (parallel to `calls`).
    var executableCalls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return _executables
    }

    /// The options each call was made with, in call order (parallel to `calls`).
    var optionsCalls: [RunOptions] {
        lock.lock(); defer { lock.unlock() }
        return _options
    }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        record(executable, arguments, options)
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        let result = record(executable, arguments, options)
        for line in Self.lines(result.stdout) { onOutput(.stdout(line)) }
        for line in Self.lines(result.stderr) { onOutput(.stderr(line)) }
        return result.exitCode
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }

    private func record(_ executable: URL, _ arguments: [String], _ options: RunOptions) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        _executables.append(executable)
        _calls.append(arguments)
        _options.append(options)
        return byExecutable[executable.lastPathComponent]?[arguments] ?? responses[arguments]
            ?? CommandResult(exitCode: 127, stdout: "", stderr: "FakeRunner: no response for \(arguments)")
    }
}

/// Runner whose every call fails to launch, like `Process.run()` throwing.
struct ThrowingRunner: CommandRunning {
    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        throw CommandRunnerError.launchFailed("Bad CPU type in executable")
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        throw CommandRunnerError.launchFailed("Bad CPU type in executable")
    }
}

/// True when the status is `.unusable` at `path` with a non-empty reason.
func isUnusable(_ status: EngineStatus, at path: URL) -> Bool {
    if case .unusable(let p, let reason) = status { return p == path && !reason.isEmpty }
    return false
}
