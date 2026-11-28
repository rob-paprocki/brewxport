import Testing
import Foundation
import AppKit
import Observation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Services for the app-model tests: fake engines, catalog, executor, helper and background seams.
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
                         shellPath: ShellPathEditor? = nil, scheduler: FakeScheduler = FakeScheduler(),
                         notifier: FakeNotifier = FakeNotifier(), loginItem: FakeLoginItem = FakeLoginItem(),
                         conditions: FakeConditions = FakeConditions(),
                         fileExists: @escaping @Sendable (String) -> Bool = { _ in true }) -> Services {
        // The model loads Installed and Updates on its own; a test that doesn't script them gets empty lists.
        catalog.scriptEmpty(.installed)
        catalog.scriptEmpty(.outdated)
        return Services(engines: engines, catalog: catalog, executor: executor, helper: helper,
                 passwords: PromptPasswordProvider(), isAdministrator: { isAdministrator }, store: store,
                 path: path, fileExists: fileExists, host: host, hostInfo: hostInfo,
                 cltPresent: { cltPresent }, receipts: receipts, setupProblem: setupProblem, isDemo: isDemo,
                 scheduler: scheduler, notifier: notifier, loginItem: loginItem, conditions: conditions,
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

    static let languages: [EngineID] = [.npm, .pipx, .uv, .cargo, .bun, .gem, .mint]

    @Test func sidebarEnginesFollowHostOrder() {
        #expect(BrewxPortAppModel(services: F.services(host: .arm64)).engineOrder
                == [.nanobrew, .homebrew, .macports, .mas] + Self.languages)
        #expect(BrewxPortAppModel(services: F.services(host: .x86_64)).engineOrder.first == .macports)
        #expect(BrewxPortAppModel(services: F.services(host: .x86_64)).engineOrder
                == [.macports, .homebrew, .nanobrew, .mas] + Self.languages)
    }

    @Test func sidebarGroupsLanguages() {
        let arm = BrewxPortAppModel(services: F.services(host: .arm64)).sidebarEngineGroups
        #expect(arm.map(\.title) == ["Engines", "Languages"])
        #expect(arm.map(\.group) == [.system, .languages])
        #expect(arm.map(\.engines) == [[.nanobrew, .homebrew, .macports, .mas], Self.languages])
        let intel = BrewxPortAppModel(services: F.services(host: .x86_64)).sidebarEngineGroups
        #expect(intel.map(\.engines) == [[.macports, .homebrew, .nanobrew, .mas], Self.languages])
        // A group with nothing in it isn't shown.
        #expect(SidebarEngineGroup.make(order: [.homebrew, .mas]).map(\.group) == [.system])
    }

    @Test func everyEngineHasItsOwnSymbol() {
        let symbols = EngineID.allCases.map(EngineRowText.symbol)
        #expect(Set(symbols).count == symbols.count)
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
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

    /// R15: a Bun too old to drive is "Too old" in the sidebar, not "Not working", with its own symbol and the reason
    /// in the tooltip; its page shows the R15 sentence. A partial check's count goes in the tooltip too.
    @Test func unsupportedEngineRowSaysTooOld() {
        let bun = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
        let reason = "Bun 1.2.20 is too old for BrewxPort. Update Bun to 1.4.5 or later with brew upgrade bun or "
            + "bun upgrade."
        // Plain text in the tooltip and on the page: no Markdown backticks.
        #expect(!reason.contains("`"))
        let status = EngineStatus.unsupported(path: bun, version: "1.2.20", reason: reason)
        #expect(EngineRowText.subtitle(status) == "Too old")
        #expect(EngineRowText.statusSymbol(status) == "arrow.up.circle")
        #expect(NSImage(systemSymbolName: "arrow.up.circle", accessibilityDescription: nil) != nil)
        #expect(EngineRowText.help(status, unchecked: nil) == reason)
        #expect(PackageCatalog.message(for: .bun, status: status) == reason)
        #expect(EngineRowText.help(.present(path: bun, version: "1.4.5"), unchecked: "2 tools couldn't be checked")
                == "Last check: 2 tools couldn't be checked")
        #expect(EngineRowText.help(.present(path: bun, version: "1.4.5"), unchecked: nil) == nil)
        #expect(NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil) != nil)
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
        #expect(model.uninstall.state == .hidden)
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
        #expect(await Self.uninstallPicks(model) == ["jq", "wget"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        #expect(!model.run.isRunning)

        model.uninstall.cancel()
        #expect(model.uninstall.state == .hidden)
        #expect(executor.runs.isEmpty)

        model.perform(.uninstall, on: [F.wget])
        #expect(await Self.uninstallPicks(model) == ["wget"])
        model.uninstall.confirm()
        #expect(!model.uninstall.sheetShown)
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
        #expect(model.uninstall.state == .hidden)
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
        // With background checks off, closing the window quits, as before they existed.
        model.background.settings.interval = .never
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

    // MARK: Quit, Dock and login

    @Test func closingWindowKeepsRunningWhenChecksOn() async {
        // Background checks are on by default: closing the window leaves BrewxPort running in the menu bar.
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        #expect(model.background.settings.checksOn)
        #expect(!model.quitsWhenLastWindowCloses)
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.quitsWhenLastWindowCloses)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        #expect(!model.quitsWhenLastWindowCloses)
        // The demo's menu bar always shows, so it keeps running whatever its interval says.
        let demo = BrewxPortAppModel(services: F.services(isDemo: true))
        demo.background.settings.interval = .never
        #expect(!demo.quitsWhenLastWindowCloses)
    }

    @Test func closingWindowQuitsWhenChecksOff() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        model.background.settings.interval = .never
        #expect(model.quitsWhenLastWindowCloses)
        // Except during a run, as before.
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.quitsWhenLastWindowCloses)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        #expect(model.quitsWhenLastWindowCloses)
        // Turning checks on again keeps it running.
        model.background.settings.interval = .daily
        #expect(!model.quitsWhenLastWindowCloses)
    }

    @Test func dockHidesWithoutWindowWhenChecksOn() {
        let model = BrewxPortAppModel(services: F.services())
        // Nothing has shown yet; the app sets this as the window opens and closes.
        #expect(!model.mainWindowShowing)
        model.mainWindowShowing = true
        #expect(model.showsDockIcon)
        // The app follows `showsDockIcon` by observing it: closing the window changes it.
        nonisolated(unsafe) var closeSeen = false
        withObservationTracking { _ = model.showsDockIcon } onChange: { closeSeen = true }
        model.mainWindowShowing = false
        #expect(closeSeen)
        #expect(!model.showsDockIcon)
        // Checks off: the Dock icon stays without a window, as before (BrewxPort quits when the window closes,
        // unless a run is going). Turning checks off from Settings changes it too.
        nonisolated(unsafe) var checksOffSeen = false
        withObservationTracking { _ = model.showsDockIcon } onChange: { checksOffSeen = true }
        model.background.settings.interval = .never
        #expect(checksOffSeen)
        #expect(model.showsDockIcon)
        model.mainWindowShowing = true
        #expect(model.showsDockIcon)
        // The demo keeps its Dock icon: a scripted demo has to stay a regular app to be driven and photographed.
        let demo = BrewxPortAppModel(services: F.services(isDemo: true))
        #expect(demo.background.settings.checksOn)
        #expect(!demo.mainWindowShowing)
        #expect(demo.showsDockIcon)
    }

    @Test func dockRuleAppliesOnceLaunchSettles() {
        // A launch at login with checks on (VM finding 1): no window ever showed, so nothing changed `showsDockIcon`
        // and no window event would set the activation policy. Once launch has settled, the rule says no Dock icon.
        let login = BrewxPortAppModel(services: F.services())
        #expect(!login.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: true))
        #expect(!login.mainWindowShowing)
        // Not recognised as a login launch (no login-item flag in the launch event), and still no window: the same.
        let unrecognised = BrewxPortAppModel(services: F.services())
        #expect(!unrecognised.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: false))
        // The system put the window up, the login launch closed it before its content appeared, and the content said
        // it appeared afterwards: what's on screen wins, and the change reaches the app's observation.
        let closed = BrewxPortAppModel(services: F.services())
        closed.mainWindowShowing = true
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = closed.showsDockIcon } onChange: { changed = true }
        #expect(!closed.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: true))
        #expect(changed)
        #expect(!closed.mainWindowShowing)
        #expect(!closed.showsDockIcon)
        // Any other launch has its window up by then: the icon stays, even before the content has said so.
        let normal = BrewxPortAppModel(services: F.services())
        #expect(normal.launchSettled(mainWindowOnScreen: true, afterLoginLaunch: false))
        #expect(normal.mainWindowShowing)
        // A window restored minimized isn't on screen, yet it's open: after a launch that closed nothing, the content's
        // word stands.
        let minimized = BrewxPortAppModel(services: F.services())
        minimized.mainWindowShowing = true
        #expect(minimized.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: false))
        #expect(minimized.mainWindowShowing)
        // Settings open counts as a window.
        let settings = BrewxPortAppModel(services: F.services())
        settings.settingsWindowShowing = true
        #expect(settings.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: true))
        // Checks off (Never): the Dock icon stays without a window.
        let off = BrewxPortAppModel(services: F.services())
        off.background.settings.interval = .never
        #expect(off.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: true))
        // The demo always keeps it.
        let demo = BrewxPortAppModel(services: F.services(isDemo: true))
        #expect(demo.launchSettled(mainWindowOnScreen: false, afterLoginLaunch: false))
    }

    @Test func quitTitleMentionsChecks() {
        let model = BrewxPortAppModel(services: F.services())
        #expect(model.quitTitle == "Quit BrewxPort (stops update checks)")
        model.background.settings.interval = .never
        #expect(model.quitTitle == "Quit BrewxPort")
        model.background.settings.interval = .hourly
        #expect(model.quitTitle == "Quit BrewxPort (stops update checks)")
    }

    @Test func loginItemToggleCallsSeam() throws {
        struct Refused: Error {}
        let store = MemoryStore()
        let loginItem = FakeLoginItem()
        let model = BrewxPortAppModel(services: F.services(store: store, loginItem: loginItem))
        let settings = model.background.settings
        #expect(!settings.openAtLogin)
        try model.background.setOpenAtLogin(true)
        #expect(loginItem.changes == [true])
        #expect(settings.openAtLogin)
        #expect(store.data(forKey: "openAtLogin") == Data("1".utf8))
        try model.background.setOpenAtLogin(false)
        #expect(loginItem.changes == [true, false])
        #expect(!settings.openAtLogin)
        // The system refuses: the error reaches the caller (Settings shows it) and nothing changes.
        loginItem.error = Refused()
        #expect(throws: Refused.self) { try model.background.setOpenAtLogin(true) }
        #expect(loginItem.changes == [true, false, true])
        #expect(!loginItem.isEnabled)
        #expect(!settings.openAtLogin)
        #expect(store.data(forKey: "openAtLogin") == Data("0".utf8))
        // Registered but waiting for approval in System Settings: the switch stays on, and Settings says to approve.
        loginItem.error = nil
        loginItem.approvalNeededOnRegister = true
        try model.background.setOpenAtLogin(true)
        #expect(!loginItem.isEnabled)
        #expect(loginItem.needsApproval)
        #expect(settings.openAtLogin)
    }

    @Test func openAtLoginFollowsSystemState() {
        func launch(stored: Bool?, isEnabled: Bool = false, needsApproval: Bool = false) -> (Bool, FakeLoginItem) {
            let store = MemoryStore()
            if let stored { store.set(Data((stored ? "1" : "0").utf8), forKey: "openAtLogin") }
            let loginItem = FakeLoginItem(isEnabled: isEnabled, needsApproval: needsApproval)
            let model = BrewxPortAppModel(services: F.services(store: store, loginItem: loginItem))
            model.start()
            return (model.background.settings.openAtLogin, loginItem)
        }
        // Removed in System Settings > General > Login Items: the switch turns off at the next launch.
        let (removed, removedItem) = launch(stored: true)
        #expect(!removed)
        // Waiting for approval keeps the person's choice; Settings says to approve it.
        #expect(launch(stored: true, needsApproval: true).0)
        // Registered and allowed, though the setting says otherwise (a reset store, say): the switch says so.
        #expect(launch(stored: false, isEnabled: true).0)
        #expect(launch(stored: nil, isEnabled: true).0)
        #expect(!launch(stored: nil).0)
        #expect(launch(stored: true, isEnabled: true).0)
        // Launch only reads: it never registers or unregisters anything.
        #expect(removedItem.changes.isEmpty)
    }

    // MARK: Running without the window

    @Test func startRunsWithoutAView() async {
        // Launch calls start() before any window shows, and a launch at login may never show one: start() alone
        // detects the engines and loads Updates and Installed.
        let catalog = Self.outdatedCatalog([F.package(.homebrew, .formula, "jq", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        #expect(model.listReloadCount == 0)
        model.start()
        #expect(await waitUntil {
            model.enginesChecked && model.updates.list.rows.map(\.name) == ["jq"] && !model.installed.list.loading
        })
        #expect(catalog.queries.contains(.installed))
        #expect(model.listReloadCount == 1)
        // The window's own call, once it appears, does nothing more.
        model.start()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.listReloadCount == 1)
        #expect(Self.outdatedQueries(catalog) == 1)
    }

    @Test func backgroundRunDoesNotReopenWindow() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(executor: executor))
        let wget = ActionRequest(operation: .upgrade, package: F.package(.homebrew, .formula, "wget", installed: "1"))
        #expect(model.lastRunOrigin == .user)
        #expect(model.reopensWindowAfterRun)
        // What the app's run-ended observer reads when it decides whether to bring the window back.
        var reopenAtEnd: [Bool] = []
        model.addRunEndedObserver { reopenAtEnd.append(model.reopensWindowAfterRun) }
        #expect(model.installRequests([wget], origin: .background))
        #expect(model.lastRunOrigin == .background)
        #expect(!model.reopensWindowAfterRun)
        #expect(await waitUntil { reopenAtEnd.count == 1 })
        #expect(reopenAtEnd == [false])
        #expect(executor.runs.count == 1)
    }

    @Test func userRunStillReopensWindow() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(
            executor: executor, helper: FakeHelperManager(),
            hostInfo: HostInfo(appleSilicon: true, macOSMajor: 15), cltPresent: true))
        let wget = F.package(.homebrew, .formula, "wget", installed: "1")
        _ = await F.source([wget], in: model)
        var reopenAtEnd: [Bool] = []
        model.addRunEndedObserver { reopenAtEnd.append(model.reopensWindowAfterRun) }
        let update = ActionRequest(operation: .upgrade, package: wget)
        let background = { model.installRequests([update], origin: .background) }
        // A row's Update after a background run.
        #expect(background())
        #expect(await waitUntil { reopenAtEnd.count == 1 })
        model.perform(.update, on: [wget.id])
        #expect(await waitUntil { reopenAtEnd.count == 2 })
        // Engine setup starts its run without installRequests, and is the user's too.
        #expect(background())
        #expect(await waitUntil { reopenAtEnd.count == 3 })
        #expect(model.setUpEngine(.homebrew))
        #expect(await waitUntil { reopenAtEnd.count == 4 })
        #expect(reopenAtEnd == [false, true, false, true])
        #expect(model.lastRunOrigin == .user)
        #expect(executor.runs.count == 4)
    }

    @Test func installRequestsReportsWhetherARunStarted() async {
        // A standard account: a cask's update needs an administrator, a formula's doesn't.
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(executor: executor, isAdministrator: false))
        let wget = ActionRequest(operation: .upgrade, package: F.package(.homebrew, .formula, "wget", installed: "1"))
        let firefox = ActionRequest(operation: .upgrade,
                                    package: F.package(.homebrew, .cask, "firefox", installed: "1"))
        #expect(model.installRequests([wget], origin: .user))
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        model.run.dismissPanel()
        let log = model.run.log, steps = model.run.steps, runNumber = model.run.runNumber
        // A background run left with nothing it may run doesn't start: no panel, and the last run's log stays.
        #expect(!model.installRequests([firefox], origin: .background))
        #expect(!model.run.panelVisible)
        #expect(model.run.log == log)
        #expect(model.run.steps == steps)
        #expect(model.run.runNumber == runNumber)
        #expect(model.lastRunOrigin == .user)
        #expect(executor.runs.count == 1)
        // Asked for by the user, the same request still says in the panel why nothing ran.
        #expect(!model.installRequests([firefox], origin: .user))
        #expect(model.run.panelVisible)
        #expect(model.run.headline == "Nothing ran")
        #expect(model.run.problems.contains { $0.contains("administrator account") })
        // Nothing starts while a run is going, from either origin.
        executor.events = [.started(0)]
        executor.hang = true
        #expect(model.installRequests([wget], origin: .background))
        #expect(await waitUntil { model.run.isRunning })
        #expect(!model.installRequests([wget], origin: .background))
        #expect(!model.installRequests([wget]))
        #expect(model.lastRunOrigin == .background)
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })
        #expect(executor.runs.count == 2)
    }

    @Test func mainWindowIsKnownByItsSceneIdentifier() {
        // SwiftUI gives the `Window(id: "main")` scene's window the identifier "main"; the Settings window's is
        // "com_apple_SwiftUI_Settings_window". Both can be main, so being main-capable doesn't pick the main window.
        #expect(MainWindowScene.id == "main")
        #expect(MainWindowScene.matches("main"))
        #expect(MainWindowScene.matches("main-AppWindow-1"))
        #expect(!MainWindowScene.matches("com_apple_SwiftUI_Settings_window"))
        #expect(!MainWindowScene.matches("notice"))
        #expect(!MainWindowScene.matches("mainly"))
        #expect(!MainWindowScene.matches(nil))
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

    // MARK: Refresh MacPorts

    static let portPresent: EngineStatus = .present(path: URL(fileURLWithPath: PlanFixtures.portPath), version: "2.12.7")

    func refreshModel(macports: EngineStatus, executor: FakeRunExecutor) async -> BrewxPortAppModel {
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: [.homebrew: .missing, .macports: macports, .nanobrew: .missing, .mas: .missing]),
            executor: executor, helper: FakeHelperManager()))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        return model
    }

    @Test func refreshMacPortsRunsOnlySelfupdate() async {
        let executor = FakeRunExecutor(events: [.needsPassword, .started(0), .finished(0, 0), .done])
        let model = await refreshModel(macports: Self.portPresent, executor: executor)
        #expect(model.showsRefreshMacPorts)
        #expect(model.canRefreshMacPorts)
        let reloads = model.listReloadCount
        #expect(model.refreshMacPortsCatalogue())
        #expect(model.lastRunOrigin == .user)
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        let steps = executor.runs[0].steps
        #expect(steps.map(\.spec.arguments) == [["-N", "selfupdate"]])
        #expect(steps.map(\.spec.executable.path) == [PlanFixtures.portPath])
        #expect(steps.map(RunRouting.route(for:)) == [.helper])
        #expect(steps.map(\.title) == ["MacPorts: refresh the port catalogue"])
        #expect(executor.runs[0].reason
                == "BrewxPort needs an administrator password to refresh MacPorts' port catalogue.")
        #expect(model.run.headline == "Finished")
        // The run's end reloads the lists, so Updates shows what the refreshed catalogue knows.
        #expect(await waitUntil { model.listReloadCount == reloads + 1 })

        // Not while a run is going.
        executor.events = [.started(0)]
        executor.hang = true
        #expect(model.refreshMacPortsCatalogue())
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(!model.canRefreshMacPorts)
        #expect(!model.refreshMacPortsCatalogue())
        model.run.cancel()
        #expect(await waitUntil { !model.run.isRunning })

        // Nor while a sheet is up.
        model.run.showingPasswordSheet = true
        #expect(!model.canRefreshMacPorts)
        #expect(!model.refreshMacPortsCatalogue())
        model.run.showingPasswordSheet = false
        #expect(model.canRefreshMacPorts)
        #expect(executor.runs.count == 2)
    }

    @Test func refreshMacPortsSaysWhyNothingRan() async {
        // MacPorts was found, then went missing: its refresh can't be built. The panel says so instead of nothing.
        let executor = FakeRunExecutor()
        let engines: [any Engine] = PlanFixtures.engines.map {
            $0.id == .macports ? MacPortsEngine(runner: PlanFixtures.runner, executable: nil) : $0
        }
        let model = BrewxPortAppModel(services: F.services(
            catalog: FakeCatalog(engines: [.macports: Self.portPresent]), executor: executor,
            helper: FakeHelperManager(), engines: engines))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        #expect(model.canRefreshMacPorts)
        #expect(!model.refreshMacPortsCatalogue())
        #expect(executor.runs.isEmpty)
        #expect(!model.run.isRunning)
        #expect(model.run.panelVisible)
        #expect(model.run.headline == "Nothing ran")
        #expect(model.run.problems == ["The port catalogue wasn't refreshed: MacPorts isn't installed"])
    }

    @Test func refreshMacPortsHiddenWithoutMacPorts() async {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let unusable = EngineStatus.unusable(path: URL(fileURLWithPath: PlanFixtures.portPath), reason: "bad")
        for status in [EngineStatus.missing, unusable] {
            let model = await refreshModel(macports: status, executor: executor)
            #expect(!model.showsRefreshMacPorts)
            #expect(!model.canRefreshMacPorts)
            #expect(!model.refreshMacPortsCatalogue())
            #expect(!model.run.panelVisible)
        }
        // Before the engines have been checked nothing is known, so it stays hidden then too.
        let unchecked = BrewxPortAppModel(services: F.services(executor: executor, helper: FakeHelperManager()))
        #expect(!unchecked.showsRefreshMacPorts)
        #expect(!unchecked.refreshMacPortsCatalogue())
        #expect(executor.runs.isEmpty)
    }

    // MARK: Set Up buttons

    static let arm = HostInfo(appleSilicon: true, macOSMajor: 15)
    static let intel = HostInfo(appleSilicon: false, macOSMajor: 15)

    /// What Installed has listed before a test looks: nothing yet, Homebrew's packages, or a Homebrew that failed.
    enum Listing { case notLoaded, homebrew([Package]), homebrewFailed }

    func setupModel(_ engines: [EngineID: EngineStatus], host: HostInfo = arm, isDemo: Bool = false,
                    executor: FakeRunExecutor? = FakeRunExecutor(), problem: String? = nil,
                    isAdministrator: Bool? = true, languages: [any Engine] = [],
                    fileExists: @escaping @Sendable (String) -> Bool = { _ in true },
                    listed: Listing = .notLoaded, path: any PathResolving = AppFixtures.NoPath())
        async -> BrewxPortAppModel {
        let catalog = FakeCatalog(engines: engines)
        switch listed {
        case .notLoaded: break
        case .homebrew(let packages): catalog.script(.installed, .homebrew, packages: packages)
        case .homebrewFailed:
            catalog.script(.installed, .homebrew,
                           FakeCatalog.Script(result: .failure(EngineError(engine: .homebrew, message: "failed"))))
        }
        let model = BrewxPortAppModel(services: F.services(
            catalog: catalog, executor: executor, helper: FakeHelperManager(), isDemo: isDemo,
            setupProblem: problem, isAdministrator: isAdministrator,
            hostInfo: host, cltPresent: true, engines: PlanFixtures.engines + languages, path: path,
            fileExists: fileExists))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        if case .notLoaded = listed {} else {
            model.refreshLists()
            await model.installed.settled()
        }
        return model
    }

    static let allMissing: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                                       .mas: .missing]

    @Test func setupButtonEnabledForMissingEngine() async {
        let model = await setupModel(Self.allMissing)
        #expect(model.setupButton(for: .homebrew) == .enabled(title: "Set Up Homebrew…"))
        #expect(model.setupButton(for: .macports) == .enabled(title: "Set Up MacPorts…"))
    }

    // MARK: Language engines' Set Up (Plan 9 Task 11)

    static let brew = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/brew"), version: "4")
    static let port = EngineStatus.present(path: URL(fileURLWithPath: "/opt/local/bin/port"), version: "2")
    static let languagesMissing = Dictionary(uniqueKeysWithValues: languages.map { ($0, EngineStatus.missing) })

    /// Every engine missing, except as `given`.
    func statuses(_ given: [EngineID: EngineStatus]) -> [EngineID: EngineStatus] {
        Self.allMissing.merging(Self.languagesMissing) { $1 }.merging(given) { $1 }
    }

    /// With Homebrew, each missing language engine's page offers Set Up and says what it installs. Homebrew installs
    /// as the user, so a standard account can too; demo mode shows the button, off.
    @Test func languageSetUpButtonsWithHomebrew() async {
        let model = await setupModel(statuses([.homebrew: Self.brew]))
        for engine in Self.languages {
            #expect(model.setupButton(for: engine) == .enabled(title: "Set Up \(engine.displayName)…"))
            // An import never needs one: bundles don't carry language tools.
            #expect(EngineSetup.setup(for: engine, status: .missing) == nil)
        }
        #expect(model.setupLine(for: .npm) == "Set Up installs Homebrew's node, which includes npm.")
        #expect(model.setupLine(for: .gem) == "Set Up installs Homebrew's ruby, which includes RubyGems.")
        #expect(model.setupLine(for: .cargo) == "Set Up installs Homebrew's rustup, then Rust's stable toolchain.")
        #expect(model.setupLine(for: .pipx) == "Set Up installs Homebrew's pipx.")
        #expect(model.setupLine(for: .uv) == "Set Up installs Homebrew's uv.")
        #expect(model.setupLine(for: .bun) == "Set Up installs Homebrew's bun.")
        #expect(model.setupLine(for: .mint) == "Set Up installs Homebrew's mint.")
        #expect(model.setupLine(for: .macports) == nil)
        let standard = await setupModel(statuses([.homebrew: Self.brew]), isAdministrator: false)
        #expect(standard.setupButton(for: .uv) == .enabled(title: "Set Up uv…"))
        let demo = await setupModel(statuses([.homebrew: Self.brew]), isDemo: true)
        #expect(demo.setupButton(for: .cargo) == .disabled(title: "Set Up Cargo…", help: "Not available in demo mode"))
        #expect(demo.setupLine(for: .cargo) == "Set Up installs Homebrew's rustup, then Rust's stable toolchain.")
        // Already there: nothing.
        let present = await setupModel(statuses([.homebrew: Self.brew])
            .merging([.uv: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/uv"), version: "0.13.4")]) { $1 })
        #expect(present.setupButton(for: .uv) == .hidden)
        #expect(present.setupLine(for: .uv) == nil)
    }

    /// Homebrew in /usr/local (an Intel Mac's) has no bottles for rustup: Cargo's line says the build takes a while.
    @Test func intelHomebrewSaysRustBuildsTakeAWhile() async {
        let intelBrew = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/brew"), version: "4")
        let model = await setupModel(statuses([.homebrew: intelBrew]), host: Self.intel)
        #expect(model.setupButton(for: .cargo) == .enabled(title: "Set Up Cargo…"))
        #expect(model.setupLine(for: .cargo) == "Set Up installs Homebrew's rustup, then Rust's stable toolchain. On "
                + "an Intel Mac, Homebrew builds Rust from source first, which can take a while.")
        #expect(model.setupLine(for: .pipx) == "Set Up installs Homebrew's pipx.")
    }

    /// MacPorts only: pipx, uv, Cargo and Mint go through MacPorts (an administrator's password), npm, Bun and
    /// RubyGems aren't offered, and their pages say why.
    @Test func languageSetUpButtonsWithMacPortsOnly() async {
        let model = await setupModel(statuses([.macports: Self.port]), host: Self.intel)
        for engine in [EngineID.pipx, .uv, .cargo, .mint] {
            #expect(model.setupButton(for: engine) == .enabled(title: "Set Up \(engine.displayName)…"))
        }
        #expect(model.setupLine(for: .mint) == "Set Up installs MacPorts' mint. Needs an administrator password.")
        #expect(model.setupLine(for: .cargo)
                == "Set Up installs MacPorts' rustup, then Rust's stable toolchain. Needs an administrator password.")
        for engine in [EngineID.npm, .bun, .gem] {
            #expect(model.setupButton(for: engine) == .unavailable(note: SetupCopy.homebrewOnly(engine, appleSilicon: false)))
            #expect(model.setupLine(for: engine) == nil)
        }
        let standard = await setupModel(statuses([.macports: Self.port]), host: Self.intel, isAdministrator: false)
        #expect(standard.setupButton(for: .uv) == .disabled(title: "Set Up uv…", help: "Needs an administrator account."))
    }

    /// Neither Homebrew nor MacPorts: the button is off and the page says which to set up first.
    @Test func languageSetUpNeedsHomebrewOrMacPorts() async {
        let model = await setupModel(statuses([:]))
        let first = SetupCopy.languageNeedsManager(.pipx, appleSilicon: true)
        #expect(model.setupButton(for: .pipx) == .disabled(title: "Set Up pipx…", help: first))
        #expect(model.setupLine(for: .pipx) == first)
        #expect(model.setupButton(for: .npm) == .unavailable(note: SetupCopy.homebrewOnly(.npm, appleSilicon: true)))
        #expect(!model.setUpEngine(.pipx))
        #expect(model.lastSetupPlanProblem == first)
    }

    /// Set Up runs Homebrew's install like any other install (as the user, nothing for the helper), and its end asks
    /// the login shell again and checks the engines again, so the new engine and its bin folder show up.
    @Test func languageSetUpRunsThenReadsTheShellAndChecksAgain() async throws {
        let path = ShellRecorder()
        let catalog = FakeCatalog(engines: [.homebrew: Self.brew, .uv: .missing])
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor, path: path))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        let before = path.events.count
        catalog.setEngines([.homebrew: Self.brew,
                            .uv: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/uv"), version: "0.13.4")])
        #expect(model.setUpEngine(.uv))
        #expect(await waitUntil { !model.run.isRunning && model.engineStatuses[.uv] != .missing })
        #expect(executor.runs.count == 1)
        #expect(try #require(executor.runs.first).steps.map(\.spec.arguments) == [["install", "--formula", "uv"]])
        #expect(try #require(executor.runs.first).steps.allSatisfy { $0.setupTarget == nil })
        // The run's end asks the shell again before anything reads it.
        #expect(path.events.dropFirst(before).first == "askAgain")
        #expect(model.setupButton(for: .uv) == .hidden)
    }

    /// A Set Up whose toolchain step failed leaves Cargo "not working" on rustup's proxy: Set Up is offered again.
    @Test func cargoWithoutAToolchainOffersSetUpAgain() async {
        let keg = "/opt/homebrew/opt/rustup/bin"
        let proxy = EngineStatus.unusable(path: URL(fileURLWithPath: keg + "/cargo"), reason: "no default toolchain")
        let model = await setupModel(statuses([.homebrew: Self.brew, .cargo: proxy]),
                                     fileExists: { $0 == keg + "/rustup" })
        #expect(model.setupButton(for: .cargo) == .enabled(title: "Set Up Cargo…"))
        #expect(model.setupLine(for: .cargo) == "Set Up installs Rust's stable toolchain with the rustup in \(keg).")
        let other = EngineStatus.unusable(path: URL(fileURLWithPath: "/opt/local/bin/cargo"), reason: "bad")
        let broken = await setupModel(statuses([.homebrew: Self.brew, .cargo: other]), fileExists: { _ in false })
        #expect(broken.setupButton(for: .cargo) == .hidden)
    }

    /// R31: the person's own rustup (`~/.cargo/bin`, or CARGO_HOME's) without a toolchain: Set Up runs that rustup's
    /// `default stable` as the user, and installs no second rustup through Homebrew or MacPorts. It needs neither of
    /// them, nor an administrator.
    @Test func ownRustupSetUpFromThePage() async throws {
        let own = NSHomeDirectory() + "/.cargo/bin"
        let proxy = EngineStatus.unusable(path: URL(fileURLWithPath: own + "/cargo"), reason: "no default toolchain")
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        for given in [[EngineID.homebrew: Self.brew], [.macports: Self.port], [:]] {
            let model = await setupModel(statuses(given.merging([.cargo: proxy]) { $1 }), executor: executor,
                                         isAdministrator: false, fileExists: { $0 == own + "/rustup" })
            #expect(model.setupButton(for: .cargo) == .enabled(title: "Set Up Cargo…"))
            #expect(model.setupLine(for: .cargo)
                    == "Set Up installs Rust's stable toolchain with the rustup in ~/.cargo/bin.")
        }
        let model = await setupModel(statuses([.homebrew: Self.brew, .cargo: proxy]), executor: executor,
                                     fileExists: { $0 == own + "/rustup" })
        #expect(model.setUpEngine(.cargo))
        #expect(await waitUntil { executor.runs.count == 1 })
        let steps = try #require(executor.runs.first).steps
        #expect(steps.map(\.spec.executable.path) == [own + "/rustup"])
        #expect(steps.map(\.spec.arguments) == [["default", "stable"]])
        #expect(steps.first?.spec.environment?["RUSTUP_AUTO_INSTALL"] == "1")
    }

    /// Fix round 1: a Cargo Set Up that couldn't start once the shell had answered (something else came up meanwhile)
    /// says so: the run panel shows why, and nothing ran.
    @Test func cargoSetUpThatCantStartSaysWhy() async throws {
        let path = ShellRecorder()
        let gate = Gate()
        let executor = FakeRunExecutor()
        let model = await setupModel(statuses([.homebrew: Self.brew]), executor: executor, path: path)
        path.resolveGate = gate
        #expect(model.setUpEngine(.cargo))
        #expect(await waitUntil { gate.waiting == 1 })
        model.showingOpenPanel = true
        path.resolveGate = nil
        gate.release()
        let why = "Cargo wasn't set up: something else came up while BrewxPort read your shell's settings. Try Set Up "
            + "again."
        #expect(await waitUntil { model.lastSetupPlanProblem != nil })
        #expect(model.lastSetupPlanProblem == why)
        #expect(model.run.panelVisible)
        #expect(model.run.problems == [why])
        #expect(executor.runs.isEmpty)
    }

    /// R31: an npm that lives in Homebrew's own prefix without being Homebrew's (Node's installer in /usr/local on an
    /// Intel Mac): `brew install node` would fail to link over it, so it isn't offered; the page keeps npm's own fix
    /// and says why.
    @Test func npmInHomebrewsPrefixGetsNoHomebrewNode() async throws {
        let reason = "npm installs tools into /usr/local, which your account can't change."
        let intelBrew = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/brew"), version: "4")
        let npm = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/npm"), version: "11.2.0")
        let model = await setupModel(statuses([.homebrew: intelBrew, .npm: npm]), host: Self.intel,
                                     languages: [FakeLanguageEngine(.npm, readOnlyReason: reason)],
                                     listed: .homebrew([]))
        #expect(model.setupButton(for: .npm) == .unavailable(note: "Homebrew's node would clash with the node already "
                                                              + "in /usr/local, so BrewxPort doesn't offer it."))
        #expect(model.setupLine(for: .npm) == nil)
        #expect(model.readOnlyReason(for: .npm) == reason)
    }

    /// Fix round 1: Homebrew's node is installed beside a read-only npm, but the shell still runs the other npm: the
    /// page names both folders. A note only: BrewxPort doesn't change the PATH for it.
    @Test func npmNoteNamesBothCopiesAfterHomebrewNode() async throws {
        let reason = "npm installs tools into /usr/local, which your account can't change."
        let npm = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/npm"), version: "11.2.0")
        let model = await setupModel(statuses([.homebrew: Self.brew, .npm: npm]),
                                     languages: [FakeLanguageEngine(.npm, readOnlyReason: reason)],
                                     listed: .homebrew([F.package(.homebrew, .formula, "node", installed: "25.1.0")]),
                                     path: ShellRecorder())
        #expect(model.setupButton(for: .npm) == .hidden)
        let note = try #require(model.pathNote(for: .npm))
        #expect(note.text == "Your shell runs npm from /usr/local/bin; Homebrew's is in /opt/homebrew/bin.")
        #expect(note.line == nil)
        model.addToPath(.npm)
        #expect(model.pathFix(for: .npm) == .offered)
        // Homebrew's npm is the one the shell runs: nothing to say.
        let homebrews = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/npm"), version: "11.2.0")
        let fine = await setupModel(statuses([.homebrew: Self.brew, .npm: homebrews]),
                                    languages: [FakeLanguageEngine(.npm, readOnlyReason: reason)],
                                    listed: .homebrew([F.package(.homebrew, .formula, "node", installed: "25.1.0")]),
                                    path: ShellRecorder())
        #expect(fine.pathNote(for: .npm) == nil)
    }

    // MARK: Rulings on Task 11 (R30, Intel builds, Cargo's fresh shell read)

    static let systemGem = EngineStatus.present(path: URL(fileURLWithPath: "/usr/bin/gem"), version: "3.5.22")

    /// R30: RubyGems runs macOS's own Ruby (or MacPorts'), which only an administrator can change. With Homebrew, its
    /// page offers Set Up of Homebrew's Ruby: the same run as a missing RubyGems' Set Up. Not without Homebrew, and not
    /// for Homebrew's own Ruby.
    @Test func systemRubyOffersHomebrewRubySetUp() async throws {
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let system = statuses([.homebrew: Self.brew, .gem: Self.systemGem])
        let model = await setupModel(system, executor: executor, listed: .homebrew([]))
        #expect(model.setupButton(for: .gem) == .enabled(title: "Set Up Homebrew's Ruby…"))
        #expect(model.setupLine(for: .gem) == "Set Up installs Homebrew's ruby, which includes RubyGems.")
        #expect(model.setUpEngine(.gem))
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(try #require(executor.runs.first).steps.map(\.spec.arguments) == [["install", "--formula", "ruby"]])
        #expect(try #require(executor.runs.first).steps.allSatisfy { $0.setupTarget == nil })

        let macPortsRuby = EngineStatus.present(path: URL(fileURLWithPath: "/opt/local/bin/gem"), version: "4.0.3")
        let withPorts = await setupModel(statuses([.homebrew: Self.brew, .gem: macPortsRuby]), listed: .homebrew([]))
        #expect(withPorts.setupButton(for: .gem) == .enabled(title: "Set Up Homebrew's Ruby…"))
        let noHomebrew = await setupModel(statuses([.macports: Self.port, .gem: Self.systemGem]), listed: .homebrew([]))
        #expect(noHomebrew.setupButton(for: .gem) == .hidden)
        #expect(noHomebrew.setupLine(for: .gem) == nil)
        let homebrewRuby = EngineStatus.present(path: URL(fileURLWithPath: "/opt/homebrew/bin/gem"), version: "4.0.10")
        let own = await setupModel(statuses([.homebrew: Self.brew, .gem: homebrewRuby]), listed: .homebrew([]))
        #expect(own.setupButton(for: .gem) == .hidden)
        let demo = await setupModel(system, isDemo: true, listed: .homebrew([]))
        #expect(demo.setupButton(for: .gem)
                == .disabled(title: "Set Up Homebrew's Ruby…", help: "Not available in demo mode"))
        // Until Installed has listed Homebrew it isn't known whether Homebrew has Ruby: nothing is offered.
        let unlisted = await setupModel(system)
        #expect(unlisted.setupButton(for: .gem) == .hidden)
    }

    /// Fix round 1: Installed couldn't list Homebrew, so whether Homebrew has Ruby or Node isn't known: no R30 button
    /// (failing closed), and the PATH note stays as the last listing that worked left it.
    @Test func homebrewRuntimeOffersFailClosedWhenHomebrewCouldNotBeListed() async throws {
        let system = statuses([.homebrew: Self.brew, .gem: Self.systemGem])
        let failed = await setupModel(system, listed: .homebrewFailed)
        #expect(failed.installed.list.failedEngines.contains(.homebrew))
        #expect(failed.setupButton(for: .gem) == .hidden)
        #expect(failed.setupLine(for: .gem) == nil)

        // Homebrew's Ruby was listed; a later listing fails: the PATH note is still there, still no button.
        let catalog = FakeCatalog(engines: system)
        catalog.script(.installed, .homebrew, packages: [F.package(.homebrew, .formula, "ruby", installed: "4.0.10")])
        let gem = FakeLanguageEngine(.gem, readOnlyReason: "This is macOS's own Ruby, and only an administrator can "
                                     + "change its gems. Set up Homebrew's Ruby to manage gems with BrewxPort.")
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, engines: PlanFixtures.engines + [gem],
                                                          path: ShellRecorder()))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        model.refreshLists()
        await model.installed.settled()
        let note = try #require(model.pathNote(for: .gem))
        catalog.script(.installed, .homebrew,
                       FakeCatalog.Script(result: .failure(EngineError(engine: .homebrew, message: "failed"))))
        model.refreshLists()
        await model.installed.settled()
        #expect(model.installed.list.failedEngines.contains(.homebrew))
        #expect(model.pathNote(for: .gem) == note)
        #expect(model.setupButton(for: .gem) == .hidden)
    }

    /// R30: npm's global folder isn't writable (Node from nodejs.org) and Homebrew has no node: the page offers Set Up
    /// of Homebrew's node beside the user-prefix fix. Only with Homebrew, and not once Homebrew's node is installed.
    @Test func npmReadOnlyOffersHomebrewNodeWhenAvailable() async throws {
        let reason = "npm installs tools into /usr/local, which your account can't change."
        let npmStatus = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/npm"), version: "11.2.0")
        func make(_ given: [EngineID: EngineStatus], readOnly: String? = reason, homebrewNode: Bool = false,
                  executor: FakeRunExecutor = FakeRunExecutor(),
                  path: any PathResolving = F.NoPath()) async -> BrewxPortAppModel {
            let catalog = FakeCatalog(engines: statuses(given))
            catalog.script(.installed, .homebrew,
                           packages: homebrewNode ? [F.package(.homebrew, .formula, "node", installed: "25.1.0")] : [])
            let npm = FakeLanguageEngine(.npm, readOnlyReason: readOnly)
            let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor,
                                                              engines: PlanFixtures.engines + [npm], path: path))
            model.checkEnginesAgain()
            _ = await waitUntil { model.enginesChecked }
            model.refreshLists()
            await model.installed.settled()
            return model
        }
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = await make([.homebrew: Self.brew, .npm: npmStatus], executor: executor)
        #expect(model.setupButton(for: .npm) == .enabled(title: "Set Up Homebrew's Node…"))
        #expect(model.setupLine(for: .npm) == "Set Up installs Homebrew's node, which includes npm.")
        #expect(model.readOnlyReason(for: .npm) == reason)
        #expect(model.setUpEngine(.npm))
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(try #require(executor.runs.first).steps.map(\.spec.arguments) == [["install", "--formula", "node"]])

        let installed = await make([.homebrew: Self.brew, .npm: npmStatus], homebrewNode: true)
        #expect(installed.setupButton(for: .npm) == .hidden)
        let noHomebrew = await make([.macports: Self.port, .npm: npmStatus])
        #expect(noHomebrew.setupButton(for: .npm) == .hidden)
        let writable = await make([.homebrew: Self.brew, .npm: npmStatus], readOnly: nil)
        #expect(writable.setupButton(for: .npm) == .hidden)

        // Final review: Volta's npm is read-only for Volta's own reason. Homebrew's node wouldn't be the npm the shell
        // runs (Volta's shims come first), so it isn't offered, and the two-copies note isn't shown either.
        let voltaStatus = EngineStatus.present(path: URL(fileURLWithPath: "/Users/someone/.volta/bin/npm"),
                                               version: "11.2.0")
        let volta = await make([.homebrew: Self.brew, .npm: voltaStatus], readOnly: NpmEngine.voltaReason)
        #expect(volta.readOnlyReason(for: .npm) == NpmEngine.voltaReason)
        #expect(volta.setupButton(for: .npm) == .hidden)
        let besideHomebrews = await make([.homebrew: Self.brew, .npm: npmStatus], homebrewNode: true,
                                         path: ShellRecorder())
        #expect(besideHomebrews.pathNote(for: .npm)?.text
                == "Your shell runs npm from /usr/local/bin; Homebrew's is in /opt/homebrew/bin.")
        let voltaBesideHomebrews = await make([.homebrew: Self.brew, .npm: voltaStatus], readOnly: NpmEngine.voltaReason,
                                              homebrewNode: true, path: ShellRecorder())
        #expect(voltaBesideHomebrews.pathNote(for: .npm) == nil)
    }

    /// Homebrew in /usr/local (an Intel Mac's) builds Bun from source (no Intel bottles), and Mint too on macOS 15 and
    /// later (Intel bottles only for Sonoma and Ventura): their lines say it can take a while. Not where bottles exist.
    @Test func intelHomebrewSaysBunAndMintBuildsTakeAWhile() async {
        let intelBrew = EngineStatus.present(path: URL(fileURLWithPath: "/usr/local/bin/brew"), version: "4")
        let sequoia = await setupModel(statuses([.homebrew: intelBrew]), host: Self.intel)
        #expect(sequoia.setupLine(for: .bun) == "Set Up installs Homebrew's bun. On an Intel Mac, Homebrew builds Bun "
                + "from source, which can take a while.")
        #expect(sequoia.setupLine(for: .mint) == "Set Up installs Homebrew's mint. On an Intel Mac, Homebrew builds "
                + "Mint from source, which can take a while.")
        #expect(sequoia.setupLine(for: .uv) == "Set Up installs Homebrew's uv.")
        let sonoma = await setupModel(statuses([.homebrew: intelBrew]),
                                      host: HostInfo(appleSilicon: false, macOSMajor: 14))
        #expect(sonoma.setupLine(for: .mint) == "Set Up installs Homebrew's mint.")
        #expect(sonoma.setupLine(for: .bun) == "Set Up installs Homebrew's bun. On an Intel Mac, Homebrew builds Bun "
                + "from source, which can take a while.")
        let arm = await setupModel(statuses([.homebrew: Self.brew]))
        #expect(arm.setupLine(for: .bun) == "Set Up installs Homebrew's bun.")
        #expect(arm.setupLine(for: .mint) == "Set Up installs Homebrew's mint.")
    }

    /// Cargo's toolchain step gets CARGO_HOME and RUSTUP_HOME from the login shell as it answers when Set Up starts
    /// (asked again first), not from whatever Installed last read. The buttons are off while it's asked.
    @Test func cargoSetUpReadsTheShellAfresh() async throws {
        let path = ShellRecorder(environment: ["RUSTUP_HOME": "/Users/tester/old-rust"])
        let catalog = FakeCatalog(engines: [.homebrew: Self.brew, .cargo: .missing, .uv: .missing])
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor, path: path))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        model.refreshLists()
        await model.installed.settled()
        path.environment = ["RUSTUP_HOME": "/Users/tester/rust", "GEM_HOME": "/Users/tester/gems"]
        let before = path.events.count
        let gate = Gate()
        path.resolveGate = gate
        #expect(model.setUpEngine(.cargo))
        #expect(await waitUntil { gate.waiting == 1 })
        #expect(executor.runs.isEmpty)
        #expect(!model.canSetUpEngines)
        #expect(model.setupButton(for: .uv) == .disabled(title: "Set Up uv…", help: "Wait for the current task to finish."))
        path.resolveGate = nil
        gate.release()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Array(path.events.dropFirst(before).prefix(2)) == ["askAgain", "resolve"])
        let toolchain = try #require(executor.runs.first?.steps.last)
        #expect(toolchain.spec.arguments == ["default", "stable"])
        #expect(toolchain.spec.environment?["RUSTUP_HOME"] == "/Users/tester/rust")
        #expect(toolchain.spec.environment?["GEM_HOME"] == nil)
    }

    /// The setup sheet and File > "Set Up Package Manager…" stay with the system package managers: a language engine
    /// is set up from its own page, through one of them.
    @Test func setupSheetLeavesLanguageEnginesOut() async {
        let systemPresent: [EngineID: EngineStatus] = [
            .homebrew: Self.brew, .macports: Self.port,
            .nanobrew: .present(path: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb"), version: "1"),
            .mas: .present(path: URL(fileURLWithPath: "/opt/homebrew/bin/mas"), version: "1")]
        let model = await setupModel(systemPresent.merging(Self.languagesMissing) { $1 })
        #expect(model.setupButton(for: .npm) == .enabled(title: "Set Up npm…"))
        #expect(!model.canShowSetupOffer)
        model.showSetupOffer()
        #expect(model.setup.stage == .hidden)
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
        // The poll stopped with the stage, and it never registers anything. A helper call still in flight has landed
        // before `reads` is taken, however slow the runner; a poll still running would tick in the 100 ms after.
        #expect(await waitUntil { !model.checkingHelper })
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
        // A helper call still in flight has landed before `reads` is taken, however slow the runner; a poll still
        // running would tick in the 100 ms after.
        #expect(await waitUntil { !model.checkingHelper })
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
        // Coming back to the app is ignored while a helper call is in flight, so wait for the setup's own call to end.
        #expect(await waitUntil { model.setup.stage == .needsHelperApproval && !model.checkingHelper })
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
        // A helper call still in flight has landed before `reads` is taken, however slow the runner; a poll still
        // running would tick in the 100 ms after.
        #expect(await waitUntil { !model.checkingHelper })
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
        // ...or while the uninstall sheet is up, which a confirmed uninstall closes before it starts.
        model.perform(.uninstall, on: [tree])
        #expect(model.confirmingRemoval)
        model.installRequests([request])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(await Self.uninstallPicks(model) == ["tree"])
        model.uninstall.confirm()
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
        model.uninstall.cancel()
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

    /// What `brew outdated` gives right after an install while Homebrew's own post-install still holds its lock.
    static let homebrewLocked = EngineError(engine: .homebrew,
                                            message: "brew outdated failed (exit 1): lockf: 200: already locked")

    final class Sleeps: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [Duration] = []
        var all: [Duration] { lock.withLock { _all } }
        func add(_ duration: Duration) { lock.withLock { _all.append(duration) } }
    }

    /// A model whose Updates answers with Homebrew's lock error, after an install run that ended.
    func lockedAfterARun(sleep: @escaping @Sendable (FakeCatalog, Duration) async -> Void) async
        -> (BrewxPortAppModel, FakeCatalog) {
        let catalog = FakeCatalog()
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .failure(Self.homebrewLocked)))
        model.listLockRetrySleep = { await sleep(catalog, $0) }
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        return (model, catalog)
    }

    @Test func homebrewLockRightAfterARunRetriesTheListsOnceAfterTwoSeconds() async {
        let sleeps = Sleeps()
        let (model, _) = await lockedAfterARun { catalog, duration in
            sleeps.add(duration)
            // Homebrew's post-install lets go of the lock meanwhile.
            catalog.script(.outdated, .homebrew, packages: [])
        }
        #expect(await waitUntil { model.listReloadCount == 2 && !model.updates.list.loading })
        #expect(sleeps.all == [.seconds(2)])
        #expect(model.updates.list.errors.isEmpty)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.listReloadCount == 2)
    }

    @Test func homebrewLockThatStaysIsRetriedOnlyOnce() async {
        let sleeps = Sleeps()
        let (model, _) = await lockedAfterARun { _, duration in sleeps.add(duration) }
        #expect(await waitUntil { model.listReloadCount == 2 && !model.updates.list.loading })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.listReloadCount == 2)
        #expect(sleeps.all == [.seconds(2)])
        #expect(model.updates.list.errors == ["Homebrew: brew outdated failed (exit 1): lockf: 200: already locked"])
    }

    @Test func otherHomebrewErrorsAfterARunAreNotRetried() async {
        let sleeps = Sleeps()
        let catalog = FakeCatalog()
        let executor = FakeRunExecutor(events: [.started(0), .finished(0, 0), .done])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, executor: executor))
        catalog.script(.outdated, .homebrew, FakeCatalog.Script(
            result: .failure(EngineError(engine: .homebrew, message: "brew outdated failed (exit 1): Error: no network"))))
        model.listLockRetrySleep = { sleeps.add($0) }
        _ = await F.source([F.package(.homebrew, .formula, "wget")], in: model)
        model.perform(.install, on: [F.wget])
        #expect(await waitUntil { model.listReloadCount == 1 && !model.updates.list.loading })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.listReloadCount == 1)
        #expect(sleeps.all.isEmpty)
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

    /// The person's Refresh and the engine page's Check again ask the login shell again (the engines' detects then
    /// read it), so a PATH fixed meanwhile is read; a background check's reload and a run's end don't.
    @Test func personsRefreshAndCheckAgainReadTheShellAgain() async {
        final class RecordingPath: PathResolving, @unchecked Sendable {
            private let lock = NSLock()
            private var asked = 0
            var askedAgain: Int { lock.withLock { asked } }
            func resolve() async -> ResolvedPath { ResolvedPath(entries: ["/usr/bin"], source: .systemDefault) }
            func askAgain() { lock.withLock { asked += 1 } }
        }
        let path = RecordingPath()
        let model = BrewxPortAppModel(services: F.services(path: path))
        model.refreshLists()
        #expect(path.askedAgain == 0)
        #expect(await waitUntil { !model.updates.list.loading })
        model.refresh()
        #expect(path.askedAgain == 1)
        #expect(model.listReloadCount == 2)
        #expect(await waitUntil { !model.updates.list.loading })
        await model.background.checkNow()
        #expect(path.askedAgain == 1)
        model.checkEnginesAgain()
        #expect(path.askedAgain == 2)
        #expect(await waitUntil { model.enginesChecked })
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

    /// Final review: every language engine refuses extra arguments, so a language tool's inspector has no Extra
    /// arguments field (and with no version or variants, no options section at all). Homebrew's still has it.
    @Test func inspectorHasNoExtraArgumentsForLanguageTools() async {
        let cowsay = Package(id: PackageRef(engine: .npm, kind: .tool, name: "cowsay"), displayName: "cowsay",
                             latestVersion: "1.6.0")
        let wget = F.package(.homebrew, .formula, "wget")
        let catalog = FakeCatalog()
        catalog.script(.search("w"), .npm, packages: [cowsay])
        catalog.script(.search("w"), .homebrew, packages: [wget])
        catalog.scriptInfo(cowsay.id, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: cowsay.id))))
        catalog.scriptInfo(wget.id, FakeCatalog.InfoScript(result: .success(PackageDetails(ref: wget.id))))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog,
                                                          engines: PlanFixtures.engines + [FakeLanguageEngine(.npm)]))
        model.discover.query = "w"
        model.discover.submit()
        #expect(await waitUntil { !model.discover.searching })
        model.perform(.showDetails, on: [cowsay.id])
        #expect(await waitUntil { model.details.details?.ref == cowsay.id })
        #expect(model.inspectorOptions == InspectorOptionFields(version: false, extraArgs: false, variants: []))
        model.perform(.showDetails, on: [wget.id])
        #expect(await waitUntil { model.details.details?.ref == wget.id })
        #expect(model.inspectorOptions == InspectorOptionFields(version: false, extraArgs: true, variants: []))
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

    /// The picks' names once the uninstall sheet has its plan, every manager's, in order; nil when there's no plan.
    static func uninstallPicks(_ model: BrewxPortAppModel) async -> [String]? {
        _ = await waitUntil { if case .checking = model.uninstall.state { false } else { true } }
        guard case .ready(let plan) = model.uninstall.state else { return nil }
        return plan.sections.flatMap(\.picks).map(\.id.name)
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
        #expect(await Self.uninstallPicks(model) == ["wget"])
        #expect(executor.runs.isEmpty)
        model.uninstall.confirm()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.operation) == [.remove])
        #expect(Self.names(executor.runs[0].steps) == ["wget"])

        // The toolbar's Remove N acts on the checked rows, also after the confirmation.
        await model.installed.settled()
        model.installed.list.selection.checked = [F.jq]
        #expect(model.installed.removeTitle == "Remove 1")
        #expect(model.canRemoveChecked)
        model.removeChecked()
        #expect(await Self.uninstallPicks(model) == ["jq"])
        model.uninstall.cancel()
        #expect(executor.runs.count == 1)
    }

    @Test func installedRowMenuActsOnInstalledRows() async {
        let catalog = Self.installedCatalog([F.package(.homebrew, .formula, "wget", installed: "1")])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        await model.installed.settled()
        #expect(model.package(for: F.wget)?.installedVersion == "1")
        model.perform(.uninstall, on: [F.wget])
        #expect(await Self.uninstallPicks(model) == ["wget"])
        model.uninstall.cancel()
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
        #expect(await Self.uninstallPicks(model) == ["wget"])
        model.uninstall.cancel()

        model.sidebar = .installed
        model.installed.list.selection.selected = [F.jq]
        #expect(model.canRemoveSelection)
        model.removeSelection()
        #expect(await Self.uninstallPicks(model) == ["jq"])
        model.uninstall.cancel()

        // Discover offers no removal; a selected Discover row is left alone.
        _ = await F.source([F.package(.homebrew, .formula, "curl")], in: model)
        model.sidebar = .discover
        #expect(!model.canRemoveSelection)
        model.removeSelection()
        #expect(model.uninstall.state == .hidden)
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
        #expect(await Self.uninstallPicks(model) == ["jq"])

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

        // The sheet still names jq, and Uninstall removes jq.
        #expect(await Self.uninstallPicks(model) == ["jq"])
        model.uninstall.confirm()
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.operation) == [.remove])
        #expect(Self.names(executor.runs[0].steps) == ["jq"])
        #expect(!model.confirmingRemoval)
    }

    @Test func nothingRunsBehindTheSetupSheet() async {
        // No package manager was found, so the launch shows the setup offer as a sheet.
        let catalog = FakeCatalog(engines: [.homebrew: .missing, .macports: .missing, .nanobrew: .missing,
                                            .mas: .missing])
        let executor = FakeRunExecutor()
        let services = F.services(catalog: catalog, executor: executor, helper: FakeHelperManager())
        let model = await F.updatesModel([F.package(.homebrew, .formula, "wget")], catalog: catalog,
                                         services: services)
        model.start()
        #expect(await waitUntil { model.setup.sheetShown })
        // The menu bar's Update items are off, and no run starts under it (automatic ones included).
        #expect(model.modalUp)
        #expect(!model.canMenuUpdate)
        #expect(!model.installRequests(model.updates.updateAllRequests(), origin: .background))
        #expect(executor.runs.isEmpty)
        // Its own Set up button still works.
        #expect(model.canSetUpEngines)
        // A file the Finder opens waits for it, then opens once it's gone.
        let file = URL(fileURLWithPath: "/tmp/BrewxPortTests-none.brewxportbundle")
        model.openFromFinder(file)
        #expect(model.pendingOpenURL == file)
        model.setup.notNow()
        #expect(await waitUntil { model.pendingOpenURL == nil })
        #expect(model.sidebar == .bundles)
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

/// A login shell that answers with `environment` and records, in order, each time it's read ("resolve") and each time
/// it's asked to answer again ("askAgain"). With `resolveGate` set, a read waits for it after recording itself.
final class ShellRecorder: PathResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var _environment: [String: String]
    private var _resolveGate: Gate?

    init(environment: [String: String] = [:]) { _environment = environment }

    var events: [String] { lock.withLock { recorded } }
    var environment: [String: String] {
        get { lock.withLock { _environment } }
        set { lock.withLock { _environment = newValue } }
    }
    var resolveGate: Gate? {
        get { lock.withLock { _resolveGate } }
        set { lock.withLock { _resolveGate = newValue } }
    }

    func resolve() async -> ResolvedPath {
        let gate = lock.withLock { () -> Gate? in
            recorded.append("resolve")
            return _resolveGate
        }
        if let gate { await gate.wait() }
        return ResolvedPath(entries: ["/opt/homebrew/bin", "/usr/bin"], source: .loginShell, environment: environment)
    }

    func askAgain() { lock.withLock { recorded.append("askAgain") } }
}
