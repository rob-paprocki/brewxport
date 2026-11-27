import Foundation

/// What a language engine takes from the user's login shell: the PATH folders to look for its tool in first, and the
/// allowlisted location variables (`ToolEnvironment.capturedVariables`; each engine's commands get only their own,
/// through `ToolEnvironment.make`). The app builds one from `LoginShellPath`'s answer, which Core can't see.
///
/// Printed, interpolated or dumped, it shows how many folders it has and the variables' names, never a folder or a
/// value: they name the user's folders.
public struct LoginShellContext: Sendable, Equatable {
    public let path: [String]
    /// Only allowlisted variables with usable values (`ToolEnvironment.allowlisted`).
    public let environment: [String: String]

    public init(path: [String], environment: [String: String]) {
        self.path = path
        self.environment = ToolEnvironment.allowlisted(environment)
    }

    /// No login shell: tools are looked for in their fixed folders only (`BrewxPort --self-check`).
    public static let none = LoginShellContext(path: [], environment: [:])
}

extension LoginShellContext: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        let names = environment.keys.sorted()
        return "LoginShellContext(PATH entries: \(path.count), variables: "
            + (names.isEmpty ? "none" : names.joined(separator: " ")) + ")"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["pathEntryCount": path.count, "variableNames": environment.keys.sorted()],
               displayStyle: .struct)
    }
}

/// Asks for the login shell's context. The app's answer is cached for the launch; a language engine asks once per
/// `detect()`.
public typealias LoginShellContextProvider = @Sendable () async -> LoginShellContext

/// A language engine that knows where it puts tools, as its last `detect()` found it: the folder it installs them into
/// (npm's global prefix) and the one their commands go in (`~/.cargo/bin`), each nil before a detect and when the tool
/// didn't say. And whether this account can change them there (`InstallAccess`).
public protocol InstallLocationReporting: Sendable {
    var installLocation: URL? { get }
    var binLocation: URL? { get }
    /// Why this account can't install, update or remove the engine's tools, with the fix where there's one: a folder it
    /// writes isn't writable, or it's a Ruby BrewxPort never installs into. Nil when it can, and before a detect. The
    /// engine refuses those commands meanwhile.
    var readOnlyReason: String? { get }
}

extension InstallLocationReporting {
    /// The plan's `installRootWritable`: nothing stops this account changing the engine's tools.
    public var installRootWritable: Bool { readOnlyReason == nil }
}

/// An engine with something to say on its page about its last listing that isn't a failure: uv's warning about a
/// tool it left out. Nil when there's nothing to say.
public protocol EngineNoteReporting: Sendable {
    var note: String? { get }
}

/// One language tool (npm, pipx, cargo…) as its engine drives it.
///
/// - Found the way the user's shell finds it: the first folder on the login shell's PATH that has it, then the
///   engine's fixed folders (`ToolLocator`). It's looked for once per `detect()` (`relocate()`), and every other call
///   uses that answer, so one check works on one copy. Before the first `detect()` there's none.
/// - Every command runs as the user with `ToolEnvironment.make` (the tool's folder first on PATH, only its manager's
///   login-shell variables, NO_COLOR) on `base` (always `ProcessRunner.baseEnvironment` in the app, never the app's
///   own environment), plus the engine's fixed `settings`, from the home folder. Queries (`run`) and the commands a
///   run launches (`command`) get the same environment and folder.
public final class LanguageTool: @unchecked Sendable {
    public let engine: EngineID
    /// The tool's file name, for messages ("npm").
    public let name: String

    private let runner: CommandRunning
    private let settings: [String: String]
    private let base: [String: String]
    private let home: String
    private let locate: @Sendable () async -> Found?
    private let lock = NSLock()
    private var found: Found?

    /// A located tool and the login-shell variables captured with it.
    private struct Found: Sendable {
        let executable: URL
        let captured: [String: String]
    }

    /// The app's tool: looked for in `loginShell().path`, then in `fixedFolders(captured variables)`.
    public init(engine: EngineID, name: String, runner: CommandRunning, settings: [String: String] = [:],
                base: [String: String], loginShell: @escaping LoginShellContextProvider,
                fixedFolders: @escaping @Sendable (_ captured: [String: String]) -> [String]) {
        self.engine = engine
        self.name = name
        self.runner = runner
        self.settings = settings
        self.base = base
        home = Self.home(base)
        locate = {
            let context = await loginShell()
            let executable = ToolLocator().locate(name, loginPath: context.path,
                                                  fixed: fixedFolders(context.environment))
            return executable.map { Found(executable: $0, captured: context.environment) }
        }
    }

    /// A tool at a fixed path (demo mode and tests), with these login-shell variables; nil means it isn't installed.
    public init(engine: EngineID, name: String, runner: CommandRunning, executable: URL?,
                captured: [String: String] = [:], settings: [String: String] = [:], base: [String: String]) {
        self.engine = engine
        self.name = name
        self.runner = runner
        self.settings = settings
        self.base = base
        home = Self.home(base)
        let fixed = executable.map { Found(executable: $0, captured: ToolEnvironment.allowlisted(captured)) }
        found = fixed
        locate = { fixed }
    }

