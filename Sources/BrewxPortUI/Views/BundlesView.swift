import BrewxPortCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// BrewxPort's own file, declared in the app's Info.plist (`UTExportedTypeDeclarations`).
    static let brewxportBundle = UTType(exportedAs: "com.brewxport.bundle", conformingTo: .json)
}

/// Bundles: one open `.brewxportbundle` or Brewfile, checked against what's on this Mac. A header with the file and
/// its counts, setup help for missing engines, the lines BrewxPort doesn't handle, then the rows grouped by engine
/// (taps first) with the same checkboxes, keys and right-click menu as the other pages. Install installs the
/// checked rows. Open and the exports go through `BundlesFilePanels`, which RootView carries.
struct BundlesView: View {
    @Bindable var model: BrewxPortAppModel
    @State private var unhandledExpanded = true

    var body: some View {
        let bundles = model.bundles
        VStack(spacing: 0) {
            let problems = [bundles.openError, bundles.tapsProblem, model.exportMessage].compactMap { $0 }
            if !problems.isEmpty {
                ErrorBanner(lines: problems)
                Divider()
            }
            if let saved = model.exportSaved {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(saved)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                Divider()
            }
            content(bundles)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: bundles.list.selection.selected) { _, refs in model.selectionChanged(refs) }
        // A new file shows its unhandled lines again.
        .onChange(of: bundles.state.name) { unhandledExpanded = true }
        .toolbar {
            ToolbarItem {
                if bundles.isOpening, bundles.state != .empty {
                    ProgressView().controlSize(.small).accessibilityLabel("Opening")
                }
            }
            ToolbarItem {
                Button("Open…", systemImage: "folder") { model.showOpenPanel() }
                    .disabled(!model.canOpenFile)
                    .help("Open a BrewxPort bundle or a Brewfile (⌘O)")
            }
            ToolbarItem {
                ExportMenu(model: model)
            }
            ToolbarItem {
                Button(installTitle(bundles), systemImage: "arrow.down.circle") { bundles.installChecked() }
                    .labelStyle(.titleAndIcon)
                    .disabled(!bundles.canInstall)
                    .help("Install the checked packages")
            }
        }
    }

    private func installTitle(_ bundles: BundlesModel) -> String {
        let count = bundles.toInstallCount
        return count == 0 ? "Install" : "Install \(count)"
    }

