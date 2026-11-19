import BrewxPortCore
import SwiftUI

/// Discover: the toolbar search, the engine filter, the merged results and the toolbar's Install.
struct DiscoverView: View {
    @Bindable var model: BrewxPortAppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var discover = model.discover
        let list = discover.list
        VStack(spacing: 0) {
            if !list.errors.isEmpty {
                ErrorBanner(lines: list.errors)
                Divider()
            }
            results(discover, list)
        }
        .searchable(text: $discover.query, placement: .toolbar, prompt: "Search all engines")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { discover.submit() }
        // Runs on appear too, so Find from another page focuses the field once Discover is on screen.
        .task(id: model.focusSearchRequest) {
            guard model.takeSearchFocusRequest() else { return }
            await Task.yield()
            searchFocused = true
        }
        .onChange(of: list.selection.selected) { _, refs in model.selectionChanged(refs) }
        .toolbar {
            ToolbarItem {
                if discover.searching {
                    ProgressView().controlSize(.small).accessibilityLabel("Searching")
                }
            }
            ToolbarItem {
                Picker("Engine", selection: $discover.engineFilter) {
                    Text("All engines").tag(EngineID?.none)
                    Divider()
                    ForEach(discover.filterChoices, id: \.self) { engine in
                        Label(engine.displayName, systemImage: EngineRowText.symbol(engine))
                            .tag(EngineID?.some(engine))
                    }
                }
                .pickerStyle(.menu)
                .help("Show results from one engine")
            }
            ToolbarItem {
                Button(discover.installTitle, systemImage: "arrow.down.circle") { model.installChecked() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!model.canInstallChecked)
                    .help("Install the checked packages")
            }
        }
    }

    @ViewBuilder private func results(_ discover: DiscoverModel, _ list: PackageListState) -> some View {
        if list.rows.isEmpty {
            if discover.searching {
                ProgressView("Searching every engine…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let query = discover.submittedQuery {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView("Search every engine", systemImage: "magnifyingglass",
                                       description: Text("Type a name and press Return to search every engine at once."))
            }
        } else {
            PackageTable(model: model, list: list)
                .onKeyPress(.return) {
                    model.performPrimary()
                    return .handled
                }
                .onKeyPress(.space) {
                    model.toggleChecks()
                    return .handled
                }
        }
    }
}

/// One line per engine that failed, above the table.
struct ErrorBanner: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
