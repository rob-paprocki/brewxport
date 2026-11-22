import Foundation
import Observation
import BrewxPortCore

/// Installed: every engine's installed packages, merged, with the names installed by more than one engine marked,
/// and for those the copy that runs first on the user's PATH.
@MainActor @Observable public final class InstalledModel {
    /// `list.loading` is what the snapshot script waits on, then `settled()` for the duplicates and winners.
    public let list: PackageListState
    /// Lowercased name → the copies (2+ engines), in list order. Any kind but mas apps.
    public private(set) var duplicates: [String: [PackageRef]] = [:]
    /// Lowercased name → the engine whose copy runs. Formulae and ports only, and only when a bin directory on the
    /// PATH holds a file named exactly like the package.
    public private(set) var winners: [String: EngineID] = [:]
    /// Set when the system PATH was used instead of the login shell's.
    public private(set) var pathNote: String?
    /// The table's sort; empty means catalog order.
    public var sortOrder: [KeyPathComparator<InstalledRow>] = []
    /// Why a name that can win has no winner. Internal: `whichCopyRunsNote` words it.
    private var noWinner: [String: NoWinner] = [:]

    enum NoWinner: Equatable {
        /// No engine's bin directory holds a file named like the package (ripgrep's command is rg).
        case differentName
        /// The engines have the file, but none of their bin directories is on the PATH.
        case notOnPath
        /// A directory that belongs to none of these engines comes first and holds the command.
        case otherCopy(String)
    }
    /// True from `reload()` until the load ended and the duplicates and winners were worked out. Internal for tests.
    @ObservationIgnored private(set) var analyzing = false
    /// How many times `reload()` ran. Internal: the snapshot script loads once when nothing did yet.
    @ObservationIgnored private(set) var reloadCount = 0
    /// True once a load has ended.
    public private(set) var hasLoaded = false
    /// Called, in the order added, with every installed ref each time a load ends, before the PATH is resolved. The
    /// app model's Discover feed is the first (Discover's installed marks have no other source); Bundles follows.
    @ObservationIgnored private var loadedObservers: [@MainActor (Set<PackageRef>) -> Void] = []

    @ObservationIgnored private let catalog: any PackageQuerying
    @ObservationIgnored private let path: any PathResolving
    @ObservationIgnored private let binDirs: [EngineID: String]
    @ObservationIgnored private let fileExists: @Sendable (String) -> Bool
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    public init(catalog: any PackageQuerying, path: any PathResolving, engines: [any Engine],
                fileExists: @escaping @Sendable (String) -> Bool, list: PackageListState) {
        self.catalog = catalog
        self.path = path
        self.fileExists = fileExists
        self.list = list
        var dirs: [EngineID: String] = [:]
        for engine in engines {
            if let url = engine.executableURL { dirs[engine.id] = url.deletingLastPathComponent().path }
        }
        binDirs = dirs
    }

    /// After BrewxPort added a directory to the person's PATH: the cached login-shell PATH is dropped, and once
    /// Installed has loaded, the shell is asked again and the Runs column worked out from its answer. The package
    /// lists aren't reloaded.
    func pathChanged() {
        Task { [weak self, path] in
            await path.forget()
            guard let self, self.hasLoaded else { return }
            await self.list.settled()
            let resolved = await path.resolve()
            self.findWinners(resolved)
        }
    }

