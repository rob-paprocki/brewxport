import Foundation

public enum PackageOperation: Sendable { case install, upgrade, remove }

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

    public init(executable: URL, arguments: [String], needsRoot: Bool, arch: Arch? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.needsRoot = needsRoot
        self.arch = arch
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

public enum EngineStatus: Equatable, Sendable {
    /// No executable was found.
    case missing
    case present(path: URL, version: String)
    /// The executable exists, but its version command failed or printed something BrewxPort can't read.
    case unusable(path: URL, reason: String)
}

/// Shared `detect()` logic. No executable → `.missing`. A launch failure → `.missing` if the file is gone,
/// otherwise `.unusable`. A non-zero exit, or output `parse` can't read (it returns nil) → `.unusable`.
func detectStatus(
    runner: CommandRunning, executable: URL?, arguments: [String],
    arch: Arch? = nil, host: Arch = .current,
    parse: (String) -> String?
) async -> EngineStatus {
    guard let executable else { return .missing }
    let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
    let result: CommandResult
    do {
        let launch = CommandSpec(executable: executable, arguments: arguments, needsRoot: false, arch: arch)
            .launchCommand(host: host)
        result = try await runner.run(launch.executable, launch.arguments,
                                      options: RunOptions(timeout: BrewxPortTimeouts.engineQuery))
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
    /// Details for one package. Throws `EngineError` when the output can't be read; never returns empty details.
    func info(_ ref: PackageRef) async throws -> PackageDetails
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege
    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec
}

extension Engine {
    public var runArch: Arch { .current }
}

/// One text field from an engine, trimmed; nil when blank.
func nonBlank(_ s: String?) -> String? {
    guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    return t
}

/// A web address from an engine; nil when blank or not a URL.
func webURL(_ s: String?) -> URL? {
    guard let t = nonBlank(s) else { return nil }
    return URL(string: t)
}
