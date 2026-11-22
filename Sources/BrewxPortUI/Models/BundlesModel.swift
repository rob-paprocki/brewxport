import Foundation
import Observation
import BrewxPortCore

/// What the Bundles page shows.
public enum BundlesState: Equatable, Sendable {
    /// No file open.
    case empty
    /// A file is open, but engine detection, the Installed list or the tap list hasn't reported yet (or a run just
    /// ended and the new Installed list isn't in). Nothing can be installed until it's `.ready`.
    case checking(name: String)
    case ready(ImportPreview, name: String)

    /// The open file's name, escaped for display. Nil when nothing is open.
    public var name: String? {
        switch self {
        case .empty: return nil
        case .checking(let name), .ready(_, let name): return name
        }
    }
}

/// The Bundles page: one open `.brewxportbundle` or Brewfile, its preview against what's on this Mac, and exports.
///
/// A file is untrusted. Requests come only from `ImportPreview.requests(for:)`, which builds them from what
/// `BundleRules` accepted, never from the file's raw entries. The preview is built only once engine detection has
/// reported, an Installed load has ended and the tap list has been read after it; until then `state` is `.checking`.
/// A run's end puts it back to `.checking` until the Installed list that follows the run is in, so a row the run
/// installed is never offered again.
///
/// Rows go into `list` (a `PackageListState`, so the table, `PackageSelection` and `RowActions` are the same as on
/// the other pages). The list sorts by name; the engine grouping (taps first) is in `preview.groups`.
@MainActor @Observable public final class BundlesModel {
    public private(set) var state: BundlesState = .empty {
        // The inspector follows the page: while checking it shows nothing, and once ready it shows the fresh row.
        didSet { if state != oldValue { app?.bundlesStateChanged() } }
    }
    /// A file picked with Open is being read (`open(_ url:)`); the page shows "Opening…".
    public private(set) var isOpening = false
    /// Why the last open failed. The file open before it, if any, stays open.
    public private(set) var openError: String?
    /// Set when Homebrew's tap list couldn't be read. Taps then count as not added (adding one that is is a no-op).
    public private(set) var tapsProblem: String?
    public let list: PackageListState

    @ObservationIgnored private var source: ImportSource?
    @ObservationIgnored private var name = ""
    private var rowStates: [PackageRef: ImportRowState] = [:]
    /// The preview's rows as table rows, built with it. `list` gets the same rows a moment later (its stream).
    @ObservationIgnored private var rowsByRefStore: [PackageRef: PackageRow] = [:]
    /// A preview was built for the open file: later builds keep the user's checks, pruned, instead of the defaults.
    @ObservationIgnored private var builtForFile = false
    /// An Installed load has ended since the last run ended.
    @ObservationIgnored private var installedFresh = false
    /// The tap list was read after that load.
    @ObservationIgnored private var tapsFresh = false
    @ObservationIgnored private var taps: [String] = []
    /// Bumped by every tap read and run end, so a late tap answer can't mark stale state fresh.
    @ObservationIgnored private var generation = 0
    /// How many previews were built. Internal for tests.
    @ObservationIgnored private(set) var buildCount = 0

    @ObservationIgnored private let catalog: any PackageQuerying
    @ObservationIgnored private let installed: InstalledModel
    @ObservationIgnored private let order: [EngineID]
    @ObservationIgnored private let host: Arch
    @ObservationIgnored private let archFor: (EngineID) -> Arch
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private weak var app: BrewxPortAppModel?

    init(catalog: any PackageQuerying, installed: InstalledModel, order: [EngineID],
         archFor: @escaping (EngineID) -> Arch, host: Arch, appVersion: String) {
        self.catalog = catalog
        self.installed = installed
        self.order = order
        self.host = host
        self.archFor = archFor
        self.appVersion = appVersion
        list = PackageListState(order: order, archFor: archFor)
    }

    /// Called once by the app model after it's set up: engine statuses, the run state and the install path come from
    /// it, and its change hooks rebuild the preview.
    func connect(_ app: BrewxPortAppModel) {
        self.app = app
        installed.addLoadedObserver { [weak self] _ in self?.installedLoaded() }
        app.addEnginesCheckedObserver { [weak self] statuses in self?.enginesChecked(statuses) }
        app.addRunEndedObserver { [weak self] in self?.runEnded() }
    }

    public var preview: ImportPreview? {
        if case .ready(let preview, _) = state { return preview }
        return nil
    }

    /// The row's state in the current preview; nil while checking or for a ref that isn't a row.
    public func rowState(_ ref: PackageRef) -> ImportRowState? {
        preview == nil ? nil : rowStates[ref]
    }

    /// The current preview's rows, by ref, as the table, the row menu and the inspector show them. Empty while
    /// checking, so nothing acts on a row from before the last run or engine check.
    public var rowsByRef: [PackageRef: PackageRow] {
        preview == nil ? [:] : rowsByRefStore
    }

