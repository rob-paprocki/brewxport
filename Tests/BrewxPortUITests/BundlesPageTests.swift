import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// What the Bundles page reads from the models: the row menu, the "Opening…" state, nothing stale while the preview
/// is checking, the snapshot script, and the export review before a save panel.
@MainActor @Suite struct BundlesPageTests {
    typealias K = BundleKit
    typealias P = PreviewFixtures

    static let jq = BundleKit.ref(.homebrew, .formula, "jq")
    static let wget = BundleKit.ref(.homebrew, .formula, "wget")
    static let tree = BundleKit.ref(.nanobrew, .formula, "tree")
    static let curl = BundleKit.ref(.macports, .port, "curl")

    /// jq will install, wget is installed, nanobrew's tree is skipped (nanobrew missing).
    private func openMixed(executor: FakeRunExecutor = FakeRunExecutor()) async throws -> BrewxPortAppModel {
        let catalog = FakeCatalog(engines: P.status([.nanobrew: .missing]))
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "wget", "1.25")])
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget"),
                                             P.entry(.nanobrew, .formula, "tree")]), name: "a")
        _ = try #require(await K.ready(model))
        model.sidebar = .bundles
        return model
    }

    // MARK: Row menu

    @Test func rowMenuOffersInstallOnlyForInstallableRows() async throws {
        let model = try await openMixed()
        let install = model.rowMenuItems(for: [Self.jq], in: .bundles).first { $0.action == .install }
        #expect(install?.isEnabled == true)
        #expect(model.rowMenuItems(for: [Self.wget], in: .bundles).map(\.action) == [.showDetails, .copyName])
        #expect(model.rowMenuItems(for: [Self.tree], in: .bundles).map(\.action) == [.showDetails, .copyName])
        // Several rows: Install shows when one of them can be installed.
        #expect(model.rowMenuItems(for: [Self.jq, Self.wget], in: .bundles).map(\.action) == [.install, .copyName])
        // A ref that isn't a row of the file gets no menu.
        #expect(model.rowMenuItems(for: [Self.curl], in: .bundles).isEmpty)
    }

    @Test func rowMenuInstallStartsARunForThatRow() async throws {
        let executor = FakeRunExecutor()
        let model = try await openMixed(executor: executor)
        model.bundles.list.selection.checked = []
        let install = try #require(model.rowMenuItems(for: [Self.jq, Self.wget], in: .bundles)
            .first { $0.action == .install })
        model.perform(install.action, on: [Self.jq, Self.wget])
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("jq") && !arguments.contains("wget"))
    }

    @Test func otherPagesKeepTheirMenus() async throws {
        let model = try await openMixed()
        // Discover's list doesn't hold the file's rows, so nothing there acts on them.
        #expect(model.rowMenuItems(for: [Self.jq], in: .discover).isEmpty)
        await model.installed.settled()
        #expect(model.rowMenuItems(for: [Self.wget], in: .installed).map(\.action) ==
                    [.uninstall, .moveTo(.macports), .showDetails, .copyName])
    }

    // MARK: Opening

    @Test func openingIsShownUntilTheReadLands() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        let gate = ReadGate()
        let data = try K.data([P.entry(.homebrew, .formula, "jq")])
        model.bundles.readFile = { _ in
            await gate.wait()
            return .success(data)
        }
        #expect(!model.bundles.isOpening)
        model.bundles.open(URL(fileURLWithPath: "/held.brewxportbundle"))
        #expect(model.bundles.isOpening)
        gate.open()
        _ = try #require(await K.ready(model))
        #expect(!model.bundles.isOpening)

        // A failed read clears it too.
        model.bundles.readFile = { _ in .failure(.unreadable) }
        model.bundles.open(URL(fileURLWithPath: "/broken"))
        #expect(model.bundles.isOpening)
        #expect(await waitUntil { model.bundles.openError != nil })
        #expect(!model.bundles.isOpening)

        // So do an open from data and close, which drop a read still going.
        let gate2 = ReadGate()
        model.bundles.readFile = { _ in
            await gate2.wait()
            return .success(data)
        }
        model.bundles.open(URL(fileURLWithPath: "/held2"))
        model.bundles.close()
        #expect(!model.bundles.isOpening)
        model.bundles.open(URL(fileURLWithPath: "/held3"))
        model.bundles.open(data: data, name: "b")
        #expect(!model.bundles.isOpening)
        gate2.open()
    }

    // MARK: Nothing stale while checking

    @Test func checkingHidesTheRowsFromKeysMenusAndTheInspector() async throws {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let catalog = FakeCatalog(engines: P.allPresent)
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget")]),
                           name: "a")
        _ = try #require(await K.ready(model))
        model.sidebar = .bundles
        model.bundles.list.selection.selected = [Self.jq]
        model.toggleInspector()
        #expect(model.details.row?.id == Self.jq)
        #expect(model.details.row?.isInstalled == false)
        #expect(model.canInstallFromInspector)

        // The run installs jq; the Installed list after it is held back, so the page is checking for a while.
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")],
                       delay: .milliseconds(300))
        var during: (row: PackageRef?, items: Int, toggle: Bool, primary: Bool, details: PackageRef?)?
        model.addRunEndedObserver {
            let row = model.details.row?.id
            // Show details on a row while checking shows nothing.
            model.perform(.showDetails, on: [Self.jq])
            during = (row, model.rowMenuItems(for: [Self.jq], in: .bundles).count,
                      model.canToggleChecks, model.canPerformPrimary, model.details.row?.id)
        }
        model.bundles.installChecked()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(during?.row == nil)
        #expect(during?.items == 0)
        #expect(during?.toggle == false)
        #expect(during?.primary == false)
        #expect(during != nil && during?.details == nil)

        // Once the new list is in, the inspector follows the selection again with the fresh row.
        #expect(await waitUntil { model.bundles.rowState(Self.jq) == .alreadyInstalled(version: "1.8.1") })
        #expect(model.details.row?.id == Self.jq)
        #expect(model.details.row?.isInstalled == true)
        #expect(!model.canInstallFromInspector)
    }

    @Test func inspectorInstallOffForRowsThatCantInstall() async throws {
        let model = try await openMixed()
        model.perform(.showDetails, on: [Self.tree])
        #expect(model.details.row?.id == Self.tree)
        #expect(!model.canInstallFromInspector)
        model.perform(.showDetails, on: [Self.jq])
        #expect(model.canInstallFromInspector)
    }

    // MARK: Snapshot

    @Test func prepareSnapshotStopsWhenTheOpenFailed() async throws {
        let model = K.app()
        model.bundles.open(data: Data([0xFF, 0xFE, 0x00]), name: "junk")
        #expect(model.bundles.openError != nil)
        let clock = ContinuousClock()
        let took = await clock.measure { await model.prepareSnapshot(.bundles) }
        #expect(took < .seconds(1))
        #expect(model.sidebar == .bundles)
    }

    @Test func prepareSnapshotStopsWhenNothingOpens() async throws {
        // Not demo services: there's no sample to open, so nothing to wait for.
        let model = K.app()
        let clock = ContinuousClock()
        let took = await clock.measure { await model.prepareSnapshot(.bundles) }
        #expect(took < .seconds(1))
        #expect(model.bundles.state == .empty)
    }

    // MARK: Exports

    @Test func brewfileExportIsReviewedBeforeTheSavePanel() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .macports, packages: [P.installed(.macports, .port, "curl", "8.0")])
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        let model = K.app(catalog: catalog)
        await model.export(.brewfile)
        #expect(model.sidebar == .bundles)
        let review = try #require(model.exportReview)
        #expect(model.exportToSave == nil)
        #expect(review.kind == .brewfile)
        #expect(review.leftOut.map(\.ref) == [Self.curl])
        #expect(review.defaultName == "Brewfile")
        #expect(String(decoding: review.data, as: UTF8.self).contains(#"brew "jq""#))
        model.confirmExport()
        #expect(model.exportReview == nil)
        #expect(model.exportToSave == review)
        model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Brewfile")))
        #expect(model.exportToSave == nil)
        #expect(model.exportMessage == nil)
        // jq was written; curl, which `brew bundle` can't read, wasn't.
        #expect(review.savedCount == 1)
        #expect(model.exportSaved == "Saved 1 entry to “Brewfile”.")
        // The next open clears it.
        model.closeBundle()
        #expect(model.exportSaved == nil)
    }

    @Test func savedBundleCountsEveryEntry() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .macports, packages: [P.installed(.macports, .port, "curl", "8.0")])
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        catalog.taps = .success(["felixkratz/formulae"])
        let model = K.app(catalog: catalog)
        await model.export(.bundle)
        let pending = try #require(model.exportToSave)
        #expect(pending.savedCount == 3)
        model.exportFinished(nil)
        #expect(model.exportSaved == nil)
        await model.export(.bundle)
        model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Mac.brewxportbundle")))
        #expect(model.exportSaved == "Saved 3 entries to “Mac.brewxportbundle”.")
    }

    // Seen in the macOS 27 VM (2026-11-21): when the save panel closes after a save, SwiftUI first sets
    // `isPresented` to false (the view's binding calls `exportFinished(nil)`), and only then calls the completion
    // with `.success`. The message still has to count what was saved.
    @Test func savedMessageSurvivesThePanelClosingFirst() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1"),
                                                         P.installed(.homebrew, .formula, "wget", "1.25")])
        let model = K.app(catalog: catalog)
        await model.export(.bundle)
        model.exportFinished(nil)
        model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Mac.brewxportbundle")))
        #expect(model.exportSaved == "Saved 2 entries to “Mac.brewxportbundle”.")
        // A cancel (the binding's nil with no completion after it) still saves nothing and says nothing.
        await model.export(.bundle)
        model.exportFinished(nil)
        #expect(model.exportSaved == nil)
    }

    // MARK: Include Dependencies in Exports

    private static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String, _ onRequest: Bool?)
        -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1",
                installedOnRequest: onRequest)
    }

    @Test func exportWithoutDependenciesLeavesThemOutAndSaysSo() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [Self.package(.homebrew, .formula, "jq", true),
                                                         Self.package(.homebrew, .formula, "oniguruma", false)])
        catalog.script(.installed, .nanobrew, packages: [Self.package(.nanobrew, .formula, "tree", nil)])
        let model = K.app(catalog: catalog)
        #expect(model.exportIncludesDependencies)
        model.exportIncludesDependencies = false
        await model.export(.bundle)
        // A dropped dependency isn't something left out by mistake: straight to the save panel.
        #expect(model.exportReview == nil)
        let pending = try #require(model.exportToSave)
        let bundle = try BundleFile.decode(pending.data)
        #expect(bundle.entries.map(\.name) == ["jq", "tree"])
        #expect(pending.savedCount == 2)
        model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Mac.brewxportbundle")))
        #expect(model.exportSaved == "Saved 2 entries to “Mac.brewxportbundle”. It leaves out 1 dependency. "
            + "BrewxPort couldn't tell which nanobrew packages are dependencies, so it kept them.")
    }

    @Test func exportWithDependenciesIsUnchanged() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [Self.package(.homebrew, .formula, "jq", true),
                                                         Self.package(.homebrew, .formula, "oniguruma", false)])
        let model = K.app(catalog: catalog)
        await model.export(.bundle)
        let pending = try #require(model.exportToSave)
        #expect(try BundleFile.decode(pending.data).entries.map(\.name) == ["jq", "oniguruma"])
        model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Mac.brewxportbundle")))
        #expect(model.exportSaved == "Saved 2 entries to “Mac.brewxportbundle”.")
    }

    @Test func includeDependenciesIsRemembered() {
        let services = AppFixtures.services(catalog: FakeCatalog(engines: P.allPresent))
        let first = BrewxPortAppModel(services: services)
        first.exportIncludesDependencies = false
        #expect(BrewxPortAppModel(services: services).exportIncludesDependencies == false)
        first.exportIncludesDependencies = true
        #expect(BrewxPortAppModel(services: services).exportIncludesDependencies)
    }

    @Test func dependenciesNoteNamesSeveralEngines() {
        let summary = ExportSummary(counts: [:], failedEngines: [:], refused: [], dependenciesLeftOut: 3,
                                    dependenciesUnknown: [.nanobrew, .macports])
        #expect(BrewxPortAppModel.dependenciesNote(summary) == "It leaves out 3 dependencies. BrewxPort couldn't "
            + "tell which nanobrew and MacPorts packages are dependencies, so it kept them.")
        #expect(BrewxPortAppModel.dependenciesNote(ExportSummary(counts: [:], failedEngines: [:], refused: [])) == nil)
    }

    @Test func noOpenPanelWhileAnExportIsGathered() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        let gate = Gate()
        catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([]), gate: gate))
        let model = K.app(catalog: catalog)
        let export = Task { await model.export(.bundle) }
        #expect(await waitUntil { gate.waiting == 1 })
        #expect(!model.canOpenFile)
        model.showOpenPanel()
        #expect(!model.showingOpenPanel)
        gate.release()
        await export.value
        #expect(model.exportToSave != nil)
        model.exportFinished(nil)
        #expect(model.canOpenFile)
    }

    @Test func cleanBundleExportGoesStraightToTheSavePanel() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        let model = K.app(catalog: catalog)
        await model.export(.bundle)
        #expect(model.exportReview == nil)
        let save = try #require(model.exportToSave)
        #expect(save.kind == .bundle)
        #expect(try BundleFile.decode(save.data).entries.map(\.ref) == [Self.jq])
        #expect(!save.defaultName.isEmpty)
    }

    @Test func failedEnginesAreReviewedAndCancelClears() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        catalog.script(.installed, .macports, .init(result: .failure(EngineError(engine: .macports, message: "port broke"))))
        let model = K.app(catalog: catalog)
        await model.export(.bundle)
        let review = try #require(model.exportReview)
        #expect(review.summary.failedEngines == [.macports: "port broke"])
        model.cancelExport()
        #expect(model.exportReview == nil)
        #expect(model.exportToSave == nil)

        // A save that fails says so.
        await model.export(.bundle)
        model.confirmExport()
        model.exportFinished(.failure(CocoaError(.fileWriteNoPermission)))
        #expect(model.exportToSave == nil)
        #expect(model.exportMessage?.hasPrefix("BrewxPort couldn't save the file") == true)
    }

    @Test func exportMessageClearsOnOpenAndClose() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        await model.export(.bundle)
        model.confirmExport()
        model.exportFinished(.failure(CocoaError(.fileWriteNoPermission)))
        #expect(model.exportMessage != nil)
        model.closeBundle()
        #expect(model.exportMessage == nil)
        await model.export(.bundle)
        model.confirmExport()
        model.exportFinished(.failure(CocoaError(.fileWriteNoPermission)))
        model.openBundle(K.brewfileURL("dump-basic"))
        #expect(model.exportMessage == nil)
    }

    // MARK: Modals

    /// A Bundles page with a preview and an export review sheet up.
    private func reviewUp() async throws -> BrewxPortAppModel {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .macports, packages: [P.installed(.macports, .port, "curl", "8.0")])
        let model = K.app(catalog: catalog)
        model.start()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        model.sidebar = .bundles
        model.bundles.list.selection.selected = [Self.jq]
        #expect(model.canPerformPrimary)
        await model.export(.brewfile)
        _ = try #require(model.exportReview)
        return model
    }

    @Test func nothingStartsBehindTheExportReview() async throws {
        let model = try await reviewUp()
        #expect(model.modalUp)
        #expect(!model.canPerformPrimary)
        #expect(!model.canToggleChecks)
        #expect(!model.canExport)
        #expect(!model.bundles.canInstall)
        model.performPrimary()
        model.bundles.installChecked()
        model.perform(.install, on: [Self.jq])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!model.run.isRunning && model.run.steps.isEmpty)
        // Open Bundle and a second export do nothing either.
        model.showOpenPanel()
        #expect(!model.showingOpenPanel)
        let review = model.exportReview
        await model.export(.bundle)
        #expect(model.exportReview == review && model.exportToSave == nil)
        model.toggleChecks()
        #expect(model.bundles.list.selection.checked == [Self.jq])
        // The save panel counts too.
        model.confirmExport()
        #expect(model.modalUp && !model.canPerformPrimary)
        model.exportFinished(nil)
        #expect(!model.modalUp && model.canPerformPrimary)
    }

    @Test func removeSelectionOffBehindTheOpenPanel() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "wget", "1.25")])
        let model = K.app(catalog: catalog)
        model.start()
        await model.installed.settled()
        model.sidebar = .installed
        model.installed.list.selection.selected = [Self.wget]
        #expect(model.canRemoveSelection)
        model.showOpenPanel()
        #expect(model.showingOpenPanel)
        #expect(!model.canRemoveSelection)
        model.sidebar = .installed
        model.removeSelection()
        #expect(model.uninstall.state == .hidden)
    }

    @Test func finderOpenWaitsForTheRemoveConfirmation() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "wget", "1.25")])
        let model = K.app(catalog: catalog)
        model.start()
        await model.installed.settled()
        model.sidebar = .installed
        model.perform(.uninstall, on: [Self.wget])
        #expect(model.confirmingRemoval)
        let url = K.brewfileURL("dump-basic")
        model.openFromFinder(url)
        #expect(model.sidebar == .installed)
        #expect(model.bundles.state == .empty)
        #expect(model.pendingOpenURL == url)
        model.uninstall.cancel()
        #expect(model.pendingOpenURL == nil)
        #expect(model.sidebar == .bundles)
        #expect(await waitUntil { model.bundles.state.name == "dump-basic.Brewfile" })
    }

    @Test func finderOpenWaitsForThePasswordSheet() async throws {
        let model = K.app()
        model.start()
        model.run.showingPasswordSheet = true
        model.openFromFinder(K.brewfileURL("dump-basic"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.bundles.state == .empty)
        #expect(model.sidebar != .bundles)
        model.run.showingPasswordSheet = false
        #expect(model.sidebar == .bundles)
        #expect(await waitUntil { model.bundles.state.name == "dump-basic.Brewfile" })
    }

    @Test func finderOpenAtLaunchWaitsForStart() async throws {
        // A cold launch with a file: the open arrives before the window has started.
        let model = K.app()
        model.openFromFinder(K.brewfileURL("dump-basic"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.bundles.state == .empty)
        #expect(model.pendingOpenURL != nil)
        model.start()
        #expect(model.pendingOpenURL == nil)
        #expect(model.sidebar == .bundles)
        let preview = try #require(await K.ready(model))
        #expect(preview.unhandled.count == 4)
    }

    @Test func noPanelsWhileARunIsGoing() async throws {
        // A run that hangs after starting: its password sheet could come up at any moment.
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = K.app(executor: executor)
        model.start()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.canOpenFile && model.canExport)
        model.bundles.installChecked()
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.canOpenFile)
        #expect(!model.canExport)
        model.showOpenPanel()
        #expect(!model.showingOpenPanel)
        await model.export(.bundle)
        #expect(model.exportReview == nil && model.exportToSave == nil)
        // The password sheet itself, while the run is going.
        let answer = Task { await model.run.askForPassword(reason: "test") }
        #expect(await waitUntil { model.run.showingPasswordSheet })
        #expect(!model.canOpenFile && !model.canExport)
        model.run.finishPassword(nil)
        _ = await answer.value
        executor.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        #expect(model.canOpenFile && model.canExport)
    }

    @Test func exportGatheredDuringARunStartIsDropped() async throws {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let catalog = FakeCatalog(engines: P.allPresent)
        let model = K.app(catalog: catalog, executor: executor)
        model.start()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        // The export's Homebrew list is held until the run has started.
        let gate = Gate()
        catalog.script(.installed, .homebrew,
                       FakeCatalog.Script(result: .success([P.installed(.homebrew, .formula, "wget", "1.25")]),
                                          gate: gate))
        let export = Task { await model.export(.bundle) }
        #expect(await waitUntil { gate.waiting == 1 })
        #expect(model.exporting)
        model.bundles.installChecked()
        #expect(await waitUntil { model.run.isRunning })
        gate.release()
        await export.value
        #expect(model.exportReview == nil && model.exportToSave == nil)
        #expect(model.exportMessage?.contains("a run started") == true)
        executor.cancel()
    }

    @Test func pickedFileWinsOverAHeldFinderFile() async throws {
        let model = K.app()
        model.start()
        // Hold a Finder file behind the open panel, then pick another file in the panel.
        model.showOpenPanel()
        model.openFromFinder(K.brewfileURL("dump-describe"))
        #expect(model.pendingOpenURL != nil)
        model.openPicked(K.brewfileURL("dump-basic"))
        model.showingOpenPanel = false
        #expect(model.pendingOpenURL == nil)
        #expect(await waitUntil { model.bundles.state.name == "dump-basic.Brewfile" })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.bundles.state.name == "dump-basic.Brewfile")
    }

    @Test func openPanelRequestShowsBundles() {
        let model = K.app()
        model.showOpenPanel()
        #expect(model.sidebar == .bundles)
        #expect(model.showingOpenPanel)
    }
}

/// Holds a test's `readFile` until `open()`.
final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }
}
