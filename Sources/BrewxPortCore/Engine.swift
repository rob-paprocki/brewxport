import Foundation

public enum PackageOperation: Sendable {
    case install, upgrade, remove
    /// Marks an installed package as one the user asked for (not just a dependency). Nothing is installed or removed.
    case markRequested
    /// Marks an installed package as a dependency of something else.
    case markDependency
    /// Repairs a language engine's tools after the runtime they run on changed (`ToolRepairing`): npm rebuilds them,
    /// the others reinstall them. Engines build these commands through `repairCommands(for:)`, never `command(for:)`.
    case repair
}

/// Whether an operation needs root.
public enum Privilege: Sendable, Equatable {
    case never
    case always
    /// May need root depending on the package; the engine decides at run time.
    case sometimes
}

public struct CommandSpec: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let needsRoot: Bool
    /// The architecture to run the executable under; nil means native.
    public let arch: Arch?
    /// The whole environment the command runs with, for a command that runs as the user; nil means the runner's
    /// base environment. Language engines set it (`LanguageTool`): their tool's folder first on PATH and their
    /// login-shell variables. A run uses it only for a language engine's step that runs as the user, never for a
    /// system engine's, nor through sudo or the helper. Never logged: printed, a CommandSpec shows only the
    /// variables' names.
    public let environment: [String: String]?
    /// The folder the command starts in, for a language engine's command that runs as the user; nil inherits
    /// BrewxPort's.
    public let workingDirectory: String?
    /// For a language engine's command that can exit 0 without doing what it was asked (RubyGems' uninstall): what a
    /// run starts after it exits 0, with the same environment and folder. The step fails unless that exits 0 too.
    /// nil: the command's own exit code is the answer.
    public let confirmation: CommandConfirmation?

    public init(executable: URL, arguments: [String], needsRoot: Bool, arch: Arch? = nil,
                environment: [String: String]? = nil, workingDirectory: String? = nil,
                confirmation: CommandConfirmation? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.needsRoot = needsRoot
        self.arch = arch
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.confirmation = confirmation
    }

    /// What to actually launch. An x86_64 command on an arm64 machine goes through `/usr/bin/arch -x86_64`
    /// (Rosetta); anything else runs as is. `host` exists so tests can force the machine's architecture.
    public func launchCommand(host: Arch = .current) -> (executable: URL, arguments: [String]) {
        if arch == .x86_64, host == .arm64 {
            return (URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", executable.path] + arguments)
        }
        return (executable, arguments)
    }
}

/// The command that confirms another one worked (`CommandSpec.confirmation`): it exits 0 when it did, and otherwise
/// says why on stderr. It runs as the user, with the confirmed command's environment and folder. For a command that
/// exits 0 whatever it finds (`mint list`), `check` says what its output must show as well.
public struct CommandConfirmation: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    /// What the confirmation's stdout must show once it exits 0; nil: its exit code alone decides.
    public let check: ConfirmationCheck?

    public init(executable: URL, arguments: [String], check: ConfirmationCheck? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.check = check
    }
}

/// What a confirmation's output must show (`CommandConfirmation.check`), read by the engine's own parser.
public enum ConfirmationCheck: Equatable, Sendable {
    /// `mint list` shows the package (`owner/repo`) with every executable of `version` linked: Mint exits 0 when it
    /// skipped a link. `metadata` is Mint's `metadata.json`, which says which repository a listed name is.
    case mintLinked(package: String, version: String, metadata: String)
    /// `mint list` doesn't show the package (`owner/repo`, or Mint's own name for one BrewxPort can't name that way):
    /// Mint exits 0 when it found nothing to uninstall. `metadata` as for `mintLinked`.
    case mintAbsent(package: String, metadata: String)

    /// nil when `stdout` shows what's expected; otherwise one line saying what it doesn't show. Reads the metadata
    /// file the check names; one that can't be read confirms nothing it's needed for.
    public func failure(in stdout: String) -> String? {
        MintEngine.confirmationFailure(self, listing: stdout)
    }
}

/// Printed, interpolated or dumped, a CommandSpec shows its executable, arguments, root and architecture, but only the
/// names of its environment's variables and whether it has a working folder: their values name the user's folders.
extension CommandSpec: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        var text = "CommandSpec(executable: \(executable.path), arguments: \(arguments), needsRoot: \(needsRoot)"
        if let arch { text += ", arch: \(arch.rawValue)" }
        if let environment { text += ", environment: " + environment.keys.sorted().joined(separator: " ") }
        if workingDirectory != nil { text += ", workingDirectory: set" }
        if let confirmation { text += ", confirmation: \(confirmation.executable.path)" }
        return text + ")"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["executable": executable.path, "arguments": arguments, "needsRoot": needsRoot,
                                "arch": arch as Any, "environmentNames": environment.map { $0.keys.sorted() } as Any,
                                "hasWorkingDirectory": workingDirectory != nil,
                                "confirmation": confirmation.map { [$0.executable.path] + $0.arguments } as Any],
               displayStyle: .struct)
    }
}