    /// Rows that can be installed (`willInstall`, `duplicate`). `RowActions` shows Install for these.
    public var installableRefs: Set<PackageRef> {
        guard preview != nil else { return [] }
        return Set(rowStates.filter { $0.value.isInstallable }.map(\.key))
    }

    /// The checked rows that can be installed, as the preview words them.
    public var checkedRequests: [ActionRequest] {
        preview?.requests(for: list.selection.checked) ?? []
    }

    /// The header's "to install": checked rows that can be installed, not every installable row.
    public var toInstallCount: Int { checkedRequests.count }

    /// "12 to install, 30 already installed, 4 skipped", and for a Brewfile " · 9 blank or comment lines", so every
    /// line of the file is accounted for. Empty until there's a preview.
    public var summaryText: String {
        guard let preview else { return "" }
        let counts = "\(toInstallCount) to install, \(preview.installedCount) already installed, "
            + "\(preview.skippedCount) skipped"
        guard let ignored = preview.ignoredLinesText else { return counts }
        return counts + " · " + ignored
    }

    /// The toolbar's Install: a preview with checked installable rows, and nothing running or waiting.
    public var canInstall: Bool {
        guard let app, preview != nil else { return false }
        return app.canRun && !app.busy && !app.modalUp && !checkedRequests.isEmpty
    }

    public func installChecked() {
        guard canInstall else { return }
        app?.installRequests(checkedRequests)
    }

    /// The row menu's Install, Return and the inspector's Install: the rows among `refs` that can be installed.
    public func install(_ refs: Set<PackageRef>) {
        guard let preview, let app else { return }
        let requests = preview.requests(for: refs)
        guard !requests.isEmpty else { return }
        app.installRequests(requests)
    }

    // MARK: Opening

    /// Reads a file the user picked, off the main actor (`read(_:)`, then the parse), and opens it. The latest open
    /// wins: a slower earlier one that finishes after it is dropped.
    public func open(_ url: URL) {
        openToken += 1
        let mine = openToken
        isOpening = true
        let shown = BundleRules.shownFileName(url.lastPathComponent)
        let readFile = readFile
        Task { [weak self] in
            let result: Result<ImportSource, OpenFailure>
            switch await readFile(url) {
            case .success(let data):
                result = await Task.detached { BundlesModel.parse(data, name: shown) }.value
            case .failure(let problem):
                result = .failure(OpenFailure(message: problem.message(name: shown)))
            }
            guard let self else { return }
            defer { self.finishedOpens += 1 }
            guard self.openToken == mine else { return }
            self.isOpening = false
            self.apply(result, name: shown)
        }
    }

    /// How many `open(_ url:)` reads have finished, applied or dropped. Internal for tests.
    @ObservationIgnored private(set) var finishedOpens = 0

    /// A bundle when the content starts with `{` (after any BOM and whitespace), otherwise a Brewfile. A file that
    /// doesn't read leaves the open file as it was and sets `openError`. Wins over any `open(_ url:)` still reading.
    public func open(data: Data, name: String) {
        openToken += 1
        isOpening = false
        let shown = BundleRules.shownFileName(name)
        apply(Self.parse(data, name: shown), name: shown)
    }

    /// Bumped by every open, so only the latest one's result lands.
    @ObservationIgnored private var openToken = 0
    /// How `open(_ url:)` reads. Tests replace it to hold one read back.
    @ObservationIgnored var readFile: @Sendable (URL) async -> Result<Data, ReadProblem> = { url in
        await Task.detached { BundlesModel.read(url) }.value
    }

    struct OpenFailure: Error, Equatable {
        let message: String
    }

    /// `name` is already escaped.
    nonisolated static func parse(_ data: Data, name: String) -> Result<ImportSource, OpenFailure> {
        do {
            guard data.count <= BundleFile.maxFileBytes else { throw BundleFileError.tooLarge }
            return .success(looksLikeJSON(data) ? .bundle(try BundleFile.decode(data))
                                                : .brewfile(try BrewfileReader.read(data)))
        } catch {
            return .failure(OpenFailure(message: message(for: error, name: name)))
        }
    }

    private func apply(_ result: Result<ImportSource, OpenFailure>, name shown: String) {
        let parsed: ImportSource
        switch result {
        case .success(let source): parsed = source
        case .failure(let failure):
            openError = failure.message
            return
        }
        openError = nil
        source = parsed
        self.name = shown
        builtForFile = false
        if !installed.hasLoaded, installed.reloadCount == 0 { installed.reload() }
        if installedFresh, !tapsFresh { readTaps() }
        rebuild()
    }

