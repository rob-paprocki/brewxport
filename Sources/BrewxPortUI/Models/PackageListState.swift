import Foundation
import Observation
import BrewxPortCore

/// The list state Discover, Updates and Installed share (each composes one; none re-implements it).
@MainActor @Observable public final class PackageListState {
    /// Empty means catalog order (`PackageCatalog.merge`).
    public var sortOrder: [KeyPathComparator<PackageRow>] = [] { didSet { recompute() } }
    public var selection = PackageSelection()
    /// Set by the owning model (engine filter, ignored packages...). Call `recompute()` after its inputs change.
    @ObservationIgnored public var isVisible: (PackageRow) -> Bool = { _ in true }
    /// Refs known to be installed. Search results carry no installed version, so Discover sets this from the
    /// installed list; it's applied on every merge, because rows are rebuilt after each engine answers.
    @ObservationIgnored public var installedRefs: Set<PackageRef> = [] { didSet { recompute() } }
    /// Installed archs for rows whose own answer doesn't carry them (Updates borrows Installed's).
    @ObservationIgnored public var borrowedArchs: [PackageRef: Set<Arch>] = [:] { didSet { recompute() } }

    /// Merged, before `isVisible`.
    public private(set) var all: [PackageRow] = []
    /// `isVisible`, then `sortOrder`.
    public private(set) var rows: [PackageRow] = []
    public private(set) var errors: [String] = []
    /// The engines whose latest answer was an error (the ones `errors` names).
    public private(set) var failedEngines: Set<EngineID> = []
    /// Updates only: for each engine whose latest check answered but couldn't check some packages (R6), which. An
    /// engine in `failedEngines` has no entry.
    public private(set) var unchecked: [EngineID: UncheckedPackages] = [:]
    /// The engines whose answer the list holds, an error included. Once a load has ended, exactly the ones that
    /// answered it: an engine that didn't answer has no rows, but they weren't reported gone.
    public var answeredEngines: Set<EngineID> { Set(outcomes.keys) }
    public private(set) var loading = false
    public private(set) var byRef: [PackageRef: PackageRow] = [:]

    /// The catalog's engine order: same-name rows sit together in this order.
    @ObservationIgnored public let order: [EngineID]
    @ObservationIgnored private let archFor: (EngineID) -> Arch
    /// The latest answer per engine. A refresh keeps the old ones until an engine's new answer replaces its entry.
    @ObservationIgnored private var outcomes: [EngineID: EngineOutcome] = [:]
    @ObservationIgnored private var answered: Set<EngineID> = []
    /// Engines whose answers the load in flight leaves out (`dropRows`); the next load counts them again.
    @ObservationIgnored private var dropped: Set<EngineID> = []
    @ObservationIgnored private var pending: (replacingAll: Bool, make: @MainActor () -> AsyncStream<EngineOutcome>)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped by every start, so a stream that was cancelled can't touch the list after its replacement started.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    public init(order: [EngineID], archFor: @escaping (EngineID) -> Arch) {
        self.order = order
        self.archFor = archFor
    }

    /// Consumes the stream, re-merging after every outcome so rows appear as engines answer. A load requested while
    /// one is running sets a pending flag and runs once after it (never dropped, never two at once).
    ///
    /// A refresh keeps the previous rows, engine by engine, until that engine answers; engines that don't answer
    /// at all this time (gone, or missing) are dropped when the stream ends. `replacingAll` starts from an empty
    /// list instead, for a new query whose results must not mix with the old ones (Discover); it also drops
    /// the selection. Selection is pruned to the new rows when the stream ends. Cancels nothing it didn't start.
    public func load(replacingAll: Bool = false, _ makeStream: @escaping @MainActor () -> AsyncStream<EngineOutcome>) {
        if loading {
            // Any request for a clean start wins over a refresh.
            pending = (replacingAll || (pending?.replacingAll ?? false), makeStream)
            return
        }
        start(replacingAll: replacingAll, makeStream)
    }

    /// Cancels the load in flight (and any pending one), then starts this one at once. Discover uses it for a new
    /// query, so a search never waits behind an engine that hasn't answered the previous one; the old stream's late
    /// answers are dropped.
    public func restart(replacingAll: Bool = true,
                        _ makeStream: @escaping @MainActor () -> AsyncStream<EngineOutcome>) {
        task?.cancel()
        task = nil
        pending = nil
        start(replacingAll: replacingAll, makeStream)
    }

    /// Takes `engines`' rows out at once, without waiting for their next answer: the copy of the engine they came from
    /// isn't the one BrewxPort uses any more. The load in flight may have asked the old copy, so its answers from them
    /// are left out too; the next load brings back what they answer then.
    public func dropRows(of engines: Set<EngineID>) {
        if loading { dropped.formUnion(engines) }
        guard !engines.isDisjoint(with: outcomes.keys) else { return }
        for engine in engines { outcomes[engine] = nil }
        recompute()
    }

    /// Returns once nothing is loading or pending (at once when idle).
    public func settled() async {
        guard loading else { return }
        await withCheckedContinuation { settledWaiters.append($0) }
    }

    /// Space: toggles the checkboxes of the selected rows that are on screen.
    public func toggleSelectedChecks() {
        selection.toggleChecks(for: onScreen(selection.selected))
    }

    /// The refs that are rows on screen now: in the list and not hidden by `isVisible`. Keys and toolbar buttons
    /// act only on these, so a row hidden by a filter is never installed by accident.
    public func onScreen(_ refs: Set<PackageRef>) -> Set<PackageRef> {
        refs.intersection(rows.map(\.id))
    }

    public func recompute() {
        merge()
        if !loading { selection.prune(keeping: Set(rows.map(\.id))) }
    }

    /// The refs that are still in the list. Anything acting on a selection goes through this first.
    public func known(_ refs: Set<PackageRef>) -> Set<PackageRef> {
        refs.filter { byRef[$0] != nil }
    }

    private func start(replacingAll: Bool, _ makeStream: @escaping @MainActor () -> AsyncStream<EngineOutcome>) {
        loading = true
        answered = []
        dropped = []
        generation += 1
        let mine = generation
        if replacingAll {
            outcomes = [:]
            merge()
            selection = PackageSelection()
        }
        task = Task { [weak self] in
            for await outcome in makeStream() {
                guard let self, self.generation == mine else { return }
                guard !self.dropped.contains(outcome.engine) else { continue }
                self.answered.insert(outcome.engine)
                self.outcomes[outcome.engine] = outcome
                self.merge()
            }
            guard let self, self.generation == mine else { return }
            self.finish()
        }
    }

    private func finish() {
        loading = false
        task = nil
        outcomes = outcomes.filter { answered.contains($0.key) }
        recompute()
        if let next = pending {
            pending = nil
            start(replacingAll: next.replacingAll, next.make)
            return
        }
        let waiters = settledWaiters
        settledWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func merge() {
        let merged = PackageCatalog.merge(Array(outcomes.values), order: order)
        all = merged.packages.map {
            PackageRow(package: $0, arch: archFor($0.id.engine), installedArchs: borrowedArchs[$0.id],
                       isInstalled: $0.installedVersion != nil || installedRefs.contains($0.id),
                       hold: merged.holds[$0.id])
        }
        byRef = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        errors = merged.errors.map(EngineErrorText.line)
        failedEngines = Set(merged.errors.map(\.engine))
        unchecked = merged.unchecked
        let visible = all.filter(isVisible)
        rows = sortOrder.isEmpty ? visible : visible.sorted(using: sortOrder)
    }
}
