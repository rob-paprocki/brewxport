import Foundation

public struct CatalogResult: Sendable {
    /// An outdated query's held updates are here too, marked in `holds`.
    public let packages: [Package]
    public let errors: [EngineError]
    /// An outdated query's held updates (`EngineOutcome.held`): ref → why it's held. Empty for other queries.
    public let holds: [PackageRef: UpdateHold]
    /// An outdated query's packages that couldn't be checked, for each engine that had some. Empty otherwise.
    public let unchecked: [EngineID: UncheckedPackages]

    public init(packages: [Package], errors: [EngineError], holds: [PackageRef: UpdateHold] = [:],
                unchecked: [EngineID: UncheckedPackages] = [:]) {
        self.packages = packages
        self.errors = errors
        self.holds = holds
        self.unchecked = unchecked
    }
}

/// What a catalog query asks every engine for.
public enum CatalogQuery: Sendable, Equatable {
    case search(String), installed, outdated
}

/// One engine's answer to a catalog query.
public struct EngineOutcome: Sendable {
    public let engine: EngineID
    public let result: Result<[Package], EngineError>
    /// An outdated check that answered: its packages that couldn't be checked (R6). `.none` otherwise.
    public let unchecked: UncheckedPackages
    /// An outdated check that answered: the updates it holds back, with why. A hold that still lets the person
    /// update (`blocksManual` false) has its package in `result` too. Empty otherwise.
    public let held: [HeldUpdate]

    public init(engine: EngineID, result: Result<[Package], EngineError>, unchecked: UncheckedPackages = .none,
                held: [HeldUpdate] = []) {
        self.engine = engine
        self.result = result
        self.unchecked = unchecked
        self.held = held
    }

    /// One engine's outdated check, as an outcome.
    public init(engine: EngineID, report: Result<OutdatedReport, EngineError>) {
        switch report {
        case .success(let report):
            self.init(engine: engine, result: .success(report.packages), unchecked: report.unchecked,
                      held: report.held)
        case .failure(let error):
            self.init(engine: engine, result: .failure(error))
        }
    }
}