    /// The folder every command runs from: `base`'s HOME when it's an absolute path, else this user's home folder.
    static func home(_ base: [String: String]) -> String {
        if let home = base["HOME"], home.hasPrefix("/") { return home }
        return NSHomeDirectory()
    }

    /// The tool as last found; nil before the first `relocate()` (for the app's tool) or when it isn't installed.
    public var executable: URL? { lock.withLock { found?.executable } }

    /// Looks for the tool again and remembers the answer. Only `detect()` calls it.
    @discardableResult
    public func relocate() async -> URL? {
        await relocated()?.executable
    }

    private func relocated() async -> Found? {
        let answer = await locate()
        lock.withLock { found = answer }
        return answer
    }

    /// Looks for the tool again, then asks it for its version like `detectStatus` (with this tool's environment).
    public func detect(_ arguments: [String], parse: (String) -> String?) async -> EngineStatus {
        let tool = await relocated()
        return await detectStatus(runner: runner, executable: tool?.executable, arguments: arguments,
                                  environment: tool.map(environment), workingDirectory: home, parse: parse)
    }

    /// Runs one query as the user and returns what it printed, whatever its exit code. Throws an `EngineError` when
    /// the tool isn't installed, and the runner's own errors (a launch failure, cancellation) as they are.
    public func run(_ arguments: [String]) async throws -> CommandResult {
        let tool = try require()
        return try await runner.run(tool.executable, arguments,
                                    options: RunOptions(environment: environment(tool), workingDirectory: home))
    }

    /// Runs another executable from the tool's own folder like `run`, with the tool's environment and folder: cargo's
    /// `rustc`, so it's the same toolchain. Throws an `EngineError` for a name that isn't a plain file name.
    public func run(sibling name: String, _ arguments: [String]) async throws -> CommandResult {
        let tool = try require()
        return try await runner.run(try sibling(name, of: tool), arguments,
                                    options: RunOptions(environment: environment(tool), workingDirectory: home))
    }

    /// The executable `name` in the tool's own folder; an `EngineError` for a name that isn't a plain file name.
    private func sibling(_ name: String, of tool: Found) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw EngineError(engine: engine, message: "Invalid executable name: \(name)")
        }
        return tool.executable.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The value `name` has in the environment the tool's commands get (`base`, the tool's own login-shell variables,
    /// the settings); nil when it isn't set there, or before the tool is found.
    public func variable(_ name: String) -> String? {
        guard let tool = lock.withLock({ found }) else { return nil }
        return environment(tool)[name]
    }

    /// The command a run launches: never as root, with the same environment and folder as the queries.
    /// `confirmedBy` is an executable beside the tool (named as for `run(sibling:)`) and its arguments: the run starts
    /// it after the command exits 0, and the step fails unless it exits 0 too (`CommandSpec.confirmation`), and, with
    /// `checking`, unless its output shows what that says.
    public func command(_ arguments: [String], confirmedBy confirmation: (sibling: String, arguments: [String])? = nil,
                        checking check: ConfirmationCheck? = nil) throws -> CommandSpec {
        let tool = try require()
        let confirm = try confirmation.map {
            CommandConfirmation(executable: try sibling($0.sibling, of: tool), arguments: $0.arguments, check: check)
        }
        return CommandSpec(executable: tool.executable, arguments: arguments, needsRoot: false,
                           environment: environment(tool), workingDirectory: home, confirmation: confirm)
    }

    /// The tool's JSON output as `T`, or an `EngineError` saying it couldn't be read.
    public func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(output.utf8))
        } catch {
            throw EngineError(engine: engine,
                              message: "Couldn't read \(name)'s JSON output: \(error.localizedDescription)")
        }
    }

    /// "<what> (exit N): <the first 300 characters of stderr>", as the system engines word a failed command. Any URL
    /// credentials in stderr are taken out first (`CredentialScrubber`), so a cut can't leave half a token.
    public func failure(_ what: String, _ result: CommandResult) -> EngineError {
        let stderr = CredentialScrubber.scrub(result.stderr)
        let excerpt = String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return EngineError(engine: engine,
                           message: "\(what) (exit \(result.exitCode))" + (excerpt.isEmpty ? "" : ": \(excerpt)"))
    }

    private func require() throws -> Found {
        guard let tool = lock.withLock({ found }) else {
            throw EngineError(engine: engine, message: "\(engine.displayName) isn't installed")
        }
        return tool
    }

    private func environment(_ tool: Found) -> [String: String] {
        ToolEnvironment.make(for: engine, executable: tool.executable, captured: tool.captured, base: base)
            .merging(settings) { $1 }
    }
}
