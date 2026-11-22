import Foundation
import BrewxPortCore

/// What one package manager says about some picked packages, for working out leftovers. Every map is keyed by
/// lower-cased name, and every name in a value is lower-cased too.
public struct DependencyFacts: Sendable {
    /// The picks and every installed package that depends on them, directly or further down.
    public var affected: Set<String>
    /// Name → the installed packages that depend on it directly. Covers `affected` and, when `dependenciesComplete`,
    /// every package in `dependencies`.
    public var dependents: [String: Set<String>]
    /// Name → the installed packages it depends on directly, for `affected` and everything they need, further down.
    /// Empty unless `dependenciesComplete`.
    public var dependencies: [String: Set<String>]
    /// The formulae and ports the person asked for. nil when any installed one can't say (nanobrew), or when the
    /// dependencies or their dependents couldn't be read: no leftovers then, never a guess.
    public var requested: Set<String>?
    /// The package manager's installed packages; formulae and ports win over a cask of the same name. Each keeps its
    /// own `installedOnRequest`.
    public var installed: [String: Package]
    /// Whether `dependencies` (and the dependents of everything in it) were read in full. false when that walk was
    /// skipped or failed: no leftovers then.
    public var dependenciesComplete: Bool

    public init(affected: Set<String>, dependents: [String: Set<String>], dependencies: [String: Set<String>],
                requested: Set<String>?, installed: [String: Package], dependenciesComplete: Bool) {
        self.affected = affected
        self.dependents = dependents
        self.dependencies = dependencies
        self.requested = requested
        self.installed = installed
        self.dependenciesComplete = dependenciesComplete
    }
}

/// Gathers `DependencyFacts` from one package manager.
///
/// - The dependents walk asks the engine (`DependentsListing`) level by level, each call within `timeout`. More than
///   `limit` packages, or a call that throws, fails the gather (never "nobody depends on it"). An engine that scans
///   everything for each answer (`DependentsMapping`, nanobrew) builds its whole map once and the walk reads it.
/// - Dependencies are walked only when `requested` is known, or when the caller asks for the walk anyway (Uninstall,
///   which reads what was asked for package by package). They need two more things, and either one missing makes
///   `requested` nil and `dependenciesComplete` false rather than failing the gather:
///   `info()` for every affected package and the installed packages they need, further down too (at most `limit` in
///   all); and the installed dependents of each of those needed packages, so a library something else still uses is
///   never offered for removal. A failed `info()`, one that doesn't list dependencies, a failed dependents call, or
///   more than `limit` packages all count as unknown.
/// - Engine calls run at most `maxConcurrentCalls` at a time.
public struct DependencyGatherer: Sendable {
    public enum Failure: Error {
        /// More than `limit` packages in the dependents walk.
        case tooMany
        /// The engine's error, as thrown.
        case failed(any Error)
    }

    /// The most engine calls one gather runs at once.
    public static let maxConcurrentCalls = 6
    /// The default for `limit`.
    public static let maxPackages = 200

    private let engines: [any Engine]
    private let catalog: any PackageQuerying
    private let timeout: Duration
    private let limit: Int

    /// - Parameters:
    ///   - timeout: How long one dependents call may take. `info()` calls have the catalog's own timeout.
    ///   - limit: The most packages one walk visits.
    public init(engines: [any Engine], catalog: any PackageQuerying,
                timeout: Duration = BrewxPortTimeouts.engineQuery, limit: Int = maxPackages) {
        self.engines = engines
        self.catalog = catalog
        self.timeout = timeout
        self.limit = limit
    }

