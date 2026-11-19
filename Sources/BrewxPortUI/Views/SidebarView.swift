import BrewxPortCore
import SwiftUI

/// Library (Discover, Updates, Installed, Bundles) and one row per engine, in the host's engine order.
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
