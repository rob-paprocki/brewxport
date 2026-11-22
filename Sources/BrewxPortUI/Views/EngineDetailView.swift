import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// One engine's page: path, version, what's wrong with it, and what it can do. BrewxPort's helper has its own page.
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
                        .disabled(!model.canCheckEngines)
                }
                SetupButton(model: model, engine: engine)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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

        }
        .formStyle(.grouped)
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
