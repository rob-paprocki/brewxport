import BrewxPortCore
import SwiftUI

/// The inspector: the followed row's details and, for a package that isn't installed, its Install button.
/// Before Install, the options the package's engine takes (`BrewxPortAppModel.inspectorOptions`).
struct DetailsInspector: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        let details = model.details
        Group {
            if let row = details.row {
                Form {
                    Section {
                        LabeledContent("Engine") {
                            Label(row.engineName, systemImage: EngineRowText.symbol(row.id.engine))
                        }
                        LabeledContent("Kind", value: row.kindName)
                        LabeledContent("Installed", value: details.details?.installedVersion ?? row.installed)
                        LabeledContent("Latest", value: details.details?.latestVersion ?? row.latest)
                    } header: {
                        Text(row.name).font(.title3)
                    }
                    if let copies = copiesNotes(row) {
                        Section("Other copies") {
                            ForEach(copies, id: \.self) { Text($0) }
                        }
                    }
                    if details.loading {
                        HStack { ProgressView().controlSize(.small); Text("Loading details…") }
                    }
                    if let error = details.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if let info = details.details, info.hasAbout {
                        Section("About") {
                            if let summary = info.summary { Text(summary) }
                            if let homepage = info.homepage { Link(homepage.absoluteString, destination: homepage) }
                            if let dependencies = info.dependencies {
                                LabeledContent("Dependencies",
                                               value: dependencies.isEmpty ? "None" : dependencies.joined(separator: ", "))
                            }
                            if !info.variants.isEmpty {
                                LabeledContent("Variants", value: info.variants.joined(separator: ", "))
                            }
                            if let executables = info.executables {
                                LabeledContent("Executables",
                                               value: executables.isEmpty ? "None" : executables.joined(separator: ", "))
                            }
                        }
                    }
                    if let fields = model.inspectorOptions, installReady {
                        optionsSection(fields)
                    }
                    Section { installRow(row) }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Select one package", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder private func installRow(_ row: PackageRow) -> some View {
        switch model.details.installAvailability(isRunning: model.run.isRunning || model.preparing,
                                                 homebrewPresent: model.homebrewPresent,
                                                 isOutdated: model.outdatedRefs.contains(row.id)
                                                    || model.hasReadOnlyUpdate(row.id)) {
        case .updateAvailable(let installed, let latest):
            // A language engine this account can't change: Update is off, saying why.
            let readOnly = model.readOnlyReason(for: row.id.engine)
            VStack(alignment: .leading, spacing: 6) {
                Text("Update available: \(installed) → \(latest)")
                Button("Update") { model.updateFromInspector() }
                    .disabled(!model.canRun || model.confirmingRemoval || readOnly != nil)
                    .help(readOnly ?? "")
            }
        case .ready:
            Button("Install") { model.installFromInspector() }
                .disabled(!model.canInstallFromInspector)
                .help(model.readOnlyReason(for: row.id.engine) ?? "")
        case .running:
            Button("Install") {}.disabled(true)
        case .alreadyInstalled:
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        case .checking:
            ProgressView().controlSize(.small).accessibilityLabel("Checking")
        case .needsHomebrew(let text):
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs Homebrew").font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }

    /// For a name several engines installed: who else has it, which copy runs, or why BrewxPort can't tell.
    private func copiesNotes(_ row: PackageRow) -> [String]? {
        let notes = [model.installed.duplicateHelp(row), model.installed.whichCopyRunsNote(row)].compactMap { $0 }
        return notes.isEmpty ? nil : notes
    }

    private var installReady: Bool {
        model.details.installAvailability(isRunning: model.run.isRunning || model.preparing,
                                          homebrewPresent: model.homebrewPresent) == .ready
    }

    @ViewBuilder private func optionsSection(_ fields: InspectorOptionFields) -> some View {
        @Bindable var details = model.details
        if fields.version || fields.extraArgs || !fields.variants.isEmpty {
            Section("Install options") {
                if fields.version {
                    TextField("Version", text: $details.options.version, prompt: Text("Latest"))
                }
                ForEach(fields.variants, id: \.self) { variant in
                    Picker(variant, selection: variantChoice(variant)) {
                        Text("Default").tag(Bool?.none)
                        Text("+\(variant)").tag(Bool?.some(true))
                        Text("-\(variant)").tag(Bool?.some(false))
                    }
                }
                if fields.extraArgs {
                    TextField("Extra arguments", text: $details.options.extraArgs, prompt: Text("None"))
                        .autocorrectionDisabled()
                }
                if let error = details.optionsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
        }
    }

    private func variantChoice(_ variant: String) -> Binding<Bool?> {
        Binding(get: { model.details.options.variants[variant] },
                set: { model.details.options.variants[variant] = $0 })
    }
}

private extension PackageDetails {
    /// False when the engine gave nothing for the About section, so no empty heading is drawn.
    var hasAbout: Bool {
        summary != nil || homepage != nil || dependencies != nil || !variants.isEmpty || executables != nil
    }
}
