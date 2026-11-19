import Foundation
import BrewxPortCore
import BrewxPortRun

public protocol RunExecuting: Sendable {
    func run(_ steps: [RunStep], reason: String) -> AsyncStream<RunEvent>
    func cancel()
}
extension RunSession: RunExecuting {}

public protocol HelperManaging: Sendable {
    /// Read-only: "Check again" uses this, never re-registers.
    func refresh() async -> HelperState
    func ensureRegistered() async -> HelperState
    func reinstall() async -> HelperState
    func openLoginItems()
}
extension HelperRegistration: HelperManaging {}

public protocol PackageQuerying: Sendable {
    func presentEngines() async -> [EngineID: EngineStatus]
    func stream(_ query: CatalogQuery) -> AsyncStream<EngineOutcome>
    func info(_ ref: PackageRef) async throws -> PackageDetails
}
extension PackageCatalog: PackageQuerying {}

/// Everything the UI needs from the outside world. Live, demo and test copies differ only here.
public struct Services: Sendable {
    public let engines: [any Engine]
    public let catalog: any PackageQuerying
    /// Nil: this copy can't run anything (`setupProblem` says why).
    public let executor: (any RunExecuting)?
    /// Nil in demo mode and when unsigned.
    public let helper: (any HelperManaging)?
    public let passwords: PromptPasswordProvider
    public let isAdministrator: AdminCheck
    public let store: any KeyValueStoring
    public let path: any PathResolving
    /// Live: FileManager. Demo: the fixture inventory read at launch.
    public let fileExists: @Sendable (String) -> Bool
    public let host: Arch
    public let setupProblem: String?
    public let isDemo: Bool

    public init(
        engines: [any Engine], catalog: any PackageQuerying, executor: (any RunExecuting)?,
        helper: (any HelperManaging)?, passwords: PromptPasswordProvider, isAdministrator: @escaping AdminCheck,
        store: any KeyValueStoring, path: any PathResolving, fileExists: @escaping @Sendable (String) -> Bool,
        host: Arch, setupProblem: String?, isDemo: Bool
    ) {
        self.engines = engines
        self.catalog = catalog
        self.executor = executor
        self.helper = helper
        self.passwords = passwords
        self.isAdministrator = isAdministrator
        self.store = store
        self.path = path
        self.fileExists = fileExists
        self.host = host
        self.setupProblem = setupProblem
        self.isDemo = isDemo
    }
}
