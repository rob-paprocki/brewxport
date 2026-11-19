import Foundation
import Observation
import BrewxPortCore

/// Why an Updates row is hidden unless "Show ignored" is on.
public enum UpdateHiddenReason: Sendable, Equatable { case ignored, skipped }

/// Updates: every engine's outdated packages, merged, less the ones the user ignores or whose latest version they
/// skipped. Update all and the toolbar's Update act only on rows that are on screen and neither ignored nor skipped.
@MainActor @Observable public final class UpdatesModel {
    public let list: PackageListState
    /// Shows ignored and skipped rows too, marked. They still aren't part of Update all.
    public var showHidden = false {
        didSet { applyVisibility() }
    }
    /// Bumped whenever the ignore and skip preferences change. `UpdatePreferences` isn't observable, so everything
    /// that reads them reads this too, and the badge and the row marks redraw on Ignore, Stop ignoring and Skip.
    private var preferencesRevision = 0
    /// True from `reload()` until its load ended and the skips were pruned. Internal for tests.
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

    /// The sidebar badge: rows that are neither ignored nor skipped, whatever "Show ignored" says.
    public var badgeCount: Int {
        list.all.reduce(0) { $0 + (hiddenReason($1) == nil ? 1 : 0) }
    }

    /// Rows that are ignored or skipped.
    public var hiddenCount: Int { list.all.count - badgeCount }

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
            self.pruning = false
        }
    }

    /// Every row that is neither ignored nor skipped, in list order.
    public func updateAllRequests() -> [ActionRequest] {
        requests(list.rows.filter { hiddenReason($0) == nil })
    }

    /// The given refs that are rows on screen and neither ignored nor skipped, in list order.
    public func requests(for refs: Set<PackageRef>) -> [ActionRequest] {
        let wanted = list.onScreen(refs)
        return requests(list.rows.filter { wanted.contains($0.id) && hiddenReason($0) == nil })
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
