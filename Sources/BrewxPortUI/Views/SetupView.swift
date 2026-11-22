import BrewxPortCore
import SwiftUI

/// The setup sheet: offer the package managers, ask for the helper's approval, report a finished, failed or
/// unstartable setup. While it runs, the run panel shows progress and this sheet is away. Every stage has a way out
/// ("Not now", or Done).
struct SetupView: View {
    @Bindable var model: BrewxPortAppModel
    @State private var chosen: EngineID?

    private var setup: SetupModel { model.setup }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch setup.stage {
            case .offer(let recommended, let others):
                offer(recommended: recommended, others: others)
            case .needsHelperApproval:
                message(title: SetupCopy.approvalTitle, text: SetupCopy.approvalText) {
                    Button("Not now", action: setup.notNow).keyboardShortcut(.cancelAction)
                    Button("Open Login Items", action: model.openLoginItems).keyboardShortcut(.defaultAction)
                }
            case .finished:
                let engine = setup.engineBeingSetUp
                message(title: engine.map(SetupCopy.readyTitle) ?? "Setup is done", text: SetupCopy.readyText) {
                    Button("Done", action: setup.done).keyboardShortcut(.defaultAction)
                }
            case .failed(_, let reason):
                message(title: SetupCopy.failedTitle, text: reason) {
                    Button("Not now", action: setup.notNow).keyboardShortcut(.cancelAction)
                    Button("Try again", action: setup.retry).keyboardShortcut(.defaultAction)
                }
            case .cannotSetUp(_, let reason):
                message(title: SetupCopy.cannotTitle, text: reason) {
                    Button("Not now", action: setup.notNow).keyboardShortcut(.cancelAction)
                    Button("Try again", action: setup.retry).keyboardShortcut(.defaultAction)
                }
            case .hidden, .running:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func offer(recommended: EngineID, others: [EngineID]) -> some View {
        let selection = chosen ?? recommended
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(SetupCopy.offerTitle).font(.title2.bold())
                Text(SetupCopy.offerSubtitle).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach([recommended] + others, id: \.self) { engine in
                    row(engine, isRecommended: engine == recommended, selected: engine == selection)
                }
            }
            HStack {
                Spacer()
                Button("Not now", action: setup.notNow).keyboardShortcut(.cancelAction)
                Button("Set Up") { setup.setUp(selection) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row(_ engine: EngineID, isRecommended: Bool, selected: Bool) -> some View {
        Button { chosen = engine } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(engine.displayName).font(.headline)
                        if isRecommended {
                            Text(SetupCopy.recommendedLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(SetupCopy.blurb(engine))
                    Text(SetupCopy.detail(engine)).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func message<Buttons: View>(title: String, text: String,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.bold())
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                buttons()
            }
        }
    }
}

/// A "Set Up <name>…" button, or the line saying why there isn't one. Draws `BrewxPortAppModel.setupButton(for:)`.
struct SetupButton: View {
    @Bindable var model: BrewxPortAppModel
    let engine: EngineID
    /// What the button's help says when it's enabled (the Bundles banner puts the manual steps here).
    var help: String?

    var body: some View {
        switch model.setupButton(for: engine) {
        case .hidden:
            EmptyView()
        case .unavailable(let note):
            Text(note).foregroundStyle(.secondary)
        case .disabled(let title, let reason):
            Button(title) { model.setUpEngine(engine) }
                .disabled(true)
                .help(reason)
        case .enabled(let title):
            Button(title) { model.setUpEngine(engine) }
                .help(help ?? "")
        }
    }
}
