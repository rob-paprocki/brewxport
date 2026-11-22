import SwiftUI

/// The menu commands. File › Open Bundle… (⌘O) shows Bundles and its open panel; Export Bundle… (⇧⌘E)
/// and Export Brewfile… save what's installed, after listing anything they leave out; Include Dependencies in Exports
/// (a checkmark, on by default and remembered) decides whether packages that came in as dependencies are in them.
/// All four are off
/// while something modal is up and while a run is going (`canOpenFile`, `canExport`), and Open Bundle… also while
/// an export is being gathered.
///
/// Find (⌘F) shows Discover and focuses its search field; Refresh (⌘R) checks Updates and Installed again
/// (after the run, when one is going); Show Details (⌘I) toggles the inspector, and Hide Details works on
/// every page while it's open.
///
/// The Package menu lists what the tables' plain keys do, with ⌘ shortcuts so they never fire while someone types in
/// the search field or the password sheet: Return installs or updates the selection (⌘↩), Space checks or unchecks
/// it, and Delete removes it after a confirmation (⌘⌫, as in Finder). While that confirmation is up, Find, Refresh
/// and the Package items are off, so nothing changes the page or the refs it names behind it. "Move to" lists the
/// package managers the one selected Installed row can move to (`moveMenuItems`), and is off anywhere else.
public struct BrewxPortCommands: Commands {
    let model: BrewxPortAppModel?

    /// Nil when the window has no model (a demo that couldn't start): the items are then disabled.
    public init(model: BrewxPortAppModel?) { self.model = model }

    public var body: some Commands {
        // BrewxPort has one window, so File has no New; it opens and exports bundles instead.
        CommandGroup(replacing: .newItem) {
            Button("Open Bundle…") { model?.showOpenPanel() }
                .keyboardShortcut("o")
                .disabled(model?.canOpenFile != true)
            Divider()
            Button("Set Up Package Manager…") { model?.showSetupOffer() }
                .disabled(model?.canShowSetupOffer != true)
            Divider()
            Button("Export Bundle…") { export(.bundle) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.canExport != true)
            Button("Export Brewfile…") { export(.brewfile) }
                .disabled(model?.canExport != true)
            Toggle("Include Dependencies in Exports", isOn: Binding(
                get: { model?.exportIncludesDependencies ?? true },
                set: { model?.exportIncludesDependencies = $0 }))
                .disabled(model?.canExport != true)
        }
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
            MoveToMenu(items: model?.moveMenuItems ?? []) { model?.moveSelection($0) }
            Button("Remove Selected…") { model?.removeSelection() }
                .keyboardShortcut(.delete)
                .disabled(model?.canRemoveSelection != true)
        }
    }

    private func export(_ kind: ExportKind) {
        guard let model else { return }
        Task { await model.export(kind) }
    }
}
