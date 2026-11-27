import BrewxPortCore
import SwiftUI

/// Updates: every engine's outdated packages with checkboxes, sortable columns, Update all, Update N (the checked
/// rows), Refresh (with "Refresh MacPorts…" in its menu when MacPorts is there) and "Show ignored". Ignored rows
/// carry `bell.slash` and skipped ones `forward`; a held row carries `pause.circle` with its reason, and one held
/// from every update has its checkbox off. With Group by Package Manager on, rows sit in one collapsible section per
/// engine whose header has its own "Update N", and says how many of its packages couldn't be checked. Those counts
/// are also above the list, so a check that found nothing still says them.
struct UpdatesView: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        @Bindable var updates = model.updates
        let list = updates.list
        VStack(spacing: 0) {
            if !list.errors.isEmpty {
                ErrorBanner(lines: list.errors)
                Divider()
            }
            if !updates.uncheckedLines.isEmpty {
                ErrorBanner(lines: updates.uncheckedLines, systemImage: "questionmark.circle")
                Divider()
            }
            content(updates, list)
        }
        .onChange(of: list.selection.selected) { _, refs in model.selectionChanged(refs) }
        .toolbar {
            ToolbarItem {
                if list.loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking for updates")
                }
            }
            ToolbarItem {
                Toggle("Show ignored", isOn: $updates.showHidden)
                    .toggleStyle(.button)
                    .help("Show ignored packages and skipped versions")
            }
            ToolbarItem {
                if model.showsRefreshMacPorts {
                    // A click checks again, as without MacPorts; the menu adds MacPorts' own catalogue refresh.
                    Menu {
                        Button("Refresh MacPorts…") { model.refreshMacPortsCatalogue() }
                            .disabled(!model.canRefreshMacPorts)
                            .help("Refresh MacPorts' port catalogue (asks for your password), then check again")
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        model.refresh()
                    }
                    .help("Check every engine for updates again (⌘R). Its menu has Refresh MacPorts…")
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                        .help("Check every engine for updates again (⌘R)")
                }
            }
            ToolbarItem {
                Button(updates.updateCheckedTitle, systemImage: "checkmark.circle") { model.updateChecked() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canUpdateChecked)
                    .help("Update the checked packages")
            }
            ToolbarItem {
                Button("Update all", systemImage: "arrow.triangle.2.circlepath") { model.updateAll() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canUpdateAll)
                    .help("Update every package that isn't ignored or skipped")
            }
        }
    }

    @ViewBuilder private func content(_ updates: UpdatesModel, _ list: PackageListState) -> some View {
        if list.rows.isEmpty {
            if list.loading {
                ProgressView("Checking every engine for updates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(updates.emptyTitle, systemImage: "checkmark.circle",
                                       description: Text(updates.emptyNote))
            }
        } else {
            UpdatesTable(model: model, updates: updates, list: list)
                .onKeyPress(.return) {
                    model.performPrimary()
                    return .handled
                }
                .onKeyPress(.space) {
                    model.toggleChecks()
                    return .handled
                }
                .onDeleteCommand { model.removeSelection() }
        }
    }

}

private struct UpdatesTable: View {
    @Bindable var model: BrewxPortAppModel
    let updates: UpdatesModel
    @Bindable var list: PackageListState

    var body: some View {
        let grouped = model.groupByPackageManager
        Table(of: PackageRow.self, selection: $list.selection.selected, sortOrder: $list.sortOrder) {
            TableColumn("") { (row: PackageRow) in
                Toggle("Select \(row.name)", isOn: list.checkedBinding(row.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(updates.blocksManual(row))
            }
            .width(24)
            TableColumn("Name", value: \.name) { (row: PackageRow) in
                HStack(spacing: 4) {
                    Text(row.name).help(row.name)
                    if let hold = updates.hold(for: row) {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.secondary)
                            .help(hold.reason)
                            .accessibilityLabel(hold.reason)
                    }
                    switch updates.hiddenReason(row) {
                    case .ignored?:
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.secondary)
                            .help("Updates ignored")
                            .accessibilityLabel("Updates ignored")
                    case .skipped?:
                        Image(systemName: "forward")
                            .foregroundStyle(.secondary)
                            .help("Version \(row.latest) skipped")
                            .accessibilityLabel("Version \(row.latest) skipped")
                    case nil:
                        EmptyView()
                    }
                }
            }
            .width(min: 80, ideal: 160)
            if !grouped {
                TableColumn("Engine", value: \.engineName) { (row: PackageRow) in
                    Label(row.engineName, systemImage: EngineRowText.symbol(row.id.engine))
                }
                .width(min: 96, ideal: 130)
            }
            TableColumn("Installed", value: \.installed) { (row: PackageRow) in
                Text(row.installed).monospacedDigit()
            }
            .width(min: 56, ideal: 90)
            TableColumn("Latest", value: \.latest) { (row: PackageRow) in
                Text(row.latest).monospacedDigit()
            }
            .width(min: 56, ideal: 90)
            TableColumn("Arch", value: \.archName)
                .width(min: 40, ideal: 55)
        } rows: {
            if grouped {
                // One section per engine, in engine order; the column sort orders rows within each section.
                ForEach(PackageSections.make(list.rows, engine: \.id.engine, order: model.engineOrder)) { section in
                    let engine = section.engine
                    let collapsed = model.isCollapsed(engine, on: .updates)
                    Section {
                        // A collapsed section only hides its rows: they stay in `list.rows`, checked or not.
                        ForEach(collapsed ? [] : section.rows) { TableRow($0) }
                    } header: {
                        PackageSectionHeader(engine: engine, count: section.rows.count, isCollapsed: collapsed) {
                            model.setCollapsed(!collapsed, engine, on: .updates)
                        } trailing: {
                            if let note = updates.uncheckedNote(for: engine) {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help(updates.uncheckedDetail(for: engine) ?? note)
                            }
                            let n = updates.updateCount(for: engine)
                            if n > 0 {
                                Button("Update \(n)") { model.updateAll(engine: engine) }
                                    .controlSize(.small)
                                    .accessibilityLabel(
                                        "Update \(engine.displayName), \(n) \(n == 1 ? "package" : "packages")")
                                    .disabled(!model.canUpdateAll)
                                    .help("Update every \(engine.displayName) package that isn't ignored or skipped")
                            }
                        }
                    }
                }
            } else {
                ForEach(list.rows) { TableRow($0) }
            }
        }
        .packageRowMenu(model: model, view: .updates)
        // Grouping hides the Engine column; a fresh table avoids the blank strip its old width leaves behind.
        .id(grouped)
    }
}
