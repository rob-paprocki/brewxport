import SwiftUI

/// The menu commands. Find (⌘F) shows Discover and focuses its search field; Refresh (⌘R) checks Updates and
/// Installed again (after the run, when one is going); Show Details (⌘I) toggles the inspector, and Hide Details
/// works on every page while it's open.
///
/// The Package menu lists what the tables' plain keys do, with ⌘ shortcuts so they never fire while someone types in
/// the search field or the password sheet: Return installs or updates the selection (⌘↩), Space checks or unchecks
/// it, and Delete removes it after a confirmation (⌘⌫, as in Finder). While that confirmation is up, Find, Refresh
/// and the Package items are off, so nothing changes the page or the refs it names behind it.
public struct BrewxPortCommands: Commands {
    let model: BrewxPortAppModel?

    /// Nil when the window has no model (a demo that couldn't start): the items are then disabled.
    public init(model: BrewxPortAppModel?) { self.model = model }

    public var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") { model?.find() }
                .keyboardShortcut("f")
                .disabled(model == nil || model?.confirmingRemoval == true)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { model?.refreshLists() }
                .keyboardShortcut("r")
                .disabled(model == nil || model?.confirmingRemoval == true)
            Button(model?.inspectorOpen == true ? "Hide Details" : "Show Details") { model?.toggleInspector() }
                .keyboardShortcut("i")
                .disabled(model?.canToggleInspector != true)
        }
        CommandMenu("Package") {
            Button(model?.primaryActionTitle ?? "Install Selected") { model?.performPrimary() }
                .keyboardShortcut(.return)
                .disabled(model?.canPerformPrimary != true)
            Button("Check or Uncheck Selected") { model?.toggleChecks() }
                .disabled(model?.canToggleChecks != true)
            Divider()
            Button("Remove Selected…") { model?.removeSelection() }
                .keyboardShortcut(.delete)
                .disabled(model?.canRemoveSelection != true)
        }
    }
}
