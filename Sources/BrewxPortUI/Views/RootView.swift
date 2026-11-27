import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// The window: sidebar, the selected page, the run panel along the bottom, the inspector, the password sheet, the
/// setup and move sheets, the uninstall confirmation, the one-time background sheet, the warning before a runtime
/// update, and Bundles' open and save panels.
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
        .modifier(BundlesFilePanels(model: model))
        // The app delegate starts the model at launch, so this is a no-op there; it covers a host that doesn't.
        .task { model.start() }
        // This view is the main window's content: it appears when the window opens and goes when it closes. The app
        // shows or hides the Dock icon from that (`showsDockIcon`).
        .onAppear { model.mainWindowShowing = true }
        .onDisappear { model.mainWindowShowing = false }
        // Dismissing the sheet ends the prompt as cancelled; see `RunController.sheetDismissed()`.
        .sheet(isPresented: $run.showingPasswordSheet, onDismiss: { model.run.sheetDismissed() }) {
            PasswordSheet(reason: run.passwordReason, previousAttemptFailed: run.passwordRetry,
                          note: model.passwordNote) {
                model.run.finishPassword($0)
            }
        }
        // The setup sheet shows while a screen has something to say; while a setup runs, the run panel shows it.
        .sheet(isPresented: setupShown) { SetupView(model: model) }
        // The move preview, while it checks, shows a plan or says why there's none. Esc or anything else that
        // dismisses it cancels; once the move runs the sheet is gone and the run panel shows it.
        .sheet(isPresented: moveShown) { MoveSheet(model: model.move) }
        // The uninstall sheet: checking, then the plan. Esc or anything else that dismisses it cancels; once the
        // uninstall runs the sheet is gone and the run panel shows it.
        .sheet(isPresented: uninstallShown) { UninstallSheet(model: model.uninstall) }
        // The one-time "BrewxPort now checks for updates", once nothing else is up (`backgroundIntroDue`). Esc closes
        // it like Done, keeping what its switches show.
        .sheet(isPresented: backgroundIntroShown) { BackgroundIntroSheet(model: model) }
        // Before an update of a Homebrew runtime that language tools run on: Update goes ahead, Cancel (or Esc)
        // starts nothing.
        .alert(model.runtimeWarning?.title ?? "", isPresented: runtimeWarningShown, presenting: model.runtimeWarning) { _ in
            Button("Cancel", role: .cancel) { model.cancelRuntimeUpdate() }
            Button("Update") { model.confirmRuntimeUpdate() }
        } message: { warning in
            Text(warning.message)
        }
    }

    private var runtimeWarningShown: Binding<Bool> {
        Binding(get: { model.runtimeWarning != nil },
                set: { shown in if !shown { model.cancelRuntimeUpdate() } })
    }

    private var backgroundIntroShown: Binding<Bool> {
        Binding(get: { model.showingBackgroundIntro },
                set: { shown in if !shown { model.closeBackgroundIntro() } })
    }

    private var setupShown: Binding<Bool> {
        Binding(get: { model.setup.sheetShown },
                set: { shown in if !shown { model.setup.dismiss() } })
    }

    private var moveShown: Binding<Bool> {
        Binding(get: { model.move.sheetShown },
                set: { shown in if !shown { model.move.cancel() } })
    }

    private var uninstallShown: Binding<Bool> {
        Binding(get: { model.uninstall.sheetShown },
                set: { shown in if !shown { model.uninstall.cancel() } })
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
            BundlesView(model: model)
        case .engine(let id):
            EngineDetailView(model: model, engine: id)
        case .helper:
            HelperView(model: model)
        }
    }
}
