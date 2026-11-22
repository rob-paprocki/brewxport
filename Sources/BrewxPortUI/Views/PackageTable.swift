import BrewxPortCore
import SwiftUI

/// The package table for Discover: a checkbox, Name, Version, Engine, Arch and Kind. Updates and Installed have their
/// own columns (`UpdatesTable`, `InstalledTable`) but the same checkbox binding and row menu.
/// The right-click menu comes from `RowActions`, and double-click opens the inspector; every action goes through
/// `BrewxPortAppModel.perform`.
struct PackageTable: View {
    @Bindable var model: BrewxPortAppModel
    @Bindable var list: PackageListState

    var body: some View {
        Table(list.rows, selection: $list.selection.selected, sortOrder: $list.sortOrder) {
            TableColumn("") { (row: PackageRow) in
                Toggle("Select \(row.name)", isOn: checked(row.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(24)
            TableColumn("Name", value: \.name) { (row: PackageRow) in
                HStack(spacing: 4) {
                    Text(row.name).help(row.name)
                    if row.isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Installed")
                            .accessibilityLabel("Installed")
                    }
                }
            }
            .width(min: 80, ideal: 160)
            TableColumn("Version", value: \.latest) { (row: PackageRow) in
                Text(row.latest).monospacedDigit()
                    .optionalHelp(row.latestHelp)
            }
            .width(min: 56, ideal: 90)
            TableColumn("Engine", value: \.engineName) { (row: PackageRow) in
                Label(row.engineName, systemImage: EngineRowText.symbol(row.id.engine))
            }
            .width(min: 96, ideal: 130)
            TableColumn("Arch", value: \.archName)
                .width(min: 40, ideal: 55)
            TableColumn("Kind", value: \.kindName)
                .width(min: 44, ideal: 65)
        }
        .packageRowMenu(model: model, view: .discover)
    }

    private func checked(_ ref: PackageRef) -> Binding<Bool> {
        list.checkedBinding(ref)
    }
}

extension PackageListState {
    /// A row's checkbox, bound through `selection.checked`.
    func checkedBinding(_ ref: PackageRef) -> Binding<Bool> {
        Binding(get: { self.selection.checked.contains(ref) },
                set: { on in
                    if on != self.selection.checked.contains(ref) { self.selection.toggleChecks(for: [ref]) }
                })
    }
}

extension View {
    /// A tooltip only when there's something to say.
    @ViewBuilder func optionalHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }

    /// The right-click menu (`BrewxPortAppModel.rowMenuItems`, from `RowActions`) and double-click for details, both
    /// through `BrewxPortAppModel.perform`. Shared by every package table, Bundles' included. The Move items
    /// (always next to each other) show as one "Move to" submenu where the first of them is.
    func packageRowMenu(model: BrewxPortAppModel, view: PackageView) -> some View {
        contextMenu(forSelectionType: PackageRef.self) { refs in
            let items = model.rowMenuItems(for: refs, in: view)
            let firstMove = items.firstIndex(where: \.isMove) ?? items.endIndex
            let moves = items.filter(\.isMove)
            ForEach(items[..<firstMove].filter { !$0.isMove }, id: \.self) { item in
                RowActionButton(item: item) { model.perform(item.action, on: refs) }
            }
            if !moves.isEmpty {
                MoveToMenu(items: moves) { model.perform($0, on: refs) }
            }
            ForEach(items[firstMove...].filter { !$0.isMove }, id: \.self) { item in
                RowActionButton(item: item) { model.perform(item.action, on: refs) }
            }
        } primaryAction: { refs in
            model.perform(.showDetails, on: refs)
        }
    }
}

/// One menu item from `RowActions`, off when it says so, with its tooltip.
struct RowActionButton: View {
    let item: RowActionItem
    let action: () -> Void

    var body: some View {
        Button(item.title, systemImage: item.systemImage, action: action)
            .disabled(!item.isEnabled)
            .optionalHelp(item.help)
    }
}

/// "Move to", with one item per package manager: in the right-click menu and the Package menu. Items that can't be
/// used still show, off (in demo mode with a tooltip); with no items at all the submenu is off.
struct MoveToMenu: View {
    let items: [RowActionItem]
    let perform: (RowAction) -> Void

    var body: some View {
        Menu("Move to") {
            ForEach(items, id: \.self) { item in
                Button(item.title) { perform(item.action) }
                    .disabled(!item.isEnabled)
                    .optionalHelp(item.help)
            }
        }
        .disabled(items.isEmpty)
    }
}
