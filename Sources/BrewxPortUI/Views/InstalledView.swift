import BrewxPortCore
import SwiftUI

/// Installed: every engine's installed packages with checkboxes, sortable columns, "Remove N" (the checked rows) and
/// Refresh. A name installed by more than one engine carries `exclamationmark.triangle`, and the Runs column ticks
/// the copy that runs first on the PATH. Delete removes the selected rows; both ask first.
struct InstalledView: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        let installed = model.installed
        let list = installed.list
        VStack(spacing: 0) {
            if !list.errors.isEmpty {
                ErrorBanner(lines: list.errors)
                Divider()
            }
            if let note = installed.pathNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                Divider()
            }
            content(installed, list)
        }
        .onChange(of: list.selection.selected) { _, refs in model.selectionChanged(refs) }
        .toolbar {
            ToolbarItem {
                if list.loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Loading installed packages")
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { model.refreshLists() }
                    .help("Ask every engine what's installed again (⌘R)")
            }
            ToolbarItem {
                Button(installed.removeTitle, systemImage: "trash") { model.removeChecked() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canRemoveChecked)
                    .help("Remove the checked packages")
            }
        }
    }

    @ViewBuilder private func content(_ installed: InstalledModel, _ list: PackageListState) -> some View {
        if list.rows.isEmpty {
            if list.loading {
                ProgressView("Asking every engine what's installed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing installed", systemImage: "shippingbox",
                                       description: Text("No engine has installed anything yet."))
            }
        } else {
            InstalledTable(model: model, installed: installed, list: list)
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

/// Fed `InstalledModel.rows`, whose values carry each row's tick and warning, so the table redraws a row when they
/// change (the winners arrive after the list, once the PATH has been read).
private struct InstalledTable: View {
    @Bindable var model: BrewxPortAppModel
    @Bindable var installed: InstalledModel
    @Bindable var list: PackageListState

    var body: some View {
        Table(installed.rows, selection: $list.selection.selected, sortOrder: $installed.sortOrder) {
            TableColumn("") { (item: InstalledRow) in
                Toggle("Select \(item.name)", isOn: list.checkedBinding(item.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Name", value: \.name) { (item: InstalledRow) in
                HStack(spacing: 4) {
                    Text(item.name).help(item.name)
                    if let help = item.duplicateHelp {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(help)
                            .accessibilityLabel(help)
                    }
                }
            }
            .width(min: 80, ideal: 160)
            TableColumn("Version", value: \.version) { (item: InstalledRow) in
                Text(item.version).monospacedDigit()
            }
            .width(min: 56, ideal: 90)
            TableColumn("Engine", value: \.engineName) { (item: InstalledRow) in
                Label(item.engineName, systemImage: EngineRowText.symbol(item.id.engine))
            }
            .width(min: 96, ideal: 130)
            TableColumn("Arch", value: \.archName)
                .width(min: 40, ideal: 55)
            TableColumn("Kind", value: \.kindName)
                .width(min: 44, ideal: 65)
            TableColumn("Runs") { (item: InstalledRow) in
                if item.runsFirst {
                    Image(systemName: "checkmark")
                        .help("This copy runs first on your PATH")
                        .accessibilityLabel("Runs first on your PATH")
                }
            }
            .width(40)
        }
        .packageRowMenu(model: model, view: .installed)
    }
}
