import BrewxPortCore
import SwiftUI

/// Updates: every engine's outdated packages with checkboxes, sortable columns, Update all, Update N (the checked
/// rows), Refresh and "Show ignored". Ignored rows carry `bell.slash` and skipped ones `forward`.
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
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshLists() }
                    .help("Check every engine for updates again (⌘R)")
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
                ContentUnavailableView("Everything is up to date", systemImage: "checkmark.circle",
                                       description: Text(emptyNote(updates)))
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

    private func emptyNote(_ updates: UpdatesModel) -> String {
        let hidden = updates.hiddenCount
        if hidden == 0 { return "No engine has a newer version of anything you installed." }
        return hidden == 1 ? "1 update is ignored or skipped." : "\(hidden) updates are ignored or skipped."
    }
}

private struct UpdatesTable: View {
    @Bindable var model: BrewxPortAppModel
    let updates: UpdatesModel
    @Bindable var list: PackageListState

    var body: some View {
        Table(list.rows, selection: $list.selection.selected, sortOrder: $list.sortOrder) {
            TableColumn("") { (row: PackageRow) in
                Toggle("Select \(row.name)", isOn: list.checkedBinding(row.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Name", value: \.name) { (row: PackageRow) in
                HStack(spacing: 4) {
                    Text(row.name).help(row.name)
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
            TableColumn("Engine", value: \.engineName) { (row: PackageRow) in
                Label(row.engineName, systemImage: EngineRowText.symbol(row.id.engine))
            }
            .width(min: 96, ideal: 130)
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
        }
        .packageRowMenu(model: model, view: .updates)
    }
}