    /// The facts for removing `picks` from `engine`. `rows` are the installed packages to read the installed map and
    /// what was asked for from (Installed's rows, all package managers; only `engine`'s are used).
    /// `walkDependenciesWhenRequestedUnknown`: walk the dependencies even when `requested` is nil (it stays nil).
    /// Throws only when the dependents walk fails.
    public func facts(for picks: [Package], engine source: EngineID, installed rows: [Package],
                      walkDependenciesWhenRequestedUnknown: Bool = false) async throws(Failure) -> DependencyFacts {
        var installed: [String: Package] = [:]
        let sourceRows = rows.filter { $0.id.engine == source }
        for package in sourceRows.sorted(by: { Self.isCommand($0) && !Self.isCommand($1) }) {
            let key = package.id.name.lowercased()
            if installed[key] == nil { installed[key] = package }
        }
        var requested: Set<String>? = []
        for package in sourceRows where Self.isCommand(package) {
            guard let asked = package.installedOnRequest else { requested = nil; break }
            if asked { requested?.insert(package.id.name.lowercased()) }
        }
        guard let firstPick = picks.first else {
            return DependencyFacts(affected: [], dependents: [:], dependencies: [:], requested: requested,
                                   installed: installed, dependenciesComplete: true)
        }

        // The picks and everything that depends on them.
        guard let listing = engines.first(where: { $0.id == source }) as? any DependentsListing else {
            throw .failed(EngineError(engine: source, message: "\(source.displayName) can't list dependents"))
        }
        let timeout = timeout
        let askDependents: @Sendable (String) async throws -> Set<String>
        if let mapping = listing as? any DependentsMapping {
            // nanobrew scans every installed formula for each answer, so the scan runs once for the whole gather. Each
            // of its calls has the timeout, so its budget grows with the number of formulae.
            let map: [String: Set<String>]
            do {
                map = try await mapping.installedDependentsMap(callTimeout: timeout)
            } catch {
                throw .failed(error)
            }
            askDependents = { name in Set((map[name] ?? []).map { $0.lowercased() }) }
        } else {
            askDependents = { name in
                let found = try await firstResult(within: timeout) { try await listing.installedDependents(of: name) }
                return Set(found.map { $0.lowercased() })
            }
        }
        let pickKeys = picks.map { $0.id.name.lowercased() }
        var dependents: [String: Set<String>]
        switch await Self.walk(from: pickKeys, limit: limit, edges: askDependents) {
        case .success(let found): dependents = found
        case .failure(let failure): throw failure
        }
        let affected = Set(dependents.keys)

        // Dependencies, for the leftovers only: unknown means no leftovers.
        var dependencies: [String: Set<String>] = [:]
        var dependenciesComplete = false
        if requested != nil || walkDependenciesWhenRequestedUnknown {
            let catalog = catalog
            let installedNow = installed
            // A name that isn't installed is asked about with its pick's kind, or the first pick's.
            var pickKinds: [String: PackageKind] = [:]
            for pick in picks where pickKinds[pick.id.name.lowercased()] == nil {
                pickKinds[pick.id.name.lowercased()] = pick.id.kind
            }
            let kinds = pickKinds
            let fallbackKind = firstPick.id.kind
            let askDependencies: @Sendable (String) async throws -> Set<String> = { name in
                let ref = installedNow[name]?.id
                    ?? PackageRef(engine: source, kind: kinds[name] ?? fallbackKind, name: name)
                guard let needs = try await catalog.info(ref).dependencies else { throw DependenciesUnknown() }
                return Set(needs.map { $0.lowercased() }.filter { installedNow[$0] != nil })
            }
            if case .success(let found) = await Self.walk(from: Array(affected), limit: limit, edges: askDependencies) {
                dependencies = found
                // Who else uses each package the affected ones need, so a shared one is never a leftover.
                let needed = found.keys.filter { dependents[$0] == nil }
                if case .success(let users) = await Self.each(needed, askDependents) {
                    dependents.merge(users) { $0.union($1) }
                    dependenciesComplete = true
                }
            }
            if !dependenciesComplete {
                requested = nil
                dependencies = [:]
            }
        }

        return DependencyFacts(affected: affected, dependents: dependents, dependencies: dependencies,
                               requested: requested, installed: installed,
                               dependenciesComplete: dependenciesComplete)
    }

    private struct DependenciesUnknown: Error {}

    private static func isCommand(_ package: Package) -> Bool {
        package.id.kind == .formula || package.id.kind == .port
    }

    /// Breadth-first from `start`, asking `edges` for every name once (a level at a time, concurrently). Returns each
    /// visited name's answer. More than `limit` names visited, or any `edges` call throwing, ends the walk.
    static func walk(from start: [String], limit: Int, edges: @escaping @Sendable (String) async throws -> Set<String>)
        async -> Result<[String: Set<String>], Failure> {
        var seen = Set(start)
        guard seen.count <= limit else { return .failure(.tooMany) }
        var answers: [String: Set<String>] = [:]
        var level = Array(seen)
        while !level.isEmpty {
            switch await each(level, edges) {
            case .failure(let error): return .failure(error)
            case .success(let found):
                answers.merge(found) { $1 }
                var next: Set<String> = []
                for names in found.values { next.formUnion(names.subtracting(seen)) }
                seen.formUnion(next)
                guard seen.count <= limit else { return .failure(.tooMany) }
                level = Array(next)
            }
        }
        return .success(answers)
    }

    /// `edges` for every name, at most `maxConcurrentCalls` at a time; the first error ends it.
    static func each(_ names: [String], _ edges: @escaping @Sendable (String) async throws -> Set<String>)
        async -> Result<[String: Set<String>], Failure> {
        do {
            return .success(try await concurrentMap(names, limit: maxConcurrentCalls, edges))
        } catch {
            return .failure(.failed(error))
        }
    }
}
