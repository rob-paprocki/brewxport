import Foundation
import BrewxPortCore
import BrewxPortRun

public protocol RunExecuting: Sendable {
    /// `verify` answers the run's check steps (`RunStep.verifyInstalled`).
    func run(_ steps: [RunStep], reason: String, verify: @escaping InstalledVerifier) -> AsyncStream<RunEvent>
    func cancel()
}

extension RunExecuting {
    /// A run whose check steps all fail (`RunSession.failClosed`).
    public func run(_ steps: [RunStep], reason: String) -> AsyncStream<RunEvent> {
        run(steps, reason: reason, verify: RunSession.failClosed)
    }
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
    /// Homebrew's third-party taps; `[]` when Homebrew is missing.
    func installedTaps() async throws -> [String]
}

extension PackageQuerying {
    public func installedTaps() async throws -> [String] { [] }
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
    /// The Mac's chip and macOS version, for package-manager setup. Tests pin it.
    public let hostInfo: HostInfo
    /// Whether the Command Line Tools are installed. Live: the marker file. Tests pin it.
    public let cltPresent: @Sendable () -> Bool
    public let receipts: any InstallerReceiptReading
    public let setupProblem: String?
    public let isDemo: Bool
    /// Times the background checks. Demo: never fires.
    public let scheduler: any BackgroundScheduling
    /// macOS notifications. Demo: grants and keeps posts, shows nothing.
    public let notifier: any UpdateNotifying
    /// Open BrewxPort at login. Demo: remembers the choice, registers nothing.
    public let loginItem: any LoginItemControlling
    /// Screen lock, recent input, battery and Low Power Mode. Demo: at the Mac, on power.
    public let conditions: any SystemConditions
    /// The move preview's "Add to PATH". Defaults to copy-only, which never writes.
    public let shellPath: ShellPathEditor

    public init(
        engines: [any Engine], catalog: any PackageQuerying, executor: (any RunExecuting)?,
        helper: (any HelperManaging)?, passwords: PromptPasswordProvider, isAdministrator: @escaping AdminCheck,
        store: any KeyValueStoring, path: any PathResolving, fileExists: @escaping @Sendable (String) -> Bool,
        host: Arch, hostInfo: HostInfo, cltPresent: @escaping @Sendable () -> Bool,
        receipts: any InstallerReceiptReading, setupProblem: String?, isDemo: Bool,
        scheduler: any BackgroundScheduling, notifier: any UpdateNotifying, loginItem: any LoginItemControlling,
        conditions: any SystemConditions, shellPath: ShellPathEditor? = nil
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
        self.hostInfo = hostInfo
        self.cltPresent = cltPresent
        self.receipts = receipts
        self.setupProblem = setupProblem
        self.isDemo = isDemo
        self.scheduler = scheduler
        self.notifier = notifier
        self.loginItem = loginItem
        self.conditions = conditions
        self.shellPath = shellPath ?? .copyOnly
    }
}
