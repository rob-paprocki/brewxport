import Foundation

/// Finds engine executables at fixed paths. GUI apps don't inherit the shell PATH.
public struct EngineLocator: Sendable {
    /// Where BrewxPort sets nanobrew up, and the first place it looks for it.
    public static let nanobrewPath = "/opt/nanobrew/prefix/bin/nb"

    private let isExecutable: @Sendable (String) -> Bool
    private let overrides: [EngineID: String]

    public init(isExecutable: @Sendable @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                overrides: [EngineID: String] = [:]) {
        self.isExecutable = isExecutable
        self.overrides = overrides
    }

    /// Ordered candidate paths for an engine on the given architecture.
    public func candidates(for id: EngineID, arch: Arch) -> [String] {
        let prefixes = arch == .arm64 ? ["/opt/homebrew/bin", "/usr/local/bin"]
                                      : ["/usr/local/bin", "/opt/homebrew/bin"]
        switch id {
        case .homebrew: return prefixes.map { $0 + "/brew" }
        case .mas: return prefixes.map { $0 + "/mas" }
        case .nanobrew: return [Self.nanobrewPath, "/opt/nb/bin/nb"]
        case .macports: return ["/opt/local/bin/port"]
        // Language engines are found from the login shell's PATH first (Plan 9 Task 2's ToolLocator), not here.
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return []
        }
    }

    /// The override if it is executable, otherwise the first executable candidate.
    public func locate(_ id: EngineID, arch: Arch = .current) -> URL? {
        if let override = overrides[id], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }
        return candidates(for: id, arch: arch)
            .first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Builds a search argv: base, then the trimmed query, preceded by `--` when the query starts with `-`.
/// Pass `separator: false` for a tool that doesn't honour `--` but also doesn't parse the query as an option (nb).
public func searchArguments(_ base: [String], query: String, engine: EngineID, separator: Bool = true) throws -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw EngineError(engine: engine, message: "Search query is empty")
    }
    return separator && trimmed.hasPrefix("-") ? base + ["--", trimmed] : base + [trimmed]
}

/// Validates package names for an install/upgrade/remove argv and returns them unchanged.
/// Rejects an empty list, blank names, and names starting with `-` (they would be read as options).
public func packageNameArguments(_ refs: [PackageRef], engine: EngineID) throws -> [String] {
    guard !refs.isEmpty else {
        throw EngineError(engine: engine, message: "No packages given")
    }
    for ref in refs {
        if ref.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw EngineError(engine: engine, message: "Package name is empty")
        }
        if ref.name.hasPrefix("-") {
            throw EngineError(engine: engine, message: "Invalid package name: \(ref.name)")
        }
    }
    return refs.map(\.name)
}
