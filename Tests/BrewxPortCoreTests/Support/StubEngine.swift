import Foundation
@testable import BrewxPortCore

/// Test double for `Engine` with per-method results and a lock-guarded call log.
final class StubEngine: Engine, @unchecked Sendable {
    let id: EngineID
    let capabilities: EngineCapabilities = []
    let executableURL: URL?
    private let status: EngineStatus
    private let searchResult: Result<[Package], Error>
    private let installedResult: Result<[Package], Error>
    private let outdatedResult: Result<[Package], Error>
    private let infoResult: Result<PackageDetails, Error>
    private let onInfo: (@Sendable () async -> Void)?
    private let onSearch: (@Sendable () async -> Void)?
    private let onDetect: (@Sendable () async -> Void)?
    private let lock = NSLock()
    private var _calls: [String] = []

    init(
        id: EngineID,
        status: EngineStatus = .present(path: URL(fileURLWithPath: "/usr/bin/true"), version: "1"),
        search: Result<[Package], Error> = .success([]),
        installed: Result<[Package], Error> = .success([]),
        outdated: Result<[Package], Error> = .success([]),
        info: Result<PackageDetails, Error> = .failure(EngineError(engine: .homebrew, message: "stub")),
        onInfo: (@Sendable () async -> Void)? = nil,
        onSearch: (@Sendable () async -> Void)? = nil,
        onDetect: (@Sendable () async -> Void)? = nil,
        executableURL: URL? = nil
    ) {
        self.executableURL = executableURL
        self.onDetect = onDetect
        self.id = id
        self.status = status
        self.searchResult = search
        self.installedResult = installed
        self.outdatedResult = outdated
        self.onSearch = onSearch
        self.infoResult = info
        self.onInfo = onInfo
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    private func log(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(name)
    }

    func detect() async -> EngineStatus {
        if let onDetect { await onDetect() }
        return status
    }

    func search(_ query: String) async throws -> [Package] {
        log("search")
        if let onSearch { await onSearch() }
        return try searchResult.get()
    }

    func listInstalled() async throws -> [Package] {
        log("listInstalled")
        return try installedResult.get()
    }

    func listOutdated() async throws -> [Package] {
        log("listOutdated")
        return try outdatedResult.get()
    }

    func info(_ ref: PackageRef) async throws -> PackageDetails {
        log("info")
        if let onInfo { await onInfo() }
        return try infoResult.get()
    }

    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }

    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        throw EngineError(engine: id, message: "stub")
    }
}

/// Two-party barrier: each caller arrives, then waits until the other has arrived too.
actor TwoPartyBarrier {
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived += 1
        if arrived >= 2 {
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
