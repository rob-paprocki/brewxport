import BrewxPortCore
import Testing
@testable import BrewxPortUI

struct PackageSelectionTests {
    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .homebrew, kind: .formula, name: name) }

    @Test func spaceChecksAllThenUnchecksAll() {
        var selection = PackageSelection()
        let rows: Set = [ref("a"), ref("b"), ref("c")]
        selection.selected = rows
        selection.checked = [ref("a")]
        // One is off: all on.
        selection.toggleChecks(for: selection.selected)
        #expect(selection.checked == rows)
        // All on: all off.
        selection.toggleChecks(for: selection.selected)
        #expect(selection.checked.isEmpty)
    }

    @Test func toggleLeavesOtherChecksAlone() {
        var selection = PackageSelection(selected: [ref("a")], checked: [ref("z")])
        selection.toggleChecks(for: [ref("a")])
        #expect(selection.checked == [ref("a"), ref("z")])
        selection.toggleChecks(for: [ref("a")])
        #expect(selection.checked == [ref("z")])
        selection.toggleChecks(for: [])
        #expect(selection.checked == [ref("z")])
    }

    @Test func pruneDropsVanishedRows() {
        var selection = PackageSelection(selected: [ref("a"), ref("b")], checked: [ref("b"), ref("c")])
        selection.prune(keeping: [ref("b"), ref("d")])
        #expect(selection.selected == [ref("b")])
        #expect(selection.checked == [ref("b")])
    }
}
