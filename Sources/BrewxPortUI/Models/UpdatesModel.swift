import Foundation
import Observation
import BrewxPortCore

/// Why an Updates row is hidden unless "Show ignored" is on.
public enum UpdateHiddenReason: Sendable, Equatable { case ignored, skipped }

/// Updates: every engine's outdated packages, merged, less the ones the user ignores or whose latest version they
/// skipped. Update all and the toolbar's Update act only on rows that are on screen and neither ignored nor skipped.
///
/// A row can be held (`hold(for:)`): its engine (Cargo's "Needs Rust 1.85", a gem that came with Ruby) or the app
/// (`appHolds`: a language engine this account can't change, a Homebrew runtime its tools run on) says why. A hold
/// that blocks manual updates keeps the row out of every update and the badge; one that blocks automatic updates
/// keeps it out of `automaticRequests()`, which background updates run.
@MainActor @Observable public final class UpdatesModel {
    public let list: PackageListState
    /// Shows ignored and skipped rows too, marked. They still aren't part of Update all.
    public var showHidden = false {
        didSet { applyVisibility() }
    }
    /// Bumped whenever the ignore and skip preferences change. `UpdatePreferences` isn't observable, so everything
    /// that reads them reads this too, and the badge and the row marks redraw on Ignore, Stop ignoring and Skip.
    private var preferencesRevision = 0
    /// Holds the app puts on updates, by ref; where the row's engine holds it too, the stricter hold counts.
    public var appHolds: [PackageRef: UpdateHold] = [:]
    /// The Homebrew runtime updates among `appHolds` (design option A), with their notice and warning.
    public var runtimeHolds: [PackageRef: RuntimeHold] = [:]
    /// For each of `runtimeHolds`, the updates related to it the way `brew upgrade` brings packages along
    /// (`HiddenRelations`): updating one of those would update the runtime too.
    @ObservationIgnored var runtimeRelations: [PackageRef: HiddenRelations] = [:]
    /// Works out `appHolds` and `runtimeHolds` once a reload has loaded, before `reloaded()` returns, so a check
    /// never acts on a list whose holds aren't in yet. The app sets it.
    @ObservationIgnored var holdsAfterReload: (@MainActor () async -> Void)?
    /// True from `reload()` until its load ended, the skips were pruned and the app's holds were worked out
    /// (`holdsAfterReload`). Meanwhile the runtime warning fails closed (`BrewxPortAppModel.warningBefore`).
    @ObservationIgnored private(set) var pruning = false

    @ObservationIgnored private let catalog: any PackageQuerying
    @ObservationIgnored private let preferences: UpdatePreferences
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    /// How many times `reload()` ran. Internal: the snapshot script loads once when nothing did yet.
    @ObservationIgnored private(set) var reloadCount = 0

    public init(catalog: any PackageQuerying, preferences: UpdatePreferences, list: PackageListState) {
        self.catalog = catalog
        self.preferences = preferences
        self.list = list
        applyVisibility()
    }

    /// The sidebar badge: rows that are neither ignored nor skipped, nor held from every update, whatever "Show
    /// ignored" says.
    public var badgeCount: Int {
        list.all.reduce(0) { $0 + (hiddenReason($1) == nil && !blocksManual($1) ? 1 : 0) }
    }

    /// Rows that are ignored or skipped.
    public var hiddenCount: Int {
        list.all.reduce(0) { $0 + (hiddenReason($1) == nil ? 0 : 1) }
    }

    /// Why the row's update is held back: its engine's hold or the app's (`appHolds`), the stricter when there are
    /// both (one that blocks manual updates, then automatic ones; the engine's on a tie); nil for an ordinary row.
    public func hold(for row: PackageRow) -> UpdateHold? {
        switch (row.hold, appHolds[row.id]) {
        case let (own?, app?):
            if own.blocksManual != app.blocksManual { return own.blocksManual ? own : app }
            if own.blocksAutomatic != app.blocksAutomatic { return own.blocksAutomatic ? own : app }
            return own
        case let (own, app): return own ?? app
        }
    }

