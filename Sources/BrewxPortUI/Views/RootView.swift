import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// The window: sidebar, the selected page, the run panel along the bottom, the inspector, the password sheet and
/// the uninstall confirmation.
public struct RootView: View {
    @Bindable var model: BrewxPortAppModel

    public init(model: BrewxPortAppModel) { self.model = model }

    public var body: some View {
        @Bindable var run = model.run
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if run.panelVisible {
                    Divider()
                    RunPanel(run: run)
                }
            }
            .inspector(isPresented: $model.inspectorOpen) {
                DetailsInspector(model: model)
                    .inspectorColumnWidth(min: 250, ideal: 280)
            }
        }
        .task { model.start() }
        // Esc, the close button or anything else that dismisses the sheet ends the prompt as cancelled, so the run
        // never waits on a sheet that's gone. A secret that was already handed over makes this a no-op.
        .sheet(isPresented: $run.showingPasswordSheet, onDismiss: { model.run.finishPassword(nil) }) {
            PasswordSheet(reason: run.passwordReason, previousAttemptFailed: run.passwordRejected,
                          note: model.passwordNote) {
                model.run.finishPassword($0)
            }
        }
        .confirmationDialog(model.uninstallTitle, isPresented: uninstallShown, presenting: model.pendingUninstall) { refs in
            // Sets the refs again first, so the order SwiftUI clears the binding and runs the action in doesn't matter.
            // They are the refs the title names: nothing can replace `pendingUninstall` while it's set
            // (`BrewxPortAppModel.confirmingRemoval`).
            Button("Remove", role: .destructive) {
                model.pendingUninstall = refs
                model.confirmUninstall()
            }
            Button("Cancel", role: .cancel) { model.cancelUninstall() }
        } message: { _ in
            Text("Each package is removed with its own engine.")
        }
    }

    private var uninstallShown: Binding<Bool> {
        Binding(get: { model.pendingUninstall != nil },
                set: { shown in if !shown { model.cancelUninstall() } })
    }

    @ViewBuilder private var page: some View {
        switch model.sidebar {
        case .discover:
            DiscoverView(model: model)
        case .updates:
            UpdatesView(model: model)
        case .installed:
            InstalledView(model: model)
        case .bundles:
            BundlesPlaceholderView()
        case .engine(let id):
            EngineDetailView(model: model, engine: id)
        }
    }
}
