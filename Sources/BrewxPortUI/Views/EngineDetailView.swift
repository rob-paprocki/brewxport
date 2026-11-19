import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// One engine's page: path, version, what's wrong with it, what it can do, and (for MacPorts) BrewxPort's helper.
struct EngineDetailView: View {
    @Bindable var model: BrewxPortAppModel
    let engine: EngineID

    var body: some View {
        Form {
            Section {
                LabeledContent("Path", value: path ?? "—")
                LabeledContent("Version", value: version ?? EngineRowText.subtitle(status))
                if let status, let message = PackageCatalog.message(for: engine, status: status) {
                    Label(message, systemImage: EngineRowText.statusSymbol(status))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    if model.checkingEngines { ProgressView().controlSize(.small).accessibilityLabel("Checking engines") }
                    Button("Check again", action: model.checkEnginesAgain)
                        .disabled(model.checkingEngines)
                }
            } header: {
                Label(engine.displayName, systemImage: EngineRowText.symbol(engine)).font(.title2)
            }

            Section("Capabilities") {
                let names = EngineRowText.capabilities(capabilities)
                if names.isEmpty {
                    Text("Install, update and remove").foregroundStyle(.secondary)
                } else {
                    ForEach(names, id: \.self) { Text($0) }
                }
            }

            if engine == .macports {
                helperSection
            }
        }
        .formStyle(.grouped)
    }

    private var helperSection: some View {
        Section("BrewxPort's helper") {
            HStack {
                if model.checkingHelper { ProgressView().controlSize(.small).accessibilityLabel("Checking the helper") }
                Text(model.helperText).fixedSize(horizontal: false, vertical: true)
            }
            if model.hasHelper {
                HStack {
                    Spacer()
                    if HelperStateDisplay.offersLoginItems(model.helperState) {
                        Button("Open Login Items", action: model.openLoginItems)
                            .disabled(model.run.isRunning)
                    }
                    if HelperStateDisplay.offersReinstall(model.helperState) {
                        Button("Reinstall helper", action: model.reinstallHelper)
                            .disabled(model.checkingHelper || model.run.isRunning)
                    }
                    Button("Check again", action: model.checkHelper)
                        .disabled(model.checkingHelper || model.run.isRunning)
                }
            }
        }
    }

    private var status: EngineStatus? { model.engineStatuses[engine] }

    private var path: String? {
        switch status {
        case .present(let url, _)?, .unusable(let url, _)?: url.path
        case .missing?, nil: model.services.engines.first { $0.id == engine }?.executableURL?.path
        }
    }

    private var version: String? {
        if case .present(_, let version)? = status { return version }
        return nil
    }

    private var capabilities: EngineCapabilities {
        model.services.engines.first { $0.id == engine }?.capabilities ?? []
    }
}