    public func close() {
        openToken += 1  // a read still going doesn't reopen anything
        isOpening = false
        source = nil
        name = ""
        builtForFile = false
        openError = nil
        rowStates = [:]
        rowsByRefStore = [:]
        state = .empty
        list.installedRefs = []
        list.restart { AsyncStream { $0.finish() } }
    }

    // MARK: Exporting

    /// Everything installed, as a `.brewxportbundle`. What failed to list is in `summary.failedEngines`. Without
    /// `includeDependencies`, packages installed as a dependency are left out (`summary.dependenciesLeftOut`).
    public func exportBundle(includeDependencies: Bool = true) async -> (data: Data, summary: ExportSummary) {
        let (bundle, summary) = await inventory(includeDependencies: includeDependencies)
        // Encoding plain strings and numbers can't fail; an empty file would be refused on import.
        return ((try? bundle.encoded()) ?? Data(), summary)
    }

    /// Everything installed that `brew bundle` can read, as a Brewfile; the rest is named in `leftOut`.
    public func exportBrewfile(includeDependencies: Bool = true) async
        -> (text: String, leftOut: [LeftOut], summary: ExportSummary) {
        let (bundle, summary) = await inventory(includeDependencies: includeDependencies)
        let written = BrewfileWriter.write(bundle, date: Date())
        return (written.text, written.leftOut, summary)
    }

    private func inventory(includeDependencies: Bool) async -> (BundleFile, ExportSummary) {
        var packages: [Package] = []
        var errors: [EngineError] = []
        for await outcome in catalog.stream(.installed) {
            switch outcome.result {
            case .success(let found): packages += found
            case .failure(let error): errors.append(error)
            }
        }
        var taps: [String] = []
        var tapsError: EngineError?
        do {
            taps = try await catalog.installedTaps()
        } catch let error as EngineError {
            tapsError = error
        } catch {
            tapsError = EngineError(engine: .homebrew, message: "\(error)")
        }
        var dependencies = 0
        var unknown = Set<EngineID>()
        if !includeDependencies {
            (packages, dependencies, unknown) = BundleExporter.requestedOnly(packages)
        }
        let made = BundleExporter.make(installed: packages, taps: taps, appVersion: appVersion, arch: host)
        var summary = ExportSummary.make(made.bundle, errors: errors, tapsError: tapsError, refused: made.refused)
        summary.dependenciesLeftOut = dependencies
        summary.dependenciesUnknown = unknown
        return (made.bundle, summary)
    }

    // MARK: Readiness

    private func installedLoaded() {
        installedFresh = true
        tapsFresh = false
        // Taps are read only while a file is open; opening one reads them if they're stale.
        if source != nil { readTaps() }
    }

    /// An engine that wasn't present at the last check and is now ("Check again" after installing it) isn't in the
    /// Installed list yet. Its rows would show "will install" for what it already has, so Installed loads again and
    /// the preview waits for it, as after a run.
    private func enginesChecked(_ statuses: [EngineID: EngineStatus]) {
        defer { lastStatuses = statuses }
        if let last = lastStatuses,
           statuses.contains(where: { id, status in Self.isPresent(status) && !Self.isPresent(last[id]) }) {
            installedFresh = false
            tapsFresh = false
            generation += 1
            installed.reload()
        }
        rebuild()
    }

    @ObservationIgnored private var lastStatuses: [EngineID: EngineStatus]?

    private static func isPresent(_ status: EngineStatus?) -> Bool {
        if case .present? = status { return true }
        return false
    }

    private func runEnded() {
        installedFresh = false
        tapsFresh = false
        generation += 1
        if source != nil { state = .checking(name: name) }
    }

    private func readTaps() {
        generation += 1
        let mine = generation
        let catalog = catalog
        Task { [weak self] in
            let result: Result<[String], EngineError>
            do {
                result = .success(try await catalog.installedTaps())
            } catch let error as EngineError {
                result = .failure(error)
            } catch {
                result = .failure(EngineError(engine: .homebrew, message: "\(error)"))
            }
            guard let self, self.generation == mine else { return }
            switch result {
            case .success(let found):
                self.taps = found
                self.tapsProblem = nil
            case .failure(let error):
                self.taps = []
                self.tapsProblem = "BrewxPort couldn't list Homebrew's taps: \(error.message)"
            }
            self.tapsFresh = true
            self.rebuild()
        }
    }

