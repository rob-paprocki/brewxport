import AppKit
import SwiftUI

/// The menu bar menu: `MenuBarItems` drawn as menu items. Settings… opens the Settings scene itself; every other
/// button goes to `MenuBarItems.perform`.
public struct MenuBarContent: View {
    let model: BrewxPortAppModel
    @Environment(\.openSettings) private var openSettings

    public init(model: BrewxPortAppModel) { self.model = model }

    public var body: some View {
        let items = MenuBarItems.make(model: model)
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            switch item {
            case .text(let text):
                Text(text)
            case .divider:
                Divider()
            case .button(let title, .openSettings, let enabled):
                // A menu bar item doesn't make BrewxPort the active app, so Settings would open behind the app in
                // front. The click is the person's own, so macOS lets BrewxPort come forward first.
                Button(title) {
                    NSApp.activate()
                    openSettings()
                }
                .disabled(!enabled)
            case .button(let title, let action, let enabled):
                Button(title) { MenuBarItems.perform(action, model: model) }
                    .disabled(!enabled)
            }
        }
    }
}
