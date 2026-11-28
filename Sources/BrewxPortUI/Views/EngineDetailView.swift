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
                if let location = model.installLocation(for: engine) {
                    LabeledContent("Installs into", value: location)
                }
                if let versions = model.versionManagerNote(for: engine) {
                    Label(versions, systemImage: "square.stack")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status, let message = PackageCatalog.message(for: engine, status: status) {
                    Label(message, systemImage: EngineRowText.statusSymbol(status))
                        .foregroundStyle(.orange)
                }
                if let reason = readOnlyReason {
                    Label(reason, systemImage: "lock")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let kept = model.keptRuntimeNote(for: engine) {
                    Label(kept, systemImage: "pin")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let unchecked = model.updates.uncheckedDetail(for: engine) {
                    Label("Last check: " + unchecked, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                if let note {
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    if model.checkingEngines { ProgressView().controlSize(.small).accessibilityLabel("Checking engines") }
                    Button("Check again", action: model.checkEnginesAgain)
                        .disabled(!model.canCheckEngines)
                }
                if let line = model.setupLine(for: engine) {
                    Label(line, systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupButton(model: model, engine: engine)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } header: {
                Label(engine.displayName, systemImage: EngineRowText.symbol(engine)).font(.title2)
            }

            if let note = model.pathNote(for: engine) {
                Section("PATH") { pathNote(note) }
            }

            if BrewxPortAppModel.repairingEngines.contains(engine), isPresent {
                Section("Repair tools") {
                    if let offer = model.repairOffer(for: engine) {
                        Label(offer, systemImage: "wrench.and.screwdriver")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(EngineDetailText.repairHelp(engine))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("Repair tools") { model.repairTools(engine) }
                            .disabled(!model.canRepair(engine))
                    }
                }
            }

            Section("Capabilities") {
                let style = capabilityStyle
                ForEach(EngineRowText.capabilityLines(for: engine, capabilities), id: \.self) {
                    Text($0).foregroundStyle(style)
                }
            }

        }
        .formStyle(.grouped)
    }

    /// The PATH note and its opt-in fix, as the move preview offers it: the line and the file it goes into, then Add
    /// to PATH (zsh and bash), or the line with Copy for any other shell. After it worked, what it did instead.
    @ViewBuilder private func pathNote(_ note: PathNote) -> some View {
        if case .done(let outcome) = model.pathFix(for: engine) {
            Label(EngineDetailText.pathFixDone(outcome, engine), systemImage: "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Label(note.text, systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            if let line = note.line {
                let offer = model.pathOffer
                let caption = EngineDetailText.pathCaption(offer, lines: line.split(separator: "\n").count)
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(line)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if case .failed(let message) = model.pathFix(for: engine) {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    switch offer {
                    case .append:
                        Button(MoveSheetText.addToPath) { model.addToPath(engine) }
                            .disabled(model.services.isDemo)
                            .help(model.services.isDemo ? MoveSheetText.notInDemo : caption + " " + line)
                    case .copyOnly:
                        Button(MoveSheetText.copy) { model.copyPathLine(engine) }
                    }
                }
            }
        }
    }

    private var isPresent: Bool {
        if case .present? = status { return true }
        return false
    }

    /// Why this account can't change the engine's tools. Read again whenever a check of the engines ends.
    private var readOnlyReason: String? {
        _ = model.engineStatuses
        return model.readOnlyReason(for: engine)
    }

    private var status: EngineStatus? { model.engineStatuses[engine] }

    private var path: String? {
        switch status {
        case .present(let url, _)?, .unusable(let url, _)?, .unsupported(let url, _, _)?: url.path
        case .missing?, nil: model.services.engines.first { $0.id == engine }?.executableURL?.path
        }
    }

    private var version: String? {
        switch status {
        case .present(_, let version)?, .unsupported(_, let version, _)?: return version
        case .missing?, .unusable?, nil: return nil
        }
    }

    /// What the engine said about its last listing or check (uv's warning about a tool it left out, RubyGems' tools
    /// that aren't on RubyGems.org). Read again whenever Installed or Updates finishes loading.
    private var note: String? {
        _ = model.installed.list.loading
        _ = model.updates.list.loading
        return (model.services.engines.first { $0.id == engine } as? any EngineNoteReporting)?.note
    }

    /// The plain Capabilities line is secondary, as before 0.8.0; an engine's own capabilities are primary.
    private var capabilityStyle: HierarchicalShapeStyle {
        EngineRowText.capabilityLinesArePlain(for: engine, capabilities) ? .secondary : .primary
    }

    private var capabilities: EngineCapabilities {
        model.services.engines.first { $0.id == engine }?.capabilities ?? []
    }
}

/// The engine page's words, kept apart from the view so they can be tested.
public enum EngineDetailText {
    /// What Repair tools does, before any runtime changed.
    public static func repairHelp(_ engine: EngineID) -> String {
        switch engine {
        case .npm: return "Rebuilds your npm tools, for when Node was updated to a new major version."
        case .gem: return "Installs your gems again, for when Ruby was updated to a new minor version."
        default: return "Reinstalls your \(engine.displayName) tools, for when the Python they run on changed."
        }
    }

    /// Above the PATH note's lines: the move preview's caption, or in the plural for Cargo's two folders.
    public static func pathCaption(_ offer: ShellPathEditor.Offer, lines: Int) -> String {
        switch offer {
        case .append(let target):
            lines > 1 ? "Adds these lines to \(target.file):" : MoveSheetText.addsLine(to: target.file)
        case .copyOnly(let hint):
            lines > 1 ? hint.map { "Add these lines to \($0):" } ?? "Add these lines to your shell's startup file:"
                : MoveSheetText.copyCaption(hint: hint)
        }
    }

    /// What replaces the PATH note once Add to PATH worked.
    public static func pathFixDone(_ outcome: ShellPathEditor.Outcome, _ engine: EngineID) -> String {
        switch outcome {
        case .added(let file):
            return "Added to \(file). Open a new Terminal window to use \(engine.possessive) tools."
        case .alreadyPresent(let file): return "Already in \(file)"
        }
    }
}