    @ViewBuilder private func content(_ bundles: BundlesModel) -> some View {
        switch bundles.state {
        case .empty:
            if bundles.isOpening {
                ProgressView("Opening…")
                    .frame(maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No bundle open", systemImage: "archivebox")
                } description: {
                    Text("Open a BrewxPort bundle or a Brewfile to see what it would install. "
                         + "Export saves what's installed on this Mac.")
                } actions: {
                    Button("Open…") { model.showOpenPanel() }
                        .disabled(!model.canOpenFile)
                    ExportMenu(model: model)
                        .fixedSize()
                }
                .frame(maxHeight: .infinity)
            }
        case .checking(let name):
            VStack(spacing: 0) {
                FileHeader(name: name, summary: nil, close: model.closeBundle)
                Divider()
                // The rows are hidden until the new preview is in, so nothing from before is offered.
                ProgressView("Checking what's installed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .ready(let preview, let name):
            VStack(spacing: 0) {
                FileHeader(name: name, summary: bundles.summaryText, close: model.closeBundle)
                if !preview.missingEngines.isEmpty || !preview.unhandled.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.missingEngines, id: \.engine) { MissingEngineBox(model: model, setup: $0) }
                        if !preview.unhandled.isEmpty {
                            UnhandledList(title: preview.unhandledTitle, unhandled: preview.unhandled,
                                          expanded: $unhandledExpanded)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                Divider()
                if preview.groups.isEmpty {
                    ContentUnavailableView("Nothing BrewxPort can install", systemImage: "archivebox",
                                           description: Text("Everything in this file is listed above, with the "
                                                             + "reason BrewxPort skips it."))
                        .frame(maxHeight: .infinity)
                } else {
                    BundlesTable(model: model, bundles: bundles, list: bundles.list, preview: preview)
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
    }
}

/// The file's name, its counts and a Close button.
private struct FileHeader: View {
    let name: String
    let summary: String?
    let close: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                if let summary {
                    Text(summary).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Close File", action: close)
                .help("Close this file")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// An engine the file needs that's missing or not working: why, how to set it up, and its install page.
private struct MissingEngineBox: View {
    @Bindable var model: BrewxPortAppModel
    let setup: EngineSetup

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label(setup.reason, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.headline)
                Text(setup.skippedCount == 1 ? "1 entry is skipped until it's set up."
                                             : "\(setup.skippedCount) entries are skipped until it's set up.")
                    .foregroundStyle(.secondary)
                if model.setupButton(for: setup.engine) == .hidden {
                    ForEach(Array(setup.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                    }
                } else {
                    // The manual steps are the button's help; the install link stays.
                    SetupButton(model: model, engine: setup.engine, help: setup.steps.joined(separator: " "))
                }
                Link("Open \(setup.link.host() ?? setup.link.absoluteString)", destination: setup.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "N lines BrewxPort doesn't handle": each with its line or entry number, its text and the reason, in monospace.
private struct UnhandledList: View {
    /// `ImportPreview.unhandledTitle`.
    let title: String
    let unhandled: [PreviewUnhandled]
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                // Lazy: a file can hold thousands of these, and only the few in view are laid out (a Grid would lay
                // out every row at once). The font is monospaced, so a hidden copy of the longest text, the same in
                // every row, gives each column one width and the rows line up as in a grid.
                let widestLocation = unhandled.map(\.location).max { $0.count < $1.count } ?? ""
                let widestText = String(unhandled.map(\.text).max { $0.count < $1.count }?.prefix(48) ?? "")
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(unhandled.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            column(item.location, widest: widestLocation)
                                .foregroundStyle(.secondary)
                            column(item.text, widest: widestText)
                                .help(item.text)
                            Text(verbatim: item.reason)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 150)
        } label: {
            Label(title, systemImage: "text.badge.xmark")
                .font(.headline)
        }
    }

    /// One line of `text`, as wide as `widest` (hidden), cut short with "…" when it's longer.
    private func column(_ text: String, widest: String) -> some View {
        ZStack(alignment: .leading) {
            Text(verbatim: widest).lineLimit(1).hidden()
            Text(verbatim: text).lineLimit(1).truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// The preview's rows, grouped by engine in `preview.groups` order (taps first within Homebrew). Checkboxes and the
/// selection are `list`'s, like the other tables; rows that can't be installed have no checkbox to tick.
private struct BundlesTable: View {
    @Bindable var model: BrewxPortAppModel
    let bundles: BundlesModel
    @Bindable var list: PackageListState
    let preview: ImportPreview

    var body: some View {
        Table(of: ImportRow.self, selection: $list.selection.selected) {
            TableColumn("") { (row: ImportRow) in
                Toggle("Select \(row.displayName)", isOn: checked(row))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!row.isInstallable)
            }
            .width(24)
            TableColumn("Name") { (row: ImportRow) in
                Text(verbatim: row.displayName).help(row.displayName)
            }
            .width(min: 100, ideal: 180)
            TableColumn("Version") { (row: ImportRow) in
                version(row)
            }
            .width(min: 56, ideal: 90)
            TableColumn("Engine") { (row: ImportRow) in
                Label(row.id.engine.displayName, systemImage: EngineRowText.symbol(row.id.engine))
            }
            .width(min: 96, ideal: 120)
            TableColumn("Kind") { (row: ImportRow) in
                Text(row.kindName)
            }
            .width(min: 44, ideal: 60)
            TableColumn("State") { (row: ImportRow) in
                state(row)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Notes") { (row: ImportRow) in
                if !row.notes.isEmpty {
                    Text(row.notes.joined(separator: ". "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.notes.joined(separator: "\n"))
                }
            }
            .width(min: 120, ideal: 220)
        } rows: {
            ForEach(preview.groups, id: \.engine) { group in
                Section(group.engine.displayName) {
                    ForEach(group.rows) { TableRow($0) }
                }
            }
        }
        .packageRowMenu(model: model, view: .bundles)
    }

    /// Only installable rows show a tick: a checked row that's already installed is never requested.
    private func checked(_ row: ImportRow) -> Binding<Bool> {
        let binding = list.checkedBinding(row.id)
        return Binding(get: { row.isInstallable && binding.wrappedValue },
                       set: { binding.wrappedValue = $0 })
    }

    /// The installed version for a row that's installed, otherwise the file's pin (shown, not applied).
    @ViewBuilder private func version(_ row: ImportRow) -> some View {
        if case .alreadyInstalled(let installed) = row.state {
            if let installed {
                Text(verbatim: installed).monospacedDigit()
            } else {
                Text("—").accessibilityLabel("None")
            }
        } else if let pin = row.pin {
            Text(verbatim: pin).monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Pinned in the file. BrewxPort installs the latest version.")
        } else {
            Text("—").foregroundStyle(.secondary)
                .accessibilityLabel("None")
        }
    }

    @ViewBuilder private func state(_ row: ImportRow) -> some View {
        switch row.state {
        case .willInstall:
            Text("Will install")
        case .alreadyInstalled:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .engineMissing:
            Label("Skipped", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .help("\(row.id.engine.displayName) isn't set up on this Mac")
        case .duplicate(let other) where other == row.id.engine:
            Label("Pick one", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("The file lists another \(other.displayName) package with this name. Check the one you want.")
        case .duplicate(let other):
            Label("Also in \(other.displayName)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("The file lists this name for \(other.displayName) too. Check the copy you want.")
        }
    }
}

/// Export Bundle…, Export Brewfile… and Include Dependencies in Exports, as the File menu has them.
struct ExportMenu: View {
    @Bindable var model: BrewxPortAppModel

    var body: some View {
        Menu {
            Button("Export Bundle…") { Task { await model.export(.bundle) } }
            Button("Export Brewfile…") { Task { await model.export(.brewfile) } }
            Divider()
            Toggle("Include Dependencies in Exports", isOn: $model.exportIncludesDependencies)
        } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        .disabled(!model.canExport)
        .help("Save what's installed on this Mac as a bundle or a Brewfile")
    }
}

/// The open panel, the export review sheet and the save panel, on RootView so File menu commands work from any page.
/// The open panel takes any file: a Brewfile has no extension, so the content decides the format.
struct BundlesFilePanels: ViewModifier {
    @Bindable var model: BrewxPortAppModel
    /// The review sheet's answer, read when it has closed: the save panel only opens after the sheet is gone.
    @State private var reviewAnswer: Bool?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $model.showingOpenPanel,
                          allowedContentTypes: [.brewxportBundle, .json, .plainText, .data]) { result in
                if case .success(let url) = result { model.openPicked(url) }
            }
            .sheet(isPresented: reviewShown, onDismiss: {
                if reviewAnswer == true { model.confirmExport() } else { model.cancelExport() }
                reviewAnswer = nil
            }) {
                if let pending = model.exportReview {
                    ExportReviewSheet(pending: pending,
                                      save: { reviewAnswer = true },
                                      cancel: { reviewAnswer = false })
                }
            }
            // On its own view: a file importer and exporter on the same view can stop each other showing. A cancel
            // comes through `saveShown`'s setter.
            .background {
                Color.clear
                    .fileExporter(isPresented: saveShown,
                                  document: ExportFile(data: model.exportToSave?.data ?? Data()),
                                  contentType: model.exportToSave?.kind == .brewfile ? .data : .brewxportBundle,
                                  defaultFilename: model.exportToSave?.defaultName) { result in
                        model.exportFinished(result.map { $0 })
                    }
            }
    }

    private var reviewShown: Binding<Bool> {
        Binding(get: { model.exportReview != nil && reviewAnswer == nil },
                set: { shown in if !shown, reviewAnswer == nil { reviewAnswer = false } })
    }

    private var saveShown: Binding<Bool> {
        Binding(get: { model.exportToSave != nil },
                set: { shown in if !shown, model.exportToSave != nil { model.exportFinished(nil) } })
    }
}

/// What an export leaves out, before the save panel: engines that couldn't list, names BrewxPort refused and, for a
/// Brewfile, what `brew bundle` can't read. Save… goes on to the save panel.
private struct ExportReviewSheet: View {
    let pending: PendingExport
    let save: () -> Void
    let cancel: () -> Void

    private var fileWord: String { pending.kind == .brewfile ? "Brewfile" : "bundle" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Some packages won't be in this \(fileWord)")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !pending.failedEngineLines.isEmpty {
                        section("Couldn't list what's installed", pending.failedEngineLines)
                    }
                    if !pending.summary.refused.isEmpty {
                        section("Left out by BrewxPort", pending.summary.refused)
                    }
                    if !pending.leftOut.isEmpty {
                        section("Not in the Brewfile",
                                pending.leftOut.map { "\($0.displayName): \($0.reason)" })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save…", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(lines.count))").font(.subheadline).bold()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The bytes an export saves.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.brewxportBundle, .data] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private extension ImportRow {
    /// The Kind column's text, as Discover's (`PackageRow.kindName`).
    var kindName: String { id.kind.rawValue }
}
