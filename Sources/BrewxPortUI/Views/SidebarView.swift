import BrewxPortCore
import BrewxPortRun
import SwiftUI

/// Library (Discover, Updates, Installed, Bundles), one row per engine in the host's engine order, and BrewxPort's
/// helper.
struct SidebarView: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("Discover", systemImage: "magnifyingglass").tag(SidebarItem.discover)
                Label("Updates", systemImage: "arrow.down.circle")
                    .badge(model.updates.badgeCount)
                    .tag(SidebarItem.updates)
                Label("Installed", systemImage: "checkmark.rectangle.stack").tag(SidebarItem.installed)
                Label("Bundles", systemImage: "archivebox").tag(SidebarItem.bundles)
            }
            Section("Engines") {
                ForEach(model.engineOrder, id: \.self) { id in
                    EngineRow(id: id, status: model.engineStatuses[id])
                        .tag(SidebarItem.engine(id))
                }
            }
            if model.hasHelper {
                Section("BrewxPort") {
                    HelperRow(state: model.helperState).tag(SidebarItem.helper)
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// The list's selection is optional; the model's never is.
    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebar }, set: { if let item = $0 { model.sidebar = item } })
    }
}

private struct EngineRow: View {
    let id: EngineID
    let status: EngineStatus?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(id.displayName)
                    Text(EngineRowText.subtitle(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: EngineRowText.symbol(id))
            }
            Spacer()
            Image(systemName: EngineRowText.statusSymbol(status))
                .foregroundStyle(statusColor)
                .accessibilityLabel(EngineRowText.subtitle(status))
        }
    }

    private var statusColor: Color {
        switch status {
        case .present?: .green
        case .unusable?: .orange
        case .missing?, nil: .secondary
        }
    }
}

private struct HelperRow: View {
    let state: HelperState?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Helper")
                    Text(HelperStateDisplay.shortText(for: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
            }
            Spacer()
            Image(systemName: HelperStateDisplay.symbol(for: state))
                .foregroundStyle(statusColor)
                .accessibilityLabel(HelperStateDisplay.shortText(for: state))
        }
    }

    private var statusColor: Color {
        switch state {
        case .enabled?: .green
        case .requiresApproval?, .failed?: .orange
        case nil, .notRegistered?, .outdated?: .secondary
        }
    }
}
