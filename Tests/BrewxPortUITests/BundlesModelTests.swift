import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// App models for the Bundles tests. Bundle bytes are encoded from `BundleEntry` values (or, where labelled, derived
/// from such an encoding); Brewfiles are the Task 0 captures.
@MainActor enum BundleKit {
    static func app(catalog: FakeCatalog = FakeCatalog(engines: PreviewFixtures.allPresent),
                    executor: FakeRunExecutor = FakeRunExecutor(),
                    helper: FakeHelperManager? = FakeHelperManager()) -> BrewxPortAppModel {
        BrewxPortAppModel(services: AppFixtures.services(catalog: catalog, executor: executor, helper: helper))
    }

    static func data(_ entries: [BundleEntry]) throws -> Data {
        try BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: entries).encoded()
    }

    static func brewfileURL(_ name: String) -> URL {
        UIFixtures.directory.appendingPathComponent("brewfile/\(name).Brewfile")
    }

    /// Waits for `.ready` and for the rows to land in the list.
    static func ready(_ model: BrewxPortAppModel) async -> ImportPreview? {
        guard await waitUntil({ model.bundles.preview != nil }) else { return nil }
        await model.bundles.list.settled()
        return model.bundles.preview
    }

    static func isChecking(_ model: BrewxPortAppModel) -> Bool {
        if case .checking = model.bundles.state { return true }
        return false
    }

    static func checkedEngines(_ model: BrewxPortAppModel) async {
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
    }

    static func ref(_ engine: EngineID, _ kind: PackageKind, _ name: String) -> PackageRef {
        PackageRef(engine: engine, kind: kind, name: name)
    }

    static func installedCount(_ catalog: FakeCatalog) -> Int {
        catalog.queries.filter { $0 == .installed }.count
    }
}

@MainActor @Suite struct BundlesModelTests {
    typealias K = BundleKit
    typealias P = PreviewFixtures

    static let jq = BundleKit.ref(.homebrew, .formula, "jq")
    static let wget = BundleKit.ref(.homebrew, .formula, "wget")
    static let curl = BundleKit.ref(.macports, .port, "curl")
    static let xcode = BundleKit.ref(.mas, .app, "497799835")
    static let tap = BundleKit.ref(.homebrew, .tap, "felixkratz/formulae")
    static let borders = BundleKit.ref(.homebrew, .formula, "felixkratz/formulae/borders")

    // MARK: Opening

