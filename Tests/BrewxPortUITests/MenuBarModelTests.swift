import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@MainActor @Suite struct MenuBarModelTests {
    typealias F = AppFixtures
    typealias Item = MenuBarItem

    /// Counts the model's requests for the main window, and whether a run was going at each.
    @MainActor final class Opens {
        var count = 0
        var duringRun: [Bool] = []
    }

    /// The model, its executor, and the window requests it made.
    @MainActor struct Harness {
        let model: BrewxPortAppModel
        let executor: FakeRunExecutor
        let opens: Opens
        var items: [MenuBarItem] { MenuBarItems.make(model: model, timeZone: MenuBarModelTests.zone) }
    }

    /// The fixed time zone the times are shown in, so the tests don't depend on this Mac's.
    static let zone = TimeZone(identifier: "Europe/Paris")!

    /// 26 November 2026 at `hour`:`minute` in `zone`.
    static func date(day: Int = 26, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// A live-mode model (with a helper, so MacPorts steps run) whose Updates page holds `packages`.
    func harness(_ packages: [Package], executor: FakeRunExecutor = FakeRunExecutor()) async -> Harness {
        let catalog = FakeCatalog()
        let services = F.services(catalog: catalog, executor: executor, helper: FakeHelperManager())
        let model = await F.updatesModel(packages, catalog: catalog, services: services)
        let opens = Opens()
        model.openMainWindow = { [weak model] in
            opens.count += 1
            opens.duringRun.append(model?.run.isRunning ?? false)
        }
        return Harness(model: model, executor: executor, opens: opens)
    }

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1",
                latestVersion: "2")
    }

    let wget = package(.homebrew, .formula, "wget")
    let jq = package(.homebrew, .formula, "jq")
    let firefox = package(.homebrew, .cask, "firefox")
    let ada = package(.nanobrew, .formula, "ada")
    let curl = package(.macports, .port, "curl")
    let keynote = package(.mas, .app, "409183694")

    /// Everything below the updates: the times, Check Now, then Open BrewxPort, Settings… and Quit.
    static func tail(times: String = "Not checked yet", checkNow: Bool = true) -> [Item] {
        [.divider, .text(times), .button("Check Now", .checkNow, enabled: checkNow), .divider,
         .button("Open BrewxPort", .openWindow), .button("Settings…", .openSettings),
         .button("Quit BrewxPort (stops update checks)", .quit)]
    }

    // MARK: Items

    @Test func itemsPerManagerWithCounts() async {
        let h = await harness([wget, jq, ada, curl, keynote])
        // In the engine order (nanobrew first on Apple silicon), only managers with updates, with how many.
        #expect(h.items == [
            .text("5 updates"),
            .button("nanobrew  1  Update", .update(.nanobrew)),
            .button("Homebrew  2  Update", .update(.homebrew)),
            .button("MacPorts  1  Update…", .update(.macports)),
            .button("Mac App Store  1  Update…", .update(.mas)),
            .button("Update All…", .update(nil)),
        ] + Self.tail())

        // Ignored and skipped rows don't count, as on Updates.
        h.model.perform(.ignore, on: [jq.id])
        h.model.perform(.skipVersion("2"), on: [keynote.id])
        #expect(Array(h.items.prefix(5)) == [
            .text("3 updates"),
            .button("nanobrew  1  Update", .update(.nanobrew)),
            .button("Homebrew  1  Update", .update(.homebrew)),
            .button("MacPorts  1  Update…", .update(.macports)),
            .button("Update All…", .update(nil)),
        ])
        h.model.perform(.ignore, on: [wget.id, curl.id])
        #expect(Array(h.items.prefix(3)) == [
            .text("1 update"),
            .button("nanobrew  1  Update", .update(.nanobrew)),
            .button("Update All", .update(nil)),
        ])

        // Off while something modal is up.
        h.model.run.showingPasswordSheet = true
        #expect(h.items[1] == .button("nanobrew  1  Update", .update(.nanobrew), enabled: false))
        #expect(h.items[2] == .button("Update All", .update(nil), enabled: false))
        h.model.run.showingPasswordSheet = false
        #expect(h.items[1] == .button("nanobrew  1  Update", .update(.nanobrew)))
    }

    @Test func passwordManagersShowEllipsis() async {
        // Formulae and nanobrew need no password: no ellipsis anywhere.
        let free = await harness([wget, ada])
        #expect(Array(free.items.prefix(4)) == [
            .text("2 updates"),
            .button("nanobrew  1  Update", .update(.nanobrew)),
            .button("Homebrew  1  Update", .update(.homebrew)),
            .button("Update All", .update(nil)),
        ])

        // A cask is a Homebrew update that needs the password (its route, not the manager's name, decides).
        let cask = await harness([wget, firefox, ada])
        #expect(Array(cask.items.prefix(4)) == [
            .text("3 updates"),
            .button("nanobrew  1  Update", .update(.nanobrew)),
            .button("Homebrew  2  Update…", .update(.homebrew)),
            .button("Update All…", .update(nil)),
        ])

        // Only the cask: still Homebrew, still the password.
        let only = await harness([firefox])
        #expect(Array(only.items.prefix(3)) == [
            .text("1 update"),
            .button("Homebrew  1  Update…", .update(.homebrew)),
            .button("Update All…", .update(nil)),
        ])
    }

    @Test func upToDateShowsHeaderOnly() async {
        let h = await harness([])
        #expect(h.items == [.text("Everything is up to date")] + Self.tail())

        // Never "up to date" while the first answers are still coming, or when a manager couldn't be checked.
        let gate = Gate()
        let catalog = FakeCatalog()
        catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .success([]), gate: gate))
        catalog.script(.outdated, .macports,
                       FakeCatalog.Script(result: .failure(EngineError(engine: .macports, message: "port failed"))))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        #expect(MenuBarItems.make(model: model).first == .text("Checking for updates…"))
        _ = await waitUntil { gate.waiting == 1 }
        gate.release()
        #expect(await waitUntil { !model.updates.list.loading })
        #expect(MenuBarItems.make(model: model).first == .text("No updates found. Couldn't check MacPorts"))
    }

    /// R6: a manager whose check answered but couldn't look some packages up isn't "couldn't check" here (only one that
    /// failed as a whole is), but nothing is "up to date" either: the menu follows Updates' own empty page
    /// (`UpdatesModel.emptyTitle`), and names the managers it couldn't fully check.
    @Test func partialCheckIsntCouldntCheck() async {
        let catalog = FakeCatalog()
        catalog.script(.outdated, .pipx, FakeCatalog.Script(
            result: .success([]), unchecked: UncheckedPackages(reasons: ["black": "PyPI didn't answer"])))
        catalog.script(.outdated, .cargo, FakeCatalog.Script(
            result: .success([]), unchecked: UncheckedPackages(reasons: ["ripgrep": "crates.io didn't answer"])))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.list.unchecked[.pipx] != nil })
        #expect(MenuBarItems.make(model: model).first
                == .text("Nothing else to update. Some pipx and Cargo tools couldn't be checked"))
        #expect(model.updates.emptyTitle == "Nothing else to update")
    }

    /// Final review: updates held from every update (here Cargo's "Needs Rust") leave nothing to update, but they're
    /// still updates: "Nothing else to update", as on Updates, never "Everything is up to date".
    @Test func heldUpdatesArentUpToDate() async {
        let catalog = FakeCatalog()
        let ripgrep = Package(id: PackageRef(engine: .cargo, kind: .tool, name: "ripgrep"), displayName: "ripgrep",
                              installedVersion: "14.1.0", latestVersion: "16.0.0")
        let hold = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        catalog.script(.outdated, .cargo, FakeCatalog.Script(result: .success([]),
                                                             held: [HeldUpdate(package: ripgrep, hold: hold)]))
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        model.refreshLists()
        #expect(await waitUntil { !model.updates.list.loading && model.updates.list.byRef[ripgrep.id] != nil })
        #expect(MenuBarItems.make(model: model).first == .text("Nothing else to update"))
    }

    @Test func refreshMacPortsBelowCheckNowWhenMacPortsWorks() async throws {
        let portPresent = EngineStatus.present(path: URL(fileURLWithPath: PlanFixtures.portPath), version: "2.12.7")
        let catalog = FakeCatalog(engines: [.macports: portPresent])
        let model = BrewxPortAppModel(services: F.services(catalog: catalog, helper: FakeHelperManager()))
        #expect(!MenuBarItems.make(model: model).contains(.button("Refresh MacPorts…", .refreshMacPorts)))
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        let items = MenuBarItems.make(model: model, timeZone: Self.zone)
        let checkNow = try #require(items.firstIndex(of: .button("Check Now", .checkNow)))
        #expect(items[checkNow + 1] == .button("Refresh MacPorts…", .refreshMacPorts))
        model.run.showingPasswordSheet = true
        #expect(MenuBarItems.make(model: model).contains(.button("Refresh MacPorts…", .refreshMacPorts,
                                                                 enabled: false)))
    }

    // MARK: Update from the menu

    /// Waits for run `count` to end and for the lists its end reloads (Update is off until they're back).
    func runEnded(_ h: Harness, count: Int) async -> Bool {
        await waitUntil { h.executor.runs.count == count && !h.model.run.isRunning && !h.model.updates.list.loading }
    }

    @Test func menuUpdateWorksFromBundlesPage() async throws {
        let h = await harness([wget, jq, ada, curl])
        // Bundles was the last page open: the window's own Update does nothing there.
        h.model.sidebar = .bundles
        h.model.updateAll(engine: .homebrew)
        #expect(h.executor.runs.isEmpty)

        // The menu's does: on Updates, as the person's run, without opening the window (no password needed).
        h.model.menuUpdate(engine: .homebrew)
        #expect(h.model.sidebar == .updates)
        try #require(await runEnded(h, count: 1))
        #expect(BrewxPortAppModelTests.names(h.executor.runs[0].steps) == ["jq", "wget"])
        #expect(h.executor.runs[0].steps.allSatisfy { $0.engine == .homebrew })
        #expect(h.model.lastRunOrigin == .user)
        #expect(h.opens.count == 0)

        // Update All… needs the password (MacPorts): the window opens first, for the sheet, before the run starts.
        h.model.sidebar = .bundles
        h.model.menuUpdate(engine: nil)
        #expect(h.model.sidebar == .updates)
        try #require(await runEnded(h, count: 2))
        #expect(Set(h.executor.runs[1].steps.map(\.engine)) == [.homebrew, .nanobrew, .macports])
        #expect(h.opens.duringRun == [false])

        // A manager that needs the password does the same.
        h.model.menuUpdate(engine: .macports)
        try #require(await runEnded(h, count: 3))
        #expect(h.executor.runs[2].steps.allSatisfy { $0.engine == .macports })
        #expect(h.opens.duringRun == [false, false])
    }

    @Test func menuUpdateStillShowsWindow() async throws {
        // The menu is a click: the window comes forward with `openMainWindow` (`MainWindow.show()`), never through
        // the background password run's `presentForPassword`, whatever that would say.
        let h = await harness([curl])
        let presents = Opens()
        h.model.presentForPassword = {
            presents.count += 1
            return false
        }
        h.model.menuUpdate(engine: .macports)
        try #require(await runEnded(h, count: 1))
        #expect(h.opens.duringRun == [false])
        #expect(presents.count == 0)
        MenuBarItems.perform(.openWindow, model: h.model)
        #expect(h.opens.count == 2)
        #expect(presents.count == 0)
    }

    @Test func menuUpdateSkipsIgnoredRows() async throws {
        let h = await harness([wget, jq, ada])
        h.model.perform(.ignore, on: [jq.id])
        h.model.perform(.skipVersion("2"), on: [ada.id])
        h.model.menuUpdate(engine: .homebrew)
        try #require(await runEnded(h, count: 1))
        #expect(BrewxPortAppModelTests.names(h.executor.runs[0].steps) == ["wget"])
        // Update All too: neither the ignored nor the skipped row.
        h.model.menuUpdate(engine: nil)
        try #require(await runEnded(h, count: 2))
        #expect(h.executor.runs[1].steps.flatMap(\.spec.arguments).filter { ["wget", "jq", "ada"].contains($0) }
                == ["wget"])
    }

    @Test func menuRefreshMacPortsOpensWindowAndRuns() async throws {
        let portPresent = EngineStatus.present(path: URL(fileURLWithPath: PlanFixtures.portPath), version: "2.12.7")
        let executor = FakeRunExecutor()
        let model = BrewxPortAppModel(services: F.services(catalog: FakeCatalog(engines: [.macports: portPresent]),
                                                           executor: executor, helper: FakeHelperManager()))
        let opens = Opens()
        model.openMainWindow = { [weak model] in
            opens.count += 1
            opens.duringRun.append(model?.run.isRunning ?? false)
        }
        // Not while it can't run (MacPorts not checked yet, then a sheet up): no window, no run.
        MenuBarItems.perform(.refreshMacPorts, model: model)
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        model.run.showingPasswordSheet = true
        MenuBarItems.perform(.refreshMacPorts, model: model)
        #expect(opens.count == 0)
        #expect(executor.runs.isEmpty)
        model.run.showingPasswordSheet = false
        // The window first (the password sheet is in it), then the refresh run.
        MenuBarItems.perform(.refreshMacPorts, model: model)
        #expect(opens.duringRun == [false])
        #expect(await waitUntil { executor.runs.count == 1 && !model.run.isRunning })
        #expect(executor.runs[0].steps.map(\.spec.arguments) == [["-N", "selfupdate"]])
        #expect(model.lastRunOrigin == .user)
    }

    @Test func menuUpdateDoesNothingWhenItCantRun() async {
        let h = await harness([wget], executor: FakeRunExecutor(events: [.started(0)], hang: true))
        h.model.sidebar = .installed
        h.model.run.showingPasswordSheet = true
        h.model.menuUpdate(engine: .homebrew)
        // Nothing ran, and the page wasn't changed under the sheet.
        #expect(h.executor.runs.isEmpty)
        #expect(h.model.sidebar == .installed)
        h.model.run.showingPasswordSheet = false
        h.model.menuUpdate(engine: .homebrew)
        #expect(await waitUntil { h.executor.runs.count == 1 })
        // Not during a run either; and a manager with nothing to update does nothing.
        h.model.menuUpdate(engine: .homebrew)
        h.model.run.cancel()
        #expect(await waitUntil { !h.model.run.isRunning })
        h.model.menuUpdate(engine: .macports)
        #expect(h.executor.runs.count == 1)
        #expect(h.opens.count == 0)
    }

    @Test func runningShowsProgressItem() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let h = await harness([wget, jq, ada], executor: executor)
        h.model.menuUpdate(engine: .homebrew)
        #expect(await waitUntil { h.model.run.steps.first?.state == .running })
        // The updates give way to the step that's running and Show (which opens the window, with the run panel).
        #expect(h.items == [.text("Updating… Homebrew: jq, wget"), .button("Show", .openWindow)] + Self.tail())
        executor.finish([.finished(0, 0), .done])
        #expect(await waitUntil { !h.model.run.isRunning })
        #expect(h.items.first == .text("3 updates"))

        // Before a step starts (the password, the helper check): just "Updating…". A run that isn't only updates
        // says "Running…".
        executor.events = []
        h.model.installRequests([ActionRequest(operation: .upgrade, package: ada)])
        #expect(await waitUntil { h.model.run.isRunning })
        #expect(h.items.first == .text("Updating…"))
        executor.finish()
        #expect(await waitUntil { !h.model.run.isRunning })
        h.model.installRequests([ActionRequest(operation: .install, package: Self.package(.homebrew, .formula, "fd"))])
        #expect(await waitUntil { h.model.run.isRunning })
        #expect(h.items.first == .text("Running…"))
        executor.finish()
        #expect(await waitUntil { !h.model.run.isRunning })

        // The icon: the count, or a progress dot during a run.
        #expect(MenuBarLabel.badge(count: 3, running: false) == "3")
        #expect(MenuBarLabel.badge(count: 0, running: false) == nil)
        #expect(MenuBarLabel.badge(count: 3, running: true) == "•")
        #expect(MenuBarLabel.badge(count: 0, running: true) == "•")
    }

    @Test func waitingForPasswordShowsInMenuAndPanel() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], executor: executor)
        // The automatic password run, whose sheet shows only while BrewxPort is active with its window key.
        h.model.run.canPresentPasswordSheet = { false }
        h.model.run.nextRunPromptNeedsFocus = true
        h.model.installRequests([ActionRequest(operation: .upgrade, package: curl)])
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(h.items.first == .text("Updating…"))
        #expect(h.model.run.headline == "Running")
        // It asks while the person is elsewhere: the menu and the run panel say what it's waiting for.
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.passwordWaitsForFocus })
        #expect(h.items == [.text("Waiting for your password"), .button("Show", .openWindow)] + Self.tail())
        #expect(h.model.run.headline == "Waiting for your password")
        h.model.run.cancel()
        #expect(await prompt.value == nil)
        #expect(await waitUntil { !h.model.run.isRunning })
        #expect(h.model.run.headline != "Waiting for your password")
    }

    @Test func checkedAndNextTimesFormatted() async {
        let h = await harness([])
        let background = h.model.background!
        background.now = { Self.date(10, 42) }
        #expect(h.items == [.text("Everything is up to date")] + Self.tail(times: "Not checked yet"))
        // Scheduled every 12 hours from 10:42; not checked yet.
        background.scheduleFromSettings()
        #expect(h.items[2] == .text("Not checked yet. Next check 22:42"))
        await background.checkNow()
        #expect(h.items[2] == .text("Checked 10:42. Next check 22:42"))
        // A check due tomorrow says so; one from yesterday too; further off, the date.
        background.settings.interval = .daily
        background.scheduleFromSettings()
        #expect(h.items[2] == .text("Checked 10:42. Next check tomorrow 10:42"))
        background.now = { Self.date(day: 27, 9, 5) }
        #expect(h.items[2] == .text("Checked yesterday 10:42. Next check 10:42"))
        background.now = { Self.date(day: 29, 9, 5) }
        #expect(h.items[2] == .text("Checked 26 Nov 10:42. Next check 27 Nov 10:42"))
        // No schedule (checks off, or the demo): only when it was checked.
        background.settings.interval = .never
        background.scheduleFromSettings()
        background.now = { Self.date(10, 50) }
        #expect(h.items[2] == .text("Checked 10:42"))
        #expect(h.items[3] == .button("Check Now", .checkNow))
    }

    @Test func quitWithTheOneTimeSheetUpClosesItUnseen() async {
        // AppKit doesn't quit while a sheet is on the window, so Quit would do nothing. The one-time sheet goes first,
        // without counting as seen: it comes back at the next launch.
        let h = await harness([wget])
        h.model.mainWindowShowing = true
        h.model.start()
        #expect(await waitUntil { h.model.showingBackgroundIntro })
        h.model.prepareToQuit()
        #expect(!h.model.showingBackgroundIntro)
        #expect(!h.model.background.settings.introShown)
        #expect(h.opens.count == 0)
        // It doesn't come straight back while BrewxPort quits.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!h.model.showingBackgroundIntro)
    }

    @Test func quitWithAPasswordSheetUpShowsIt() async {
        // Any other sheet needs an answer first: the window comes forward with it, so Quit isn't silent.
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], executor: executor)
        h.model.menuUpdate(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 1 })
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.showingPasswordSheet })
        let opens = h.opens.count
        h.model.prepareToQuit()
        #expect(h.opens.count == opens + 1)
        h.model.run.finishPassword(nil)
        _ = await prompt.value
        h.model.run.cancel()
        // Nothing up: Quit just quits, and the window stays where it is.
        #expect(await waitUntil { !h.model.run.isRunning && !h.model.modalUp })
        h.model.prepareToQuit()
        #expect(h.opens.count == opens + 1)
    }

    @Test func checkNowIsOffWhileChecking() async {
        let gate = Gate()
        let catalog = FakeCatalog()
        let model = BrewxPortAppModel(services: F.services(catalog: catalog))
        catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .success([wget]), gate: gate))
        let check = Task { await model.background.checkNow() }
        #expect(await waitUntil { gate.waiting == 1 })
        #expect(MenuBarItems.make(model: model).contains(.button("Check Now", .checkNow, enabled: false)))
        gate.release()
        await check.value
        #expect(MenuBarItems.make(model: model).contains(.button("Check Now", .checkNow)))
    }

    // MARK: Demo

    @Test func demoCheckNowFindsFixtureUpdatesAgain() async throws {
        let model = BrewxPortAppModel(services: try DemoServices.make(DemoTests.options(), delay: .zero))
        model.start()
        let adaURL = DemoTests.adaURL
        // Homebrew's three, MacPorts' figlet, npm's two, pipx's two, uv's isort, Cargo's ripgrep, Bun's two,
        // RubyGems' lolcat and thor (never Ruby's own bundled gems) and Mint's JohnSundell/Ink.
        #expect(await waitUntil {
            !model.updates.list.loading && model.updates.badgeCount == 15 && !model.installed.list.loading
                && model.installed.list.byRef[adaURL] != nil
        })
        let launchVersion = try #require(model.installed.list.byRef[adaURL]?.package.installedVersion)
        #expect(MenuBarItems.make(model: model).first == .text("15 updates"))

        // Homebrew's three formulae need no password, so the demo run finishes by itself.
        model.menuUpdate(engine: .homebrew)
        #expect(await waitUntil { model.run.runNumber == 1 && !model.run.isRunning })
        #expect(await waitUntil { !model.updates.list.loading && model.updates.badgeCount == 12 })
        #expect(await waitUntil {
            model.installed.list.byRef[adaURL]?.package.installedVersion != launchVersion
        })

        // Check Now reads the fixtures again: the updates are back, and Installed agrees with them.
        await model.background.checkNow()
        #expect(model.updates.badgeCount == 15)
        #expect(MenuBarItems.make(model: model).first == .text("15 updates"))
        #expect(await waitUntil {
            !model.installed.list.loading && model.installed.list.byRef[adaURL]?.package.installedVersion == launchVersion
        })
    }
}
