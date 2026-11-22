import Testing
import Foundation
import AppKit
import Observation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Services for the app-model tests: fake engines, catalog, executor and helper.
@MainActor enum AppFixtures {
    static let path = "/opt/homebrew/bin/brew"

    struct NoPath: PathResolving {
        func resolve() async -> ResolvedPath { ResolvedPath(entries: ["/usr/bin", "/bin"], source: .systemDefault) }
    }

    static func services(catalog: FakeCatalog = FakeCatalog(), executor: FakeRunExecutor? = FakeRunExecutor(),
                         helper: FakeHelperManager? = nil, isDemo: Bool = false, host: Arch = .arm64,
                         setupProblem: String? = nil, isAdministrator: Bool? = true,
                         hostInfo: HostInfo = HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: Bool = true,
                         receipts: any InstallerReceiptReading = NoReceipts(),
                         store: MemoryStore = MemoryStore(),
                         engines: [any Engine] = PlanFixtures.engines, path: any PathResolving = NoPath(),
                         shellPath: ShellPathEditor? = nil) -> Services {
        // The model loads Installed and Updates on its own; a test that doesn't script them gets empty lists.
        catalog.scriptEmpty(.installed)
        catalog.scriptEmpty(.outdated)
        return Services(engines: engines, catalog: catalog, executor: executor, helper: helper,
                 passwords: PromptPasswordProvider(), isAdministrator: { isAdministrator }, store: store,
                 path: path, fileExists: { _ in true }, host: host, hostInfo: hostInfo,
                 cltPresent: { cltPresent }, receipts: receipts, setupProblem: setupProblem, isDemo: isDemo,
                 shellPath: shellPath)
    }

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String,
                        installed: String? = nil) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                installedVersion: installed, latestVersion: "2")
    }

    /// A list holding `packages` (all from Homebrew's answer), registered as the model's lookup source.
    static func source(_ packages: [Package], in model: BrewxPortAppModel) async -> PackageListState {
        let list = PackageListState(order: model.engineOrder, archFor: { _ in .arm64 })
        let byEngine = Dictionary(grouping: packages, by: \.id.engine)
        list.load {
            AsyncStream { continuation in
                for (engine, found) in byEngine { continuation.yield(EngineOutcome(engine: engine, result: .success(found))) }
                continuation.finish()
            }
        }
        _ = await waitUntil { !list.loading }
        model.packageSources.append(list)
        return list
    }

    static let wget = PackageRef(engine: .homebrew, kind: .formula, name: "wget")
    static let jq = PackageRef(engine: .homebrew, kind: .formula, name: "jq")
    static let firefox = PackageRef(engine: .nanobrew, kind: .cask, name: "firefox")
    static let curl = PackageRef(engine: .macports, kind: .port, name: "curl")
}

@MainActor @Suite struct BrewxPortAppModelTests {
    typealias F = AppFixtures

    @Test func startsOnUpdatesAndRoutesPromptsToTheRun() {
        let services = F.services()
        let model = BrewxPortAppModel(services: services)
        #expect(model.sidebar == .updates)
        #expect(services.passwords.prompter === model.run)
    }

    @Test func sidebarEnginesFollowHostOrder() {
        #expect(BrewxPortAppModel(services: F.services(host: .arm64)).engineOrder == [.nanobrew, .homebrew, .macports, .mas])
        #expect(BrewxPortAppModel(services: F.services(host: .x86_64)).engineOrder.first == .macports)
        #expect(BrewxPortAppModel(services: F.services(host: .x86_64)).engineOrder == [.macports, .homebrew, .nanobrew, .mas])
    }

