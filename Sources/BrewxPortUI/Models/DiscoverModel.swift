import Foundation
import Observation
import BrewxPortCore

/// Discover: one query to every engine, merged rows (the same name from several engines sits together, in engine
/// order), an engine filter and the installed marks. A search runs on submit only, never per keystroke, because an
/// engine can take seconds to answer.
@MainActor @Observable public final class DiscoverModel {
    /// Carries the engine order, each engine's arch, the rows and the per-engine errors.
    public let list: PackageListState
    public var query = ""
    /// Nil shows every engine.
    public var engineFilter: EngineID? {
        didSet { applyFilter() }
    }
    public var searching: Bool { list.loading }
    /// The query of the last search started; nil before the first one.
    public private(set) var submittedQuery: String?

    @ObservationIgnored private let catalog: any PackageQuerying

    public init(catalog: any PackageQuerying, list: PackageListState) {
        self.catalog = catalog
        self.list = list
        applyFilter()
    }

    /// Searches every engine for the trimmed query. A search still in flight is cancelled first, so the new one
    /// never waits behind an engine that hung on the old one, and the old one's late answers never show.
    public func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submittedQuery = text
        let catalog = catalog
        list.restart(replacingAll: true) { catalog.stream(.search(text)) }
    }

    /// Search results carry no installed version; the installed list says which rows are installed.
    ///
    /// A nanobrew cask whose installer needs admin rights is installed through Homebrew, so it shows up in
    /// `brew list`, not `nb list`. Both name the same cask, so a Homebrew cask counts for nanobrew's row too.
    public func markInstalled(_ installed: Set<PackageRef>) {
        let routed = installed.filter { $0.engine == .homebrew && $0.kind == .cask }
            .map { PackageRef(engine: .nanobrew, kind: .cask, name: $0.name) }
        list.installedRefs = installed.union(routed)
    }

    /// The toolbar button's title: "Install", or "Install 2" with two rows checked.
    public var installTitle: String {
        let count = checkedRefs.count
        return count == 0 ? "Install" : "Install \(count)"
    }

    /// Checked rows on screen that aren't installed: what the toolbar's Install acts on.
    public var checkedRefs: Set<PackageRef> {
        list.onScreen(list.selection.checked).filter { list.byRef[$0]?.isInstalled == false }
    }

    /// The engine filter's choices, in the list's engine order.
    public var filterChoices: [EngineID] { list.order }

    /// The search field's placeholder: the engine the filter shows ("Search npm"), else every engine. The search
    /// itself still asks every engine, so the filter can change without searching again.
    public var searchPrompt: String { engineFilter.map { "Search \($0.displayName)" } ?? "Search all engines" }

    private func applyFilter() {
        let filter = engineFilter
        list.isVisible = { row in filter == nil || row.id.engine == filter }
        list.recompute()
    }
}
