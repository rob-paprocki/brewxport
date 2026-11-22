import Foundation
import Observation
import Synchronization
import BrewxPortCore
import BrewxPortRun

/// "Move to…": gathers the facts for moving one installed package to another package manager, works out the plan
/// (`MovePlanner`), and starts the run through the app's one run path (password sheet, step rows, log).
///
/// Gathering, in order:
/// - Installed's rows (after any load in flight settles) give the source's packages, what the person asked for, and
///   what's already on the target.
/// - The dependents walk asks the source engine (`DependentsListing`) level by level. More than `maxPackages` in the
///   move set fails the move; a dependents call that throws fails it too (never "nobody depends on it"). A source that
///   scans everything for each answer (`DependentsMapping`, nanobrew) builds its whole map once and the walk reads it.
/// - Engine calls run at most `maxConcurrentCalls` at a time.
/// - Leftovers need two more things, and either one missing means no leftovers at all (`requested = nil`), never a
///   guess: the source's `info()` for every package in the move set and the installed packages they need, further
///   down too (at most `maxPackages` in all); and the installed dependents of each of those needed packages, so a
///   library something outside the move still uses is never offered for removal. A failed `info()`, one that doesn't
///   list dependencies, a failed dependents call, or more than `maxPackages` packages all count as "unknown".
/// - Each package in the move set is looked up on the target with `PackageCatalog.info` (which has the engine
///   timeout). It counts only when the name the engine reported (`PackageDetails.reportedName`) equals the source
///   name, ignoring case, so an alias never stands in for the package; a lookup that throws
///   or times out makes that package "can't move" ("couldn't find it on <target>", or "<target> didn't answer in
///   time"). A package already in Installed's target rows isn't looked up. A dependent that can't move at all (an app, a third-party tap formula) gets its
///   reason without a lookup.
@MainActor @Observable public final class MoveModel {
    public enum State: Equatable, Sendable {
        case hidden
        case checking
        case ready(MovePlan)
        case failed(String)
        case running
    }

    public private(set) var state: State = .hidden

    /// The PATH warning's "Add to PATH": not clicked yet, done (added, or already there), or failed with the reason.
    public enum PathFix: Equatable, Sendable {
        case offered
        case done(ShellPathEditor.Outcome)
        case failed(String)
    }

    /// Starts over with every preview.
    public private(set) var pathFix: PathFix = .offered

    /// Whether "Add to PATH" can write a file, or only offer the line to copy. Read from the home folder once per
    /// preview, when its plan is ready, not on every redraw.
    public private(set) var pathOffer: ShellPathEditor.Offer = .copyOnly(hint: nil)

    /// The line the PATH warning offers; nil when the plan has no warning.
    public var pathLine: String? {
        guard case .ready(let plan) = state, let bin = plan.pathBin else { return nil }
        return ShellPathEditor.line(for: bin)
    }

    public var isDemo: Bool { services.isDemo }

    /// The preview sheet is up: checking, showing a plan, or showing why there's none. Not while the move runs.
    public var sheetShown: Bool {
        switch state {
        case .checking, .ready, .failed: return true
        case .hidden, .running: return false
        }
    }

    /// The most packages one move gathers facts for.
    static let maxPackages = 200

    /// How long one dependents call may take. Tests shorten it.
    @ObservationIgnored var queryTimeout: Duration = BrewxPortTimeouts.engineQuery
    @ObservationIgnored private let services: Services
    @ObservationIgnored private let installed: InstalledModel
    @ObservationIgnored private weak var app: BrewxPortAppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start and cancel, so an answer for an earlier start is dropped.
    @ObservationIgnored private var generation = 0
    /// The source's maps behind the plan on screen; `MoveRunBuilder` orders the removals with them.
    @ObservationIgnored private var graph: (dependents: [String: Set<String>], dependencies: [String: Set<String>]) = ([:], [:])
    /// The move that's running: its plan, its steps, what its check found missing, and the run's number.
    @ObservationIgnored private var running: (MovePlan, MoveRun, MissingOnTarget, Int)?

    init(services: Services, installed: InstalledModel) {
        self.services = services
        self.installed = installed
    }

    /// Called once by the app model after it's set up: the run state and the run path come from it.
    func connect(_ app: BrewxPortAppModel) {
        self.app = app
        app.addRunEndedObserver { [weak self] in self?.runEnded() }
    }

