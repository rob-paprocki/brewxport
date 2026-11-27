import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@MainActor @Suite struct BackgroundUpdaterTests {
    typealias F = AppFixtures

    static let twelveHours: TimeInterval = 12 * 3600
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let later = start.addingTimeInterval(3600)

    /// Counts the model's requests for the main window.
    @MainActor final class Counter { var count = 0 }

    /// The app's `presentForPassword`: whether macOS made BrewxPort the active app with its window key, and how
    /// often it was asked.
    @MainActor final class Presenter {
        var allowed = true
        var count = 0
    }

    /// The model and every fake behind it.
    @MainActor struct Harness {
        let model: BrewxPortAppModel
        let catalog: FakeCatalog
        let executor: FakeRunExecutor
        let scheduler: FakeScheduler
        let notifier: FakeNotifier
        let conditions: FakeConditions
        /// The window coming up for the person: `openMainWindow`, or a `presentForPassword` that worked.
        let windowOpens: Counter
        let presenter: Presenter

        var background: BackgroundUpdater { model.background }
        /// "N updates available" posts.
        var available: [FakeNotifier.Post] { notifier.posts.filter { $0.id == BackgroundUpdater.availableID } }
        /// "N updates need your password" posts.
        var needsPassword: [FakeNotifier.Post] { notifier.posts.filter { $0.id == BackgroundUpdater.passwordID } }
        /// Posts after automatic runs.
        var summaries: [FakeNotifier.Post] { notifier.posts.filter { $0.target == .runLog } }
        /// "N updates need your attention" posts: updates left out of an automatic run because of an ignored or
        /// skipped package.
        var attention: [FakeNotifier.Post] { notifier.posts.filter { $0.id == BackgroundUpdater.attentionID } }
    }

    /// Homebrew and MacPorts with canned dependents (real commands), for the ignored-and-skipped relations.
    @MainActor struct Related {
        let catalog = FakeCatalog()
        let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        let port = MoveFakeEngine(wrapping: PlanFixtures.engines[2])
        var engines: [any Engine] { [brew, PlanFixtures.engines[1], port, PlanFixtures.engines[3]] }

        /// What `info` says `name` needs.
        func needs(_ engine: EngineID, _ name: String, _ dependencies: [String]) {
            let ref = PackageRef(engine: engine, kind: engine == .macports ? .port : .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: dependencies))))
        }

        /// Installed lists `packages`, each asked for.
        func installed(_ engine: EngineID, _ packages: [Package]) {
            catalog.script(.installed, engine, packages: packages.map {
                var package = $0
                package.installedOnRequest = true
                return package
            })
        }
    }

    /// A live-mode model (with a helper, so MacPorts steps really run) whose Updates page already holds `packages`.
    /// The clock reads `start`; the wait for the person polls every 10 ms.
    func harness(_ packages: [Package], mode: AutoUpdateMode = .notify, isAdministrator: Bool? = true,
                 executor: FakeRunExecutor = FakeRunExecutor(), store: MemoryStore = MemoryStore(),
                 conditions: FakeConditions = FakeConditions(), isDemo: Bool = false,
                 engines: [any Engine] = PlanFixtures.engines, catalog: FakeCatalog = FakeCatalog()) async -> Harness {
        let scheduler = FakeScheduler()
        let notifier = FakeNotifier()
        let services = F.services(catalog: catalog, executor: executor, helper: FakeHelperManager(), isDemo: isDemo,
                                  isAdministrator: isAdministrator, store: store, engines: engines,
                                  scheduler: scheduler, notifier: notifier, conditions: conditions)
        let model = await F.updatesModel(packages, catalog: catalog, services: services)
        let opens = Counter()
        let presenter = Presenter()
        model.openMainWindow = { opens.count += 1 }
        model.presentForPassword = {
            presenter.count += 1
            if presenter.allowed { opens.count += 1 }
            return presenter.allowed
        }
        model.background.settings.mode = mode
        model.background.now = { Self.start }
        model.background.userPollInterval = .milliseconds(10)
        return Harness(model: model, catalog: catalog, executor: executor, scheduler: scheduler, notifier: notifier,
                       conditions: conditions, windowOpens: opens, presenter: presenter)
    }

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String, latest: String = "2") -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1",
                latestVersion: latest)
    }

    let wget = package(.homebrew, .formula, "wget")
    let jq = package(.homebrew, .formula, "jq")
    let firefox = package(.homebrew, .cask, "firefox")
    let ada = package(.nanobrew, .formula, "ada")
    let curl = package(.macports, .port, "curl")
    let keynote = package(.mas, .app, "409183694")

    /// Ends hanging run `run` with every step succeeding.
    static func succeed(_ executor: FakeRunExecutor, run: Int) {
        let steps = executor.runs[run].steps.indices
        executor.finish(steps.flatMap { [RunEvent.started($0), .finished($0, 0)] } + [.done])
    }

    // MARK: Schedule

    @Test func scheduleUsesTwelveHoursByDefault() async {
        let h = await harness([])
        // Launch schedules the checks, window or not.
        h.model.start()
        #expect(h.scheduler.interval == Self.twelveHours)
        #expect(h.background.nextCheck == Self.start.addingTimeInterval(Self.twelveHours))
        #expect(h.background.lastChecked == nil)
        // The scheduled work is a check, and the next one is timed from its end.
        h.background.now = { Self.later }
        await h.scheduler.fire()
        #expect(h.background.lastChecked == Self.later)
        #expect(h.background.nextCheck == Self.later.addingTimeInterval(Self.twelveHours))
    }

    @Test func neverCancelsSchedule() async {
        let h = await harness([])
        h.background.scheduleFromSettings()
        #expect(h.scheduler.interval == Self.twelveHours)
        h.background.settings.interval = .never
        h.background.scheduleFromSettings()
        #expect(h.scheduler.interval == nil)
        #expect(h.scheduler.work == nil)
        #expect(h.background.nextCheck == nil)
        h.background.settings.interval = .hourly
        h.background.scheduleFromSettings()
        #expect(h.scheduler.interval == 3600)
    }

    @Test func testIntervalComesFromTheModelsCreator() {
        let scheduler = FakeScheduler()
        let model = BrewxPortAppModel(services: F.services(scheduler: scheduler), testIntervalOverride: 120)
        model.background.scheduleFromSettings()
        #expect(scheduler.interval == 120)
        #expect(BrewxPortAppModel(services: F.services()).background.settings.testIntervalOverride == nil)
    }

    /// A model on `store` whose last check finished at `date` (with `wget` outdated), as an earlier launch left it.
    func checked(at date: Date, store: MemoryStore) async {
        let earlier = await harness([wget], store: store)
        earlier.background.now = { date }
        await earlier.background.checkNow()
    }

    @Test func lastCheckSurvivesRelaunch() async {
        let store = MemoryStore()
        await checked(at: Self.start, store: store)
        let next = await harness([wget], store: store)
        #expect(next.background.lastChecked == Self.start)
    }

    @Test func launchChecksWhenOverdue() async {
        // The last check was 13 hours ago (BrewxPort was quit, or the Mac shut down, before the next one came).
        let store = MemoryStore()
        await checked(at: Self.start.addingTimeInterval(-13 * 3600), store: store)
        let h = await harness([wget, jq], store: store)
        h.background.settings.introShown = true
        let reloads = h.model.listReloadCount
        h.model.start()
        // It checks soon after launch, without waiting a full interval, and reads the launch's own load.
        #expect(await waitUntil { h.background.lastChecked == Self.start })
        #expect(h.model.listReloadCount == reloads + 1)
        #expect(h.available.map(\.title) == ["2 updates available"])
        #expect(h.background.nextCheck == Self.start.addingTimeInterval(Self.twelveHours))
        #expect(h.scheduler.firstDelay == Self.twelveHours)

        // Never checked at all (the first launch of this version): the same.
        let first = await harness([wget])
        first.background.settings.introShown = true
        first.model.start()
        #expect(await waitUntil { first.background.lastChecked == Self.start })
        #expect(first.available.count == 1)
    }

    @Test func launchTimesFirstCheckFromTheLastOne() async {
        // Checked 2 hours ago: the next check is due in 10 hours, not 12.
        let store = MemoryStore()
        await checked(at: Self.start.addingTimeInterval(-2 * 3600), store: store)
        let h = await harness([wget], store: store)
        h.background.settings.introShown = true
        h.model.start()
        #expect(h.scheduler.interval == Self.twelveHours)
        #expect(h.scheduler.firstDelay == TimeInterval(10 * 3600))
        #expect(h.background.nextCheck == Self.start.addingTimeInterval(10 * 3600))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.background.lastChecked == Self.start.addingTimeInterval(-2 * 3600))
        await h.scheduler.fire()
        #expect(h.background.lastChecked == Self.start)
        #expect(h.background.nextCheck == Self.start.addingTimeInterval(Self.twelveHours))
    }

    @Test func launchCheckWaitsForTheOneTimeSheet() async {
        // The first launch of this version: the one-time sheet asks about notifications first, so the overdue check
        // waits for it to close (its notice would otherwise go out before macOS was asked, and count as told).
        let h = await harness([wget])
        h.model.mainWindowShowing = true
        h.model.start()
        #expect(await waitUntil { h.model.showingBackgroundIntro })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.background.lastChecked == nil)
        #expect(h.notifier.posts.isEmpty)
        h.model.closeBackgroundIntro()
        #expect(await waitUntil { h.background.lastChecked == Self.start })
        #expect(h.available.count == 1)
    }

    @Test func demoSchedulesNothingButChecksNow() async {
        let h = await harness([wget], isDemo: true)
        h.background.scheduleFromSettings()
        #expect(h.scheduler.interval == nil)
        #expect(h.background.nextCheck == nil)
        await h.background.checkNow()
        #expect(h.available.count == 1)
    }

    // MARK: Notify once

    @Test func checkPostsOneNotificationForNewUpdates() async {
        let h = await harness([wget, jq, curl])
        await h.background.checkNow()
        #expect(h.notifier.posts == [FakeNotifier.Post(id: BackgroundUpdater.availableID, title: "3 updates available",
                                                       body: "Homebrew 2, MacPorts 1", target: .updates)])
        #expect(h.background.lastChecked == Self.start)
        #expect(h.background.state == .idle)
        #expect(h.executor.runs.isEmpty)
    }

    @Test func sameVersionsDoNotNotifyAgain() async {
        let h = await harness([wget, jq])
        await h.background.checkNow()
        await h.background.checkNow()
        #expect(h.available.count == 1)
        // A new version notifies again, counting everything that waits, under the same id (it replaces the last).
        h.catalog.script(.outdated, .macports, packages: [curl])
        await h.background.checkNow()
        #expect(h.available.count == 2)
        #expect(h.available.last?.title == "3 updates available")
        #expect(h.available.last?.body == "Homebrew 2, MacPorts 1")
        #expect(h.available.last?.id == h.available.first?.id)
    }

    /// Final review (R6): a check whose registry lookup failed for one tool leaves it off Updates while pipx still
    /// answers; once it's looked up again at the same version, that's no new notice.
    @Test func toolAPartialCheckMissedDoesNotNotifyAgain() async {
        let black = Self.package(.pipx, .tool, "black", latest: "25.1")
        let h = await harness([wget, black])
        await h.background.checkNow()
        #expect(h.available.map(\.title) == ["2 updates available"])
        h.catalog.script(.outdated, .pipx, FakeCatalog.Script(
            result: .success([]), unchecked: UncheckedPackages(reasons: ["black": "PyPI didn't answer"])))
        await h.background.checkNow()
        #expect(h.model.updates.list.byRef[black.id] == nil)
        h.catalog.script(.outdated, .pipx, packages: [black])
        await h.background.checkNow()
        #expect(h.available.count == 1)
    }

    @Test func ledgerSurvivesRelaunch() async {
        let store = MemoryStore()
        let first = await harness([wget, curl], store: store)
        await first.background.checkNow()
        #expect(first.available.count == 1)
        let second = await harness([wget, curl], store: store)
        await second.background.checkNow()
        #expect(second.available.isEmpty)
        #expect(second.model.updates.badgeCount == 2)
    }

    @Test func newerVersionNotifiesAgain() async {
        let h = await harness([wget])
        await h.background.checkNow()
        #expect(h.available.map(\.title) == ["1 update available"])
        #expect(h.available.first?.body == "Homebrew 1")
        h.catalog.script(.outdated, .homebrew, packages: [Self.package(.homebrew, .formula, "wget", latest: "3")])
        await h.background.checkNow()
        #expect(h.available.map(\.title) == ["1 update available", "1 update available"])
    }

    @Test func notificationsOffStillUpdatesBadge() async {
        let h = await harness([wget])
        h.background.settings.notificationsOn = false
        h.catalog.script(.outdated, .macports, packages: [curl])
        await h.background.checkNow()
        #expect(h.notifier.posts.isEmpty)
        #expect(h.model.updates.badgeCount == 2)
        #expect(h.background.lastChecked == Self.start)
        // What was found while they were off counts as told: turning them on doesn't replay it.
        h.background.settings.notificationsOn = true
        await h.background.checkNow()
        #expect(h.notifier.posts.isEmpty)
    }

    // MARK: Runs

    @Test func checkWaitsForRunningRun() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let h = await harness([wget], executor: executor)
        h.background.scheduleFromSettings()
        h.model.updateAll()
        #expect(await waitUntil { h.model.run.isRunning && executor.runs.count == 1 })
        let reloads = h.model.listReloadCount
        let check = Task { await h.background.checkNow() }
        #expect(await waitUntil { h.background.state == .checking })
        // A scheduled check meanwhile joins the one that's waiting.
        await h.scheduler.fire()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.notifier.posts.isEmpty)
        #expect(h.model.listReloadCount == reloads)
        executor.hang = false
        executor.finish([.finished(0, 0), .done])
        await check.value
        #expect(h.available.count == 1)
        #expect(h.background.lastChecked == Self.start)
        // The run's end reloaded the lists; the check read them and didn't reload them again.
        #expect(h.model.listReloadCount == reloads + 1)
    }

    @Test func autoUpdateNeverStartsDuringRun() async {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let h = await harness([wget, curl], mode: .passwordFree, executor: executor)
        h.background.scheduleFromSettings()
        // The person's own run.
        h.model.updateAll(engine: .macports)
        #expect(await waitUntil { h.model.run.isRunning && executor.runs.count == 1 })
        let fired = Task { await h.scheduler.fire() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        executor.hang = false
        executor.finish([.finished(0, 0), .done])
        await fired.value
        #expect(await waitUntil { executor.runs.count == 2 && !h.model.run.isRunning })
        #expect(Set(executor.runs[1].steps.map(\.engine)) == [.homebrew])
        #expect(h.model.lastRunOrigin == .background)
    }

    @Test func notifyModeNeverRuns() async {
        let h = await harness([wget, ada, curl])
        await h.background.checkNow()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.executor.runs.isEmpty)
        #expect(!h.model.run.isRunning)
        #expect(h.available.map(\.title) == ["3 updates available"])
        #expect(h.windowOpens.count == 0)
    }

    @Test func passwordFreeModeRunsOnlyFormulaeAndNanobrew() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, firefox, ada, curl, keynote], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        let steps = executor.runs[0].steps
        #expect(Set(steps.map(\.engine)) == [.homebrew, .nanobrew])
        #expect(steps.allSatisfy { RunRouting.route(for: $0) == .user })
        let arguments = steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("wget") && arguments.contains("ada") && !arguments.contains("firefox"))
        #expect(h.model.lastRunOrigin == .background)
        #expect(h.background.state == .updating(runNumber: h.model.run.runNumber))
        // The ones that need the password are notified.
        #expect(h.available.map(\.title) == ["3 updates available"])
        #expect(h.available.first?.body == "Homebrew 1, MacPorts 1, Mac App Store 1")
        h.catalog.script(.outdated, .homebrew, packages: [firefox])
        h.catalog.script(.outdated, .nanobrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        #expect(h.summaries.first?.title == "Updated 2")
        #expect(Set(h.summaries.first?.body.components(separatedBy: ", ") ?? []) == ["wget", "ada"])
        #expect(h.background.state == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
    }

    @Test func ignoredAndSkippedNeverAutoUpdate() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, jq, ada, curl], mode: .passwordFree, executor: executor)
        h.model.perform(.ignore, on: [wget.id, curl.id])
        h.model.perform(.skipVersion("2"), on: [jq.id])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("ada") && !arguments.contains("wget") && !arguments.contains("jq"))
        // curl needs the password but is ignored: nothing to notify.
        #expect(h.available.isEmpty)
    }

    // MARK: Ignored and skipped packages an update would bring along (ruling R13)

    @Test func autoRunSkipsPackageWithIgnoredDependent() async {
        // python@3.12 is ignored and depends on openssl@3. `brew upgrade openssl@3` would upgrade python@3.12 too
        // (Homebrew upgrades a formula's outdated dependents), so the automatic run leaves openssl@3 out.
        let r = Related()
        let openssl = Self.package(.homebrew, .formula, "openssl@3")
        let python = Self.package(.homebrew, .formula, "python@3.12")
        r.installed(.homebrew, [openssl, python, jq])
        r.brew.setDependents("openssl@3", ["python@3.12"])
        r.needs(.homebrew, "python@3.12", ["openssl@3"])
        r.needs(.homebrew, "openssl@3", [])
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([openssl, python, jq], mode: .passwordFree, executor: executor, engines: r.engines,
                              catalog: r.catalog)
        h.model.perform(.ignore, on: [python.id])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("jq"))
        #expect(!arguments.contains("openssl@3") && !arguments.contains("python@3.12"))
        // Told instead, once, with its own notice; it isn't counted as available as well.
        #expect(h.attention == [FakeNotifier.Post(
            id: BackgroundUpdater.attentionID, title: "1 update needs your attention",
            body: BackgroundUpdater.attentionBody(count: 1), target: .updates)])
        #expect(h.available.isEmpty)
        // The next check leaves it out again, without telling again.
        h.catalog.script(.outdated, .homebrew, packages: [openssl, python])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 && !h.model.run.isRunning })
        await h.background.checkNow()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.count == 1)
        #expect(h.attention.count == 1)
        #expect(h.available.isEmpty)
    }

    @Test func autoRunSkipsPackageWithSkippedDependency() async {
        // curl needs openssl3, whose new version the person skipped. `port upgrade curl` would upgrade openssl3 first,
        // so Update everything's password run leaves curl out; wget, unrelated, still runs at once.
        let r = Related()
        let openssl = Self.package(.macports, .port, "openssl3")
        r.installed(.macports, [curl, openssl])
        r.installed(.homebrew, [wget])
        r.port.setDependents("openssl3", ["curl"])
        r.needs(.macports, "curl", ["openssl3"])
        r.needs(.macports, "openssl3", [])
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl, openssl], mode: .everything, executor: executor, engines: r.engines,
                              catalog: r.catalog)
        h.model.perform(.skipVersion("2"), on: [openssl.id])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        #expect(h.attention.map(\.title) == ["1 update needs your attention"])
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        // No password run follows: the only update that needed one is left out.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.background.state == .idle)
    }

    @Test func autoRunLeavesOutEveryUpdateWhenRelationsCantBeRead() async {
        // Homebrew can't say what depends on the ignored python@3.12: every Homebrew update is left out (never a
        // guess). nanobrew's ada, with nothing ignored there, still runs.
        let r = Related()
        let openssl = Self.package(.homebrew, .formula, "openssl@3")
        let python = Self.package(.homebrew, .formula, "python@3.12")
        r.installed(.homebrew, [openssl, python, jq])
        r.brew.failDependents("python@3.12")
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([openssl, python, jq, ada], mode: .passwordFree, executor: executor,
                              engines: r.engines, catalog: r.catalog)
        h.model.perform(.ignore, on: [python.id])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.nanobrew])
        #expect(h.attention.map(\.title) == ["2 updates need your attention"])
        #expect(h.available.isEmpty)
    }

    @Test func ignoredCaskLeavesFormulaeAlone() async throws {
        // The usual ignore: an app that updates itself. firefox's details are the real `brew info --json=v2 --cask
        // firefox` capture, read by HomebrewEngine (no formula dependencies), and `brew uses --installed` has nothing
        // for it. Nothing relates it to jq or wget, so they still update by themselves.
        let r = Related()
        r.installed(.homebrew, [firefox, jq, wget])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrewxPortCoreTests/Fixtures/homebrew/info-cask-firefox.json")
        let runner = UIFakeRunner()
        runner.respond(["info", "--json=v2", "--cask", "firefox"],
                       CommandResult(exitCode: 0, stdout: try String(contentsOf: fixture, encoding: .utf8), stderr: ""))
        let engine = HomebrewEngine(runner: runner, executable: URL(fileURLWithPath: PlanFixtures.brewPath),
                                    arch: .arm64)
        r.catalog.scriptInfo(firefox.id, .init(result: .success(try await engine.info(firefox.id))))
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([firefox, jq, wget], mode: .passwordFree, executor: executor, engines: r.engines,
                              catalog: r.catalog)
        h.model.perform(.ignore, on: [firefox.id])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        let arguments = executor.runs[0].steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("jq") && arguments.contains("wget"))
        #expect(r.brew.dependentsCalls == ["firefox"])
        #expect(h.attention.isEmpty)
    }

    @Test func relationsAreOnlyReadWhenAnAutomaticRunCouldStart() async {
        // Notify me never runs anything, so nobody is asked what depends on what.
        let r = Related()
        let python = Self.package(.homebrew, .formula, "python@3.12")
        r.installed(.homebrew, [python, jq])
        let h = await harness([python, jq], engines: r.engines, catalog: r.catalog)
        h.model.perform(.ignore, on: [python.id])
        await h.background.checkNow()
        #expect(r.brew.dependentsCalls.isEmpty)
        #expect(r.catalog.infoCalls.isEmpty)
        #expect(h.available.map(\.title) == ["1 update available"])
    }

    @Test func everythingRunsPasswordPartOnlyWhenActive() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([wget, curl], mode: .everything, executor: executor, conditions: conditions)
        h.model.sidebar = .installed
        await h.background.checkNow()
        // The password-free part runs at once, in the background.
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        #expect(h.model.lastRunOrigin == .background)
        // The password part isn't notified: it runs when the person is back.
        #expect(h.available.isEmpty)
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        #expect(h.summaries.map(\.title) == ["Updated 1"])
        // Away (no input for 15 minutes): several polls go by and nothing opens or runs.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.model.sidebar == .installed)
        // Input again: the window opens on Updates and the password part runs as the person's run.
        conditions.idleSeconds = 5
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(Set(executor.runs[1].steps.map(\.engine)) == [.macports])
        #expect(h.windowOpens.count == 1)
        #expect(h.model.sidebar == .updates)
        #expect(h.model.lastRunOrigin == .user)
        #expect(h.background.state == .updating(runNumber: h.model.run.runNumber))
        h.catalog.script(.outdated, .macports, packages: [])
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { h.summaries.count == 2 })
        #expect(h.background.state == .idle)
    }

    @Test func backgroundPasswordRunNeedsActiveApp() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl, keynote], mode: .everything, executor: executor)
        // At the Mac, but macOS doesn't make BrewxPort the active app (nobody clicked anything of ours): a sheet
        // shown now could take a password typed for another app. No run; a notification asks for a click instead.
        h.presenter.allowed = false
        h.model.sidebar = .installed
        await h.background.checkNow()
        #expect(await waitUntil { h.needsPassword.count == 1 })
        // The window (wherever it is) keeps its page.
        #expect(h.model.sidebar == .installed)
        #expect(h.needsPassword.first == FakeNotifier.Post(
            id: BackgroundUpdater.passwordID, title: "2 updates need your password", body: "MacPorts 1, Mac App Store 1",
            target: .updates))
        #expect(executor.runs.isEmpty)
        #expect(h.presenter.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.available.isEmpty)
        #expect(h.background.state == .waitingForUser(count: 2))
        // It keeps waiting for the click, without trying to take the screen again on every poll.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.presenter.count == 1)
        #expect(executor.runs.isEmpty)
        #expect(h.background.state == .waitingForUser(count: 2))
        // The next check tries once more and, refused again, asks for the click again (ruling R14: once per check's
        // wait, under the same id, so it replaces the last one rather than piling up).
        await h.background.checkNow()
        #expect(await waitUntil { h.presenter.count == 2 })
        #expect(await waitUntil { h.needsPassword.count == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.needsPassword.count == 2)
        #expect(h.needsPassword.last?.id == h.needsPassword.first?.id)
        #expect(h.available.isEmpty)
        #expect(executor.runs.isEmpty)
        #expect(h.background.state == .waitingForUser(count: 2))
        // Switching away from Update everything ends the wait: they now wait like any update, and are told as
        // available, once (the password notice doesn't count as telling them).
        h.background.settings.mode = .notify
        #expect(await waitUntil { h.background.state == .idle })
        #expect(h.available.map(\.title) == ["2 updates available"])
        #expect(h.notifier.posts.count == 3)
        await h.background.checkNow()
        #expect(h.available.count == 1)
    }

    @Test func passwordNotificationClickStartsRun() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        h.presenter.allowed = false
        h.model.sidebar = .installed
        await h.background.checkNow()
        #expect(await waitUntil { h.needsPassword.count == 1 })
        #expect(executor.runs.isEmpty)
        // The person clicks it (a real click, which makes BrewxPort active): the window comes up on Updates, then
        // the password run starts as theirs.
        h.notifier.click(.updates)
        #expect(h.windowOpens.count == 1)
        #expect(h.model.sidebar == .updates)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.macports])
        #expect(h.model.lastRunOrigin == .user)
        #expect(h.background.state == .updating(runNumber: h.model.run.runNumber))
        #expect(h.presenter.count == 1)
    }

    /// Whether BrewxPort is the active app with its main window key, as the app would answer.
    @MainActor final class Focus { var value = true }

    @Test func backgroundPasswordSheetWaitsForFocusAtPromptTime() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        let focus = Focus()
        h.model.run.canPresentPasswordSheet = { focus.value }
        // The window was up and key, so the password run started, marked as one whose sheet needs the focus.
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(h.model.run.promptNeedsFocus)
        #expect(!h.model.run.nextRunPromptNeedsFocus)
        // The person switches to another app before the run asks for the password (after the helper check).
        focus.value = false
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.passwordWaitsForFocus })
        // The sheet waits (the run just waits with it), and the notification asks for a click.
        #expect(!h.model.run.showingPasswordSheet)
        #expect(h.needsPassword.map(\.title) == ["1 update needs your password"])
        #expect(h.model.run.isRunning)
        // Activation elsewhere, or a key window that isn't ours, changes nothing.
        h.model.run.presentWaitingPrompt()
        #expect(!h.model.run.showingPasswordSheet)
        // Back in BrewxPort with its window key: the sheet shows.
        focus.value = true
        h.model.run.presentWaitingPrompt()
        #expect(h.model.run.showingPasswordSheet)
        #expect(!h.model.run.passwordWaitsForFocus)
        h.model.run.finishPassword(nil)
        #expect(await prompt.value == nil)

        // A cancel while the sheet waits ends the prompt like a cancelled sheet.
        focus.value = false
        let second = Task { await h.model.run.askForPassword(reason: "r", previousAttemptFailed: true) }
        #expect(await waitUntil { h.model.run.passwordWaitsForFocus })
        // Told once: the same version isn't announced again.
        #expect(h.needsPassword.count == 1)
        h.model.run.cancel()
        #expect(await second.value == nil)
        #expect(!h.model.run.passwordWaitsForFocus)
        #expect(!h.model.run.showingPasswordSheet)
    }

    /// Set once a task is done; a test waits for it without hanging when it never is.
    @MainActor final class Done { var value = false }

    /// Update everything's password run is going, its prompt waiting for BrewxPort to be active with its window key.
    func passwordPromptWaiting(_ h: Harness, focus: Focus) async -> Task<SecretBuffer?, Never> {
        focus.value = false
        h.model.run.canPresentPasswordSheet = { focus.value }
        await h.background.checkNow()
        _ = await waitUntil { h.executor.runs.count == 1 }
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        _ = await waitUntil { h.model.run.passwordWaitsForFocus }
        return prompt
    }

    @Test func unansweredPasswordPromptEndsQuietlyWhenAway() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        let h = await harness([curl], mode: .everything, executor: executor, conditions: conditions)
        let prompt = await passwordPromptWaiting(h, focus: Focus())
        #expect(h.model.run.isRunning)
        // The person walks away without answering: the prompt ends as "not now", not as a cancel.
        conditions.idleSeconds = 900
        #expect(await waitUntil { !h.model.run.isRunning })
        if !h.model.run.isRunning { #expect(await prompt.value == nil) }
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        // Nothing is locked meanwhile, and nothing is posted: the updates still wait for the person.
        #expect(h.model.canMenuUpdate)
        #expect(h.available.isEmpty)
        #expect(h.summaries.isEmpty)
        // Back at the Mac: the password run comes again (a cancel would hold it until the next scheduled check).
        conditions.idleSeconds = 0
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(h.windowOpens.count == 2)
    }

    @Test func lockingTheScreenEndsAWaitingPasswordPrompt() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        let h = await harness([curl], mode: .everything, executor: executor, conditions: conditions)
        h.background.userPollInterval = .seconds(3600)
        let prompt = await passwordPromptWaiting(h, focus: Focus())
        conditions.screenLocked = true
        conditions.change()
        #expect(await waitUntil { !h.model.run.isRunning })
        if !h.model.run.isRunning { #expect(await prompt.value == nil) }
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        conditions.screenLocked = false
        conditions.change()
        #expect(await waitUntil { executor.runs.count == 2 })
    }

    @Test func checkComingDueEndsAWaitingPasswordPrompt() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        h.background.scheduleFromSettings()
        let prompt = await passwordPromptWaiting(h, focus: Focus())
        // A scheduled check comes due while the prompt waits: the check isn't parked behind it.
        h.presenter.allowed = false
        let done = Done()
        Task {
            await h.scheduler.fire()
            done.value = true
        }
        #expect(await waitUntil { done.value })
        #expect(!h.model.run.isRunning)
        if !h.model.run.isRunning { #expect(await prompt.value == nil) }
        #expect(h.background.lastChecked == Self.start)
        // It decided the password part again: BrewxPort couldn't come forward, so it asks for a click (a new
        // notice: this check's own wait), and the click starts the run (no cancel's hold).
        #expect(h.background.state == .waitingForUser(count: 1))
        #expect(await waitUntil { h.needsPassword.count == 2 })
        h.notifier.click(.updates)
        #expect(await waitUntil { executor.runs.count == 2 })
    }

    /// Update everything's password run is going with BrewxPort in front, its window key: the sheet shows at once.
    func passwordSheetShown(_ h: Harness) async -> Task<SecretBuffer?, Never> {
        h.model.run.canPresentPasswordSheet = { true }
        await h.background.checkNow()
        _ = await waitUntil { h.executor.runs.count == 1 }
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        _ = await waitUntil { h.model.run.showingPasswordSheet }
        return prompt
    }

    /// Ends whatever run is still going, so a check parked behind it finishes too.
    func endRun(_ h: Harness) async {
        h.model.run.cancel()
        _ = await waitUntil { !h.model.run.isRunning }
    }

    @Test func shownAutomaticSheetEndsAfterIdle() async {
        // Ruling R21: the sheet is up (not waiting for the focus), and nobody answers it.
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        let h = await harness([curl], mode: .everything, executor: executor, conditions: conditions)
        let prompt = await passwordSheetShown(h)
        #expect(h.model.run.showingPasswordSheet)
        #expect(!h.model.run.passwordWaitsForFocus)
        // Several polls with the person still there: it stays.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.run.showingPasswordSheet)
        // No input for 10 minutes: the sheet goes as "not now", not as a cancel.
        conditions.idleSeconds = 900
        #expect(await waitUntil { !h.model.run.isRunning })
        #expect(!h.model.run.showingPasswordSheet)
        if !h.model.run.isRunning { #expect(await prompt.value == nil) }
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        // Nothing is locked meanwhile, and nothing is posted: the update still waits for the person.
        #expect(h.model.canMenuUpdate)
        #expect(h.available.isEmpty)
        #expect(h.summaries.isEmpty)
        // Back at the Mac: the password run comes again (a cancel would hold it until the next scheduled check).
        conditions.idleSeconds = 0
        #expect(await waitUntil { executor.runs.count == 2 })
        // This time the person types the password, then leaves while the run goes on: it isn't ended.
        let second = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.showingPasswordSheet })
        h.model.run.finishPassword(SecretBuffer(copying: Array("pw".utf8)))
        _ = await second.value
        conditions.idleSeconds = 900
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.run.isRunning)
        await endRun(h)
    }

    @Test func shownAutomaticSheetEndsWhenCheckComesDue() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        h.background.scheduleFromSettings()
        let prompt = await passwordSheetShown(h)
        // A scheduled check comes due with the sheet up and unanswered: the sheet goes ("not now"), and the check runs
        // rather than wait behind it.
        let done = Done()
        Task {
            await h.scheduler.fire()
            done.value = true
        }
        #expect(await waitUntil { done.value })
        #expect(!h.model.run.showingPasswordSheet)
        if !h.model.run.showingPasswordSheet { #expect(await prompt.value == nil) }
        #expect(h.background.lastChecked == Self.start)
        // The check decided the password part again. BrewxPort is still in front, so the run comes back once, and
        // only once: nothing else ends it until the next check.
        #expect(await waitUntil { executor.runs.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 2)
        #expect(h.summaries.isEmpty)
        #expect(h.available.isEmpty)

        // The next check comes due while that run is still in its helper check, before it has asked: it doesn't wait
        // behind the run for the sheet that's about to show (which would hold every later check back too). The run
        // stops before it asks, and this time BrewxPort can't come forward, so the update waits for a click (R14).
        h.presenter.allowed = false
        let second = Done()
        Task {
            await h.scheduler.fire()
            second.value = true
        }
        #expect(await waitUntil { second.value })
        if !second.value { await endRun(h) }
        #expect(!h.model.run.isRunning)
        #expect(!h.model.run.showingPasswordSheet)
        #expect(h.background.state == .waitingForUser(count: 1))
        #expect(await waitUntil { h.needsPassword.count == 1 })
        #expect(h.summaries.isEmpty)
        #expect(h.available.isEmpty)
        // Not a cancel, so nothing is held: the click starts the run.
        h.notifier.click(.updates)
        #expect(await waitUntil { executor.runs.count == 3 })

        // Answered, the run is the person's to finish: a check coming due now waits for it, as for any run.
        let third = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.showingPasswordSheet })
        h.model.run.finishPassword(SecretBuffer(copying: Array("pw".utf8)))
        _ = await third.value
        let fourth = Done()
        Task {
            await h.scheduler.fire()
            fourth.value = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.run.isRunning)
        #expect(!fourth.value)
        await endRun(h)
        #expect(await waitUntil { fourth.value })
    }

    @Test func userStartedSheetNeverAutoEnds() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        let h = await harness([curl], mode: .everything, executor: executor, conditions: conditions)
        h.background.scheduleFromSettings()
        h.model.run.canPresentPasswordSheet = { true }
        // The person's own run (the menu bar's MacPorts Update), the same packages as an automatic one would take.
        h.model.menuUpdate(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 1 })
        // Away, and a check comes due before the run has asked: the person's run isn't touched, and the check waits
        // for it to end, as for any run.
        conditions.idleSeconds = 900
        conditions.change()
        let done = Done()
        Task {
            await h.scheduler.fire()
            done.value = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.model.run.isRunning)
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.showingPasswordSheet })
        // The sheet is up, unanswered, and the person still isn't there: it stays, through polls and system changes.
        conditions.screenLocked = true
        conditions.change()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.model.run.showingPasswordSheet)
        #expect(h.model.run.isRunning)
        #expect(!done.value)
        // Only the person ends it (here, Cancel); the waiting check then runs.
        h.model.run.finishPassword(nil)
        #expect(await prompt.value == nil)
        await endRun(h)
        #expect(await waitUntil { done.value })
        #expect(executor.runs.count == 1)
    }

    @Test func passwordNoticeCoversVersionsAlreadyAnnounced() async {
        // Notify me announced curl and keynote. The person then picks Update everything, and BrewxPort can't come
        // forward: the "need your password" notice still goes out (it isn't held back by the "available" one).
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl, keynote], executor: executor)
        await h.background.checkNow()
        #expect(h.available.map(\.title) == ["2 updates available"])
        h.background.settings.mode = .everything
        h.presenter.allowed = false
        await h.background.checkNow()
        #expect(await waitUntil { h.needsPassword.count == 1 })
        #expect(h.needsPassword.first?.title == "2 updates need your password")
        #expect(h.background.state == .waitingForUser(count: 2))
    }

    @Test func manualRunEndingTheWaitTellsWhatIsLeft() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([curl, keynote], mode: .everything, executor: executor, conditions: conditions)
        await h.background.checkNow()
        #expect(h.background.state == .waitingForUser(count: 2))
        #expect(h.available.isEmpty)
        // The person updates MacPorts themselves: that replaces the waiting run, and keynote, still outdated, is told.
        h.model.updateAll(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 1 })
        h.catalog.script(.outdated, .macports, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.available.count == 1 })
        #expect(h.available.first?.title == "1 update available")
        #expect(h.available.first?.body == "Mac App Store 1")
        #expect(h.background.state == .idle)
    }

    @Test func userRunPromptUnchanged() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], executor: executor)
        // Not active, not key: a run the person started still shows its sheet at once, as before.
        h.model.run.canPresentPasswordSheet = { false }
        h.model.menuUpdate(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(!h.model.run.promptNeedsFocus)
        let prompt = Task { await h.model.run.askForPassword(reason: "r") }
        #expect(await waitUntil { h.model.run.showingPasswordSheet })
        #expect(!h.model.run.passwordWaitsForFocus)
        #expect(h.needsPassword.isEmpty)
        h.model.run.finishPassword(nil)
        #expect(await prompt.value == nil)
        h.model.run.cancel()
        #expect(await waitUntil { !h.model.run.isRunning })
    }

    @Test func everythingWaitsWhileLockedThenRunsOnReturn() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.screenLocked = true
        let h = await harness([wget, curl], mode: .everything, executor: executor, conditions: conditions)
        // No poll in this test: only the system's unlock event can end the wait.
        h.background.userPollInterval = .seconds(3600)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        // Woke, still locked.
        conditions.change()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        conditions.screenLocked = false
        conditions.change()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(Set(executor.runs[1].steps.map(\.engine)) == [.macports])
        #expect(h.windowOpens.count == 1)
    }

    @Test func manualRunReplacesTheWaitingPasswordRun() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([wget, curl], mode: .everything, executor: executor, conditions: conditions)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        h.model.updateAll(engine: .macports)
        #expect(await waitUntil { executor.runs.count == 2 })
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { !h.model.run.isRunning && h.background.state == .idle })
        conditions.idleSeconds = 0
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 2)
        #expect(h.windowOpens.count == 0)
    }

    @Test func cancelledPasswordUpdatesAreNotifiedAsAvailable() async {
        // BrewxPort couldn't come forward, so "need your password" asked for a click. The person clicks, then cancels
        // the sheet: those updates wait for the next scheduled check and are notified as available, once. The password
        // notice didn't count as telling them.
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        h.presenter.allowed = false
        await h.background.checkNow()
        #expect(await waitUntil { h.needsPassword.count == 1 })
        #expect(h.available.isEmpty)
        h.notifier.click(.updates)
        #expect(await waitUntil { executor.runs.count == 1 })
        executor.finish([.needsPassword, .cancelled, .done])
        #expect(await waitUntil { h.available.count == 1 })
        #expect(h.available.first?.title == "1 update available")
        #expect(h.available.first?.body == "MacPorts 1")
        // Once: the next Check Now (still held after the cancel) doesn't tell them again.
        await h.background.checkNow()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(h.available.count == 1)
        #expect(executor.runs.count == 1)
    }

    @Test func cancelledPasswordRunIsNotifiedInstead() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        await h.background.checkNow()
        // At the Mac and nothing password-free: the password run starts at once.
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(h.windowOpens.count == 1)
        #expect(h.available.isEmpty)
        // The person cancels the password sheet.
        executor.finish([.needsPassword, .cancelled, .done])
        #expect(await waitUntil { h.available.count == 1 })
        #expect(h.available.first?.title == "1 update available")
        #expect(h.summaries.isEmpty)
        #expect(h.background.state == .idle)
        // It waits for the next check: nothing asks again meanwhile.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
    }

    @Test func checkDuringAutoRunDecidesThePasswordPartOnce() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl], mode: .everything, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        // Check Now while the password-free run goes: it waits for the run's end.
        let check = Task { await h.background.checkNow() }
        try? await Task.sleep(for: .milliseconds(30))
        // The run's own end handling is held until the check has finished: the order that went wrong.
        let gate = Gate()
        h.background.autoRunEndPause = { await gate.wait() }
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        await check.value
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(h.windowOpens.count == 1)
        #expect(await waitUntil { gate.waiting == 1 })
        h.background.autoRunEndPause = {}
        gate.release()
        #expect(await waitUntil { h.summaries.count == 1 })
        // The password run fails (curl is still outdated). Nothing asks again before the next check.
        executor.finish([.started(0), .finished(0, 1), .started(1), .finished(1, 1), .done])
        #expect(await waitUntil { h.summaries.count == 2 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(executor.runs.count == 2)
        #expect(h.windowOpens.count == 1)
        #expect(h.background.state == .idle)
    }

    @Test func cancelThenQueuedCheckDoesNotReopenSheet() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([curl], mode: .everything, executor: executor)
        h.background.scheduleFromSettings()
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(h.windowOpens.count == 1)
        // Check Now while the password sheet is up: it waits for the run's end.
        let check = Task { await h.background.checkNow() }
        try? await Task.sleep(for: .milliseconds(30))
        executor.finish([.needsPassword, .cancelled, .done])
        await check.value
        try? await Task.sleep(for: .milliseconds(50))
        // The cancel holds: no sheet again, only the notification.
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 1)
        #expect(h.available.map(\.title) == ["1 update available"])
        // Another Check Now still only notifies.
        await h.background.checkNow()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.count == 1)
        // The next scheduled check asks again.
        await h.scheduler.fire()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(h.windowOpens.count == 2)
    }

    @Test func partialRepostKeepsAllWaitingRows() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(h.available.map(\.body) == ["MacPorts 1"])
        // The person cancels the background run: wget waits too now, and the notice that replaces the last one
        // still covers curl.
        h.model.run.cancel()
        #expect(await waitUntil { h.available.count == 2 })
        #expect(h.available.last?.title == "2 updates available")
        #expect(h.available.last?.body == "Homebrew 1, MacPorts 1")
    }

    @Test func switchingToNotifyDuringFreeRunSkipsPasswordRun() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl], mode: .everything, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        h.background.settings.mode = .notify
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        #expect(await waitUntil { h.available.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.available.first?.body == "MacPorts 1")
        #expect(h.background.state == .idle)
    }

    @Test func switchingModeWhileWaitingCancelsTheWait() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([wget, curl], mode: .everything, executor: executor, conditions: conditions)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        h.background.settings.mode = .passwordFree
        // The wait ends without the person coming back, and what it held is notified.
        #expect(await waitUntil { h.background.state == .idle })
        #expect(h.available.map(\.body) == ["MacPorts 1"])
        conditions.idleSeconds = 0
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
    }

    @Test func passwordRunThatCannotStartStopsWaiting() async {
        // MacPorts is missing from this copy: its update plans no step, so no run can take it.
        let engines = PlanFixtures.engines.filter { $0.id != .macports }
        let catalog = FakeCatalog()
        let notifier = FakeNotifier()
        let executor = FakeRunExecutor()
        let services = F.services(catalog: catalog, executor: executor, helper: FakeHelperManager(),
                                  engines: engines, notifier: notifier)
        let model = await F.updatesModel([curl], catalog: catalog, services: services)
        let opens = Counter()
        model.openMainWindow = { opens.count += 1 }
        model.presentForPassword = {
            opens.count += 1
            return true
        }
        model.background.settings.mode = .everything
        model.background.userPollInterval = .milliseconds(10)
        await model.background.checkNow()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(executor.runs.isEmpty)
        // Tried once (the panel says why nothing ran), then left for the next check.
        #expect(opens.count == 1)
        #expect(model.background.state == .idle)
        #expect(notifier.posts.map(\.title) == ["1 update available"])
    }

    @Test func cancelledBackgroundRunSkipsThePasswordPart() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl], mode: .everything, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        // The person cancels the password-free run from its panel.
        h.model.run.cancel()
        #expect(await waitUntil { h.available.count == 1 })
        #expect(h.available.first?.title == "2 updates available")
        #expect(h.summaries.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.background.state == .idle)
    }

    @Test func standardAccountEverythingActsPasswordFree() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, curl], mode: .everything, isAdministrator: false, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        #expect(h.model.lastRunOrigin == .background)
        #expect(h.available.map(\.body) == ["MacPorts 1"])
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.background.state == .idle)
    }

    // MARK: Battery

    @Test func lowBatteryDefersScheduledCheckButNotCheckNow() async {
        let conditions = FakeConditions()
        conditions.batteryLow = true
        let h = await harness([wget], conditions: conditions)
        h.background.scheduleFromSettings()
        let reloads = h.model.listReloadCount
        await h.scheduler.fire()
        #expect(h.background.lastChecked == nil)
        #expect(h.model.listReloadCount == reloads)
        #expect(h.notifier.posts.isEmpty)
        // Check Now is the person asking: it runs on battery.
        await h.background.checkNow()
        #expect(h.available.count == 1)
        #expect(h.background.lastChecked == Self.start)
        // Low Power Mode defers a scheduled check too.
        conditions.batteryLow = false
        conditions.lowPowerMode = true
        h.background.now = { Self.later }
        h.catalog.script(.outdated, .homebrew, packages: [Self.package(.homebrew, .formula, "wget", latest: "3")])
        await h.scheduler.fire()
        #expect(h.background.lastChecked == Self.start)
        // Back to normal power: the deferred check runs.
        conditions.lowPowerMode = false
        conditions.change()
        #expect(await waitUntil { h.background.lastChecked == Self.later && h.available.count == 2 })
    }

    @Test func lowBatteryHoldsAutomaticUpdatesAfterCheckNow() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.batteryLow = true
        let h = await harness([wget, curl], mode: .passwordFree, executor: executor, conditions: conditions)
        await h.background.checkNow()
        // The check and its notification happen; the update waits for power, so everything is notified.
        #expect(h.background.lastChecked == Self.start)
        #expect(h.available.map(\.title) == ["2 updates available"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)
        // A change that leaves the battery low changes nothing.
        conditions.change()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.isEmpty)
        // Back on power: the automatic update runs.
        conditions.batteryLow = false
        conditions.change()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        #expect(h.model.lastRunOrigin == .background)
    }

    @Test func lowPowerHoldsPasswordRunUntilPowerReturns() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([wget, curl], mode: .everything, executor: executor, conditions: conditions)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.background.state == .waitingForUser(count: 1) })
        // Low Power Mode comes on, then the person comes back: the password run still waits.
        conditions.lowPowerMode = true
        conditions.idleSeconds = 0
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        #expect(h.windowOpens.count == 0)
        #expect(h.background.state == .waitingForUser(count: 1))
        conditions.lowPowerMode = false
        conditions.change()
        #expect(await waitUntil { executor.runs.count == 2 })
        #expect(Set(executor.runs[1].steps.map(\.engine)) == [.macports])
        #expect(h.windowOpens.count == 1)
    }

    // MARK: Held updates

    /// A language engine whose every step runs as the user (so automatic updates would take its rows), building
    /// `<tool> upgrade <names>`, at most `limit` names per command (pipx's real limit is 1).
    struct ToolEngine: Engine {
        let id: EngineID
        var limit: Int?
        let capabilities: EngineCapabilities = []
        func maxTargetsPerCommand(for operation: PackageOperation) -> Int? { limit }
        var executableURL: URL? { URL(fileURLWithPath: "/opt/homebrew/bin/\(id.rawValue)") }
        func detect() async -> EngineStatus { .present(path: executableURL!, version: "1") }
        func search(_ query: String) async throws -> [Package] { [] }
        func listInstalled() async throws -> [Package] { [] }
        func listOutdated() async throws -> [Package] { [] }
        func info(_ ref: PackageRef) async throws -> PackageDetails { PackageDetails(ref: ref) }
        func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }
        func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
            CommandSpec(executable: executableURL!, arguments: ["upgrade"] + refs.map(\.name), needsRoot: false)
        }
    }

    static func tool(_ engine: EngineID, _ name: String) -> Package {
        Package(id: PackageRef(engine: engine, kind: .tool, name: name), displayName: name, installedVersion: "1",
                latestVersion: "2")
    }

    /// A harness whose Updates page also holds `held` (with `homebrew`'s rows), its engines able to run them all.
    func heldHarness(_ homebrew: [Package], held: [EngineID: [HeldUpdate]], listed: [EngineID: [Package]] = [:],
                     mode: AutoUpdateMode, executor: FakeRunExecutor) async -> Harness {
        let engines = PlanFixtures.engines + held.keys.map { ToolEngine(id: $0) as any Engine }
        let h = await harness(homebrew, mode: mode, executor: executor, engines: engines)
        for (engine, holds) in held {
            h.catalog.script(.outdated, engine, FakeCatalog.Script(result: .success(listed[engine] ?? []), held: holds))
        }
        h.model.refreshLists()
        await h.model.updates.reloaded()
        return h
    }

    /// Needs Rust 1.96: shown on Updates with why, never run, by an automatic update or Update all, and not told as
    /// available (nobody can run it).
    @Test func cargoNeedsNewerRustShownAndNotAutomatic() async {
        let ripgrep = Self.tool(.cargo, "ripgrep")
        let hold = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await heldHarness([wget], held: [.cargo: [HeldUpdate(package: ripgrep, hold: hold)]],
                                  mode: .passwordFree, executor: executor)
        #expect(h.model.updates.list.byRef[ripgrep.id]?.hold == hold)
        #expect(h.model.updates.badgeCount == 1)
        #expect(!h.model.outdatedRefs.contains(ripgrep.id))
        // The row's menu has Update off for it alone.
        let items = h.model.rowMenuItems(for: [ripgrep.id], in: .updates)
        #expect(items.first { $0.action == .update }?.isEnabled == false)
        #expect(h.model.rowMenuItems(for: [ripgrep.id, wget.id], in: .updates)
            .first { $0.action == .update }?.isEnabled == true)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.engine) == [.homebrew])
        #expect(!executor.runs[0].steps.flatMap(\.spec.arguments).contains("ripgrep"))
        #expect(h.available.isEmpty)
    }

    /// R19: a gem that came with Ruby is never updated automatically; it waits for the person like any update that
    /// waits (told as available), and Update all and the row's own Update still take it.
    @Test func gemShippedWithRubyNotAutomatic() async {
        let rake = Self.tool(.gem, "rake")
        let hold = UpdateHold(reason: "Came with Ruby, so BrewxPort updates it only when you ask.",
                              blocksAutomatic: true, blocksManual: false)
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await heldHarness([wget], held: [.gem: [HeldUpdate(package: rake, hold: hold)]],
                                  listed: [.gem: [rake]], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.engine) == [.homebrew])
        #expect(h.available.map(\.title) == ["1 update available"])
        #expect(h.available.first?.body == "RubyGems 1")
        #expect(h.model.updates.updateAllRequests().map(\.package.id) == [rake.id, wget.id])
        #expect(h.model.outdatedRefs.contains(rake.id))
    }

    // MARK: Runtimes language tools use (design option A)

    static func formula(_ name: String, _ installed: String, _ latest: String) -> Package {
        Package(id: PackageRef(engine: .homebrew, kind: .formula, name: name), displayName: name,
                installedVersion: installed, latestVersion: latest)
    }

    /// The runtime notices posted, by id.
    func runtimeNotices(_ h: Harness) -> [FakeNotifier.Post] {
        h.notifier.posts.filter { $0.id.hasPrefix(BackgroundUpdater.runtimeIDPrefix) }
    }

    /// A harness on `Related`'s engines plus `languages`, whose Installed lists `packages` (Homebrew's, nothing
    /// depending on anything unless `relate` says so) and whose Updates holds them.
    func runtimeHarness(_ packages: [Package], languages: [any Engine], mode: AutoUpdateMode = .passwordFree,
                        executor: FakeRunExecutor = FakeRunExecutor(),
                        relate: (Related) -> Void = { _ in }) async -> Harness {
        let r = Related()
        r.installed(.homebrew, packages)
        for package in packages { r.needs(.homebrew, package.id.name, []) }
        relate(r)
        return await harness(packages, mode: mode, executor: executor, engines: r.engines + languages,
                             catalog: r.catalog)
    }

    /// Homebrew's Ruby going from 4.0 to 4.1 leaves the gems RubyGems installed behind, so an automatic run skips it
    /// and says so once, in the design's words; a Ruby patch update runs as usual.
    @Test func autoRunHoldsBackRubyMinor() async {
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")])
        let h = await runtimeHarness([wget, ruby], languages: [gem])
        #expect(h.model.updates.hold(for: h.model.updates.list.byRef[ruby.id]!)
                == UpdateHold(reason: "Updating it needs your gems reinstalled.", blocksAutomatic: true,
                              blocksManual: false))
        await h.background.checkNow()
        #expect(await waitUntil { h.executor.runs.count == 1 })
        #expect(h.executor.runs[0].steps.flatMap(\.refs) == [wget.id])
        #expect(runtimeNotices(h).map(\.title) == ["Ruby 4.1 is ready"])
        #expect(runtimeNotices(h).map(\.body) == ["Updating it needs your gems reinstalled."])
        #expect(runtimeNotices(h).first?.target == .updates)
        // Not told again as available, nor as a runtime once more on the next check.
        #expect(h.available.isEmpty)
        #expect(h.attention.isEmpty)
        #expect(await waitUntil { !h.model.run.isRunning })
        await h.background.checkNow()
        #expect(runtimeNotices(h).count == 1)
        #expect(h.available.isEmpty)

        // A patch update keeps its gems, so it runs.
        let patch = Self.formula("ruby", "4.0.9", "4.0.10")
        let next = await runtimeHarness([patch], languages: [gem])
        #expect(next.model.updates.hold(for: next.model.updates.list.byRef[patch.id]!) == nil)
        await next.background.checkNow()
        #expect(await waitUntil { next.executor.runs.count == 1 })
        #expect(next.executor.runs[0].steps.flatMap(\.refs) == [patch.id])
        #expect(runtimeNotices(next).isEmpty)
    }

    /// Homebrew's Node going to a new major version needs npm's globals rebuilt; a minor one doesn't. Homebrew's own
    /// revision suffix (`_1`) isn't a version part.
    @Test func autoRunHoldsBackNodeMajor() async {
        let node = Self.formula("node", "25.2.1_1", "26.0.0")
        let npm = FakeLanguageEngine(.npm, uses: [RuntimeUse(formula: "node")])
        let h = await runtimeHarness([node], languages: [npm])
        await h.background.checkNow()
        #expect(runtimeNotices(h).map(\.title) == ["Node 26 is ready"])
        #expect(runtimeNotices(h).map(\.body) == ["Updating it needs your npm tools rebuilt."])
        #expect(h.executor.runs.isEmpty)

        let minor = Self.formula("node", "25.2.1", "25.3.0_1")
        let next = await runtimeHarness([minor], languages: [npm])
        await next.background.checkNow()
        #expect(await waitUntil { next.executor.runs.count == 1 })
        #expect(runtimeNotices(next).isEmpty)

        // An npm on another Node (nvm's) isn't Homebrew's: its major update runs.
        let nvm = FakeLanguageEngine(.npm, uses: [])
        let other = await runtimeHarness([node], languages: [nvm])
        await other.background.checkNow()
        #expect(await waitUntil { other.executor.runs.count == 1 })
    }

    /// Any change to a python@3.x that pipx's or uv's tools run on breaks them until they're reinstalled; one no tool
    /// uses updates as usual. A manager that can't say which Python its tools use counts as using it.
    @Test func autoRunHoldsBackPythonUsedByTools() async {
        let python15 = Self.formula("python@3.15", "3.15.2", "3.15.3")
        let python14 = Self.formula("python@3.14", "3.14.4", "3.14.5")
        let pipx = FakeLanguageEngine(.pipx, uses: [RuntimeUse(formula: "python@3.15", tools: ["black"])])
        let uv = FakeLanguageEngine(.uv, uses: [RuntimeUse(formula: "python@3.15", tools: ["ruff"])])
        let h = await runtimeHarness([python14, python15], languages: [pipx, uv])
        await h.background.checkNow()
        #expect(await waitUntil { h.executor.runs.count == 1 })
        #expect(h.executor.runs[0].steps.flatMap(\.refs) == [python14.id])
        #expect(runtimeNotices(h).map(\.title) == ["Python 3.15.3 is ready"])
        #expect(runtimeNotices(h).map(\.body) == ["Updating it needs your pipx and uv tools reinstalled."])

        uv.uses = .failure(EngineError(engine: .uv, message: "This uv doesn't say which Python its tools use"))
        let unsure = await runtimeHarness([python14], languages: [pipx, uv])
        await unsure.background.checkNow()
        #expect(runtimeNotices(unsure).map(\.body) == ["Updating it needs your uv tools reinstalled."])
        #expect(unsure.executor.runs.isEmpty)
    }

    /// `brew upgrade` brings a formula's outdated dependencies and dependents along, so an automatic run also leaves
    /// out every update that would update a held runtime that way: yarn (which needs node) and pre-commit (which needs
    /// the python@3.15 pipx's tools run on). They're told in one "need your attention" notice saying why; jq runs.
    @Test func autoRunLeavesOutUpdatesThatBringAHeldRuntimeAlong() async {
        let node = Self.formula("node", "25.2.1", "26.0.0")
        let python = Self.formula("python@3.15", "3.15.2", "3.15.3")
        let yarn = Self.formula("yarn", "1.22.21", "1.22.22")
        let preCommit = Self.formula("pre-commit", "4.0.0", "4.0.1")
        let npm = FakeLanguageEngine(.npm, uses: [RuntimeUse(formula: "node")])
        let pipx = FakeLanguageEngine(.pipx, uses: [RuntimeUse(formula: "python@3.15", tools: ["black"])])
        let h = await runtimeHarness([jq, node, python, yarn, preCommit], languages: [npm, pipx]) { r in
            r.brew.setDependents("node", ["yarn"])
            r.needs(.homebrew, "yarn", ["node"])
            r.brew.setDependents("python@3.15", ["pre-commit"])
            r.needs(.homebrew, "pre-commit", ["python@3.15"])
        }
        #expect(h.model.updates.runtimesBroughtAlong(by: yarn.id) == [node.id])
        #expect(h.model.updates.runtimesBroughtAlong(by: preCommit.id) == [python.id])
        #expect(h.model.updates.runtimesBroughtAlong(by: jq.id).isEmpty)
        await h.background.checkNow()
        #expect(await waitUntil { h.executor.runs.count == 1 })
        #expect(h.executor.runs[0].steps.flatMap(\.refs) == [jq.id])
        #expect(h.attention.map(\.title) == ["2 updates need your attention"])
        #expect(h.attention.map(\.body) == ["Updating them would also update Node and Python, which your language "
                                            + "tools run on."])
        #expect(h.available.isEmpty)
        #expect(BackgroundUpdater.attentionBody(count: 1, ignoredOrSkipped: true, runtimes: ["Ruby"])
                == "Updating it would also update a package you ignored or skipped, or Ruby, which your language "
                + "tools run on.")
    }

    /// The runtime notice has its own place in the notify-once ledger: a Ruby version told as available while
    /// BrewxPort only notified is still told as "Ruby 4.1 is ready" once automatic updates hold it back.
    @Test func runtimeNoticeAfterItWasToldAsAvailable() async {
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")])
        let h = await runtimeHarness([ruby], languages: [gem], mode: .notify)
        await h.background.checkNow()
        #expect(h.available.map(\.title) == ["1 update available"])
        #expect(runtimeNotices(h).isEmpty)
        h.background.settings.mode = .passwordFree
        await h.background.checkNow()
        #expect(runtimeNotices(h).map(\.title) == ["Ruby 4.1 is ready"])
        await h.background.checkNow()
        #expect(runtimeNotices(h).count == 1)
        #expect(h.available.count == 1)
    }

    // MARK: Python patch updates (R29)

    /// No registry: the runtime checks never look anything up.
    struct NoRegistry: RegistryFetching {
        func get(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    /// One captured pipx command from `Fixtures/pipx`.
    static func pipxCapture(_ name: String) -> CommandResult {
        let folder = UIFixtures.directory.appendingPathComponent("pipx")
        func read(_ file: String) -> String? {
            try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
        }
        let exit = Int32(read(name + ".exit")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 127
        return CommandResult(exitCode: exit, stdout: read(name + ".json") ?? read(name + ".txt") ?? "", stderr: "")
    }

    /// The venvs' `pyvenv.cfg` files T13 captured: pipx's black through Homebrew's `opt/python@3.15` link, a uv tool on
    /// uv's own CPython, and one on the Command Line Tools' Python.
    nonisolated static let capturedVenvConfigs = ["pipx/t13-pyvenv-cfg-black.cfg", "uv/t13-pyvenv-cfg-black.cfg",
                                                  "uv/t13-on-system-python-pyvenv-cfg-ruff.cfg"]

    /// A venv's `pyvenv.cfg` naming `home`: the captured file that names it (`capturedVenvConfigs`). Not a capture for
    /// any other `home` (one Cellar copy, Homebrew's `Frameworks` link: T13 made no venv there): the file as Python's
    /// `venv` module writes it, `home` first.
    nonisolated static func venvConfig(home: String, venv: String) -> String {
        for file in capturedVenvConfigs {
            if let text = try? String(contentsOf: UIFixtures.directory.appendingPathComponent(file), encoding: .utf8),
               VenvConfig.home(text) == home {
                return text
            }
        }
        return "home = \(home)\ninclude-system-site-packages = false\nversion = 3.15.2\n"
            + "executable = \(home)/python3.15\ncommand = \(home)/python3.15 -m venv \(venv)\n"
    }

    /// The captured pipx (black and cowsay on Homebrew's python@3.15, PIPX_HOME the VM's), detected, whose venvs'
    /// `pyvenv.cfg` name `homes` (venv name → home; a venv without one has none).
    static func pipxWithVenvs(_ homes: [String: String]) async -> PipxEngine {
        let runner = UIFakeRunner([["--version"]: pipxCapture("version"),
                                   ["environment", "--value", "PIPX_HOME"]: pipxCapture("environment-pipx-home"),
                                   ["environment", "--value", "PIPX_BIN_DIR"]: pipxCapture("environment-pipx-bin-dir"),
                                   ["list", "--json"]: pipxCapture("list-json")])
        let venvs = "/Users/tester/Library/Application Support/pipx/venvs/"
        let pipx = PipxEngine(runner: runner, registry: NoRegistry(),
                              executable: URL(fileURLWithPath: "/opt/homebrew/bin/pipx"),
                              readToolFile: { path in
                                  guard path.hasPrefix(venvs), path.hasSuffix("/pyvenv.cfg") else { return nil }
                                  let name = String(path.dropFirst(venvs.count).dropLast("/pyvenv.cfg".count))
                                  return homes[name].map { Data(venvConfig(home: $0, venv: venvs + name).utf8) }
                              })
        _ = await pipx.detect()
        return pipx
    }

    static let python15 = formula("python@3.15", "3.15.2", "3.15.3")
    static let optHome = "/opt/homebrew/opt/python@3.15/bin"

    /// R29: venvs made through Homebrew's `opt/python@3.15` link follow its patch updates, so the update isn't held.
    @Test func pythonPatchNotHeldForOptPathVenvs() async {
        let pipx = await Self.pipxWithVenvs(["black": Self.optHome, "cowsay": Self.optHome])
        let h = await runtimeHarness([Self.python15], languages: [pipx])
        #expect(h.model.updates.runtimeHolds.isEmpty)
        await h.background.checkNow()
        #expect(await waitUntil { h.executor.runs.count == 1 })
        #expect(h.executor.runs[0].steps.flatMap(\.refs) == [Self.python15.id])
        #expect(runtimeNotices(h).isEmpty)
    }

    /// R29: a venv pinned to one Cellar copy goes with it, so the patch update is held for that tool alone.
    @Test func pythonPatchHeldForCellarPinnedVenv() async {
        let pipx = await Self.pipxWithVenvs(["black": "/opt/homebrew/Cellar/python@3.15/3.15.2/bin",
                                             "cowsay": Self.optHome])
        let h = await runtimeHarness([Self.python15], languages: [pipx])
        #expect(h.model.updates.runtimeHolds[Self.python15.id]?.engines == [.pipx: ["black"]])
        await h.background.checkNow()
        #expect(h.executor.runs.isEmpty)
        #expect(runtimeNotices(h).map(\.body) == ["Updating it needs your pipx tools reinstalled."])
    }

    /// A venv made through Homebrew's `Frameworks` link is Homebrew's Python, resolved through the formula's versioned
    /// folder: it counts as pinned, so the patch update is held for it.
    @Test func pythonPatchHeldForFrameworksVenv() async {
        let frameworks = "/opt/homebrew/Frameworks/Python.framework/Versions/3.15/bin"
        let pipx = await Self.pipxWithVenvs(["black": frameworks, "cowsay": Self.optHome])
        let h = await runtimeHarness([Self.python15], languages: [pipx])
        #expect(h.model.updates.runtimeHolds[Self.python15.id]?.engines == [.pipx: ["black"]])
    }

    /// R29: a venv whose `pyvenv.cfg` can't be read could be pinned: the patch update is held (the careful way).
    @Test func pythonPatchHeldWhenVenvUnreadable() async {
        let pipx = await Self.pipxWithVenvs(["cowsay": Self.optHome])
        let h = await runtimeHarness([Self.python15], languages: [pipx])
        #expect(h.model.updates.runtimeHolds[Self.python15.id]?.engines == [.pipx: ["black"]])
        await h.background.checkNow()
        #expect(h.executor.runs.isEmpty)
        #expect(runtimeNotices(h).map(\.title) == ["Python 3.15.3 is ready"])
    }

    /// R29: a venv whose `pyvenv.cfg` names a Python outside Homebrew (uv's own here, as captured) doesn't run on
    /// Homebrew's python@3.15 at all: it isn't "used by" that formula, and its update isn't held for it.
    @Test func pythonUpdateNotHeldForToolOnNonHomebrewPython() async throws {
        let uvPython = "/Users/tester/.local/share/uv/python/cpython-3.12-macos-aarch64-none/bin"
        let pipx = await Self.pipxWithVenvs(["black": uvPython, "cowsay": Self.optHome])
        #expect(try await pipx.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["cowsay"],
                                                            patchSafeTools: ["cowsay"])])
        let h = await runtimeHarness([Self.python15], languages: [pipx])
        #expect(h.model.updates.runtimeHolds.isEmpty)
        await h.background.checkNow()
        #expect(await waitUntil { h.executor.runs.count == 1 })
        #expect(h.executor.runs[0].steps.flatMap(\.refs) == [Self.python15.id])
        #expect(runtimeNotices(h).isEmpty)

        // Neither venv on Homebrew's Python (the other on the Command Line Tools' Python): pipx's tools use none.
        let elsewhere = await Self.pipxWithVenvs(["black": uvPython,
                                                  "cowsay": "/Library/Developer/CommandLineTools/usr/bin"])
        #expect(try await elsewhere.runtimeUses().isEmpty)
    }

    /// When Homebrew couldn't say what depends on a held runtime, an automatic run still leaves every Homebrew update
    /// out, and its notice says they only may bring the runtime along, as the manual warning does.
    @Test func attentionNoticeSaysMayWhenRelationsWerentRead() async {
        let ruby = Self.formula("ruby", "4.0.10", "4.1.0")
        let gem = FakeLanguageEngine(.gem, uses: [RuntimeUse(formula: "ruby")])
        // The plain Homebrew engine can't say what depends on Ruby here (its runner knows no `brew uses`).
        let h = await harness([wget, ruby], mode: .passwordFree, engines: PlanFixtures.engines + [gem])
        await h.background.checkNow()
        #expect(h.executor.runs.isEmpty)
        #expect(h.attention.map(\.body) == ["Updating it may also update Ruby, which your language tools run on."])
        #expect(BackgroundUpdater.attentionBody(count: 2, ignoredOrSkipped: false, runtimes: ["Node"],
                                                maybeRuntimes: ["Python"])
                == "Updating them would also update Node, and may also update Python, which your language tools run "
                + "on.")
        #expect(BackgroundUpdater.attentionBody(count: 2, ignoredOrSkipped: true, runtimes: [], maybeRuntimes: ["Ruby"])
                == "Updating them would also update a package you ignored or skipped, and may also update Ruby, which "
                + "your language tools run on.")
    }

    // MARK: After a run

    /// R6: the summary counts what the run updated from the run's own results. A tool whose step failed isn't
    /// "updated" because its row vanished from the next check (pipx couldn't check it then); one whose step worked is,
    /// whatever the next check could look up. pipx upgrades one tool per step, as the real engine does.
    @Test func updaterCountsFromRunResultsNotFromVanishedRows() async throws {
        let black = Self.tool(.pipx, "black")
        let isort = Self.tool(.pipx, "isort")
        let notChecked = UncheckedPackages(reasons: ["black": "PyPI didn't answer", "isort": "PyPI didn't answer"])
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, black, isort], mode: .passwordFree, executor: executor,
                              engines: PlanFixtures.engines + [ToolEngine(id: .pipx, limit: 1)])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.refs) == [[wget.id], [black.id], [isort.id]])
        // After the run, Homebrew no longer lists wget, and pipx couldn't look black or isort up: both vanish.
        h.catalog.script(.outdated, .homebrew, packages: [])
        h.catalog.script(.outdated, .pipx, FakeCatalog.Script(result: .success([]), unchecked: notChecked))
        executor.finish([.started(0), .finished(0, 0), .started(1), .finished(1, 1), .started(2), .finished(2, 0),
                         .done])
        #expect(await waitUntil { h.summaries.count == 1 })
        #expect(h.summaries.first?.title == "Updated 2. 1 failed: black")
        #expect(h.summaries.first?.body == "isort, wget")
    }

    /// A package the reload still lists counts as failed only when it's offered at or below the version the run
    /// targeted, or isn't held. A crate updated to 15 whose 16 now waits for a newer Rust was updated; one still
    /// offered at 15 wasn't.
    @Test func heldNewerVersionAfterTheRunIsntAFailure() async {
        let hold = UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true)
        let ripgrep = Package(id: PackageRef(engine: .cargo, kind: .tool, name: "ripgrep"), displayName: "ripgrep",
                              installedVersion: "14.1.0", latestVersion: "15.0.0")
        for offered in ["16.0.0", "15.0.0"] {
            let executor = FakeRunExecutor(events: [], hang: true)
            let h = await harness([wget, ripgrep], mode: .passwordFree, executor: executor,
                                  engines: PlanFixtures.engines + [ToolEngine(id: .cargo, limit: 1)])
            await h.background.checkNow()
            #expect(await waitUntil { executor.runs.count == 1 })
            var after = ripgrep
            after.installedVersion = offered == "16.0.0" ? "15.0.0" : "14.1.0"
            after.latestVersion = offered
            h.catalog.script(.outdated, .homebrew, packages: [])
            h.catalog.script(.outdated, .cargo, FakeCatalog.Script(result: .success([]),
                                                                   held: [HeldUpdate(package: after, hold: hold)]))
            Self.succeed(executor, run: 0)
            #expect(await waitUntil { h.summaries.count == 1 })
            if offered == "16.0.0" {
                #expect(h.summaries.first?.title == "Updated 2")
                #expect(h.summaries.first?.body == "ripgrep, wget")
            } else {
                #expect(h.summaries.first?.title == "Updated 1. 1 failed: ripgrep")
                #expect(h.summaries.first?.body == "wget")
            }
        }
    }

    /// R27: a step naming several packages that exits non-zero may still have updated some (Homebrew carries on past
    /// one formula that fails). Each is decided by the reload: still listed failed; gone from an engine that checked
    /// everything is updated, as before 10a.
    @Test func failedBatchStepCountsWhatTheReloadShows() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, jq], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.refs) == [[jq.id, wget.id]])
        h.catalog.script(.outdated, .homebrew, packages: [jq])
        executor.finish([.started(0), .finished(0, 1), .done])
        #expect(await waitUntil { h.summaries.count == 1 })
        #expect(h.summaries.first?.title == "Updated 1. 1 failed: jq")
        #expect(h.summaries.first?.body == "wget")
    }

    /// R27: gone after a failed batch step, from an engine whose check couldn't look it up, BrewxPort can't tell:
    /// "not confirmed", never "updated".
    @Test func failedBatchStepWithAPartialCheckIsNotConfirmed() async {
        let rake = Self.tool(.gem, "rake")
        let thor = Self.tool(.gem, "thor")
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([rake, thor], mode: .passwordFree, executor: executor,
                              engines: PlanFixtures.engines + [ToolEngine(id: .gem)])
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(executor.runs[0].steps.map(\.refs) == [[rake.id, thor.id]])
        h.catalog.script(.outdated, .gem, FakeCatalog.Script(
            result: .success([thor]), unchecked: UncheckedPackages(reasons: ["rake": "RubyGems.org didn't answer"])))
        executor.finish([.started(0), .finished(0, 1), .done])
        #expect(await waitUntil { h.summaries.count == 1 })
        #expect(h.summaries.first?.title == "Updates failed: thor. 1 not confirmed: rake")
        #expect(h.summaries.first?.body == "")
    }

    /// An engine that can't answer the reload can't say what its failed batch step updated: "not confirmed". A step
    /// that worked counts as updated whatever the reload says, unless the reload still lists the package.
    @Test func unansweredEngineCountsSucceededStepsAndLeavesFailedBatchNotConfirmed() async {
        for homebrewSucceeds in [false, true] {
            let executor = FakeRunExecutor(events: [], hang: true)
            let h = await harness([wget, jq, ada], mode: .passwordFree, executor: executor)
            await h.background.checkNow()
            #expect(await waitUntil { executor.runs.count == 1 })
            let steps = executor.runs[0].steps
            #expect(steps.map(\.refs) == [[ada.id], [jq.id, wget.id]])
            // After the run Homebrew can't answer; nanobrew no longer lists ada.
            let broke = EngineError(engine: .homebrew, message: "brew broke")
            h.catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .failure(broke)))
            h.catalog.script(.outdated, .nanobrew, packages: [])
            executor.finish([.started(0), .finished(0, 0), .started(1), .finished(1, homebrewSucceeds ? 0 : 1),
                             .done])
            #expect(await waitUntil { h.summaries.count == 1 })
            if homebrewSucceeds {
                #expect(h.summaries.first?.title == "Updated 3")
                #expect(h.summaries.first?.body == "ada, jq, wget")
            } else {
                #expect(h.summaries.first?.title == "Updated 1. 2 not confirmed: jq, wget")
                #expect(h.summaries.first?.body == "ada")
            }
        }
    }

    @Test func summaryWhenNothingUpdatedSaysUpdatesFailed() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, jq], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        // Homebrew still lists both after the run.
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        let title = h.summaries.first?.title ?? ""
        #expect(title.hasPrefix("Updates failed: "))
        #expect(Set(title.dropFirst("Updates failed: ".count).components(separatedBy: ", ")) == ["wget", "jq"])
        #expect(h.summaries.first?.body == "")
    }

    @Test func autoRunSummaryNamesFailures() async throws {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget, jq, ada], mode: .passwordFree, executor: executor)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        // After the run Homebrew still lists jq: its update didn't happen.
        h.catalog.script(.outdated, .homebrew, packages: [jq])
        h.catalog.script(.outdated, .nanobrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        let summary = try #require(h.summaries.first)
        #expect(summary.title == "Updated 2. 1 failed: jq")
        #expect(Set(summary.body.components(separatedBy: ", ")) == ["wget", "ada"])
        #expect(summary.id != BackgroundUpdater.availableID)
        // A failure isn't retried until the next check.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.count == 1)
        // Clicking it shows the run's panel in the window.
        h.model.run.dismissPanel()
        h.notifier.click(summary)
        #expect(h.model.run.panelVisible)
        #expect(h.windowOpens.count == 1)
    }

    @Test func summaryClickShowsItsOwnRunOnly() async throws {
        let store = MemoryStore()
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget], mode: .passwordFree, executor: executor, store: store)
        await h.background.checkNow()
        #expect(await waitUntil { executor.runs.count == 1 })
        h.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(executor, run: 0)
        #expect(await waitUntil { h.summaries.count == 1 })
        let first = try #require(h.summaries.first)
        // The person runs something else since: the panel would show that run, so the click only opens Updates.
        #expect(h.model.installRequests([ActionRequest(operation: .install, package: jq)]))
        #expect(await waitUntil { executor.runs.count == 2 })
        Self.succeed(executor, run: 1)
        #expect(await waitUntil { !h.model.run.isRunning })
        h.model.run.dismissPanel()
        h.model.sidebar = .installed
        h.notifier.click(first)
        #expect(!h.model.run.panelVisible)
        #expect(h.model.sidebar == .updates)
        #expect(h.windowOpens.count == 1)
        // The next launch's first automatic run gets an id of its own, so its summary doesn't replace this one.
        let next = await harness([wget], mode: .passwordFree, executor: FakeRunExecutor(events: [], hang: true),
                                 store: store)
        await next.background.checkNow()
        #expect(await waitUntil { next.executor.runs.count == 1 })
        next.catalog.script(.outdated, .homebrew, packages: [])
        Self.succeed(next.executor, run: 0)
        #expect(await waitUntil { next.summaries.count == 1 })
        #expect(next.summaries.first?.id != first.id)
    }

    // MARK: Checks off, and the person busy

    @Test func neverDropsAutomaticWorkThatWaited() async {
        // Held for power, then checks turned off: power coming back starts nothing.
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.batteryLow = true
        let h = await harness([wget], mode: .passwordFree, executor: executor, conditions: conditions)
        await h.background.checkNow()
        h.background.settings.interval = .never
        h.background.scheduleFromSettings()
        conditions.batteryLow = false
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(executor.runs.isEmpty)

        // Update everything's password part waits for the person, then checks are turned off: their return starts
        // nothing, and no window comes up.
        let away = FakeConditions()
        away.idleSeconds = 900
        let w = await harness([curl], mode: .everything, executor: FakeRunExecutor(events: [], hang: true),
                              conditions: away)
        await w.background.checkNow()
        #expect(w.background.state == .waitingForUser(count: 1))
        w.background.settings.interval = .never
        w.background.scheduleFromSettings()
        #expect(w.background.state == .idle)
        away.idleSeconds = 0
        away.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(w.executor.runs.isEmpty)
        #expect(w.windowOpens.count == 0)
    }

    @Test func automaticRunWaitsForAnExport() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget], mode: .passwordFree, executor: executor)
        // The person exports; reading the installed packages takes a while.
        let gate = Gate()
        h.catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([wget]), gate: gate))
        let export = Task { await h.model.export(.bundle) }
        #expect(await waitUntil { h.model.exporting && gate.waiting == 1 })
        // A check meanwhile: it tells, and its automatic run waits rather than stop the export.
        await h.background.checkNow()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.isEmpty)
        #expect(h.available.count == 1)
        #expect(await waitUntil { gate.waiting == 2 })
        gate.release()
        await export.value
        #expect(h.model.exportMessage == nil)
        #expect(h.model.exportToSave != nil)
        // The save panel is up: still waiting.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(executor.runs.isEmpty)
        // The person saves: the automatic run goes ahead.
        h.model.exportFinished(.success(URL(fileURLWithPath: "/tmp/Mac.brewxportbundle")))
        #expect(await waitUntil { executor.runs.count == 1 })
        #expect(Set(executor.runs[0].steps.map(\.engine)) == [.homebrew])
        #expect(h.model.lastRunOrigin == .background)
    }

    @Test func passwordRunWaitsForAnExport() async {
        let executor = FakeRunExecutor(events: [], hang: true)
        let conditions = FakeConditions()
        conditions.idleSeconds = 900
        let h = await harness([curl], mode: .everything, executor: executor, conditions: conditions)
        await h.background.checkNow()
        #expect(h.background.state == .waitingForUser(count: 1))
        let gate = Gate()
        h.catalog.script(.installed, .homebrew, FakeCatalog.Script(result: .success([]), gate: gate))
        let export = Task { await h.model.export(.bundle) }
        #expect(await waitUntil { h.model.exporting && gate.waiting == 1 })
        // The person is back, but the export is being read: the window and the sheet wait.
        conditions.idleSeconds = 0
        conditions.change()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.windowOpens.count == 0)
        #expect(executor.runs.isEmpty)
        gate.release()
        await export.value
        #expect(h.model.exportMessage == nil)
        h.model.exportFinished(nil)
        #expect(await waitUntil { executor.runs.count == 1 })
    }

    @Test func clickingUpdatesNotificationOpensUpdates() async {
        let h = await harness([wget])
        h.model.sidebar = .installed
        h.notifier.click(.updates)
        #expect(h.model.sidebar == .updates)
        #expect(h.windowOpens.count == 1)
    }

    // MARK: The model going away

    /// A harness the test has let go of: only weak references to its model and updater, so the updater's own tasks
    /// are all that can still hold them.
    @MainActor final class Dropped {
        weak var model: BrewxPortAppModel?
        weak var background: BackgroundUpdater?
        let notifier: FakeNotifier

        init(_ h: Harness) {
            model = h.model
            background = h.background
            notifier = h.notifier
        }
    }

    /// An automatic run has ended, and the updater is handling its end (held at `autoRunEndPause`) when the harness
    /// is let go of.
    func autoRunEndPending(_ gate: Gate) async -> Dropped {
        let executor = FakeRunExecutor(events: [], hang: true)
        let h = await harness([wget], mode: .passwordFree, executor: executor)
        h.background.autoRunEndPause = { await gate.wait() }
        await h.background.checkNow()
        _ = await waitUntil { executor.runs.count == 1 }
        Self.succeed(executor, run: 0)
        _ = await waitUntil { gate.waiting == 1 }
        return Dropped(h)
    }

    @Test func modelGoingAwayEndsAPendingAutoRunEnd() async {
        let gate = Gate()
        let dropped = await autoRunEndPending(gate)
        #expect(gate.waiting == 1)
        // The model goes (the app quitting, a test ending) before the run's end is handled; the updater's task then
        // goes on, finds it gone, and does nothing.
        #expect(await waitUntil { dropped.model == nil })
        gate.release()
        #expect(await waitUntil { dropped.background == nil })
        #expect(dropped.notifier.posts.filter { $0.target == .runLog }.isEmpty)
    }

    /// A check (from a task of its own, as the schedule's and the one-time sheet's are) is reading the reloaded
    /// lists, which wait for `gate`, when the harness is let go of.
    func checkPendingOnReload(_ gate: Gate, done: Done) async -> Dropped {
        let h = await harness([wget])
        h.catalog.script(.outdated, .homebrew, FakeCatalog.Script(result: .success([wget]), gate: gate))
        let background = h.background
        Task {
            await background.checkNow()
            done.value = true
        }
        _ = await waitUntil { gate.waiting == 1 }
        return Dropped(h)
    }

    @Test func modelGoingAwayEndsAPendingCheck() async {
        let gate = Gate()
        let done = Done()
        let dropped = await checkPendingOnReload(gate, done: done)
        #expect(gate.waiting == 1)
        #expect(await waitUntil { dropped.model == nil })
        gate.release()
        #expect(await waitUntil { done.value })
        #expect(await waitUntil { dropped.background == nil })
        #expect(dropped.notifier.posts.isEmpty)
    }

    /// A check is waiting for a run that never ends (the person's, hanging) when the harness is let go of.
    func checkWaitingForRun(done: Done) async -> Dropped {
        let executor = FakeRunExecutor(events: [.started(0)], hang: true)
        let h = await harness([wget], executor: executor)
        h.model.updateAll()
        _ = await waitUntil { h.model.run.isRunning && executor.runs.count == 1 }
        let background = h.background
        Task {
            await background.checkNow()
            done.value = true
        }
        _ = await waitUntil { h.background.state == .checking }
        return Dropped(h)
    }

    @Test func modelGoingAwayEndsACheckWaitingForARun() async {
        let done = Done()
        let dropped = await checkWaitingForRun(done: done)
        #expect(await waitUntil { dropped.model == nil })
        // The wait for the run's end ends with the model, so neither the check's task nor the updater stays behind.
        #expect(await waitUntil { done.value })
        #expect(await waitUntil { dropped.background == nil })
        #expect(dropped.notifier.posts.isEmpty)
    }
}