    @Test func engineRowTextForEachStatus() {
        let url = URL(fileURLWithPath: F.path)
        #expect(EngineRowText.subtitle(.present(path: url, version: "7.0.13")) == "7.0.13")
        #expect(EngineRowText.subtitle(.missing) == "Not installed")
        #expect(EngineRowText.subtitle(.unusable(path: url, reason: "x")) == "Not working")
        #expect(EngineRowText.subtitle(nil) == "Checking…")
        #expect(EngineRowText.statusSymbol(.present(path: url, version: "1")) == "checkmark.circle.fill")
        #expect(EngineRowText.statusSymbol(.missing) == "minus.circle")
        #expect(EngineRowText.statusSymbol(.unusable(path: url, reason: "x")) == "exclamationmark.triangle.fill")
        #expect(EngineRowText.statusSymbol(nil) == "ellipsis.circle")
        #expect([EngineID.homebrew, .nanobrew, .macports, .mas].map(EngineRowText.symbol)
                == ["mug.fill", "hare.fill", "shippingbox.fill", "bag.fill"])
    }

    @Test func startDetectsEnginesAndEnsuresTheHelperOnce() async {
        let catalog = FakeCatalog(engines: [.homebrew: .missing])
        let helper = FakeHelperManager(ensure: [.requiresApproval])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, helper: helper))
        model.start()
        model.start()
        #expect(await waitUntil { model.helperState == .requiresApproval && !model.engineStatuses.isEmpty })
        #expect(model.engineStatuses[.homebrew] == .missing)
        #expect(helper.ensureCount == 1)
        #expect(helper.refreshCount == 0)
        #expect(!model.checkingHelper)
    }

    @Test func standardAccountOnlyReadsTheHelperAtLaunch() async {
        // Registering needs an administrator; a standard account's runs never use the helper.
        let catalog = FakeCatalog(engines: [.homebrew: .missing])
        let helper = FakeHelperManager(refresh: [.notRegistered])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, helper: helper, isAdministrator: false))
        model.start()
        #expect(await waitUntil { model.helperState == .notRegistered && !model.engineStatuses.isEmpty })
        #expect(helper.ensureCount == 0)
        #expect(helper.refreshCount == 1)
        // Unknown membership (nil) still registers, as before.
        let unknown = FakeHelperManager(ensure: [.enabled])
        let other = BrewxPortAppModel(services: F.services(catalog: FakeCatalog(engines: [.homebrew: .missing]),
                                                        helper: unknown, isAdministrator: nil))
        other.start()
        #expect(await waitUntil { other.helperState == .enabled })
        #expect(unknown.ensureCount == 1)
    }

    @Test func changesDoNothingWhenThisCopyCannotRun() async {
        let model = BrewxPortAppModel(services: F.services(executor: nil, setupProblem: "Not signed."))
        _ = await F.source([F.package(.homebrew, .formula, "wget", installed: "1")], in: model)
        let wget = PackageRef(engine: .homebrew, kind: .formula, name: "wget")
        for action in [RowAction.install, .update, .uninstall] {
            model.perform(action, on: [wget])
        }
        #expect(model.pendingUninstall == nil)
        #expect(!model.preparing)
        #expect(!model.run.isRunning)
        #expect(!model.run.panelVisible)
        // Ignore still works.
        model.perform(.ignore, on: [wget])
        #expect(model.preferences.isIgnored(wget))
    }

    @Test func hideDetailsWorksOnEveryPage() {
        let model = BrewxPortAppModel(services: F.services())
        model.sidebar = .discover
        #expect(model.canToggleInspector)
        model.toggleInspector()
        model.sidebar = .engine(.homebrew)
        #expect(model.inspectorOpen)
        #expect(model.canToggleInspector)
        model.toggleInspector()
        #expect(!model.inspectorOpen)
        #expect(!model.canToggleInspector)
    }

    @Test func helperNotAskedWhenServicesHaveNone() async {
        let catalog = FakeCatalog(engines: [.homebrew: .missing])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, helper: nil, isDemo: true))
        model.start()
        #expect(await waitUntil { !model.engineStatuses.isEmpty })
        #expect(model.helperState == nil)
        #expect(!model.checkingHelper)
        model.checkHelper()
        model.reinstallHelper()
        model.openLoginItems()
        #expect(model.helperState == nil)
    }

    @Test func checkAgainUsesRefresh() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let model = BrewxPortAppModel(services: F.services(helper: helper))
        model.checkHelper()
        #expect(await waitUntil { model.helperState == .requiresApproval && !model.checkingHelper })
        #expect(helper.refreshCount == 1)
        #expect(helper.ensureCount == 0)
        #expect(helper.reinstallCount == 0)
    }

    @Test func uninstallAsksBeforeRunning() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget", installed: "1"),
                            F.package(.homebrew, .formula, "jq", installed: "1")], in: model)

        model.perform(.uninstall, on: [F.wget, F.jq])
        #expect(model.pendingUninstall == [F.wget, F.jq])
        #expect(model.uninstallTitle == "Remove jq (Homebrew) and wget (Homebrew)?")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        #expect(!model.run.isRunning)

        model.cancelUninstall()
        #expect(model.pendingUninstall == nil)
        #expect(executor.runs.isEmpty)

        model.perform(.uninstall, on: [F.wget])
        #expect(model.uninstallTitle == "Remove wget (Homebrew)?")
        model.confirmUninstall()
        #expect(model.pendingUninstall == nil)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.operation) == [.remove])
        #expect(executor.runs[0].steps[0].spec.arguments.contains("wget"))
    }

    @Test func performWhileRunningDoesNothing() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let catalog = FakeCatalog()
        catalog.scriptInfo(F.firefox, .init(result: .success(PackageDetails(ref: F.firefox, installerNeedsRoot: false))))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget"), F.package(.homebrew, .formula, "jq", installed: "1"),
                            F.package(.nanobrew, .cask, "firefox")], in: model)

        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning && executor.runs.count == 1 })

        model.perform(.uninstall, on: [F.jq])
        #expect(model.pendingUninstall == nil)
        model.perform(.install, on: [F.firefox])
        #expect(!model.preparing)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(catalog.infoCalls.isEmpty)
        #expect(executor.runs.count == 1)

        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
    }

    @Test func performWhilePreparingDoesNothing() async {
        let executor = FakeRunExecutor()
        let catalog = FakeCatalog()
        catalog.scriptInfo(F.firefox, .init(result: .success(PackageDetails(ref: F.firefox, installerNeedsRoot: false)),
                                            delay: .milliseconds(300)))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget"), F.package(.nanobrew, .cask, "firefox")], in: model)

        model.perform(.install, on: [F.firefox])
        #expect(model.preparing)
        model.perform(.install, on: [F.wget])
        model.perform(.install, on: [F.firefox])
        #expect(await waitUntil { !model.preparing && executor.runs.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(catalog.infoCalls == [F.firefox])
        #expect(executor.runs[0].steps.map(\.engine) == [.nanobrew])
    }

    @Test func nbCaskInstallAsksHomebrewWhenItIsThere() async {
        let executor = FakeRunExecutor()
        let brewFirefox = PackageRef(engine: .homebrew, kind: .cask, name: "firefox")
        let catalog = FakeCatalog(engines: [.homebrew: .present(path: URL(fileURLWithPath: F.path), version: "5")])
        catalog.scriptInfo(brewFirefox, .init(result: .success(PackageDetails(ref: brewFirefox, installerNeedsRoot: true))))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.checkEnginesAgain()
        #expect(await waitUntil { !model.engineStatuses.isEmpty })
        _ = await F.source([F.package(.nanobrew, .cask, "firefox")], in: model)

        model.perform(.install, on: [F.firefox])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(catalog.infoCalls == [brewFirefox])
        #expect(executor.runs[0].steps.map(\.engine) == [.homebrew])
    }

    @Test func installSkipsRowsAlreadyInstalled() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget"), F.package(.homebrew, .formula, "jq", installed: "1")],
                           in: model)
        model.perform(.install, on: [F.wget, F.jq])
        #expect(await waitUntil { executor.runs.count == 1 })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("wget"))
        #expect(!arguments.contains("jq"))
    }

    @Test func missingHelperOutsideDemoExplainsWhy() async {
        let executor = FakeRunExecutor()
        let problem = "This copy of BrewxPort isn't signed by a developer team, so it can't install updates."
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: nil, setupProblem: problem))
        _ = await F.source([F.package(.macports, .port, "curl")], in: model)
        model.perform(.install, on: [F.curl])
        #expect(await waitUntil { !model.run.isRunning && model.run.log.lines.contains { $0.text.contains(problem) } })
        #expect(executor.runs.isEmpty)
    }

    @Test func demoRunsTreatTheHelperAsReady() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: nil, isDemo: true))
        _ = await F.source([F.package(.macports, .port, "curl")], in: model)
        model.perform(.install, on: [F.curl])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.engine) == [.macports])
    }

    @Test func runEnsuresTheHelperAndShowsItsState() async {
        let executor = FakeRunExecutor()
        let helper = FakeHelperManager(ensure: [.enabled])
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: helper))
        _ = await F.source([F.package(.macports, .port, "curl")], in: model)
        model.perform(.install, on: [F.curl])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(helper.ensureCount == 1)
        #expect(model.helperState == .enabled)
    }

    @Test func helperButtonsDoNothingDuringARun() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let helper = FakeHelperManager()
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: helper))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        model.checkHelper()
        model.reinstallHelper()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(helper.refreshCount == 0)
        #expect(helper.reinstallCount == 0)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
    }

    @Test func reinstallRefusedWhileStartupEnsureIsInFlight() async {
        let helper = FakeHelperManager(ensure: [.requiresApproval])
        helper.holdEnsure = true
        let model = BrewxPortAppModel(services: F.services(helper: helper))
        model.start()
        #expect(await waitUntil { model.checkingHelper && helper.ensureCount == 1 })
        model.reinstallHelper()
        model.checkHelper()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(helper.reinstallCount == 0)
        #expect(helper.refreshCount == 0)
        helper.releaseEnsure()
        #expect(await waitUntil { !model.checkingHelper && model.helperState == .requiresApproval })
        #expect(helper.reinstallCount == 0)
        #expect(helper.ensureCount == 1)
    }

    @Test func closingTheWindowDuringARunDoesNotQuit() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let helper = FakeHelperManager()
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: helper))
        #expect(model.quitsWhenLastWindowCloses)
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.quitsWhenLastWindowCloses)
        // Open Login Items is refused during a run too.
        model.openLoginItems()
        #expect(helper.openCount == 0)
        var ended = 0
        model.addRunEndedObserver { ended += 1 }
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        #expect(model.quitsWhenLastWindowCloses)
        // The app hears that the run ended, so it can bring back a window closed during the run.
        #expect(await waitUntil { ended == 1 })
        model.openLoginItems()
        #expect(helper.openCount == 1)
    }

    @Test func setupRunRechecksEngines() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 1), .done])
        let model = BrewxPortAppModel(services: F.services(
            executor: executor, helper: FakeHelperManager(),
            hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true))
        var checks = 0
        model.addEnginesCheckedObserver { _ in checks += 1 }
        #expect(model.canSetUpEngines)
        model.setUpEngine(.homebrew)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.setupTarget) == [SetupTarget.homebrew])
        // Even a failed setup ends with a fresh engine check.
        #expect(await waitUntil { checks == 1 })
        // An ordinary run doesn't recheck.
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { executor.runs.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(checks == 1)
    }

    @Test func setupThatNeverStartsDoesNotRecheckAfterALaterRun() async {
        // A standard account: the setup's helper step is dropped up front, so no run starts.
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(
            executor: executor, helper: FakeHelperManager(), isAdministrator: false,
            hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true))
        var checks = 0
        model.addEnginesCheckedObserver { _ in checks += 1 }
        #expect(model.setUpEngine(.homebrew) == false)
        #expect(!model.run.isRunning)
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        _ = await waitUntil { executor.runs.count == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(checks == 0)
    }

    @Test func setupWaitsForHelperApprovalThenStartsExactlyOneRun() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 1), .done])
        let helper = FakeHelperManager(refresh: [.enabled], ensure: [.requiresApproval, .enabled])
        let none: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                              .mas: .missing]
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: none), executor: executor, helper: helper,
            hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true))
        model.start()
        #expect(await waitUntil { model.helperState == .requiresApproval && model.setup.stage != .hidden })
        model.setup.setUp(.homebrew)
        // The helper's answer reaches the setup model in its own main-actor hop, so the stage can lag a moment.
        #expect(await waitUntil { model.setup.stage == .needsHelperApproval })
        model.checkHelper()
        #expect(await waitUntil { executor.runs.count == 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(executor.runs.count == 1)
        // The run failed (nothing appeared after the recheck): the screen says so rather than going away.
        #expect(await waitUntil { if case .failed = model.setup.stage { true } else { false } })
    }

    // MARK: Set Up buttons

    static let arm = HostInfo(appleSilicon: true, macOSMajor: 15)
    static let intel = HostInfo(appleSilicon: false, macOSMajor: 15)

    func setupModel(_ engines: [EngineID: EngineStatus], host: HostInfo = arm, isDemo: Bool = false,
                    executor: FakeRunExecutor? = FakeRunExecutor(), problem: String? = nil,
                    isAdministrator: Bool? = true) async -> BrewxPortAppModel {
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: engines), executor: executor, helper: FakeHelperManager(), isDemo: isDemo,
            setupProblem: problem, isAdministrator: isAdministrator,
            hostInfo: host, cltPresent: true))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        return model
    }

    static let allMissing: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                                       .mas: .missing]

    @Test func setupButtonEnabledForMissingEngine() async {
        let model = await setupModel(Self.allMissing)
        #expect(model.setupButton(for: .homebrew) == .enabled(title: "Set Up Homebrew…"))
        #expect(model.setupButton(for: .macports) == .enabled(title: "Set Up MacPorts…"))
    }

    @Test func setupButtonHiddenWhenPresentOrUnusable() async {
        let model = await setupModel([.homebrew: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4"),
                                      .macports: .unusable(path: URL(fileURLWithPath: "/opt/local/bin/port"), reason: "bad")])
        #expect(model.setupButton(for: .homebrew) == .hidden)
        #expect(model.setupButton(for: .macports) == .hidden)
    }

    @Test func setupButtonHomebrewOnIntelIsOneLine() async {
        let model = await setupModel(Self.allMissing, host: Self.intel)
        #expect(model.setupButton(for: .homebrew)
                == .unavailable(note: "Homebrew doesn't support Intel Macs. MacPorts does the same job."))
        #expect(model.setupButton(for: .macports) == .enabled(title: "Set Up MacPorts…"))
    }

    @Test func setupButtonDisabledInDemo() async {
        let model = await setupModel(Self.allMissing, isDemo: true)
        #expect(model.setupButton(for: .homebrew)
                == .disabled(title: "Set Up Homebrew…", help: "Not available in demo mode"))
    }

    @Test func setupButtonsExplainOnAStandardAccount() async {
        let model = await setupModel(Self.allMissing, isAdministrator: false)
        #expect(model.setupButton(for: .homebrew)
                == .disabled(title: "Set Up Homebrew…", help: "Needs an administrator account."))
        #expect(model.setupButton(for: .macports)
                == .disabled(title: "Set Up MacPorts…", help: "Needs an administrator account."))
        #expect(model.setupButton(for: .nanobrew)
                == .disabled(title: "Set Up nanobrew…", help: "Needs an administrator account."))
    }

    @Test func aSetupWithNothingToRunKeepsItsFirstProblem() async {
        let model = await setupModel(Self.allMissing)
        #expect(!model.setUpEngine(.mas))
        #expect(model.lastSetupPlanProblem == "Set up Homebrew or MacPorts first: mas installs through one of them.")
        #expect(model.setUpEngine(.homebrew))
        #expect(model.lastSetupPlanProblem == nil)
    }

    @Test func previewFirstLaunchDoesNothingOutsideDemo() async {
        let model = await setupModel([.homebrew: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")])
        model.previewFirstLaunch()
        #expect(model.engineStatuses[.homebrew] != .missing)
        #expect(model.setup.stage == .hidden)
    }

    @Test func setupButtonMasNeedsAPackageManager() async {
        let model = await setupModel(Self.allMissing)
        guard case .disabled(_, let help) = model.setupButton(for: .mas) else { Issue.record("not disabled"); return }
        #expect(help == "Set up Homebrew or MacPorts first: mas installs through one of them.")
        let withBrew = await setupModel(Self.allMissing.merging(
            [.homebrew: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")]) { $1 })
        #expect(withBrew.setupButton(for: .mas) == .enabled(title: "Set Up Mac App Store…"))
    }

    @Test func setupButtonDisabledWhileARunGoesAndFollowsCanSetUp() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = await setupModel(Self.allMissing, executor: executor)
        #expect(model.canSetUpEngines)
        #expect(model.setUpEngine(.homebrew))
        #expect(!model.canSetUpEngines)
        guard case .disabled(_, let help) = model.setupButton(for: .macports) else { Issue.record("not disabled"); return }
        #expect(help == "Wait for the current task to finish.")
    }

    @Test func setupButtonDisabledWhenCopyCannotRun() async {
        let model = await setupModel(Self.allMissing, executor: nil, problem: "No helper.")
        guard case .disabled(_, let help) = model.setupButton(for: .homebrew) else { Issue.record("not disabled"); return }
        #expect(help == "No helper.")
    }

    @Test func checkAgainIsOffWhileARunGoes() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = await setupModel(Self.allMissing, executor: executor)
        #expect(model.canCheckEngines)
        #expect(model.setUpEngine(.homebrew))
        #expect(!model.canCheckEngines)
    }

    @Test func menuOfferFollowsSetupModel() async {
        let model = await setupModel(Self.allMissing)
        // The first launch shows it by itself; "Not now" closes it, and the menu brings it back.
        #expect(await waitUntil { model.setup.stage != .hidden })
        #expect(!model.canShowSetupOffer)
        model.setup.notNow()
        #expect(model.canShowSetupOffer)
        model.showSetupOffer()
        #expect(model.setup.stage == .offer(recommended: .homebrew, others: [.macports, .nanobrew]))
        #expect(!model.canShowSetupOffer)
        let demo = await setupModel(Self.allMissing, isDemo: true)
        #expect(!demo.canShowSetupOffer)
    }

    /// A fresh Mac with nothing installed, the helper needing approval, and the setup sheet waiting on it.
    private func waitingForApproval(helper: FakeHelperManager, executor: FakeRunExecutor = FakeRunExecutor(),
                                    notifications: NotificationCenter = NotificationCenter(),
                                    pollSleep: @escaping @Sendable (Duration) async -> Void)
        async -> BrewxPortAppModel {
        let none: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                              .mas: .missing]
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: none), executor: executor, helper: helper,
            hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true), notifications: notifications)
        model.pollSleep = pollSleep
        model.start()
        _ = await waitUntil { model.helperState == .requiresApproval && model.setup.stage != .hidden }
        return model
    }

    private static let shortSleep: @Sendable (Duration) async -> Void = { _ in
        try? await Task.sleep(for: .milliseconds(5))
    }

    @Test func approvalPollNoticesApprovalAndStartsOneRun() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let helper = FakeHelperManager(refresh: [.requiresApproval, .requiresApproval, .enabled],
                                       ensure: [.requiresApproval, .enabled])
        let model = await waitingForApproval(helper: helper, executor: executor, pollSleep: Self.shortSleep)
        #expect(helper.refreshCount == 0)
        model.setup.setUp(.homebrew)
        // The helper's answer reaches the setup model in its own main-actor hop, so the stage can lag a moment.
        #expect(await waitUntil { model.setup.stage == .needsHelperApproval })
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(model.setup.stage != .needsHelperApproval)
        #expect(helper.refreshCount >= 3)
        // The poll stopped with the stage, and it never registers anything.
        try? await Task.sleep(for: .milliseconds(100))
        let reads = helper.refreshCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == reads)
        #expect(executor.runs.count == 1)
        #expect(helper.reinstallCount == 0)
    }

    @Test func approvalPollStopsAfterNotNow() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let model = await waitingForApproval(helper: helper, pollSleep: Self.shortSleep)
        model.setup.setUp(.homebrew)
        #expect(await waitUntil { helper.refreshCount >= 2 })
        model.setup.notNow()
        try? await Task.sleep(for: .milliseconds(100))
        let reads = helper.refreshCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == reads)
    }

    @Test func noPollingInOtherStages() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let model = await waitingForApproval(helper: helper, pollSleep: Self.shortSleep)
        // The offer is showing: nothing is being waited for.
        if case .offer = model.setup.stage {} else { Issue.record("expected the offer") }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == 0)
    }

    @Test func becomingActiveRereadsTheHelperWhileWaiting() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let center = NotificationCenter()
        let model = await waitingForApproval(helper: helper, notifications: center, pollSleep: { _ in
            try? await Task.sleep(for: .seconds(30))
        })
        model.setup.setUp(.homebrew)
        #expect(await waitUntil { model.setup.stage == .needsHelperApproval })
        let before = helper.refreshCount
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await waitUntil { helper.refreshCount == before + 1 })
        model.setup.notNow()
    }

    /// A model past launch with the helper in `state` (from `ensure`), engines checked, and no poll that ever ticks
    /// unless `pollSleep` says so.
    private func helperModel(_ helper: FakeHelperManager, state: HelperState, notifications: NotificationCenter,
                             pollSleep: @escaping @Sendable (Duration) async -> Void = { _ in
                                 try? await Task.sleep(for: .seconds(30))
                             }) async -> BrewxPortAppModel {
        let model = BrewxPortAppModel(services: F.services(catalog: FakeCatalog(engines: [.homebrew: .missing]),
                                                           helper: helper), notifications: notifications)
        model.pollSleep = pollSleep
        model.start()
        _ = await waitUntil { model.helperState == state && !model.engineStatuses.isEmpty && !model.checkingHelper }
        return model
    }

    @Test func becomingActiveRereadsTheHelperWhenItNeedsApproval() async {
        for waiting in [HelperState.requiresApproval, .notRegistered] {
            let helper = FakeHelperManager(refresh: [.enabled], ensure: [waiting])
            let center = NotificationCenter()
            let model = await helperModel(helper, state: waiting, notifications: center)
            #expect(model.setup.stage != .needsHelperApproval)
            #expect(helper.refreshCount == 0)
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            #expect(await waitUntil { model.helperState == .enabled }, "\(waiting)")
            #expect(helper.refreshCount == 1)
            // Once it's ready, coming back to the app reads nothing more.
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(helper.refreshCount == 1)
            #expect(helper.ensureCount == 1)
            #expect(helper.reinstallCount == 0)
        }
    }

    @Test func becomingActiveLeavesAReadyHelperAlone() async {
        for state in [HelperState.enabled, .outdated, .failed("x")] {
            let helper = FakeHelperManager(refresh: [state], ensure: [state])
            let center = NotificationCenter()
            let model = await helperModel(helper, state: state, notifications: center)
            center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try? await Task.sleep(for: .milliseconds(50))
            #expect(helper.refreshCount == 0, "\(state)")
            _ = model
        }
    }

    @Test func helperPageOpenLoginItemsPollsUntilApproved() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval, .requiresApproval, .enabled],
                                       ensure: [.requiresApproval])
        let model = await helperModel(helper, state: .requiresApproval, notifications: NotificationCenter(),
                                      pollSleep: Self.shortSleep)
        model.sidebar = .helper
        model.openLoginItems()
        #expect(helper.openCount == 1)
        #expect(await waitUntil { model.helperState == .enabled })
        #expect(helper.refreshCount == 3)
        // The poll stopped once the helper was approved, and it never registers anything.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == 3)
        #expect(helper.ensureCount == 1)
        #expect(helper.reinstallCount == 0)
    }

    @Test func leavingTheHelperPageStopsThePoll() async {
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let model = await helperModel(helper, state: .requiresApproval, notifications: NotificationCenter(),
                                      pollSleep: Self.shortSleep)
        model.sidebar = .helper
        model.openLoginItems()
        #expect(await waitUntil { helper.refreshCount >= 2 })
        model.sidebar = .updates
        try? await Task.sleep(for: .milliseconds(100))
        let reads = helper.refreshCount
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == reads)
    }

    @Test func openLoginItemsElsewhereStartsNoPagePoll() async {
        // The setup sheet's button has its own poll (while the setup waits); from any other page nothing polls.
        let helper = FakeHelperManager(refresh: [.requiresApproval], ensure: [.requiresApproval])
        let model = await helperModel(helper, state: .requiresApproval, notifications: NotificationCenter(),
                                      pollSleep: Self.shortSleep)
        model.sidebar = .updates
        model.openLoginItems()
        #expect(helper.openCount == 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(helper.refreshCount == 0)
        // Nor on the Helper page once the helper is ready.
        let ready = FakeHelperManager(refresh: [.enabled], ensure: [.enabled])
        let other = await helperModel(ready, state: .enabled, notifications: NotificationCenter(),
                                      pollSleep: Self.shortSleep)
        other.sidebar = .helper
        other.openLoginItems()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ready.refreshCount == 0)
    }

    @Test func demoSetUpIsNoOp() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(
            executor: executor, isDemo: true, hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true))
        #expect(!model.canSetUpEngines)
        model.setUpEngine(.homebrew)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        #expect(!model.run.isRunning)
    }

    @Test func runEndedObserversAllCalled() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        var calls: [String] = []
        model.addRunEndedObserver { calls.append("a") }
        model.addRunEndedObserver { calls.append("b") }
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { calls.count == 2 })
        #expect(calls == ["a", "b"])
        // The lists were reloaded before the observers heard about it.
        #expect(model.listReloadCount == 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 2)
    }

    @Test func enginesCheckedObserversCalled() async {
        let url = URL(fileURLWithPath: F.path)
        let catalog = FakeCatalog(engines: [.homebrew: .present(path: url, version: "5"), .mas: .missing])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        var heard: [[EngineID: EngineStatus]] = []
        var sawChecked: [Bool] = []
        model.addEnginesCheckedObserver { statuses in
            heard.append(statuses)
            sawChecked.append(model.enginesChecked)
        }
        model.addEnginesCheckedObserver { _ in heard.append([:]) }
        #expect(!model.enginesChecked)
        model.checkEnginesAgain()
        #expect(await waitUntil { heard.count == 2 })
        #expect(model.enginesChecked)
        #expect(heard[0] == [.homebrew: .present(path: url, version: "5"), .mas: .missing])
        #expect(heard[1] == [:])
        // The statuses are the model's by the time observers run.
        #expect(sawChecked == [true])
        catalog.setEngines([.homebrew: .missing])
        model.checkEnginesAgain()
        #expect(await waitUntil { heard.count == 4 })
        #expect(heard[2] == [.homebrew: .missing])
    }

    @Test func discoverInstallUnchangedAfterRefactor() async {
        // Discover's install goes through installRequests: same steps, same order, installed rows still left out.
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget"), F.package(.homebrew, .formula, "jq"),
                            F.package(.homebrew, .formula, "tree", installed: "1")], in: model)
        let tree = PackageRef(engine: .homebrew, kind: .formula, name: "tree")
        model.perform(.install, on: [F.wget, F.jq, tree])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.operation) == [.install])
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("jq") && arguments.contains("wget") && !arguments.contains("tree"))
        // installRequests is guarded like the rest: nothing while a run is going.
        let request = ActionRequest(operation: .install, package: F.package(.homebrew, .formula, "jq"))
        model.installRequests([request])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        // ...or while the remove confirmation is up, which a confirmed uninstall clears before it starts.
        model.perform(.uninstall, on: [tree])
        #expect(model.confirmingRemoval)
        model.installRequests([request])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        model.confirmUninstall()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(executor.runs[1].steps.map(\.operation) == [.remove])
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
    }

    @Test func discoverInstallCheckedOffBehindRemoveConfirmation() async {
        let catalog = FakeCatalog()
        catalog.script(.search("wget"), .homebrew, packages: [F.package(.homebrew, .formula, "wget")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        _ = await F.source([F.package(.homebrew, .formula, "jq", installed: "1")], in: model)
        model.discover.query = "wget"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.list.rows.isEmpty })
        model.discover.list.selection.checked = [F.wget]
        #expect(model.canInstallChecked)
        model.perform(.uninstall, on: [F.jq])
        #expect(model.confirmingRemoval)
        #expect(!model.canInstallChecked)
        model.cancelUninstall()
        #expect(model.canInstallChecked)
    }

    @Test func promptRoutedToRunController() async {
        let services = F.services()
        let model = BrewxPortAppModel(services: services)
        let answer = Task {
            await services.passwords.password(reason: "BrewxPort needs it.", previousAttemptFailed: false)
        }
        #expect(await waitUntil { model.run.showingPasswordSheet })
        #expect(model.run.passwordReason == "BrewxPort needs it.")
        model.run.finishPassword(nil)
        #expect(await answer.value == nil)
        #expect(!model.run.showingPasswordSheet)
    }

    @Test func listsReloadAfterRun() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        #expect(model.listReloadCount == 0)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { !model.run.isRunning && model.listReloadCount == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.listReloadCount == 1)
    }

    @Test func refreshDuringARunWaitsAndReloadsOnce() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        model.refreshLists()
        model.refreshLists()
        #expect(model.listReloadCount == 0)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning && model.listReloadCount == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.listReloadCount == 1)
    }

    @Test func refreshQueuedDuringARunThatRanNothingIsNotLost() async {
        // The helper check leaves nothing to run; the run still ends (onRunEnded), so the queued refresh happens.
        let executor = FakeRunExecutor()
        let gate = HelperGate()
        let model = BrewxPortAppModel(services: F.services(executor: executor, helper: FakeHelperManager()))
        let curl = AppFixtures.package(.macports, .port, "curl")
        let plan = ActionPlanner.make([ActionRequest(operation: .install, package: curl)], engines: PlanFixtures.engines,
                                      order: model.engineOrder)
        model.run.start(plan) { await gate.ensure() }
        #expect(await waitUntil { gate.isWaiting })
        model.refreshLists()
        #expect(model.listReloadCount == 0)
        gate.open(.requiresApproval)
        #expect(await waitUntil { !model.run.isRunning && model.listReloadCount == 1 })
        #expect(executor.runs.isEmpty)
    }

    @Test func preferenceActionsAndDetails() async {
        let model = BrewxPortAppModel(services: F.services())
        _ = await F.source([F.package(.homebrew, .formula, "wget", installed: "1"),
                            F.package(.homebrew, .formula, "jq", installed: "1")], in: model)
        model.perform(.ignore, on: [F.wget])
        #expect(model.preferences.isIgnored(F.wget))
        model.perform(.stopIgnoring, on: [F.wget])
        #expect(!model.preferences.isIgnored(F.wget))
        model.perform(.skipVersion("2"), on: [F.jq])
        #expect(model.preferences.isSkipped(F.package(.homebrew, .formula, "jq", installed: "1")))

        var copied: [String] = []
        model.writeToPasteboard = { copied.append($0) }
        model.perform(.copyName, on: [F.wget, F.jq])
        #expect(copied == ["jq\nwget"])

        model.perform(.showDetails, on: [F.wget])
        #expect(model.inspectorOpen)
        #expect(model.details.row?.id == F.wget)
    }

    @Test func packageLookupFollowsSourceOrder() async {
        let model = BrewxPortAppModel(services: F.services())
        #expect(model.package(for: F.wget) == nil)
        _ = await F.source([F.package(.homebrew, .formula, "wget", installed: "1")], in: model)
        _ = await F.source([F.package(.homebrew, .formula, "wget", installed: "0.9")], in: model)
        #expect(model.package(for: F.wget)?.installedVersion == "1")
        #expect(model.outdatedRefs.isEmpty)
    }

    @Test func prepareSnapshotSwitchesTheSidebar() async {
        let model = BrewxPortAppModel(services: F.services())
        await model.prepareSnapshot(.installed)
        #expect(model.sidebar == .installed)
    }

    @Test func findSwitchesToDiscoverAndRequestsFocus() {
        let model = BrewxPortAppModel(services: F.services())
        #expect(model.sidebar == .updates)
        model.find()
        #expect(model.sidebar == .discover)
        #expect(model.focusSearchRequest == 1)
        #expect(model.takeSearchFocusRequest())
        #expect(!model.takeSearchFocusRequest())
        model.find()
        #expect(model.focusSearchRequest == 2)
    }

    @Test func snapshotScriptSubmitsRipgrep() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep")],
                       delay: .milliseconds(100))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        await model.prepareSnapshot(.discover)
        #expect(model.sidebar == .discover)
        #expect(model.discover.query == "ripgrep")
        #expect(catalog.queries == [.search("ripgrep")])
        #expect(!model.discover.searching)
        #expect(model.discover.list.rows.map(\.name) == ["ripgrep"])
    }

    @Test func discoverListUsesHostOrderAndEngineArch() async {
        let catalog = FakeCatalog()
        catalog.script(.search("ripgrep"), .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.discover.query = "ripgrep"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        let ref = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        // PlanFixtures' Homebrew runs as arm64; the row's package is found through the model.
        #expect(model.discover.list.byRef[ref]?.arch == .arm64)
        #expect(model.package(for: ref)?.displayName == "ripgrep")
    }

    @Test func inspectorInstallUsesOptions() async {
        let catalog = FakeCatalog()
        let curl = F.package(.macports, .port, "curl")
        catalog.script(.search("curl"), .macports, packages: [curl])
        catalog.scriptInfo(F.curl, FakeCatalog.InfoScript(result: .success(
            PackageDetails(ref: F.curl, variants: ["universal", "ssl"]))))
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor,
                                                        isDemo: true))
        model.discover.query = "curl"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        model.perform(.showDetails, on: [F.curl])
        #expect(await waitUntil { model.details.details != nil })
        #expect(model.inspectorOptions == InspectorOptionFields(version: false, extraArgs: true,
                                                                variants: ["ssl", "universal"]))
        model.details.options.variants = ["universal": true]
        model.details.options.extraArgs = "-s"
        model.installFromInspector()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps[0].spec.arguments.contains("+universal"))
        #expect(executor.runs[0].steps[0].spec.arguments.contains("-s"))
        #expect(model.details.optionsError == nil)
    }

    @Test func inspectorInstallRejectsBadOptions() async {
        let catalog = FakeCatalog()
        catalog.script(.search("curl"), .macports, packages: [F.package(.macports, .port, "curl")])
        catalog.scriptInfo(F.curl, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: F.curl))))
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.discover.query = "curl"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        model.perform(.showDetails, on: [F.curl])
        model.details.options.extraArgs = "-f"
        model.installFromInspector()
        #expect(model.details.optionsError?.hasPrefix("MacPorts doesn't accept -f here") == true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        // Showing another package clears the message.
        model.details.show(nil)
        #expect(model.details.optionsError == nil)
    }

    @Test func discoverInstallTitleCountsChecks() async {
        let catalog = FakeCatalog()
        catalog.script(.search("x"), .homebrew, packages: [F.package(.homebrew, .formula, "wget"),
                                                           F.package(.homebrew, .formula, "jq")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        #expect(model.discover.installTitle == "Install")
        #expect(!model.canInstallChecked)
        model.discover.query = "x"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        model.discover.list.selection.checked = [F.wget, F.jq]
        #expect(model.discover.installTitle == "Install 2")
        #expect(model.canInstallChecked)
    }

    @Test func inspectorFollowsSingleSelectionWhileOpen() async {
        let model = BrewxPortAppModel(services: F.services())
        _ = await F.source([F.package(.homebrew, .formula, "wget"), F.package(.homebrew, .formula, "jq")], in: model)
        model.selectionChanged([F.wget])
        #expect(model.details.row == nil)

        model.inspectorOpen = true
        model.selectionChanged([F.wget])
        #expect(model.details.row?.id == F.wget)
        model.selectionChanged([F.wget, F.jq])
        #expect(model.details.row == nil)
        model.selectionChanged([F.jq])
        #expect(model.details.row?.id == F.jq)
        model.selectionChanged([])
        #expect(model.details.row == nil)
    }

    @Test func refusedInstallSaysNothingRanWithTheReason() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(executor: executor, isDemo: true))
        let nanobrew = F.package(.nanobrew, .formula, "ripgrep")
        let macports = F.package(.macports, .port, "ripgrep")
        _ = await F.source([nanobrew, macports], in: model)
        model.perform(.install, on: [nanobrew.id, macports.id])
        #expect(await waitUntil { model.run.panelVisible && !model.run.isRunning })
        #expect(executor.runs.isEmpty)
        #expect(model.run.headline == "Nothing ran")
        #expect(model.run.problems.count == 1)
        #expect(model.run.problems.first?.contains("Pick one") == true)
    }

    @Test func finishedRunSaysFinishedWithNoProblems() async {
        // A real run reports each step; a bare `.done` would leave the step skipped ("Finished with problems").
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(executor: executor, isDemo: true))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(model.run.headline == "Finished")
        #expect(model.run.problems.isEmpty)
    }

    // The 0.2.0 report: Updates listed apps, the run said "Finished", nothing changed. On a standard account the cask
    // step is skipped while the formula step runs; the header has to say so.
    @Test func standardAccountSkippingACaskSaysFinishedWithProblems() async {
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(executor: executor, isDemo: true, isAdministrator: false))
        let wget = F.package(.homebrew, .formula, "wget", installed: "1")
        let firefox = F.package(.homebrew, .cask, "firefox", installed: "1")
        _ = await F.source([wget, firefox], in: model)
        model.perform(.update, on: [wget.id, firefox.id])
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(model.run.problems.contains { $0.contains("administrator account") })
        #expect(model.run.headline == "Finished with problems")
    }

    // Whatever the cause (a skipped step, a failed one, Homebrew printing "Not upgrading" and exiting 0), a package
    // that's still outdated once Updates reloads after the run is named in the panel.
    @Test func updateThatLeavesAPackageOutdatedNamesIt() async {
        let catalog = FakeCatalog()
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor, isDemo: true))
        let wget = F.package(.homebrew, .formula, "wget", installed: "1")
        let jq = F.package(.homebrew, .formula, "jq", installed: "1")
        // Homebrew keeps reporting wget as outdated after the run; jq was updated.
        catalog.script(.outdated, .homebrew, packages: [wget])
        _ = await F.source([wget, jq], in: model)
        model.perform(.update, on: [wget.id, jq.id])
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(await waitUntil { model.run.problems.contains("Still out of date after the update: wget.") })
        #expect(model.run.headline == "Finished with problems")
    }

    @Test func returnAndToolbarInstallSkipFilterHiddenRows() async {
        let catalog = FakeCatalog()
        let homebrew = F.package(.homebrew, .formula, "ripgrep")
        let nanobrew = F.package(.nanobrew, .formula, "ripgrep")
        catalog.script(.search("ripgrep"), .homebrew, packages: [homebrew])
        catalog.script(.search("ripgrep"), .nanobrew, packages: [nanobrew])
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor, isDemo: true))
        model.discover.query = "ripgrep"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        model.discover.engineFilter = .homebrew
        // Selected and checked while hidden (the filter only prunes when it changes).
        model.discover.list.selection.selected = [homebrew.id, nanobrew.id]
        model.discover.list.selection.checked = [homebrew.id, nanobrew.id]
        #expect(model.discover.checkedRefs == [homebrew.id])
        #expect(model.discover.installTitle == "Install 1")

        model.installSelected()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.engine) == [.homebrew])
    }

    @Test func startMarksInstalledDiscoverRows() async {
        let catalog = FakeCatalog()
        let ripgrep = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        catalog.script(.installed, .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep", installed: "14")])
        catalog.script(.search("ripgrep"), .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.start()
        model.discover.query = "ripgrep"
        model.discover.submit()
        #expect(await waitUntil { model.discover.list.byRef[ripgrep]?.isInstalled == true })
    }

    // MARK: Updates

    static func outdatedCatalog(_ packages: [Package]) -> FakeCatalog {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.outdated, engine, packages: found)
        }
        return catalog
    }

    /// Which of wget and jq the steps name.
    static func names(_ steps: [RunStep]) -> [String] {
        let arguments = steps.flatMap(\.spec.arguments)
        return ["jq", "wget"].filter(arguments.contains)
    }

    static func outdatedQueries(_ catalog: FakeCatalog) -> Int {
        catalog.queries.filter { $0 == .outdated }.count
    }

    @Test func archColumnShowsTheInstalledArchAndUpdatesBorrowIt() async {
        // Intel MacPorts on Apple silicon: the engine runs as arm64, the port was built for x86_64.
        let catalog = FakeCatalog()
        var curl = F.package(.macports, .port, "curl", installed: "1")
        curl.installedArchs = [.x86_64]
        var zlib = F.package(.macports, .port, "zlib", installed: "1")
        zlib.installedArchs = [.arm64, .x86_64]
        let jq = F.package(.homebrew, .formula, "jq", installed: "1")
        catalog.script(.installed, .macports, packages: [curl, zlib])
        catalog.script(.installed, .homebrew, packages: [jq])
        var outdatedCurl = curl
        outdatedCurl.installedArchs = nil      // `port outdated` doesn't say
        catalog.script(.outdated, .macports, packages: [outdatedCurl])
        catalog.script(.outdated, .homebrew, packages: [jq])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, host: .arm64))
        model.start()
        #expect(await waitUntil { model.installed.list.all.count == 3 && model.updates.list.all.count == 2 })
        await model.installed.settled()
        let installed = Dictionary(uniqueKeysWithValues: model.installed.rows.map { ($0.name, $0.archName) })
        #expect(installed == ["curl": "x86_64", "zlib": "universal", "jq": "arm64"])
        #expect(await waitUntil { model.updates.list.byRef[curl.id]?.archName == "x86_64" })
        #expect(model.updates.list.byRef[jq.id]?.archName == "arm64")
        #expect(model.updates.list.byRef[curl.id]?.arch == .arm64)
    }

    @Test func reloadWaitsForRun() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "jq", installed: "1")])
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        model.refreshLists()
        model.refreshLists()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(Self.outdatedQueries(catalog) == 0)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning && Self.outdatedQueries(catalog) == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(Self.outdatedQueries(catalog) == 1)
        #expect(model.updates.list.rows.map(\.name) == ["jq"])
    }

    @Test func runThatRanNothingStillReloadsUpdates() async {
        // The helper check leaves nothing to run; Updates is checked again all the same.
        let catalog = Self.outdatedCatalog([F.package(.macports, .port, "curl", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: FakeRunExecutor(),
                                                        helper: FakeHelperManager(ensure: [.requiresApproval])))
        let curl = AppFixtures.package(.macports, .port, "curl")
        let plan = ActionPlanner.make([ActionRequest(operation: .upgrade, package: curl)], engines: PlanFixtures.engines,
                                      order: model.engineOrder)
        #expect(model.run.start(plan) { .requiresApproval })
        #expect(await waitUntil { !model.run.isRunning && Self.outdatedQueries(catalog) == 1 })
        #expect(model.run.headline == "Nothing ran")
    }

    @Test func inspectorUpdateRunsTheSameStepAsTheMenu() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "wget", installed: "1")])
        let menuExecutor = FakeRunExecutor()
        let menu = BrewxPortAppModel(services: F.services(catalog: catalog, executor: menuExecutor))
        menu.refreshLists()
        #expect(await waitUntil { !menu.updates.list.loading && menu.updates.badgeCount == 1 })
        menu.perform(.update, on: [F.wget])
        #expect(await waitUntil { menuExecutor.runs.count == 1 })

        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 1 })
        model.perform(.showDetails, on: [F.wget])
        #expect(model.details.installAvailability(isRunning: false, homebrewPresent: true,
                                                  isOutdated: model.outdatedRefs.contains(F.wget))
                == .updateAvailable(installed: "1", latest: "2"))
        model.updateFromInspector()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.operation) == [.upgrade])
        #expect(executor.runs[0].steps.map(\.spec) == menuExecutor.runs[0].steps.map(\.spec))
    }

    @Test func badgeFollowsIgnore() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "wget", installed: "1"),
                                            F.package(.homebrew, .formula, "jq", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 2 })
        model.perform(.ignore, on: [F.wget])
        #expect(model.updates.badgeCount == 1)
        #expect(model.updates.list.rows.map(\.id) == [F.jq])
        #expect(model.outdatedRefs == [F.wget, F.jq])
        model.perform(.stopIgnoring, on: [F.wget])
        #expect(model.updates.badgeCount == 2)
        model.perform(.skipVersion("2"), on: [F.jq])
        #expect(model.updates.badgeCount == 1)
    }

    @Test func ignoreAndSkipNotifyTheBadgeAndMarks() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "wget", installed: "1"),
                                            F.package(.homebrew, .formula, "jq", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 2 })
        // The sidebar badge redraws on Ignore.
        nonisolated(unsafe) var badgeChanged = false
        withObservationTracking { _ = model.updates.badgeCount } onChange: { badgeChanged = true }
        model.perform(.ignore, on: [F.wget])
        #expect(badgeChanged)
        // With hidden rows shown, the rows stay the same but their marks redraw on Skip.
        model.updates.showHidden = true
        nonisolated(unsafe) var marksChanged = false
        withObservationTracking {
            _ = model.updates.list.rows.map(model.updates.hiddenReason)
        } onChange: { marksChanged = true }
        model.perform(.skipVersion("2"), on: [F.jq])
        #expect(marksChanged)
        #expect(model.updates.hiddenReason(model.updates.list.byRef[F.jq]!) == .skipped)
    }

    @Test func snapshotScriptChecksTwoAndOpensInspector() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "wget", installed: "1"),
                                            F.package(.homebrew, .formula, "jq", installed: "1"),
                                            F.package(.macports, .port, "curl", installed: "1")])
        catalog.script(.outdated, .nanobrew, packages: [], delay: .milliseconds(100))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.sidebar = .discover
        await model.prepareSnapshot(.updates)
        #expect(model.sidebar == .updates)
        #expect(!model.updates.list.loading)
        let rows = model.updates.list.rows
        #expect(rows.count == 3)
        #expect(model.updates.list.selection.checked == Set(rows.prefix(2).map(\.id)))
        #expect(model.updates.list.selection.selected == [rows[0].id])
        #expect(model.inspectorOpen)
        #expect(model.details.row?.id == rows[0].id)
    }

    @Test func updateAllAndCheckedActOnUpdatableRowsOnly() async {
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "wget", installed: "1"),
                                            F.package(.homebrew, .formula, "jq", installed: "1")])
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 2 })
        model.perform(.ignore, on: [F.wget])
        #expect(model.canUpdateAll)
        model.updateAll()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(Self.names(executor.runs[0].steps) == ["jq"])

        // Checked but hidden by the ignore: not updated. Return acts on the highlighted row.
        model.updates.list.selection.checked = [F.wget]
        #expect(!model.canUpdateChecked)
        model.updateChecked()
        model.updates.list.selection.selected = [F.jq]
        model.updateSelected()
        #expect(await waitUntil { executor.runs.count == 2 && !model.run.isRunning })
        #expect(Self.names(executor.runs[1].steps) == ["jq"])
    }

    // MARK: Installed

    static func installedCatalog(_ packages: [Package]) -> FakeCatalog {
        let catalog = FakeCatalog()
        for (engine, found) in Dictionary(grouping: packages, by: \.id.engine) {
            catalog.script(.installed, engine, packages: found)
        }
        return catalog
    }

    @Test func deleteRemovesSelectionAfterConfirm() async {
        let catalog = Self.installedCatalog([F.package(.homebrew, .formula, "wget", installed: "1"),
                                             F.package(.homebrew, .formula, "jq", installed: "1")])
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.refreshLists()
        await model.installed.settled()
        let list = model.installed.list
        list.selection.selected = [F.wget]
        list.selection.checked = [F.jq]
        // Delete asks first and acts on the highlighted row, not the checked one.
        model.removeSelected()
        #expect(model.pendingUninstall == [F.wget])
        #expect(model.uninstallTitle == "Remove wget (Homebrew)?")
        #expect(executor.runs.isEmpty)
        model.confirmUninstall()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.operation) == [.remove])
        #expect(Self.names(executor.runs[0].steps) == ["wget"])

        // The toolbar's Remove N acts on the checked rows, also after the confirmation.
        await model.installed.settled()
        model.installed.list.selection.checked = [F.jq]
        #expect(model.installed.removeTitle == "Remove 1")
        #expect(model.canRemoveChecked)
        model.removeChecked()
        #expect(model.pendingUninstall == [F.jq])
        model.cancelUninstall()
        #expect(executor.runs.count == 1)
    }

    @Test func uninstallTitleNamesUpToFive() async {
        let model = BrewxPortAppModel(services: F.services())
        let names = ["g", "b", "a", "f", "c", "e", "d"]
        _ = await F.source(names.map { F.package(.homebrew, .formula, $0, installed: "1") }
                           + [F.package(.macports, .port, "a", installed: "1")], in: model)
        let refs = Set(names.map { PackageRef(engine: .homebrew, kind: .formula, name: $0) })
        model.perform(.uninstall, on: refs.union([PackageRef(engine: .macports, kind: .port, name: "a")]))
        #expect(model.uninstallTitle
                == "Remove a (Homebrew), a (MacPorts), b (Homebrew), c (Homebrew), d (Homebrew) and 3 more?")
        // A confirmation that's up can't be replaced; the next one comes after it's dismissed.
        model.cancelUninstall()
        model.perform(.uninstall, on: [PackageRef(engine: .macports, kind: .port, name: "a"), F.curl])
        #expect(model.uninstallTitle == "Remove a (MacPorts)?")
    }

    @Test func installedRowMenuActsOnInstalledRows() async {
        let catalog = Self.installedCatalog([F.package(.homebrew, .formula, "wget", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        await model.installed.settled()
        #expect(model.package(for: F.wget)?.installedVersion == "1")
        model.perform(.uninstall, on: [F.wget])
        #expect(model.pendingUninstall == [F.wget])
        model.cancelUninstall()
        model.perform(.showDetails, on: [F.wget])
        #expect(model.details.row?.id == F.wget)
    }

    @Test func discoverInstalledMarksRefreshAfterRun() async {
        let ripgrep = PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [])
        catalog.script(.search("ripgrep"), .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep")])
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.start()
        await model.installed.settled()
        model.discover.query = "ripgrep"
        model.discover.submit()
        await model.discover.list.settled()
        #expect(model.discover.list.byRef[ripgrep]?.isInstalled == false)

        catalog.script(.installed, .homebrew, packages: [F.package(.homebrew, .formula, "ripgrep", installed: "14")])
        model.perform(.install, on: [ripgrep])
        #expect(await waitUntil { model.discover.list.byRef[ripgrep]?.isInstalled == true })
        #expect(model.installed.list.byRef[ripgrep] != nil)
        // Exactly one writer: the marks are the Installed list's refs.
        #expect(model.discover.list.installedRefs == Set(model.installed.list.all.map(\.id)))
    }

    @Test func snapshotScriptWaitsForInstalled() async {
        let catalog = Self.installedCatalog([F.package(.nanobrew, .formula, "figlet", installed: "2.2.5"),
                                             F.package(.homebrew, .formula, "jq", installed: "1")])
        catalog.script(.installed, .macports, packages: [F.package(.macports, .port, "figlet", installed: "2.2.5_0")],
                       delay: .milliseconds(100))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        await model.prepareSnapshot(.installed)
        #expect(model.sidebar == .installed)
        #expect(!model.installed.list.loading)
        #expect(!model.installed.analyzing)
        let figlets = model.installed.duplicates["figlet"] ?? []
        #expect(figlets.map(\.engine) == [.nanobrew, .macports])
        #expect(model.installed.list.selection.selected == Set(figlets.prefix(1)))
        #expect(model.inspectorOpen)
        #expect(model.details.row?.id == figlets.first)
    }

    // MARK: Keyboard and menu

    /// wget is installed and outdated; jq is installed and current. Both lists loaded.
    static func keyboardModel(executor: FakeRunExecutor = FakeRunExecutor()) async -> BrewxPortAppModel {
        let catalog = FakeCatalog()
        catalog.script(.installed, .homebrew, packages: [F.package(.homebrew, .formula, "wget", installed: "1"),
                                                         F.package(.homebrew, .formula, "jq", installed: "2")])
        catalog.script(.outdated, .homebrew, packages: [F.package(.homebrew, .formula, "wget", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        model.refreshLists()
        await model.installed.settled()
        _ = await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 1 }
        return model
    }

    @Test func returnFollowsThePage() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = await Self.keyboardModel(executor: executor)

        model.sidebar = .updates
        #expect(model.primaryActionTitle == "Update Selected")
        #expect(!model.canPerformPrimary)
        model.updates.list.selection.selected = [F.wget]
        #expect(model.canPerformPrimary)

        // Installed: only a selected row with an update is updated.
        model.sidebar = .installed
        model.installed.list.selection.selected = [F.jq]
        #expect(!model.canPerformPrimary)
        model.performPrimary()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        model.installed.list.selection.selected = [F.wget, F.jq]
        #expect(model.canPerformPrimary)
        model.performPrimary()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.operation) == [.upgrade])
        #expect(Self.names(executor.runs[0].steps) == ["wget"])

        model.sidebar = .discover
        #expect(model.primaryActionTitle == "Install Selected")
        // Bundles is a package table now (Task 7), with nothing open here: nothing to act on.
        model.sidebar = .bundles
        #expect(model.currentView == .bundles)
        #expect(!model.canPerformPrimary)
        model.sidebar = .engine(.homebrew)
        #expect(model.currentView == nil)
        #expect(!model.canPerformPrimary)
    }

    @Test func deleteRemovesOnUpdatesAndInstalledOnly() async {
        let model = await Self.keyboardModel()
        model.sidebar = .updates
        model.updates.list.selection.selected = [F.wget]
        #expect(model.canRemoveSelection)
        model.removeSelection()
        #expect(model.pendingUninstall == [F.wget])
        model.cancelUninstall()

        model.sidebar = .installed
        model.installed.list.selection.selected = [F.jq]
        #expect(model.canRemoveSelection)
        model.removeSelection()
        #expect(model.pendingUninstall == [F.jq])
        model.cancelUninstall()

        // Discover offers no removal; a selected Discover row is left alone.
        _ = await F.source([F.package(.homebrew, .formula, "curl")], in: model)
        model.sidebar = .discover
        #expect(!model.canRemoveSelection)
        model.removeSelection()
        #expect(model.pendingUninstall == nil)
    }

    @Test func spaceTogglesTheCurrentPagesChecks() async {
        let model = await Self.keyboardModel()
        model.sidebar = .installed
        #expect(!model.canToggleChecks)
        model.installed.list.selection.selected = [F.wget, F.jq]
        #expect(model.canToggleChecks)
        model.toggleChecks()
        #expect(model.installed.list.selection.checked == [F.wget, F.jq])
        #expect(model.updates.list.selection.checked.isEmpty)
        model.toggleChecks()
        #expect(model.installed.list.selection.checked.isEmpty)
    }

    @Test func nothingActsBehindTheRemoveConfirmation() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = await Self.keyboardModel(executor: executor)
        model.sidebar = .installed
        model.installed.list.selection.selected = [F.jq]
        model.removeSelection()
        #expect(model.confirmingRemoval)
        let title = model.uninstallTitle

        // With the dialog up, the menu items are off and the keys and row actions do nothing.
        model.installed.list.selection.selected = [F.wget]
        #expect(!model.canPerformPrimary)
        #expect(!model.canRemoveSelection)
        #expect(!model.canToggleChecks)
        model.performPrimary()
        model.toggleChecks()
        model.removeSelection()
        model.perform(.uninstall, on: [F.wget])
        model.perform(.update, on: [F.wget])
        model.updates.list.selection.selected = [F.wget]
        model.sidebar = .updates
        model.removeSelection()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        #expect(model.installed.list.selection.checked.isEmpty)

        // The dialog still names jq, and Remove removes jq.
        #expect(model.pendingUninstall == [F.jq])
        #expect(model.uninstallTitle == title)
        model.confirmUninstall()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.operation) == [.remove])
        #expect(Self.names(executor.runs[0].steps) == ["jq"])
        #expect(!model.confirmingRemoval)
    }

    @Test func showDetailsTogglesTheInspectorOnTheSelection() async {
        let model = await Self.keyboardModel()
        model.sidebar = .installed
        model.installed.list.selection.selected = [F.jq]
        #expect(!model.inspectorOpen)
        model.toggleInspector()
        #expect(model.inspectorOpen)
        #expect(model.details.row?.id == F.jq)
        model.toggleInspector()
        #expect(!model.inspectorOpen)

        // Switching pages leaves no row from the last page in the inspector.
        model.toggleInspector()
        model.sidebar = .updates
        #expect(model.details.row == nil)
        model.updates.list.selection.selected = [F.wget]
        model.sidebar = .discover
        model.sidebar = .updates
        #expect(model.details.row?.id == F.wget)
        model.toggleInspector()
        model.sidebar = .installed

        // Two selected rows: the inspector opens empty.
        model.installed.list.selection.selected = [F.jq, F.wget]
        model.toggleInspector()
        #expect(model.inspectorOpen)
        #expect(model.details.row == nil)
    }
}