    /// The held runtimes (`runtimeHolds`) that updating `ref` would bring along: a formula that needs one or that one
    /// needs, as `brew upgrade` takes outdated dependencies and dependents with it. Not `ref` itself. A runtime whose
    /// relations couldn't be read counts every update from its package manager (never a guess).
    public func runtimesBroughtAlong(by ref: PackageRef) -> [PackageRef] {
        broughtAlong(by: ref).map(\.runtime)
    }

    /// `runtimesBroughtAlong`, each saying whether it's certain (the relations were read) or only possible (they
    /// couldn't be).
    func broughtAlong(by ref: PackageRef) -> [(runtime: PackageRef, certain: Bool)] {
        Self.broughtAlong(by: ref, holds: runtimeHolds, relations: runtimeRelations)
    }

    /// `broughtAlong(by:)` among `holds`, by `relations`: a runtime with none (not read, or not read yet) may come
    /// along with every update from its package manager.
    static func broughtAlong(by ref: PackageRef, holds: [PackageRef: RuntimeHold],
                             relations: [PackageRef: HiddenRelations]) -> [(runtime: PackageRef, certain: Bool)] {
        holds.keys.sorted { $0.name < $1.name }.compactMap { runtime in
            guard runtime != ref else { return nil }
            switch (relations[runtime] ?? .none).relation(ref, hidden: [runtime]) {
            case .unrelated: return nil
            case .related: return (runtime, true)
            case .unknown: return (runtime, false)
            }
        }
    }

    /// The row's update is held from every update: nobody may pick it.
    public func blocksManual(_ row: PackageRow) -> Bool { hold(for: row)?.blocksManual == true }

    /// `ref`'s row on Updates is held from every update.
    public func blocksManual(_ ref: PackageRef) -> Bool { list.byRef[ref].map(blocksManual) ?? false }

    /// R6: what the section of `engine` says about the packages its last check couldn't look up ("2 tools couldn't be
    /// checked"), or the check's own note when it names none (R26, npm without its list); nil when it checked them all,
    /// or failed as a whole (its error says that).
    public func uncheckedNote(for engine: EngineID) -> String? {
        guard let unchecked = list.unchecked[engine], !unchecked.isEmpty else { return nil }
        let noun = engine.isLanguage ? ("tool", "tools") : ("package", "packages")
        switch unchecked.count {
        case 0 where !unchecked.unnamed: return unchecked.note
        case 0: return "Some \(noun.1) couldn't be checked"
        case 1: return "1 \(noun.0) couldn't be checked"
        default: return "\(unchecked.count) \(noun.1) couldn't be checked"
        }
    }

    /// `uncheckedNote(for:)` with the names, and the check's note when there's one besides, for a tooltip or a page:
    /// "2 tools couldn't be checked: black, ruff".
    public func uncheckedDetail(for engine: EngineID) -> String? {
        guard let note = uncheckedNote(for: engine), let unchecked = list.unchecked[engine] else { return nil }
        let named = unchecked.names.isEmpty ? note : note + ": " + unchecked.names.joined(separator: ", ")
        guard let own = unchecked.note, own != note else { return named }
        return named + ". " + own
    }

    /// The empty page's title: "Everything is up to date" only when every check answered in full and nothing is held
    /// back; otherwise "Nothing else to update".
    public var emptyTitle: String {
        let partly = !list.unchecked.isEmpty || list.all.contains { hold(for: $0) != nil }
        return partly ? "Nothing else to update" : "Everything is up to date"
    }

    /// The empty page's line under its title: what couldn't be checked (the lines above the list name it), and how
    /// many updates are ignored or skipped.
    public var emptyNote: String {
        let hidden = hiddenCount
        let hiddenLine = hidden == 1 ? "1 update is ignored or skipped." : "\(hidden) updates are ignored or skipped."
        guard list.unchecked.isEmpty else {
            let unchecked = "Some packages couldn't be checked, as the lines above say."
            return hidden == 0 ? unchecked : unchecked + " " + hiddenLine
        }
        return hidden == 0 ? "No engine has a newer version of anything you installed." : hiddenLine
    }