public enum EngineStatus: Equatable, Sendable {
    /// No executable was found.
    case missing
    case present(path: URL, version: String)
    /// The executable exists, but its version command failed or printed something BrewxPort can't read.
    case unusable(path: URL, reason: String)
    /// It works, but it's a version BrewxPort doesn't drive (Bun before 1.4.5, R15): nothing is asked of it, and it
    /// isn't a failure. `reason` says so and how to update it.
    case unsupported(path: URL, version: String, reason: String)
}

/// Shared `detect()` logic. No executable → `.missing`. A launch failure → `.missing` if the file is gone,
/// otherwise `.unusable`. A non-zero exit, or output `parse` can't read (it returns nil) → `.unusable`.
/// `environment` and `workingDirectory` are a language tool's (`LanguageTool`); nil keeps the runner's own.
func detectStatus(
    runner: CommandRunning, executable: URL?, arguments: [String],
    arch: Arch? = nil, host: Arch = .current,
    environment: [String: String]? = nil, workingDirectory: String? = nil,
    parse: (String) -> String?
) async -> EngineStatus {
    guard let executable else { return .missing }
    let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
    let result: CommandResult
    do {
        let launch = CommandSpec(executable: executable, arguments: arguments, needsRoot: false, arch: arch)
            .launchCommand(host: host)
        result = try await runner.run(launch.executable, launch.arguments,
                                      options: RunOptions(environment: environment,
                                                          timeout: BrewxPortTimeouts.engineQuery,
                                                          workingDirectory: workingDirectory))
    } catch {
        if case CommandRunnerError.timedOut(let after) = error {
            return .unusable(path: executable, reason: BrewxPortTimeouts.didntAnswer(within: after))
        }
        guard FileManager.default.fileExists(atPath: executable.path) else { return .missing }
        let detail: String
        if case CommandRunnerError.launchFailed(let reason) = error { detail = reason } else { detail = String(describing: error) }
        return .unusable(path: executable, reason: "couldn't run `\(command)`: \(detail)")
    }
    guard result.exitCode == 0 else {
        let err = String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        return .unusable(path: executable, reason: "`\(command)` exited \(result.exitCode)" + (err.isEmpty ? "" : ": \(err)"))
    }
    guard let version = parse(result.stdout) else {
        return .unusable(path: executable, reason: "couldn't read a version from `\(command)`")
    }
    return .present(path: executable, version: version)
}

public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let versionPinning = EngineCapabilities(rawValue: 1 << 0)
    public static let casks = EngineCapabilities(rawValue: 1 << 1)
    public static let jsonOutput = EngineCapabilities(rawValue: 1 << 2)
    public static let sourceBuilds = EngineCapabilities(rawValue: 1 << 3)
}

public struct EngineError: Error, Equatable, Sendable {
    public let engine: EngineID
    public let message: String

    public init(engine: EngineID, message: String) {
        self.engine = engine
        self.message = message
    }
}

public protocol Engine: Sendable {
    var id: EngineID { get }
    var capabilities: EngineCapabilities { get }
    /// The engine's executable, or nil when none was found.
    var executableURL: URL? { get }
    /// The architecture the engine's commands run under.
    var runArch: Arch { get }
    func detect() async -> EngineStatus
    func search(_ query: String) async throws -> [Package]
    func listInstalled() async throws -> [Package]
    func listOutdated() async throws -> [Package]
    /// The outdated check as the catalog asks for it: `listOutdated()`'s updates, plus the packages that couldn't be
    /// checked while the rest answered and the updates held back with why. The default has neither.
    func checkOutdated() async throws -> OutdatedReport
    /// Details for one package. Throws `EngineError` when the output can't be read; never returns empty details.
    func info(_ ref: PackageRef) async throws -> PackageDetails
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege
    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec
    /// The most packages one `command(for: operation, …)` may name; nil: as many as are asked for. ActionPlanner
    /// splits a batch to fit, so each command gets its own step and its own result.
    func maxTargetsPerCommand(for operation: PackageOperation) -> Int?
}

