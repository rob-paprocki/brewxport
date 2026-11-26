import SwiftUI

/// The menu bar icon: a box, with the number of updates beside it (nothing at 0), or a dot while a run is going.
public struct MenuBarLabel: View {
    let count: Int
    let running: Bool

    public init(count: Int, running: Bool) {
        self.count = count
        self.running = running
    }

    public var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "shippingbox")
            if let badge = Self.badge(count: count, running: running) { Text(badge) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// What shows beside the box: the count, a progress dot during a run, or nothing.
    static func badge(count: Int, running: Bool) -> String? {
        if running { return "•" }
        return count > 0 ? "\(count)" : nil
    }

    private var accessibilityText: String {
        if running { return "BrewxPort, updating" }
        switch count {
        case 0: return "BrewxPort"
        case 1: return "BrewxPort, 1 update"
        default: return "BrewxPort, \(count) updates"
        }
    }
}