    /// One line per engine with an `uncheckedDetail`, in engine order: "pipx: 2 tools couldn't be checked: black,
    /// ruff". Shown above the list, so a check that found nothing still says it.
    public var uncheckedLines: [String] {
        list.order.compactMap { engine in uncheckedDetail(for: engine).map { "\(engine.displayName): \($0)" } }
    }

    /// Nil for a row Update all acts on.
    public func hiddenReason(_ row: PackageRow) -> UpdateHiddenReason? {
        _ = preferencesRevision
        if preferences.isIgnored(row.id) { return .ignored }
        if preferences.isSkipped(row.package) { return .skipped }
        return nil
    }

    public func canUpdateAll(isRunning: Bool) -> Bool {
        !isRunning && !list.loading && !updateAllRequests().isEmpty
    }

    /// Asks every engine for its outdated packages, then forgets skips whose package has a newer version now.
    public func reload() {
        reloadCount += 1
        let catalog = catalog
        list.load { catalog.stream(.outdated) }
        pruning = true
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            guard let self else { return }
            await self.list.settled()
            guard !Task.isCancelled else { return }
            self.preferences.prune(outdated: self.list.all.map(\.package))
            self.preferencesRevision += 1
            self.list.recompute()
            await self.holdsAfterReload?()
            guard !Task.isCancelled else { return }
            self.pruning = false
        }
    }

    /// Returns once the latest `reload()` has loaded and its skips are pruned (at once when none is going). A reload
    /// asked for meanwhile is waited for too: it replaces the earlier prune, which then ends without pruning.
    public func reloaded() async {
        await list.settled()
        while pruning, let pruneTask {
            await pruneTask.value
        }
    }

    /// Every row that is neither ignored nor skipped, nor held from every update, in list order.
    public func updateAllRequests() -> [ActionRequest] {
        requests(list.rows.filter { hiddenReason($0) == nil && !blocksManual($0) })
    }

    /// What an automatic update may run: Update all's rows, less those held from automatic updates (a gem that came
    /// with Ruby). Those wait for the person, like any update that does.
    public func automaticRequests() -> [ActionRequest] {
        let rows = list.rows.filter { hiddenReason($0) == nil && hold(for: $0)?.blocksAutomatic != true }
        return requests(rows.filter { !blocksManual($0) })
    }

    /// What a section's "Update N" acts on: Update all's rows from one engine, collapsed section or not.
    public func updateAllRequests(for engine: EngineID) -> [ActionRequest] {
        updateAllRequests().filter { $0.package.id.engine == engine }
    }

    /// The N in a section's "Update N"; the button is hidden at 0.
    public func updateCount(for engine: EngineID) -> Int {
        updateAllRequests(for: engine).count
    }

    /// The given refs that are rows on screen and neither ignored nor skipped, nor held from every update, in list
    /// order.
    public func requests(for refs: Set<PackageRef>) -> [ActionRequest] {
        let wanted = list.onScreen(refs)
        return requests(list.rows.filter { wanted.contains($0.id) && hiddenReason($0) == nil && !blocksManual($0) })
    }

    /// What the toolbar's Update acts on: the checked rows (not the highlighted ones).
    public func checkedRequests() -> [ActionRequest] {
        requests(for: list.selection.checked)
    }

    /// "Update", or "Update 2" with two updatable rows checked.
    public var updateCheckedTitle: String {
        let count = checkedRequests().count
        return count == 0 ? "Update" : "Update \(count)"
    }

    /// After an ignore, stop-ignoring or skip: hides or shows rows without asking the engines again.
    public func preferencesChanged() {
        preferencesRevision += 1
        list.recompute()
    }

    private func requests(_ rows: [PackageRow]) -> [ActionRequest] {
        rows.map { ActionRequest(operation: .upgrade, package: $0.package) }
    }

    private func applyVisibility() {
        let showHidden = showHidden
        list.isVisible = { [weak self] row in
            showHidden || self?.hiddenReason(row) == nil
        }
        list.recompute()
    }
}