    @Test func openBundleBuildsPreview() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.macports, .port, "curl")]),
                           name: "Mac.brewxportbundle")
        let preview = try #require(await K.ready(model))
        #expect(model.bundles.state == .ready(preview, name: "Mac.brewxportbundle"))
        #expect(model.bundles.openError == nil)
        #expect(model.bundles.rowState(Self.jq) == .willInstall)
        #expect(model.bundles.rowState(Self.curl) == .willInstall)
        #expect(model.bundles.rowState(Self.wget) == nil)
        #expect(Set(model.bundles.list.all.map(\.id)) == [Self.jq, Self.curl])
        #expect(model.bundles.list.selection.checked == preview.initiallyChecked)
        #expect(model.bundles.checkedRequests.map(\.package.id) == [Self.jq, Self.curl])
        #expect(model.bundles.canInstall)
        #expect(model.bundles.summaryText == "2 to install, 0 already installed, 0 skipped")
        // Opening started the Installed load nothing had started yet.
        #expect(model.installed.reloadCount == 1)
    }

    @Test func openBrewfileBuildsPreview() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        model.bundles.open(K.brewfileURL("dump-basic"))
        let preview = try #require(await K.ready(model))
        #expect(model.bundles.state == .ready(preview, name: "dump-basic.Brewfile"))
        #expect(preview.unhandled.map(\.location) == ["line 7", "line 8", "line 9", "line 10"])
        #expect(model.bundles.rowState(Self.jq) == .willInstall)
        #expect(model.bundles.rowState(Self.tap) == .willInstall)
        // The header counts checked rows: borders (a third-party formula, now accepted) needs the tap, so the tap
        // starts checked and is counted too.
        #expect(model.bundles.list.selection.checked.contains(Self.tap))
        #expect(model.bundles.toInstallCount == model.bundles.checkedRequests.count)
        #expect(model.bundles.toInstallCount == preview.toInstallCount)
        // dump-basic has no blank or comment lines; the count is still shown, so every line is accounted for.
        #expect(model.bundles.summaryText
                == "\(model.bundles.toInstallCount) to install, 0 already installed, 4 skipped · 0 blank or comment lines")
    }

    @Test func brewfileSummaryCountsBlankAndCommentLines() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        model.bundles.open(K.brewfileURL("dump-describe"))
        let preview = try #require(await K.ready(model))
        let doc = try P.brewfile("dump-describe")
        #expect(doc.ignoredCount > 1)
        #expect(preview.brewfileLines == ImportPreview.BrewfileLines(total: doc.lineCount, ignored: doc.ignoredCount))
        #expect(model.bundles.summaryText.hasSuffix(" · \(doc.ignoredCount) blank or comment lines"))
    }

    @Test func openGarbageSetsErrorAndKeepsOldPreview() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "good.brewxportbundle")
        let preview = try #require(await K.ready(model))

        model.bundles.open(data: Data([0xFF, 0xFE, 0x00, 0x80, 0x81]), name: "junk.bin")
        #expect(model.bundles.openError == "“junk.bin” isn't a Brewfile or a BrewxPort bundle.")
        #expect(model.bundles.state == .ready(preview, name: "good.brewxportbundle"))

        model.bundles.open(data: Data("{ \"schemaVersion\": ".utf8), name: "broken.brewxportbundle")
        #expect(model.bundles.openError == "“broken.brewxportbundle” isn't a BrewxPort bundle: it isn't valid JSON.")
        model.bundles.open(data: Data(#"{"schemaVersion": 99, "createdBy": "x", "arch": "arm64", "entries": []}"#.utf8),
                           name: "new.brewxportbundle")
        #expect(model.bundles.openError?.contains("newer version of BrewxPort") == true)
        model.bundles.open(data: Data(repeating: 0x20, count: BundleFile.maxFileBytes + 1), name: "huge")
        #expect(model.bundles.openError?.contains("8 MB") == true)
        #expect(model.bundles.state == .ready(preview, name: "good.brewxportbundle"))
        #expect(model.bundles.checkedRequests.map(\.package.id) == [Self.jq])

        // A file name is shown escaped.
        model.bundles.open(data: Data([0xFF]), name: "bad\u{7}name")
        #expect(model.bundles.openError?.contains("bad\\u{7}name") == true)

        // A good file clears the error.
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "wget")]), name: "other.brewxportbundle")
        #expect(model.bundles.openError == nil)
        #expect(await waitUntil { model.bundles.rowState(Self.wget) == .willInstall })
    }

    @Test func openURLChecksTheFileFirst() async throws {
        let model = K.app()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        model.bundles.open(folder)
        #expect(await waitUntil {
            model.bundles.openError == "“\(folder.lastPathComponent)” isn't a file BrewxPort can open."
        })
        #expect(model.bundles.state == .empty)

        let big = folder.appendingPathComponent("big.brewxportbundle")
        try Data(repeating: 0x20, count: BundleFile.maxFileBytes + 1).write(to: big)
        model.bundles.open(big)
        #expect(await waitUntil { model.bundles.openError?.contains("8 MB") == true })
        #expect(model.bundles.state == .empty)

        model.bundles.open(folder.appendingPathComponent("gone.brewxportbundle"))
        #expect(await waitUntil { model.bundles.openError == "BrewxPort couldn't read “gone.brewxportbundle”." })
        #expect(model.bundles.state == .empty)

        // A FIFO is refused without blocking the open.
        let fifo = folder.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        model.bundles.open(fifo)
        #expect(await waitUntil { model.bundles.openError == "“pipe” isn't a file BrewxPort can open." })
        #expect(model.bundles.state == .empty)
    }

    @Test func symlinkedBrewfileOpens() async throws {
        // A Brewfile linked from a dotfiles folder: the link is followed to the captured file.
        let model = K.app()
        await K.checkedEngines(model)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("Brewfile")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: K.brewfileURL("dump-basic"))
        model.bundles.open(link)
        let preview = try #require(await K.ready(model))
        #expect(model.bundles.openError == nil)
        #expect(model.bundles.state.name == "Brewfile")
        #expect(preview.unhandled.count == 4)
        // A link to a folder is still refused.
        let dirLink = folder.appendingPathComponent("folder-link")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: UIFixtures.directory)
        model.bundles.open(dirLink)
        #expect(await waitUntil { model.bundles.openError == "“folder-link” isn't a file BrewxPort can open." })
        #expect(model.bundles.state.name == "Brewfile")
    }

    @Test func slowerEarlierOpenDoesNotWin() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        let slow = URL(fileURLWithPath: "/slow.brewxportbundle")
        let fast = URL(fileURLWithPath: "/fast.brewxportbundle")
        let slowData = try K.data([P.entry(.homebrew, .formula, "wget")])
        let fastData = try K.data([P.entry(.homebrew, .formula, "jq")])
        // The slow read waits at the gate until the test lets it go.
        let gate = Gate()
        model.bundles.readFile = { url in
            if url == slow {
                await gate.wait()
                return .success(slowData)
            }
            return .success(fastData)
        }
        model.bundles.open(slow)
        model.bundles.open(fast)
        _ = try #require(await K.ready(model))
        #expect(model.bundles.state.name == "fast.brewxportbundle")
        #expect(await waitUntil { gate.waiting == 1 })
        gate.release()
        #expect(await waitUntil { model.bundles.finishedOpens == 2 })
        #expect(model.bundles.state.name == "fast.brewxportbundle")
        #expect(model.bundles.rowState(Self.jq) == .willInstall)
        #expect(model.bundles.rowState(Self.wget) == nil)
        // An open from data wins over a read still going, and so does close.
        model.bundles.open(slow)
        model.bundles.open(data: fastData, name: "pasted")
        #expect(await waitUntil { gate.waiting == 1 })
        gate.release()
        #expect(await waitUntil { model.bundles.finishedOpens == 3 })
        #expect(model.bundles.state.name == "pasted")
        model.bundles.open(slow)
        model.bundles.close()
        #expect(await waitUntil { gate.waiting == 1 })
        gate.release()
        #expect(await waitUntil { model.bundles.finishedOpens == 4 })
        #expect(model.bundles.state == .empty)
    }

    @Test func engineThatAppearsWaitsForItsInstalledList() async throws {
        // nanobrew missing at first; installed afterwards with tree already on it, then "Check again".
        let catalog = FakeCatalog(engines: P.status([.nanobrew: .missing]))
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        let tree = K.ref(.nanobrew, .formula, "tree")
        model.bundles.open(data: try K.data([P.entry(.nanobrew, .formula, "tree")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.bundles.rowState(tree) == .engineMissing)
        let loads = model.installed.reloadCount

        catalog.script(.installed, .nanobrew, packages: [P.installed(.nanobrew, .formula, "tree", "2.2")],
                       delay: .milliseconds(200))
        catalog.setEngines(P.allPresent)
        var stateWhenChecked: Bool?
        model.addEnginesCheckedObserver { _ in
            stateWhenChecked = K.isChecking(model) && model.bundles.rowState(tree) == nil
        }
        model.checkEnginesAgain()
        #expect(await waitUntil { stateWhenChecked != nil })
        #expect(stateWhenChecked == true)
        #expect(model.installed.reloadCount == loads + 1)
        #expect(await waitUntil { model.bundles.rowState(tree) == .alreadyInstalled(version: "2.2") })
        #expect(model.bundles.checkedRequests.isEmpty)

        // A check that changes nothing doesn't reload.
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.checkingEngines })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.installed.reloadCount == loads + 1)
    }

    @Test func openBeforeInstalledLoadedShowsChecking() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")],
                       delay: .milliseconds(300))
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget")]),
                           name: "a.brewxportbundle")
        #expect(model.bundles.state == .checking(name: "a.brewxportbundle"))
        #expect(model.bundles.preview == nil)
        #expect(model.bundles.checkedRequests.isEmpty)
        #expect(!model.bundles.canInstall)
        #expect(model.bundles.buildCount == 0)
        #expect(model.installed.reloadCount == 1)
        #expect(await waitUntil { K.installedCount(catalog) == 1 })
        _ = try #require(await K.ready(model))
        #expect(model.bundles.rowState(Self.jq) == .alreadyInstalled(version: "1.8.1"))
        #expect(model.bundles.rowState(Self.wget) == .willInstall)
        #expect(model.bundles.checkedRequests.map(\.package.id) == [Self.wget])
    }

    @Test func openBeforeEnginesCheckedShowsChecking() async throws {
        let model = K.app()
        model.installed.reload()
        await model.installed.settled()
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a.brewxportbundle")
        #expect(K.isChecking(model))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(K.isChecking(model))
        #expect(model.bundles.buildCount == 0)
        // Installed had loaded, so opening didn't load it again.
        #expect(model.installed.reloadCount == 1)
        model.checkEnginesAgain()
        _ = try #require(await K.ready(model))
        #expect(model.bundles.rowState(Self.jq) == .willInstall)
    }

    @Test func previewBuiltOnceAllReportInEitherOrder() async throws {
        let entries = [P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget")]
        let installedJQ = [P.installed(.homebrew, .formula, "jq", "1.8.1")]

        // Engines, then Installed (held back by a delay).
        let slow = FakeCatalog(engines: P.allPresent)
        slow.script(.installed, .homebrew, packages: installedJQ, delay: .milliseconds(300))
        let first = K.app(catalog: slow)
        await K.checkedEngines(first)
        first.bundles.open(data: try K.data(entries), name: "a")
        #expect(K.isChecking(first))
        _ = try #require(await K.ready(first))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(first.bundles.buildCount == 1)
        #expect(first.bundles.rowState(Self.jq) == .alreadyInstalled(version: "1.8.1"))
        #expect(first.bundles.rowState(Self.wget) == .willInstall)

        // Installed (and its taps), then engines.
        let fast = FakeCatalog(engines: P.allPresent)
        fast.script(.installed, .homebrew, packages: installedJQ)
        let second = K.app(catalog: fast)
        second.bundles.open(data: try K.data(entries), name: "a")
        #expect(await waitUntil { second.installed.hasLoaded })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(K.isChecking(second))
        #expect(second.bundles.buildCount == 0)
        second.checkEnginesAgain()
        _ = try #require(await K.ready(second))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(second.bundles.buildCount == 1)
        #expect(second.bundles.rowState(Self.jq) == .alreadyInstalled(version: "1.8.1"))
        #expect(second.bundles.rowState(Self.wget) == .willInstall)
    }

    @Test func importedTapAlreadyPresentShowsInstalled() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.taps = .success(["FelixKratz/formulae"])
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .tap, "felixkratz/formulae"),
                                             P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.bundles.rowState(Self.tap) == .alreadyInstalled(version: nil))
        #expect(model.bundles.list.byRef[Self.tap]?.isInstalled == true)
        #expect(!model.bundles.installableRefs.contains(Self.tap))
        #expect(model.bundles.checkedRequests.map(\.package.id) == [Self.jq])
    }

    @Test func tapListFailureIsShownAndTapsCountAsAbsent() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.taps = .failure(EngineError(engine: .homebrew, message: "Homebrew didn't answer"))
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .tap, "felixkratz/formulae")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.bundles.rowState(Self.tap) == .willInstall)
        #expect(model.bundles.tapsProblem == "BrewxPort couldn't list Homebrew's taps: Homebrew didn't answer")
    }

    @Test func engineWhoseInstalledListFailedIsSkipped() async throws {
        // Without its installed list BrewxPort can't tell what's there, so it installs nothing through it.
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .macports, .init(result: .failure(EngineError(engine: .macports, message: "boom"))))
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.macports, .port, "curl"), P.entry(.homebrew, .formula, "jq")]),
                           name: "a")
        let preview = try #require(await K.ready(model))
        #expect(model.bundles.rowState(Self.curl) == .engineMissing)
        #expect(preview.missingEngines.first?.reason.contains("couldn't list what MacPorts has installed") == true)
        #expect(model.bundles.checkedRequests.map(\.package.id) == [Self.jq])
    }

    // MARK: Installing

    @Test func installCheckedOnePasswordOneRun() async throws {
        let executor = FakeRunExecutor()
        let helper = FakeHelperManager(ensure: [.enabled])
        let model = K.app(executor: executor, helper: helper)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.macports, .port, "curl"),
                                             P.entry(.mas, .app, "497799835", displayName: "Xcode")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(Set(model.bundles.checkedRequests.map(\.package.id)) == [Self.jq, Self.curl, Self.xcode])
        model.bundles.installChecked()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew, .macports, .mas])
        #expect(model.run.promptToken <= 1)
        #expect(helper.ensureCount == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
    }

    @Test func installDisabledWhileRunning() async throws {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = K.app(executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget")]),
                           name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.bundles.canInstall)
        model.bundles.installChecked()
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.bundles.canInstall)
        model.sidebar = .bundles
        #expect(!model.canPerformPrimary)
        let items = RowActions.items(for: [Self.jq], in: .bundles, rows: model.bundles.list.byRef, outdated: [],
                                     prefs: model.preferences, isRunning: model.run.isRunning, canRun: model.canRun,
                                     installable: model.bundles.installableRefs)
        #expect(items.first?.action == .install && items.first?.isEnabled == false)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        // A copy that can't run anything can't install either.
        let cannot = BrewxPortAppModel(services: AppFixtures.services(catalog: FakeCatalog(engines: P.allPresent),
                                                                      executor: nil, setupProblem: "Not signed."))
        await K.checkedEngines(cannot)
        cannot.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(cannot))
        #expect(!cannot.bundles.canInstall)
    }

    @Test func secondInstallClickDoesNothing() async throws {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let catalog = FakeCatalog(engines: P.allPresent)
        let firefox = K.ref(.nanobrew, .cask, "firefox")
        catalog.scriptInfo(K.ref(.homebrew, .cask, "firefox"),
                           .init(result: .success(PackageDetails(ref: firefox, installerNeedsRoot: false)),
                                 delay: .milliseconds(200)))
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.nanobrew, .cask, "firefox"), P.entry(.homebrew, .formula, "jq")]),
                           name: "a")
        _ = try #require(await K.ready(model))
        model.bundles.installChecked()
        #expect(model.preparing)
        #expect(!model.bundles.canInstall)
        model.bundles.installChecked()
        model.bundles.install([Self.jq])
        #expect(await waitUntil { executor.runs.count == 1 })
        model.bundles.installChecked()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(executor.runs.count == 1)
        #expect(catalog.infoCalls.count == 1)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
    }

    @Test func requestOptionsComeFromVerdict() async throws {
        // DERIVED: a bundle encoded from values. BundleEntry's init takes any options; the decoder's BundleRules
        // check is what refuses Homebrew extra arguments.
        let executor = FakeRunExecutor()
        let model = K.app(executor: executor, helper: FakeHelperManager(ensure: [.enabled]))
        await K.checkedEngines(model)
        let data = try K.data([
            P.entry(.homebrew, .formula, "wget", options: InstallOptions(extraArgs: ["--no-quarantine"])),
            P.entry(.macports, .port, "curl", options: InstallOptions(variants: ["+universal"], extraArgs: ["-s"])),
            P.entry(.homebrew, .formula, "jq"),
        ])
        model.bundles.open(data: data, name: "hostile.brewxportbundle")
        let preview = try #require(await K.ready(model))
        #expect(preview.unhandled.map(\.location) == ["entry 1"])
        #expect(preview.unhandled.first?.text.contains("--no-quarantine") == true)
        #expect(model.bundles.rowState(Self.wget) == nil)
        // Every row checked: still no request carries the token, and the port keeps only what the verdict allowed.
        model.bundles.list.selection.checked = Set(model.bundles.list.all.map(\.id))
        let requests = model.bundles.checkedRequests
        #expect(requests.map(\.package.id) == [Self.jq, Self.curl])
        #expect(!requests.contains { $0.options.extraArgs.contains("--no-quarantine") })
        #expect(requests.first { $0.package.id == Self.curl }?.options
                == InstallOptions(version: nil, variants: ["+universal"], extraArgs: ["-s"]))
        model.bundles.installChecked()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(!arguments.contains("--no-quarantine"))
        #expect(!arguments.contains("wget"))
        #expect(arguments.contains("+universal"))
    }

    @Test func bundlesPageRoutesThroughThePreview() async throws {
        // Menu, Return and the inspector all build requests from the preview: an engine-missing or installed row is
        // never requested, and nothing from Discover's path (row lookup, inspector options) is used.
        let executor = FakeRunExecutor()
        let catalog = FakeCatalog(engines: P.status([.nanobrew: .missing]))
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "wget", "1.25")])
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        let tree = K.ref(.nanobrew, .formula, "tree")
        model.bundles.open(data: try K.data([P.entry(.nanobrew, .formula, "tree"), P.entry(.homebrew, .formula, "jq"),
                                             P.entry(.homebrew, .formula, "wget"),
                                             P.entry(.mas, .app, "497799835", displayName: "Xcode")]), name: "a")
        _ = try #require(await K.ready(model))
        model.sidebar = .bundles
        #expect(model.currentView == .bundles)
        #expect(model.primaryActionTitle == "Install Selected")

        // Copy name and Show details find the file's rows.
        var copied: [String] = []
        model.writeToPasteboard = { copied.append($0) }
        model.perform(.copyName, on: [Self.xcode])
        #expect(copied == ["Xcode (497799835)"])
        model.perform(.showDetails, on: [tree])
        #expect(model.inspectorOpen)
        #expect(model.details.row?.id == tree)
        #expect(model.inspectorOptions == nil)
        model.installFromInspector()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)

        // Uninstall and Update do nothing here.
        model.perform(.uninstall, on: [Self.wget])
        #expect(model.pendingUninstall == nil)
        model.perform(.update, on: [Self.wget])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)

        // Return acts on the selected rows that can be installed.
        model.bundles.list.selection.selected = [tree, Self.wget]
        #expect(!model.canPerformPrimary)
        model.performPrimary()
        model.bundles.list.selection.selected = [tree, Self.jq, Self.wget]
        #expect(model.canPerformPrimary)
        #expect(model.canToggleChecks)
        model.performPrimary()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("jq") && !arguments.contains("wget") && !arguments.contains("tree"))
        #expect(executor.runs[0].steps.map(\.engine) == [.homebrew])

        // The inspector's Install on Bundles goes through the preview too, without the inspector's options.
        #expect(await waitUntil { model.bundles.preview != nil })
        model.perform(.showDetails, on: [Self.xcode])
        model.details.options = InstallOptionsDraft(extraArgs: "--force")
        model.installFromInspector()
        #expect(await waitUntil { executor.runs.count == 2 && !model.run.isRunning })
        #expect(executor.runs[1].steps.map(\.engine) == [.mas])
        #expect(!executor.runs[1].steps.flatMap(\.spec.arguments).contains("--force"))

        // Discover's own paths never see the file's rows.
        #expect(model.package(for: tree) == nil)
    }

    @Test func reopenReplacesPreviewAndPrunesChecks() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        let model = K.app(catalog: catalog)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.homebrew, .formula, "wget")]),
                           name: "a")
        _ = try #require(await K.ready(model))
        model.bundles.list.selection.checked = [Self.wget]

        // Another file: its own rows and its own starting checks.
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq"), P.entry(.macports, .port, "curl")]),
                           name: "b")
        #expect(await waitUntil { model.bundles.state.name == "b" && model.bundles.rowState(Self.curl) != nil })
        await model.bundles.list.settled()
        #expect(model.bundles.rowState(Self.wget) == nil)
        #expect(Set(model.bundles.list.all.map(\.id)) == [Self.jq, Self.curl])
        #expect(model.bundles.list.selection.checked == [Self.jq, Self.curl])

        // The same file rebuilt (engines checked again): the user's checks stay, minus rows that can't install now.
        model.bundles.list.selection.checked = [Self.curl]
        model.bundles.list.selection.selected = [Self.jq]
        catalog.setEngines(P.status([.macports: .missing]))
        model.checkEnginesAgain()
        #expect(await waitUntil { model.bundles.rowState(Self.curl) == .engineMissing })
        await model.bundles.list.settled()
        #expect(model.bundles.list.selection.checked.isEmpty)
        #expect(model.bundles.list.selection.selected == [Self.jq])
        #expect(!model.bundles.canInstall)
        #expect(model.bundles.summaryText == "0 to install, 0 already installed, 1 skipped")
    }

    @Test func afterRunInstalledRowsMoveToAlreadyInstalled() async throws {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .done])
        let catalog = FakeCatalog(engines: P.allPresent)
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .tap, "felixkratz/formulae"),
                                             P.entry(.homebrew, .formula, "felixkratz/formulae/borders"),
                                             P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        #expect(model.bundles.list.selection.checked == [Self.tap, Self.borders, Self.jq])
        model.bundles.list.selection.checked = [Self.tap, Self.borders]
        let builds = model.bundles.buildCount

        // What the run leaves behind, as the next listing reports it.
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "borders", "1.6")])
        catalog.taps = .success(["felixkratz/formulae"])
        model.bundles.installChecked()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(await waitUntil { model.bundles.buildCount > builds && model.bundles.preview != nil })
        await model.bundles.list.settled()
        #expect(model.bundles.rowState(Self.tap) == .alreadyInstalled(version: nil))
        #expect(model.bundles.rowState(Self.borders) == .alreadyInstalled(version: "1.6"))
        #expect(model.bundles.rowState(Self.jq) == .willInstall)
        // jq was unchecked by hand and stays unchecked; the installed rows dropped out of the checks.
        #expect(model.bundles.list.selection.checked.isEmpty)
        #expect(model.bundles.summaryText == "0 to install, 2 already installed, 0 skipped")
    }

    @Test func runEndShowsCheckingUntilTheNewListArrives() async throws {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let catalog = FakeCatalog(engines: P.allPresent)
        let model = K.app(catalog: catalog, executor: executor)
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")],
                       delay: .milliseconds(300))
        var sawChecking = false
        model.addRunEndedObserver { sawChecking = K.isChecking(model) && !model.bundles.canInstall }
        model.bundles.installChecked()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(sawChecking)
        #expect(await waitUntil { model.bundles.rowState(Self.jq) == .alreadyInstalled(version: "1.8.1") })
    }

    // MARK: Exporting

    @Test func exportListsFailedEngine() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        catalog.script(.installed, .macports, .init(result: .failure(EngineError(engine: .macports, message: "port broke"))))
        catalog.taps = .failure(EngineError(engine: .homebrew, message: "tap broke"))
        let model = K.app(catalog: catalog)

        let bundle = await model.exportBundle()
        #expect(model.sidebar == .bundles)
        #expect(bundle.summary.failedEngines == [.macports: "port broke", .homebrew: "tap broke"])
        #expect(bundle.summary.counts == [.homebrew: 1])
        let decoded = try BundleFile.decode(bundle.data)
        #expect(decoded.entries.map(\.ref) == [Self.jq])
        #expect(decoded.entries.first?.installedVersion == "1.8.1")

        let brewfile = await model.exportBrewfile()
        #expect(brewfile.text.contains(#"brew "jq""#))
        #expect(brewfile.leftOut.isEmpty)
        #expect(brewfile.summary.failedEngines == bundle.summary.failedEngines)
    }

    @Test func exportBrewfileNamesWhatItLeavesOut() async throws {
        let catalog = FakeCatalog(engines: P.allPresent)
        catalog.script(.installed, .macports, packages: [P.installed(.macports, .port, "curl", "8.0")])
        catalog.script(.installed, .homebrew, packages: [P.installed(.homebrew, .formula, "jq", "1.8.1")])
        let model = K.app(catalog: catalog)
        let brewfile = await model.exportBrewfile()
        #expect(brewfile.leftOut.map(\.ref) == [Self.curl])
        #expect(brewfile.summary.failedEngines.isEmpty)
    }

    @Test func closeClearsTheFile() async throws {
        let model = K.app()
        await K.checkedEngines(model)
        model.bundles.open(data: try K.data([P.entry(.homebrew, .formula, "jq")]), name: "a")
        _ = try #require(await K.ready(model))
        model.bundles.open(data: Data([0xFF]), name: "junk")
        model.bundles.close()
        #expect(model.bundles.state == .empty)
        #expect(model.bundles.openError == nil)
        await model.bundles.list.settled()
        #expect(model.bundles.list.all.isEmpty)
        #expect(model.bundles.checkedRequests.isEmpty)
        // A later Installed load doesn't bring it back.
        model.installed.reload()
        await model.installed.settled()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.bundles.state == .empty)
    }

    @Test func openBundleFromTheMenuShowsBundles() async throws {
        let model = K.app()
        model.openBundle(K.brewfileURL("dump-basic"))
        #expect(model.sidebar == .bundles)
        #expect(await waitUntil { model.bundles.state == .checking(name: "dump-basic.Brewfile") })
    }
}