extension Engine {
    public var runArch: Arch { .current }

    public func checkOutdated() async throws -> OutdatedReport { OutdatedReport(packages: try await listOutdated()) }

    public func maxTargetsPerCommand(for operation: PackageOperation) -> Int? { nil }

    /// Refuses more packages than `maxTargetsPerCommand(for:)` allows: "uv installs one tool at a time". ActionPlanner
    /// never asks for more; this keeps any other caller from getting a command that leaves names out.
    func requireTargetLimit(_ refs: [PackageRef], for operation: PackageOperation) throws {
        guard let limit = maxTargetsPerCommand(for: operation), refs.count > limit else { return }
        let verb: String
        switch operation {
        case .install: verb = "installs"
        case .upgrade: verb = "updates"
        case .remove: verb = "removes"
        case .repair: verb = "repairs"
        case .markRequested, .markDependency: verb = "marks"
        }
        let noun = id.isLanguage ? "tool" : "package"
        let count = limit == 1 ? "one \(noun)" : "\(limit) \(noun)s"
        throw EngineError(engine: id, message: "\(id.displayName) \(verb) \(count) at a time")
    }
}

/// An engine that can list its installed third-party taps (Homebrew). Demo mode's wrapper forwards it.
public protocol TapListing: Sendable {
    func listTaps() async throws -> [String]
}

/// An engine whose package catalogue can be refreshed by a command (MacPorts' `port selfupdate`). Demo mode's wrapper
/// forwards it.
public protocol CatalogRefreshing: Sendable {
    /// The command that refreshes the catalogue. Throws `EngineError` when it can't be built.
    func selfupdateCommand() throws -> CommandSpec
}

/// An engine that can name the installed packages that directly depend on one package (Homebrew, MacPorts, nanobrew).
/// Direct dependents only, named as the engine lists them; callers walk further themselves. Throws when the engine
/// can't answer, so a caller never mistakes "couldn't ask" for "nobody depends on it". Demo mode's wrapper forwards it.
public protocol DependentsListing: Sendable {
    func installedDependents(of name: String) async throws -> Set<String>
}

/// An engine with no reverse lookup (nanobrew), whose every `installedDependents` call scans all installed packages.
/// A caller that needs many answers builds the whole map once instead.
public protocol DependentsMapping: DependentsListing {
    /// Lower-cased name → the installed packages that directly depend on it. Each engine call may take `callTimeout`
    /// (nil: no limit). Throws when any part of the scan fails, like `installedDependents`.
    func installedDependentsMap(callTimeout: Duration?) async throws -> [String: Set<String>]
}

/// `work` for every key, at most `limit` at a time, keyed by the key. The first error cancels the calls still going
/// and is thrown. Duplicate keys are asked once.
public func concurrentMap<Key: Hashable & Sendable, Value: Sendable>(
    _ keys: [Key], limit: Int, _ work: @escaping @Sendable (Key) async throws -> Value
) async throws -> [Key: Value] {
    var pending = Array(Set(keys)).makeIterator()
    return try await withThrowingTaskGroup(of: (Key, Value).self) { group in
        for _ in 0..<max(1, limit) {
            guard let key = pending.next() else { break }
            group.addTask { (key, try await work(key)) }
        }
        var answers: [Key: Value] = [:]
        while let (key, value) = try await group.next() {
            answers[key] = value
            if let next = pending.next() { group.addTask { (next, try await work(next)) } }
        }
        return answers
    }
}

/// One text field from an engine, trimmed; nil when blank.
func nonBlank(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// A web address from an engine: an `https` or `http` URL with a host; nil for anything else. Language registries'
/// home pages are set by any package's author, and Details makes them links: another scheme (an SMB share, ssh, a
/// local file or app, another app's own scheme) would be handed to the system on a click.
func webURL(_ s: String?) -> URL? {
    guard let t = nonBlank(s), let url = URL(string: t), let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty else { return nil }
    return url
}

/// An engine's located executable. Located once when the engine is made; only `detect()` looks again, so an engine
/// installed while BrewxPort runs is found by the next check, and every other operation reads one stable value.
public final class ExecutableCache: @unchecked Sendable {
    private let lock = NSLock()
    private let locate: @Sendable () -> URL?
    private var value: URL?

    public init(locate: @escaping @Sendable () -> URL?) {
        self.locate = locate
        value = locate()
    }

    public var current: URL? { lock.withLock { value } }

    /// Looks again and remembers the answer.
    public func relocate() -> URL? {
        let found = locate()
        lock.withLock { value = found }
        return found
    }
}
