import Foundation
import BrewxPortCore

/// The two ways a row can be picked: highlighted (`selected`, by clicking) or ticked (`checked`, by its checkbox).
///
/// Which set each input acts on: toolbar buttons use `checked`; the context menu uses the set it was opened for;
/// Return and Delete use `selected`; Space toggles the checkboxes of `selected` (all on if any is off, else all off).
public struct PackageSelection: Equatable, Sendable {
    public var selected: Set<PackageRef>
    public var checked: Set<PackageRef>

    public init(selected: Set<PackageRef> = [], checked: Set<PackageRef> = []) {
        self.selected = selected
        self.checked = checked
    }

    public mutating func toggleChecks(for refs: Set<PackageRef>) {
        guard !refs.isEmpty else { return }
        if refs.isSubset(of: checked) {
            checked.subtract(refs)
        } else {
            checked.formUnion(refs)
        }
    }

    /// Drops refs that are no longer in the list, from both sets.
    public mutating func prune(keeping visible: Set<PackageRef>) {
        selected.formIntersection(visible)
        checked.formIntersection(visible)
    }
}