    /// Asks every engine for its installed packages again, then works out the duplicates and which copy runs.
    public func reload() {
        reloadCount += 1
        let catalog = catalog
        list.load { catalog.stream(.installed) }
        analyzing = true
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            guard let self else { return }
            await self.list.settled()
            guard !Task.isCancelled else { return }
            self.hasLoaded = true
            let refs = Set(self.list.all.map(\.id))
            for observer in self.loadedObservers { observer(refs) }
            self.findDuplicates()
            // Resolved once per launch (LoginShellPath caches it, except a shell that didn't answer in time, which is
            // asked again on the next reload), and never before Installed first loads.
            let resolved = await self.path.resolve()
            guard !Task.isCancelled else { return }
            self.findWinners(resolved)
            self.analyzing = false
        }
    }

    /// Adds a load observer; see `loadedObservers`.
    public func addLoadedObserver(_ observer: @escaping @MainActor (Set<PackageRef>) -> Void) {
        loadedObservers.append(observer)
    }

    /// Returns once the load and the analysis after it are done (at once when nothing is going).
    public func settled() async {
        while analyzing, let task = analysisTask {
            await task.value
        }
    }

    /// The table's rows: `list.rows` with each row's marks, sorted by `sortOrder`. The marks are part of the row
    /// values, so the table redraws a row when its tick or warning changes (winners arrive after the list).
    public var rows: [InstalledRow] {
        let rows = list.rows.map { InstalledRow(row: $0, runsFirst: runsFirst($0), duplicateHelp: duplicateHelp($0)) }
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    /// Checked rows on screen: what the toolbar's Remove acts on.
    public var checkedRefs: Set<PackageRef> { list.onScreen(list.selection.checked) }

    /// "Remove", or "Remove 2" with two rows checked.
    public var removeTitle: String {
        let count = checkedRefs.count
        return count == 0 ? "Remove" : "Remove \(count)"
    }

    /// The warning's help text on a duplicate row: "Also installed by MacPorts. MacPorts's copy runs first on your
    /// PATH.", without the second sentence when BrewxPort can't tell. Nil for a row that isn't a duplicate.
    public func duplicateHelp(_ row: PackageRow) -> String? {
        let key = Self.key(row.id)
        guard let copies = duplicates[key], copies.contains(row.id) else { return nil }
        var others: [String] = []
        for ref in copies where ref.engine != row.id.engine && !others.contains(ref.engine.displayName) {
            others.append(ref.engine.displayName)
        }
        let also = "Also installed by \(ListFormatter.localizedString(byJoining: others))."
        guard let winner = winners[key] else { return also }
        return also + " \(winner.displayName)'s copy runs first on your PATH."
    }

    /// The Runs column's checkmark: this row is the copy that runs first on the PATH.
    public func runsFirst(_ row: PackageRow) -> Bool {
        Self.canWin(row.id) && winners[Self.key(row.id)] == row.id.engine
    }

    /// For the details of a duplicate formula or port that has no winner: why none of the copies is ticked.
    public func whichCopyRunsNote(_ row: PackageRow) -> String? {
        let key = Self.key(row.id)
        guard Self.canWin(row.id), duplicates[key]?.contains(row.id) == true, winners[key] == nil,
              let reason = noWinner[key] else { return nil }
        switch reason {
        case .differentName: return "BrewxPort can't tell which copy runs: its command has a different name."
        case .notOnPath: return "None of these copies is on your PATH."
        case .otherCopy(let dir): return "Another copy, in \(dir), runs first on your PATH."
        }
    }

    private static func key(_ ref: PackageRef) -> String { ref.name.lowercased() }

    /// Only formulae and ports put a command named like the package on the PATH.
    private static func canWin(_ ref: PackageRef) -> Bool { ref.kind == .formula || ref.kind == .port }

    private func findDuplicates() {
        var copies: [String: [PackageRef]] = [:]
        for row in list.all where row.id.engine != .mas && row.id.kind != .app {
            copies[Self.key(row.id), default: []].append(row.id)
        }
        duplicates = copies.filter { Set($0.value.map(\.engine)).count > 1 }
    }

    /// Only the engines that have the package now are asked about, so a bin directory shared with another engine
    /// (Homebrew and mas) or a copy that was just removed can't win.
    private func findWinners(_ resolved: ResolvedPath) {
        pathNote = resolved.source == .systemDefault
            ? (resolved.note ?? LoginShellPath.unusableNote) : nil
        var engines: [String: (name: String, dirs: [EngineID: String])] = [:]
        for row in list.all where Self.canWin(row.id) {
            guard let dir = binDirs[row.id.engine] else { continue }
            engines[Self.key(row.id), default: (row.id.name, [:])].dirs[row.id.engine] = dir
        }
        var found: [String: EngineID] = [:]
        var reasons: [String: NoWinner] = [:]
        for (key, candidate) in engines {
            if let winner = PathWinner.winner(command: candidate.name, path: resolved.entries, binDirs: candidate.dirs,
                                              exists: fileExists) {
                found[key] = winner
            } else if !candidate.dirs.values.contains(where: { fileExists("\($0)/\(candidate.name)") }) {
                // Decided without the PATH: no engine's copy has a command named like the package.
                reasons[key] = .differentName
            } else if let first = PathWinner.firstDirectory(holding: candidate.name, path: resolved.entries,
                                                            exists: fileExists) {
                reasons[key] = .otherCopy(first)
            } else {
                reasons[key] = .notOnPath
            }
        }
        winners = found
        noWinner = reasons
    }
}

/// One Installed table row: the package and its marks, so a change in either is a change in the row's value.
public struct InstalledRow: Identifiable, Hashable, Sendable {
    public let row: PackageRow
    /// The Runs column's tick.
    public let runsFirst: Bool
    /// The warning's help text; nil for a name only one engine installed.
    public let duplicateHelp: String?

    public var id: PackageRef { row.id }
    public var name: String { row.name }
    public var version: String { row.installed }
    public var engineName: String { row.engineName }
    public var archName: String { row.archName }
    public var kindName: String { row.kindName }
}
