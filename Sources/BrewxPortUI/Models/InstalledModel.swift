import Foundation
import Observation
import BrewxPortCore

/// Installed: every engine's installed packages, merged, with the tools installed by more than one engine marked,
/// and for those the copy that runs first on the user's PATH. Copies are matched by the commands they put on the
/// PATH where the engine names them (a crate's binaries, a Mint tool's executables, an npm or Bun global's `bin`), a
/// formula's or port's own name standing for its command, and by package name as the fallback: ripgrep from Homebrew
/// and Cargo, typescript from npm and Bun, and also Cargo's fd-find with Homebrew's fd (`fd`) or Mint's
/// realm/SwiftLint with Homebrew's swiftlint. The copy that runs is told apart by those commands (`rg`, `tsc`) in each
/// engine's own bin folder.
@MainActor @Observable public final class InstalledModel {
    /// `list.loading` is what the snapshot script waits on, then `settled()` for the duplicates and winners.
    public let list: PackageListState
    /// Each group of copies (2+ engines), in list order, keyed by its first row's lowercased name (not Mint's
    /// `owner/repo` when another copy has a plain one). Any kind but mas apps.
    public private(set) var duplicates: [String: [PackageRef]] = [:]
    /// The same keys (for a lone package, its own lowercased name) → the engine whose copy runs. Formulae, ports and
    /// language tools only, and only when a bin directory on the PATH holds the package's command: a file named
    /// exactly like the package, or for a tool one of the commands its engine names.
    public private(set) var winners: [String: EngineID] = [:]
    /// Each row's key in `duplicates` and `winners`, as the last load's grouping found it.
    @ObservationIgnored private var groupKeys: [PackageRef: String] = [:]
    /// The commands each tool's engine named for it at the last load (`commands`), read once per load.
    @ObservationIgnored private var toolCommands: [PackageRef: [String]] = [:]
    /// Set when the system PATH was used instead of the login shell's.
    public private(set) var pathNote: String?
    /// The login shell's PATH as Installed last read it; nil before that, and when the shell didn't answer (the
    /// system PATH says nothing about the person's). The language engines' pages compare their bin folders with it.
    public private(set) var loginPath: [String]?
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
        /// Several of the copies' engines put their commands in the directory that comes first.
        case sharedFolder(String)
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
    /// The language engines, whose bin folders (`InstallLocationReporting.binLocation`) and tools' commands
    /// (`ExecutableNaming`) are read when the winners are worked out: a detect finds them.
    @ObservationIgnored private let languageEngines: [EngineID: any Engine]
    @ObservationIgnored private let fileExists: @Sendable (String) -> Bool
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    public init(catalog: any PackageQuerying, path: any PathResolving, engines: [any Engine],
                fileExists: @escaping @Sendable (String) -> Bool, list: PackageListState) {
        self.catalog = catalog
        self.path = path
        self.fileExists = fileExists
        self.list = list
        var dirs: [EngineID: String] = [:]
        for engine in engines where !engine.id.isLanguage {
            if let url = engine.executableURL { dirs[engine.id] = url.deletingLastPathComponent().path }
        }
        binDirs = dirs
        languageEngines = Dictionary(engines.filter(\.id.isLanguage).map { ($0.id, $0) }) { first, _ in first }
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
            // Cached by LoginShellPath until the person's Refresh or Check again. Installed asks only once it has
            // loaded; a language engine's detect may have asked first.
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

    /// The warning's help text on a duplicate row: "Also installed by MacPorts. MacPorts' copy runs first on your
    /// PATH.", without the second sentence when BrewxPort can't tell. Nil for a row that isn't a duplicate.
    public func duplicateHelp(_ row: PackageRow) -> String? {
        let key = groupKey(row.id)
        guard let copies = duplicates[key], copies.contains(row.id) else { return nil }
        var others: [String] = []
        for ref in copies where ref.engine != row.id.engine && !others.contains(ref.engine.displayName) {
            others.append(ref.engine.displayName)
        }
        let also = "Also installed by \(ListFormatter.localizedString(byJoining: others))."
        guard let winner = winners[key] else { return also }
        return also + " \(winner.possessive) copy runs first on your PATH."
    }

    /// The Runs column's checkmark: this row is the copy that runs first on the PATH.
    public func runsFirst(_ row: PackageRow) -> Bool {
        Self.canWin(row.id) && winners[groupKey(row.id)] == row.id.engine
    }

    /// For the details of a duplicate formula or port that has no winner: why none of the copies is ticked.
    public func whichCopyRunsNote(_ row: PackageRow) -> String? {
        let key = groupKey(row.id)
        guard Self.canWin(row.id), duplicates[key]?.contains(row.id) == true, winners[key] == nil,
              let reason = noWinner[key] else { return nil }
        switch reason {
        case .differentName: return "BrewxPort can't tell which copy runs: its command has a different name."
        case .notOnPath: return "None of these copies is on your PATH."
        case .otherCopy(let dir): return "Another copy, in \(dir), runs first on your PATH."
        case .sharedFolder(let dir): return "These copies share \(dir), so BrewxPort can't tell which one runs."
        }
    }

    private static func key(_ ref: PackageRef) -> String { ref.name.lowercased() }

    /// `ref`'s key in `duplicates` and `winners`: its group's, else its own name's.
    private func groupKey(_ ref: PackageRef) -> String { groupKeys[ref] ?? Self.key(ref) }

    /// Only formulae, ports and language tools put commands on the PATH.
    private static func canWin(_ ref: PackageRef) -> Bool {
        ref.kind == .formula || ref.kind == .port || ref.kind == .tool
    }

    /// Where `engine`'s commands go: a system engine's own bin directory, or a language engine's bin folder as its
    /// last detect found it.
    private func binDir(_ engine: EngineID) -> String? {
        if let dir = binDirs[engine] { return dir }
        return (languageEngines[engine] as? any InstallLocationReporting)?.binLocation.map { PathWinner.normalized($0.path) }
    }

    /// The commands a tool's engine names for it (`rg` for ripgrep); none for anything else. Read at each load
    /// (`findDuplicates`), then kept for the winners.
    private func commands(_ ref: PackageRef) -> [String] {
        if let known = toolCommands[ref] { return known }
        guard ref.kind == .tool else { return [] }
        return (languageEngines[ref.engine] as? any ExecutableNaming)?.executables(of: ref.name) ?? []
    }

    /// Groups the rows (any kind but mas apps) that share a lowercased package name or a command: a tool's commands as
    /// its engine names them, a formula's or port's own name (its engines don't name commands). A group with copies
    /// from two or more engines is a duplicate. A tool's command counts only when it's a file in its engine's bin
    /// folder: npm and Bun name what a package.json declares, and corepack (Node 24 and earlier) declares pnpm and yarn
    /// without putting them there until `corepack enable`.
    private func findDuplicates() {
        let rows = list.all.map(\.id).filter { $0.engine != .mas && $0.kind != .app }
        var named: [PackageRef: [String]] = [:]
        for ref in rows where ref.kind == .tool {
            let declared = (languageEngines[ref.engine] as? any ExecutableNaming)?.executables(of: ref.name) ?? []
            named[ref] = binDir(ref.engine).map { dir in declared.filter { fileExists("\(dir)/\($0)") } } ?? []
        }
        toolCommands = named
        // Union-find over the rows, joined by every key they share.
        var parent = Array(rows.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        var firstWithKey: [String: Int] = [:]
        for (index, ref) in rows.enumerated() {
            for key in [Self.key(ref)] + (named[ref] ?? []).map({ $0.lowercased() }) {
                if let other = firstWithKey[key] {
                    let (a, b) = (root(index), root(other))
                    if a != b { parent[max(a, b)] = min(a, b) }
                } else {
                    firstWithKey[key] = index
                }
            }
        }
        var groups: [Int: [PackageRef]] = [:]
        for index in rows.indices { groups[root(index), default: []].append(rows[index]) }
        var keys: [PackageRef: String] = [:]
        var copies: [String: [PackageRef]] = [:]
        for members in groups.values {
            // Keyed by the first row's name, in list order, that isn't a path (Mint's `owner/repo`).
            let key = Self.key(members.first { !$0.name.contains("/") } ?? members[0])
            for ref in members { keys[ref] = key }
            if Set(members.map(\.engine)).count > 1 { copies[key] = members }
        }
        groupKeys = keys
        duplicates = copies
    }

    /// Only the engines that have the package now are asked about, so a bin directory shared with another engine
    /// (Homebrew and mas) or a copy that was just removed can't win.
    private func findWinners(_ resolved: ResolvedPath) {
        pathNote = resolved.source == .systemDefault
            ? (resolved.note ?? LoginShellPath.unusableNote) : nil
        loginPath = resolved.source == .loginShell ? resolved.entries : nil
        var engines: [String: (names: [String], dirs: [EngineID: String])] = [:]
        for row in list.all where Self.canWin(row.id) {
            guard let dir = binDir(row.id.engine) else { continue }
            let key = groupKey(row.id)
            var candidate = engines[key] ?? ([], [:])
            candidate.dirs[row.id.engine] = dir
            // Each copy's own name (never a path: Mint's `owner/repo` isn't a command), then its commands.
            let own = row.id.name.contains("/") ? [] : [row.id.name]
            for command in own + commands(row.id) where !candidate.names.contains(command) {
                candidate.names.append(command)
            }
            engines[key] = candidate
        }
        var found: [String: EngineID] = [:]
        var reasons: [String: NoWinner] = [:]
        for (key, candidate) in engines {
            // The package's own name first, then the commands its tools' engines name: the first at least two copies
            // have (any copy's, for a package from one engine), so a command only one copy holds (npm's `corepack`)
            // never decides between them.
            let needed = min(2, candidate.dirs.count)
            guard let command = candidate.names.first(where: { name in
                candidate.dirs.values.filter { fileExists("\($0)/\(name)") }.count >= needed
            }) else {
                // Decided without the PATH: no engine's copy has a command named like the package.
                reasons[key] = .differentName
                continue
            }
            guard let first = PathWinner.firstDirectory(holding: command, path: resolved.entries, exists: fileExists)
            else {
                reasons[key] = .notOnPath
                continue
            }
            let owners = candidate.dirs.filter { PathWinner.normalized($0.value) == first }.keys
            if owners.count > 1 {
                reasons[key] = .sharedFolder(first)
            } else if let winner = owners.first {
                found[key] = winner
            } else {
                reasons[key] = .otherCopy(first)
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
