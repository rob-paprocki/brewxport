import BrewxPortRun
import SwiftUI

/// BrewxPort's helper: its state with the buttons that fix it, what it does, and where macOS lists it.
struct HelperView: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        Form {
            Section {
                HStack {
                    if model.checkingHelper {
                        ProgressView().controlSize(.small).accessibilityLabel("Checking the helper")
                    }
                    Text(model.helperText).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if HelperStateDisplay.offersReinstall(model.helperState) {
                        Button("Reinstall helper", action: model.reinstallHelper)
                            .disabled(model.checkingHelper || model.run.isRunning)
                    }
                    Button("Check again", action: model.checkHelper)
                        .disabled(model.checkingHelper || model.run.isRunning)
                }
            } header: {
                Label("Helper", systemImage: "lock.shield").font(.title2)
            }

            Section("What it does") {
                Text(HelperStateDisplay.about).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Open Login Items", action: model.openLoginItems)
                        .disabled(model.run.isRunning)
                }
            }
        }
        .formStyle(.grouped)
    }
}
