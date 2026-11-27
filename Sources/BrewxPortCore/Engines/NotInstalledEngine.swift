import Foundation

/// Stands in for an engine BrewxPort can't drive yet: always "Not installed", with nothing to list and no commands.
/// Plan 9 used one for each language engine until its real engine replaced it (Tasks 3-9); now the demo's
/// `--demo-missing` makes one (so a language engine's Set Up can be seen), and the engine lists' branch for a system
/// engine, which isn't reached.
public struct NotInstalledEngine: Engine {
    public let id: EngineID

    public init(id: EngineID) {
        self.id = id
    }

    public var capabilities: EngineCapabilities { [] }
    public var executableURL: URL? { nil }

    public func detect() async -> EngineStatus { .missing }
    public func search(_ query: String) async throws -> [Package] { [] }
    public func listInstalled() async throws -> [Package] { [] }
    public func listOutdated() async throws -> [Package] { [] }

    public func info(_ ref: PackageRef) async throws -> PackageDetails { throw notInstalled }

    /// Language engines never need root (Plan 9's global constraints).
    public func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    public func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        throw notInstalled
    }

    private var notInstalled: EngineError {
        EngineError(engine: id, message: PackageCatalog.message(for: id, status: .missing) ?? "")
    }
}