    /// Builds the preview from the open file and the current state, or shows `.checking` when part of the state
    /// hasn't reported. The first build for a file starts from `initiallyChecked`; later ones keep the user's checks
    /// on rows that can still be installed.
    private func rebuild() {
        guard let source else { return }
        guard let app, app.enginesChecked, installedFresh, tapsFresh else {
            state = .checking(name: name)
            return
        }
        // An engine whose installed list failed can't say what's there, so nothing is installed through it.
        var status = app.engineStatuses
        for engine in installed.list.failedEngines {
            if case .present(let path, _)? = status[engine] {
                status[engine] = .unusable(
                    path: path, reason: "BrewxPort couldn't list what \(engine.displayName) has installed")
            }
        }
        let preview = ImportPreview.make(
            source, installed: InstalledState(packages: installed.list.all.map(\.package), taps: taps),
            status: status, order: order)
        buildCount += 1

        let rows = preview.groups.flatMap(\.rows)
        let installable = Set(rows.filter(\.isInstallable).map(\.id))
        let checked = builtForFile ? list.selection.checked.intersection(installable) : preview.initiallyChecked
        let selected = builtForFile ? list.selection.selected.intersection(rows.map(\.id)) : []
        builtForFile = true
        rowStates = Dictionary(rows.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        rowsByRefStore = Dictionary(rows.map { row in
            (row.id, PackageRow(package: Self.package(row), arch: archFor(row.id.engine),
                                isInstalled: row.state.isAlreadyInstalled))
        }, uniquingKeysWith: { first, _ in first })

        let outcomes = Dictionary(grouping: rows, by: \.id.engine).map { engine, rows in
            EngineOutcome(engine: engine, result: .success(rows.map(Self.package)))
        }
        list.installedRefs = Set(rows.filter(\.state.isAlreadyInstalled).map(\.id))
        list.restart {
            AsyncStream { continuation in
                for outcome in outcomes { continuation.yield(outcome) }
                continuation.finish()
            }
        }
        // `restart` cleared the selection synchronously; the rows arrive after, and the prune at the end keeps these.
        list.selection = PackageSelection(selected: selected, checked: checked)
        state = .ready(preview, name: name)
    }

    /// The table's package for a row: the display name (a mas app's with its id) and, when installed, its version.
    private static func package(_ row: ImportRow) -> Package {
        var version: String?
        if case .alreadyInstalled(let installed) = row.state { version = installed }
        return Package(id: row.id, displayName: row.displayName, installedVersion: version)
    }

    // MARK: Reading files

    enum ReadProblem: Error, Equatable {
        case notAFile, tooLarge, unreadable

        func message(name: String) -> String {
            switch self {
            case .notAFile: return "“\(name)” isn't a file BrewxPort can open."
            case .tooLarge: return BundlesModel.message(for: BundleFileError.tooLarge, name: name)
            case .unreadable: return "BrewxPort couldn't read “\(name)”."
            }
        }
    }

    /// A regular file only. The file is opened first (following symlinks, so a Brewfile linked from a dotfiles
    /// folder opens), non-blocking so a FIFO can't hold the open; then the open descriptor is checked with `fstat`
    /// (a folder, FIFO or device is refused, and so is a size over the cap) and read through that same descriptor,
    /// so nothing can swap the file between the check and the read. The read stops one byte past the cap, so a file
    /// that grows meanwhile is still refused. Runs off the main actor.
    nonisolated static func read(_ url: URL) -> Result<Data, ReadProblem> {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return .failure(.unreadable) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(.unreadable) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        guard info.st_size <= off_t(BundleFile.maxFileBytes) else { return .failure(.tooLarge) }
        let bytes: Data
        do {
            // nil is end of file: an empty file.
            bytes = try handle.read(upToCount: BundleFile.maxFileBytes + 1) ?? Data()
        } catch {
            return .failure(.unreadable)
        }
        return bytes.count > BundleFile.maxFileBytes ? .failure(.tooLarge) : .success(bytes)
    }

    /// The first byte after a UTF-8 BOM and ASCII whitespace is `{`.
    nonisolated static func looksLikeJSON(_ data: Data) -> Bool {
        var bytes = data[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let first = bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }
        return first == UInt8(ascii: "{")
    }

    /// `name` is already escaped.
    nonisolated static func message(for error: any Error, name: String) -> String {
        switch error {
        case BundleFileError.tooLarge:
            return "“\(name)” is too big to open. BrewxPort opens files up to "
                + "\(BundleFile.maxFileBytes / 1024 / 1024) MB, with at most \(BundleFile.maxEntries.formatted()) entries."
        case BundleFileError.notJSON:
            return "“\(name)” isn't a BrewxPort bundle: it isn't valid JSON."
        case BundleFileError.notABundle:
            return "“\(name)” isn't a BrewxPort bundle: it's missing parts every bundle has."
        case BundleFileError.newerSchema(let version):
            return "“\(name)” was made by a newer version of BrewxPort (format \(version)). "
                + "Update BrewxPort to open it."
        case BundleFileError.unsupportedSchema(let version):
            return "“\(name)” uses bundle format \(version), which BrewxPort can't read."
        case BrewfileError.notText:
            return "“\(name)” isn't a Brewfile or a BrewxPort bundle."
        default:
            return "BrewxPort couldn't open “\(name)”."
        }
    }
}