    /// Gathers the facts for moving `package` to `target` and shows the plan. Does nothing in demo mode, during a run
    /// (or while a move is running), or for a package that can't be offered a move. A start while checking replaces
    /// that check.
    public func start(_ package: Package, to target: EngineID) {
        guard !services.isDemo, state != .running, let app, !app.busy else { return }
        let sourceID = package.id.engine
        guard target != sourceID,
              let sourceEngine = services.engines.first(where: { $0.id == sourceID }),
              let listing = sourceEngine as? any DependentsListing,
              MovePlanner.isMovable(package, engineHasDependents: true) else { return }
        task?.cancel()
        generation += 1
        let mine = generation
        state = .checking
        pathFix = .offered
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.gather(package, to: target, listing: listing)
            guard !Task.isCancelled, self.generation == mine else { return }
            switch outcome {
            case .success(let gathered):
                self.graph = (gathered.dependents, gathered.dependencies)
                self.pathOffer = self.services.shellPath.offer
                self.state = .ready(MovePlanner.plan(gathered))
            case .failure(let failure):
                self.state = .failed(failure.message)
            }
        }
    }

    /// The sheet's "Also remove leftovers" toggle.
    public func setRemoveLeftovers(_ on: Bool) {
        guard case .ready(var plan) = state else { return }
        plan.removeLeftovers = on
        state = .ready(plan)
    }

    /// "Add to PATH": appends the warning's line to the login shell's startup file, the one the sheet named
    /// (`pathOffer`). Only on a click, never in demo mode. Once it's there, the cached PATH is dropped so the Runs
    /// column and later previews see it.
    public func addToPath() {
        guard !services.isDemo, case .ready(let plan) = state, let bin = plan.pathBin else { return }
        do {
            let outcome = try services.shellPath.add(bin, to: pathOffer)
            pathFix = .done(outcome)
            installed.pathChanged()
        } catch {
            pathFix = .failed(MoveSheetText.pathFixFailure(error))
        }
    }

    /// The Copy button for a shell BrewxPort doesn't edit.
    public func copyPathLine() {
        guard let line = pathLine else { return }
        app?.writeToPasteboard(line)
    }

    /// Starts the move shown in the sheet. Does nothing unless a plan is showing and nothing else is running.
    public func confirm() {
        guard case .ready(let plan) = state, let app, app.canRun, !app.busy else { return }
        let run: MoveRun
        do {
            run = try MoveRunBuilder.run(for: plan, engines: services.engines, dependents: graph.dependents,
                                         dependencies: graph.dependencies)
        } catch let error as MoveRunError {
            switch error {
            case .nothingToMove: state = .failed("Nothing here can move to \(plan.target.displayName).")
            case .engineMissing(let id): state = .failed("\(id.displayName) isn't available.")
            }
            return
        } catch let error as EngineError {
            state = .failed(EngineErrorText.line(error))
            return
        } catch {
            state = .failed("BrewxPort couldn't plan the move: \(error.localizedDescription)")
            return
        }
        state = .running
        let found = MissingOnTarget()
        // A run that had nothing it could do never started (the run panel says why), so there's nothing to wait for.
        guard app.startMove(run.actions, checked: { found.set($0) }) else {
            state = .hidden
            return
        }
        running = (plan, run, found, app.run.runNumber)
    }

    /// Closes the sheet. A check in flight is dropped. A running move is the run panel's to cancel.
    public func cancel() {
        guard state != .running else { return }
        task?.cancel()
        task = nil
        generation += 1
        state = .hidden
    }

    /// After a move's run: one line in the run panel when an old copy wasn't removed (`MoveRunSummary`).
    private func runEnded() {
        guard state == .running else { return }
        state = .hidden
        guard let (plan, run, found, number) = running, let app else { return }
        running = nil
        let missing = found.get()?.map { ref in
            plan.moving.first { $0.new.id == ref }?.new.displayName ?? ref.name
        }
        if let note = MoveRunSummary.note(for: run, rows: app.run.steps, missing: missing,
                                          source: plan.picked.id.engine, target: plan.target) {
            app.run.addProblem(note, run: number)
        }
    }

    // MARK: Gathering

    struct GatherFailure: Error {
        let message: String
    }

    private func gather(_ picked: Package, to target: EngineID,
                        listing: any DependentsListing) async -> Result<MoveFacts, GatherFailure> {
        let source = picked.id.engine
        await installed.settled()
        let rows = installed.list.all.map(\.package)

        // The source's packages by lower-cased name: formulae and ports first, so a cask of the same name never
        // stands in for a formula.
        var sourceInstalled: [String: Package] = [:]
        let sourceRows = rows.filter { $0.id.engine == source }
        for package in sourceRows.sorted(by: { Self.isCommand($0) && !Self.isCommand($1) }) {
            let key = package.id.name.lowercased()
            if sourceInstalled[key] == nil { sourceInstalled[key] = package }
        }
        var pickedRow = picked
        if let row = sourceRows.first(where: { $0.id == picked.id }) { pickedRow = row }
        var requested: Set<String>? = []
        for package in sourceRows where Self.isCommand(package) {
            guard let asked = package.installedOnRequest else { requested = nil; break }
            if asked { requested?.insert(package.id.name.lowercased()) }
        }
        var onTargetRows: [String: Package] = [:]
        for package in rows where package.id.engine == target && Self.isCommand(package) {
            onTargetRows[package.id.name.lowercased()] = onTargetRows[package.id.name.lowercased()] ?? package
        }

        // The move set: the picked package and everything that depends on it.
        let pickedKey = picked.id.name.lowercased()
        let timeout = queryTimeout
        let askDependents: @Sendable (String) async throws -> Set<String>
        if let mapping = listing as? any DependentsMapping {
            // nanobrew scans every installed formula for each answer, so the scan runs once for the whole move. Each
            // of its calls has the timeout, so its budget grows with the number of formulae.
            let map: [String: Set<String>]
            do {
                map = try await mapping.installedDependentsMap(callTimeout: timeout)
            } catch {
                return .failure(GatherFailure(message: "BrewxPort couldn't find out what depends on \(picked.displayName): "
                                                  + Self.text(error)))
            }
            askDependents = { name in Set((map[name] ?? []).map { $0.lowercased() }) }
        } else {
            askDependents = { name in
                let found = try await firstResult(within: timeout) { try await listing.installedDependents(of: name) }
                return Set(found.map { $0.lowercased() })
            }
        }
        var dependents: [String: Set<String>]
        switch await Self.walk(from: [pickedKey], limit: Self.maxPackages, edges: askDependents) {
        case .success(let found): dependents = found
        case .failure(.tooMany):
            return .failure(GatherFailure(message: "Too many packages depend on \(picked.displayName) to move it here."))
        case .failure(.failed(let error)):
            return .failure(GatherFailure(message: "BrewxPort couldn't find out what depends on \(picked.displayName): "
                                              + Self.text(error)))
        }
        let members = Array(dependents.keys)

        // Dependencies, for the leftovers only: unknown means no leftovers.
        var dependencies: [String: Set<String>] = [:]
        if requested != nil {
            let catalog = services.catalog
            let installedNow = sourceInstalled
            let pickedKind = picked.id.kind
            let askDependencies: @Sendable (String) async throws -> Set<String> = { name in
                let ref = installedNow[name]?.id ?? PackageRef(engine: source, kind: pickedKind, name: name)
                guard let needs = try await catalog.info(ref).dependencies else { throw GatherFailure(message: "") }
                return Set(needs.map { $0.lowercased() }.filter { installedNow[$0] != nil })
            }
            if case .success(let found) = await Self.walk(from: members, limit: Self.maxPackages,
                                                          edges: askDependencies) {
                dependencies = found
                // Who else uses each package the move set needs, so a shared one is never a leftover.
                let needed = found.keys.filter { dependents[$0] == nil }
                if case .success(let users) = await Self.each(needed, askDependents) {
                    dependents.merge(users) { $0.union($1) }
                } else {
                    requested = nil
                }
            } else {
                requested = nil
            }
            if requested == nil { dependencies = [:] }
        }

        // Each member on the target.
        let catalog = services.catalog
        let targetKind: PackageKind = target == .macports ? .port : .formula
        var onTarget: [String: TargetLookup] = [:]
        var toLookUp: [String] = []
        for name in members {
            let old = name == pickedKey ? pickedRow : sourceInstalled[name]
            if let old, !MovePlanner.isMovable(old, engineHasDependents: true) {
                onTarget[name] = .failed(Self.unmovableReason(old))
            } else if let there = onTargetRows[name] {
                onTarget[name] = .alreadyInstalled(there)
            } else {
                toLookUp.append(name)
            }
        }
        // A lookup never throws (a failure is its answer), so a missing entry can only come from cancellation, and
        // a member without an entry counts as not on the target.
        let lookups = (try? await concurrentMap(toLookUp, limit: Self.maxConcurrentCalls) { name -> TargetLookup in
            let ref = PackageRef(engine: target, kind: targetKind, name: name)
            do {
                return Self.lookup(try await catalog.info(ref), for: name)
            } catch {
                return .failed(Self.lookupFailure(error, target: target))
            }
        }) ?? [:]
        onTarget.merge(lookups) { $1 }

        // The PATH check: the target's bin directory against the login shell's PATH.
        guard let targetEngine = services.engines.first(where: { $0.id == target }),
              let executable = targetEngine.executableURL
                ?? EngineLocator().locate(target, arch: targetEngine.runArch) else {
            return .failure(GatherFailure(message: "\(target.displayName) isn't installed."))
        }
        let pathEntries = await services.path.resolve().entries

        return .success(MoveFacts(picked: pickedRow, target: target, dependents: dependents,
                                  dependencies: dependencies, requested: requested,
                                  sourceInstalled: sourceInstalled, onTarget: onTarget, pathEntries: pathEntries,
                                  targetBin: executable.deletingLastPathComponent().path))
    }

    private static func isCommand(_ package: Package) -> Bool {
        package.id.kind == .formula || package.id.kind == .port
    }

    /// Why a dependent can't move, for the sheet.
    private static func unmovableReason(_ package: Package) -> String {
        if package.id.kind == .cask || package.id.kind == .app || package.id.engine == .mas {
            return "a \(package.id.engine.displayName) app"
        }
        if package.fullName != nil { return "from a third-party tap" }
        return "can't be moved"
    }

    /// A target lookup that threw, in the preview's words: a timeout says so, anything else (the engine's own error
    /// text, which also covers "no such package") is "couldn't find it". The raw text isn't shown; there's no log for it.
    nonisolated static func lookupFailure(_ error: any Error, target: EngineID) -> String {
        let timedOut = error is CallTimedOut
            || (error as? EngineError)?.message.contains("didn't answer within") == true
        return timedOut ? "\(target.displayName) didn't answer in time" : "couldn't find it on \(target.displayName)"
    }

    /// A target's answer for the lower-cased source name `name`. It counts only when the name the engine itself
    /// reported equals `name`, ignoring case: Homebrew answers an alias with another formula, so `python3` would
    /// otherwise "find" `python@3.15`. An answer that names nothing counts as not found.
    nonisolated static func lookup(_ details: PackageDetails, for name: String) -> TargetLookup {
        guard let reported = details.reportedName, reported.lowercased() == name else { return .notFound }
        return .found(Package(id: details.ref, displayName: reported, latestVersion: details.latestVersion,
                              summary: details.summary))
    }

    nonisolated private static func text(_ error: any Error) -> String {
        if let error = error as? EngineError { return EngineErrorText.line(error) }
        if let error = error as? CallTimedOut { return BrewxPortTimeouts.didntAnswer(within: error.timeout) }
        if case CommandRunnerError.timedOut(let after) = error { return BrewxPortTimeouts.didntAnswer(within: after) }
        return error.localizedDescription
    }

    enum WalkError: Error {
        case tooMany
        case failed(any Error)
    }

    /// The most engine calls one gather runs at once (dependents, `info()` and target lookups each).
    nonisolated static let maxConcurrentCalls = 6

    /// Breadth-first from `start`, asking `edges` for every name once (a level at a time, concurrently). Returns each
    /// visited name's answer. More than `limit` names visited, or any `edges` call throwing, ends the walk.
    nonisolated static func walk(from start: [String], limit: Int,
                                 edges: @escaping @Sendable (String) async throws -> Set<String>)
        async -> Result<[String: Set<String>], WalkError> {
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
    nonisolated static func each(_ names: [String], _ edges: @escaping @Sendable (String) async throws -> Set<String>)
        async -> Result<[String: Set<String>], WalkError> {
        do {
            return .success(try await concurrentMap(names, limit: maxConcurrentCalls, edges))
        } catch {
            return .failure(.failed(error))
        }
    }
}

/// What a move's check step found missing on the target, set from the run's verifier.
final class MissingOnTarget: Sendable {
    private let value = Mutex<[PackageRef]?>(nil)
    func set(_ refs: [PackageRef]) { value.withLock { $0 = refs } }
    func get() -> [PackageRef]? { value.withLock { $0 } }
}