/// Queries every present engine in parallel, as a stream of per-engine outcomes or merged into one result.
public actor PackageCatalog {
    private let engines: [any Engine]
    private let arch: Arch

    private let queryTimeout: Duration
    /// The engines a detect found present, so `info` knows which it must detect first.
    private let detected = DetectedEngines()

    public init(engines: [any Engine], arch: Arch = .current, queryTimeout: Duration = BrewxPortTimeouts.engineQuery) {
        self.engines = engines
        self.arch = arch
        self.queryTimeout = queryTimeout
    }

    /// The one place that words an engine's status for people. Nil when the engine is fine.
    public static func message(for id: EngineID, status: EngineStatus) -> String? {
        switch status {
        case .present: return nil
        case .missing: return "\(id.displayName) isn't installed"
        case .unusable(_, let reason): return "\(id.displayName) is installed but not working: \(reason)"
        case .unsupported(_, _, let reason): return reason
        }
    }

    static func timeoutError(_ id: EngineID, after timeout: Duration) -> EngineError {
        EngineError(engine: id, message: "\(id.displayName) \(BrewxPortTimeouts.didntAnswer(within: timeout))")
    }

    /// The system package managers in the host's order, then the language package managers in theirs.
    public static func defaultOrder(for arch: Arch) -> [EngineID] {
        let system: [EngineID]
        switch arch {
        case .arm64: system = [.nanobrew, .homebrew, .macports, .mas]
        case .x86_64: system = [.macports, .homebrew, .nanobrew, .mas]
        }
        return system + EngineID.allCases.filter(\.isLanguage)
    }

    /// Detects every engine (missing and unusable ones included), concurrently.
    public func presentEngines() async -> [EngineID: EngineStatus] {
        let timeout = queryTimeout
        let detected = detected
        return await withTaskGroup(of: (EngineID, EngineStatus).self) { group in
            for engine in engines {
                group.addTask {
                    let status = await Self.detect(engine, timeout: timeout, recordingIn: detected)
                    return (engine.id, status)
                }
            }
            var result: [EngineID: EngineStatus] = [:]
            for await (id, status) in group { result[id] = status }
            return result
        }
    }

    /// The status of an engine whose `detect()` didn't answer in time.
    static func detectTimedOut(_ engine: any Engine, after timeout: Duration) -> EngineStatus {
        .unusable(path: engine.executableURL ?? URL(fileURLWithPath: "/"),
                  reason: BrewxPortTimeouts.didntAnswer(within: timeout))
    }

    /// `engine.detect()` against the timer, noted in `detected` when it found the engine present.
    private static func detect(_ engine: any Engine, timeout: Duration,
                               recordingIn detected: DetectedEngines) async -> EngineStatus {
        let status = await timed(timeout) { await engine.detect() } ?? detectTimedOut(engine, after: timeout)
        if case .present = status { detected.insert(engine.id) }
        return status
    }

    public func search(_ query: String) async -> CatalogResult {
        await collect(.search(query))
    }

    public func installed() async -> CatalogResult {
        await collect(.installed)
    }

    public func outdated() async -> CatalogResult {
        await collect(.outdated)
    }

    /// Details for one package from its own engine, with the same timeout and `EngineError` wording as the other queries.
    /// An engine no detect has found present yet is detected first, so details asked for before any list (a bundle
    /// row's, say) don't fail as "isn't installed"; one that isn't present says why, as the lists do.
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard let engine = engines.first(where: { $0.id == ref.engine }) else {
            throw EngineError(engine: ref.engine, message: "\(ref.engine.displayName) isn't available")
        }
        if !detected.contains(engine.id) {
            let status = await Self.detect(engine, timeout: queryTimeout, recordingIn: detected)
            if let message = Self.message(for: engine.id, status: status) {
                throw EngineError(engine: engine.id, message: message)
            }
        }
        return try await Self.race(engine, timeout: queryTimeout) { try await $0.info(ref) }.get()
    }

    /// Homebrew's third-party taps (`brew tap`), with the same detection, timeout and `EngineError` wording as the
    /// other queries. `[]` when there's no Homebrew engine or Homebrew isn't installed; throws when it's unusable.
    public func installedTaps() async throws -> [String] {
        guard let engine = engines.first(where: { $0.id == .homebrew }) else { return [] }
        let timeout = queryTimeout
        let status = await Self.detect(engine, timeout: timeout, recordingIn: detected)
        switch status {
        case .missing:
            return []
        case .unusable, .unsupported:
            throw EngineError(engine: .homebrew, message: Self.message(for: .homebrew, status: status) ?? "")
        case .present:
            return try await Self.race(engine, timeout: timeout) { engine in
                guard let taps = engine as? any TapListing else { return [] }
                return try await taps.listTaps()
            }.get()
        }
    }

    private func collect(_ query: CatalogQuery) async -> CatalogResult {
        var outcomes: [EngineOutcome] = []
        for await outcome in stream(query) { outcomes.append(outcome) }
        return Self.merge(outcomes, order: Self.defaultOrder(for: arch))
    }

    /// One element per engine that isn't missing, in the order they finish. Unusable engines and detect timeouts
    /// yield a failure. Cancelling the consumer's task cancels every query (and their child processes).
    public nonisolated func stream(_ query: CatalogQuery) -> AsyncStream<EngineOutcome> {
        let (stream, continuation) = AsyncStream<EngineOutcome>.makeStream()
        let engines = self.engines
        let timeout = queryTimeout
        let detected = detected
        let work: @Sendable (any Engine) async throws -> OutdatedReport = { engine in
            switch query {
            case .search(let text): OutdatedReport(packages: try await engine.search(text))
            case .installed: OutdatedReport(packages: try await engine.listInstalled())
            case .outdated: try await engine.checkOutdated()
            }
        }
        let task = Task {
            await withTaskGroup(of: EngineOutcome?.self) { group in
                for engine in engines {
                    group.addTask { await Self.outcome(engine, timeout: timeout, detected: detected, query: work) }
                }
                for await outcome in group {
                    if let outcome { continuation.yield(outcome) }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Detects one engine, then queries it if it's present. Nil when the engine is missing, or a version BrewxPort
    /// doesn't drive (`unsupported`): its page says so, rather than every check.
    private static func outcome(
        _ engine: any Engine, timeout: Duration, detected: DetectedEngines,
        query: @escaping @Sendable (any Engine) async throws -> OutdatedReport
    ) async -> EngineOutcome? {
        let status = await detect(engine, timeout: timeout, recordingIn: detected)
        switch status {
        case .missing, .unsupported:
            return nil
        case .unusable:
            // Not queried, but reported so a broken engine isn't silently skipped.
            let text = message(for: engine.id, status: status) ?? ""
            return EngineOutcome(engine: engine.id, result: .failure(EngineError(engine: engine.id, message: text)))
        case .present:
            return EngineOutcome(engine: engine.id, report: await race(engine, timeout: timeout, query: query))
        }
    }

    /// Merges per-engine outcomes into one list. Packages sort by name, then engine order, then kind (formula, port,
    /// app, cask, tool), so equal rows never depend on sort stability. Errors sort by engine order. Held updates join
    /// the packages (once, whether or not their engine listed them too), with their holds in `holds`.
    public static func merge(_ outcomes: [EngineOutcome], order: [EngineID]) -> CatalogResult {
        func position(_ id: EngineID) -> Int { order.firstIndex(of: id) ?? order.count }
        let kinds: [PackageKind] = [.formula, .port, .app, .cask, .tool]
        func rank(_ kind: PackageKind) -> Int { kinds.firstIndex(of: kind) ?? kinds.count }

        var packages: [Package] = []
        var errors: [EngineError] = []
        var holds: [PackageRef: UpdateHold] = [:]
        var unchecked: [EngineID: UncheckedPackages] = [:]
        for outcome in outcomes {
            switch outcome.result {
            case .success(let list):
                let listed = Set(list.map(\.id))
                packages += list
                for held in outcome.held where holds[held.package.id] == nil {
                    holds[held.package.id] = held.hold
                    if !listed.contains(held.package.id) { packages.append(held.package) }
                }
                if !outcome.unchecked.isEmpty { unchecked[outcome.engine] = outcome.unchecked }
            case .failure(let error): errors.append(error)
            }
        }
        packages.sort { a, b in
            let cmp = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            if a.id.engine != b.id.engine { return position(a.id.engine) < position(b.id.engine) }
            return rank(a.id.kind) < rank(b.id.kind)
        }
        errors.sort { position($0.engine) < position($1.engine) }
        return CatalogResult(packages: packages, errors: errors, holds: holds, unchecked: unchecked)
    }

    /// Runs `work` against a timer. Returns nil if the timer wins; the loser is cancelled.
    private static func timed<T: Sendable>(
        _ timeout: Duration, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                return nil
            }
            var winner: T?
            for await outcome in group {
                if let outcome { winner = outcome }
                break
            }
            group.cancelAll()
            return winner
        }
    }

    /// Runs one engine query against a timer. Whichever finishes first wins and the other is cancelled;
    /// cancelling the query also ends the engine's child process (see `CommandRunning`).
    private static func race<T: Sendable>(
        _ engine: any Engine,
        timeout: Duration,
        query: @escaping @Sendable (any Engine) async throws -> T
    ) async -> Result<T, EngineError> {
        await withTaskGroup(of: Result<T, EngineError>?.self) { group in
            group.addTask {
                do {
                    return .success(try await query(engine))
                } catch let error as EngineError {
                    return .failure(error)
                } catch {
                    return .failure(EngineError(engine: engine.id, message: String(describing: error)))
                }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                return .failure(timeoutError(engine.id, after: timeout))
            }
            var winner: Result<T, EngineError>?
            for await outcome in group {
                if let outcome { winner = outcome; break }
            }
            group.cancelAll()
            return winner ?? .failure(EngineError(engine: engine.id, message: "\(engine.id.displayName) was cancelled"))
        }
    }
}

/// The engines a detect has found present (`PackageCatalog.info`), shared by the catalog's concurrent queries.
private final class DetectedEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<EngineID> = []

    func insert(_ id: EngineID) { _ = lock.withLock { ids.insert(id) } }
    func contains(_ id: EngineID) -> Bool { lock.withLock { ids.contains(id) } }
}
