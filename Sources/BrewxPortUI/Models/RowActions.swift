import Foundation
import BrewxPortCore

public enum RowAction: Hashable, Sendable {
    case install, update, uninstall, ignore, stopIgnoring, skipVersion(String), showDetails, copyName
    /// Installed's "Move to" submenu: one item per package manager the row can move to.
    case moveTo(EngineID)
}

public struct RowActionItem: Hashable, Sendable {
    public let action: RowAction
    public let title: String
    public let systemImage: String
    public let isEnabled: Bool
    /// A tooltip, for an item that's off for a reason the person can't see (demo mode).
    public var help: String? = nil

    /// A "Move to" item: the menus show these together in a submenu.
    public var isMove: Bool {
        if case .moveTo = action { return true }
        return false
    }

    func disabled() -> RowActionItem {
        RowActionItem(action: action, title: title, systemImage: systemImage, isEnabled: false, help: help)
    }
}

/// The right-click menu: only the items that apply to the rows it was opened for, in a fixed order.
public enum RowActions {
    /// `installable` is read only on Bundles (`BundlesModel.installableRefs`): its Install shows when one of the rows
    /// can be installed. Bundles has no Update, Uninstall, Ignore or Skip.
    ///
    /// `moveTargets` are the package managers a package can be moved to (present, and able to list dependents). One
    /// movable Installed row (`MovePlanner.isMovable`) gets a "Move to" item for each of them but its own, after
    /// Uninstall. In demo mode they show, off, with a tooltip saying why.
    @MainActor public static func items(for refs: Set<PackageRef>, in view: PackageView,
                                        rows: [PackageRef: PackageRow], outdated: Set<PackageRef>,
                                        prefs: UpdatePreferences, isRunning: Bool, canRun: Bool,
                                        installable: Set<PackageRef> = [], moveTargets: [EngineID] = [],
                                        isDemo: Bool = false) -> [RowActionItem] {
        // Only rows the list knows: a ref that vanished (or was filtered out of the table) isn't acted on.
        let refs = refs.filter { rows[$0] != nil }
        guard !refs.isEmpty else { return [] }
        let mayRun = canRun && !isRunning
        var items: [RowActionItem] = []
        func add(_ action: RowAction, _ title: String, _ image: String, enabled: Bool = true) {
            items.append(RowActionItem(action: action, title: title, systemImage: image, isEnabled: enabled))
        }
        let single = refs.count == 1

        switch view {
        case .discover:
            if refs.contains(where: { rows[$0]?.isInstalled != true }) {
                add(.install, "Install", "arrow.down.circle", enabled: mayRun)
            }
        case .updates:
            add(.update, "Update", "arrow.triangle.2.circlepath", enabled: mayRun)
            if refs.allSatisfy({ prefs.isIgnored($0) }) {
                add(.stopIgnoring, "Stop ignoring", "bell")
            } else {
                add(.ignore, "Ignore updates", "bell.slash")
            }
            if single, let ref = refs.first, let latest = rows[ref]?.package.latestVersion {
                add(.skipVersion(latest), "Skip version \(latest)", "forward")
            }
            add(.uninstall, "Uninstall…", "trash", enabled: mayRun)
        case .installed:
            if refs.contains(where: { outdated.contains($0) }) {
                add(.update, "Update", "arrow.triangle.2.circlepath", enabled: mayRun)
            }
            add(.uninstall, "Uninstall…", "trash", enabled: mayRun)
            if single, let ref = refs.first, let package = rows[ref]?.package, moveTargets.contains(ref.engine),
               MovePlanner.isMovable(package, engineHasDependents: true) {
                for target in EngineID.allCases where target != ref.engine && moveTargets.contains(target) {
                    items.append(RowActionItem(action: .moveTo(target), title: target.displayName,
                                               systemImage: "arrow.right.circle", isEnabled: mayRun && !isDemo,
                                               help: isDemo ? SetupCopy.demoHelp : nil))
                }
            }
        case .bundles:
            if refs.contains(where: { installable.contains($0) }) {
                add(.install, "Install", "arrow.down.circle", enabled: mayRun)
            }
        }
        if single { add(.showDetails, "Show details", "info.circle") }
        add(.copyName, single ? "Copy name" : "Copy names", "doc.on.doc")
        return items
    }

    /// Display names, one per line, in name order. For mas that's the app name, not the id.
    public static func copyText(for refs: Set<PackageRef>, rows: [PackageRef: PackageRow]) -> String {
        refs.compactMap { rows[$0]?.name }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }
}
