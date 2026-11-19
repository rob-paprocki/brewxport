import Foundation

public struct CatalogResult: Sendable {
    public let packages: [Package]
    public let errors: [EngineError]

    public init(packages: [Package], errors: [EngineError]) {
        self.packages = packages
        self.errors = errors
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

    public init(engine: EngineID, result: Result<[Package], EngineError>) {
        self.engine = engine
        self.result = result
    }
}

/// Queries every present engine in parallel, as a stream of per-engine outcomes or merged into one result.
public actor PackageCatalog {
    private let engines: [any Engine]
    private let arch: Arch

    private let queryTimeout: Duration

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
        }
    }

    static func timeoutError(_ id: EngineID, after timeout: Duration) -> EngineError {
        EngineError(engine: id, message: "\(id.displayName) \(BrewxPortTimeouts.didntAnswer(within: timeout))")
    }

    public static func defaultOrder(for arch: Arch) -> [EngineID] {
        switch arch {
        case .arm64: return [.nanobrew, .homebrew, .macports, .mas]
        case .x86_64: return [.macports, .homebrew, .nanobrew, .mas]
        }
    }

    /// Detects every engine (missing and unusable ones included), concurrently.
    public func presentEngines() async -> [EngineID: EngineStatus] {
        let timeout = queryTimeout
        return await withTaskGroup(of: (EngineID, EngineStatus).self) { group in
            for engine in engines {
                group.addTask {
                    let status = await Self.timed(timeout) { await engine.detect() }
                        ?? Self.detectTimedOut(engine, after: timeout)
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
    public func info(_ ref: PackageRef) async throws -> PackageDetails {
        guard let engine = engines.first(where: { $0.id == ref.engine }) else {
            throw EngineError(engine: ref.engine, message: "\(ref.engine.displayName) isn't available")
        }
        return try await Self.race(engine, timeout: queryTimeout) { try await $0.info(ref) }.get()
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
        let work: @Sendable (any Engine) async throws -> [Package] = { engine in
            switch query {
            case .search(let text): try await engine.search(text)
            case .installed: try await engine.listInstalled()
            case .outdated: try await engine.listOutdated()
            }
        }
        let task = Task {
            await withTaskGroup(of: EngineOutcome?.self) { group in
                for engine in engines {
                    group.addTask { await Self.outcome(engine, timeout: timeout, query: work) }
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

    /// Detects one engine, then queries it if it's present. Nil when the engine is missing.
    private static func outcome(
        _ engine: any Engine, timeout: Duration,
        query: @escaping @Sendable (any Engine) async throws -> [Package]
    ) async -> EngineOutcome? {
        let status = await timed(timeout) { await engine.detect() } ?? detectTimedOut(engine, after: timeout)
        switch status {
        case .missing:
            return nil
        case .unusable:
            // Not queried, but reported so a broken engine isn't silently skipped.
            let text = message(for: engine.id, status: status) ?? ""
            return EngineOutcome(engine: engine.id, result: .failure(EngineError(engine: engine.id, message: text)))
        case .present:
            return EngineOutcome(engine: engine.id, result: await race(engine, timeout: timeout, query: query))
        }
    }

    /// Merges per-engine outcomes into one list. Packages sort by name, then engine order, then kind (formula, port,
    /// app, cask), so equal rows never depend on sort stability. Errors sort by engine order.
    public static func merge(_ outcomes: [EngineOutcome], order: [EngineID]) -> CatalogResult {
        func position(_ id: EngineID) -> Int { order.firstIndex(of: id) ?? order.count }
        let kinds: [PackageKind] = [.formula, .port, .app, .cask]
        func rank(_ kind: PackageKind) -> Int { kinds.firstIndex(of: kind) ?? kinds.count }

        var packages: [Package] = []
        var errors: [EngineError] = []
        for outcome in outcomes {
            switch outcome.result {
            case .success(let list): packages += list
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
        return CatalogResult(packages: packages, errors: errors)
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
