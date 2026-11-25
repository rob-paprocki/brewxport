import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Homebrew has wget (asked for) and libidn2 (a dependency only wget uses); MacPorts has curl (asked for); nanobrew
/// has jq. Each engine's dependents are canned (`MoveFakeEngine`); dependencies come from the catalog's `info`.
@MainActor struct UninstallScenario {
    let catalog = FakeCatalog(engines: [
        .homebrew: .present(path: URL(fileURLWithPath: PlanFixtures.brewPath), version: "4"),
        .nanobrew: .present(path: URL(fileURLWithPath: PlanFixtures.nbPath), version: "1"),
        .macports: .present(path: URL(fileURLWithPath: PlanFixtures.portPath), version: "2"),
    ])
    let executor: FakeRunExecutor
    let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
    let nb = MappingFakeEngine(wrapping: PlanFixtures.engines[1])
    let port = MoveFakeEngine(wrapping: PlanFixtures.engines[2])
    let model: BrewxPortAppModel

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String, onRequest: Bool?) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1",
                latestVersion: "1", installedOnRequest: onRequest)
    }
    static let wget = package(.homebrew, .formula, "wget", onRequest: true)
    static let libidn2 = package(.homebrew, .formula, "libidn2", onRequest: false)
    static let curl = package(.macports, .port, "curl", onRequest: true)
    static let jq = package(.nanobrew, .formula, "jq", onRequest: nil)

    /// `executor: nil` is a copy that can't run anything; `self.executor` is then a spare that never runs.
    init(executor: FakeRunExecutor? = FakeRunExecutor(), isDemo: Bool = false,
         homebrew: [Package] = [wget, libidn2], isAdministrator: Bool? = true) {
        self.executor = executor ?? FakeRunExecutor()
        let engines: [any Engine] = [brew, nb, port, PlanFixtures.engines[3]]
        // A ready helper, so MacPorts removals aren't left out by the preflight.
        model = BrewxPortAppModel(services: AppFixtures.services(catalog: catalog, executor: executor,
                                                                helper: isDemo ? nil : FakeHelperManager(),
                                                                isDemo: isDemo, isAdministrator: isAdministrator,
                                                                engines: engines))
        catalog.script(.installed, .homebrew, packages: homebrew)
        catalog.script(.installed, .macports, packages: [Self.curl])
        catalog.script(.installed, .nanobrew, packages: [Self.jq])
        brew.setDependents("libidn2", ["wget"])
        dependencies(.homebrew, .formula, "wget", ["libidn2"])
        dependencies(.homebrew, .formula, "libidn2", [])
        dependencies(.macports, .port, "curl", [])
    }

    func dependencies(_ engine: EngineID, _ kind: PackageKind, _ name: String, _ needs: [String]?) {
        let ref = PackageRef(engine: engine, kind: kind, name: name)
        catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: needs))))
    }

    /// Loads Installed, then starts an uninstall of `packages`.
    func start(_ packages: [Package] = [wget]) async {
        model.installed.reload()
        await model.installed.settled()
        model.perform(.uninstall, on: Set(packages.map(\.id)))
    }

    func ready() async -> UninstallPlan? {
        _ = await waitUntil { if case .checking = model.uninstall.state { false } else { true } }
        if case .ready(let plan) = model.uninstall.state { return plan }
        return nil
    }

    var installedQueries: Int { catalog.queries.filter { if case .installed = $0 { true } else { false } }.count }
}

@MainActor @Suite struct UninstallModelTests {
    typealias S = UninstallScenario

    static func names(_ steps: [RunStep]) -> [String] {
        steps.map { $0.spec.arguments.last ?? "" }
    }

    @Test func startShowsCheckingThenTheLeftovers() async throws {
        let s = S()
        await s.start()
        #expect(s.model.uninstall.state == .checking)
        #expect(s.model.uninstall.sheetShown)
        #expect(s.model.confirmingRemoval)
        let plan = try #require(await s.ready())
        #expect(plan.sections.count == 1)
        #expect(plan.sections[0].picks.map(\.id.name) == ["wget"])
        #expect(plan.sections[0].leftovers.map(\.id.name) == ["libidn2"])
        #expect(plan.sections[0].removeLeftovers)
        #expect(s.executor.runs.isEmpty)
    }

    @Test func oneManagerCheckFailsOtherStillOffered() async throws {
        let s = S()
        s.port.failDependents("curl")
        await s.start([S.wget, S.curl])
        let plan = try #require(await s.ready())
        #expect(plan.sections.map(\.engine) == [.homebrew, .macports])
        #expect(plan.sections[0].leftovers.map(\.id.name) == ["libidn2"])
        #expect(plan.sections[0].note == nil)
        #expect(plan.sections[1].picks.map(\.id.name) == ["curl"])
        #expect(plan.sections[1].leftovers.isEmpty)
        #expect(plan.sections[1].note == "Couldn't work out leftovers for MacPorts.")
        // The failed check only costs MacPorts its box: curl is still removed, after Homebrew's removals.
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(Self.names(s.executor.runs[0].steps) == ["wget", "libidn2", "curl"])
    }

    @Test func caskDependenciesOffered() async throws {
        // droid's details are the real `brew info --json=v2 --cask droid` capture, read by HomebrewEngine: it needs
        // ripgrep. ripgrep needs pcre2, both installed as dependencies (`info-installed-cask-deps.json`), and
        // `brew uses --installed ripgrep` lists the cask (`uses-installed-ripgrep-cask.txt`).
        let droid = S.package(.homebrew, .cask, "droid", onRequest: nil)
        let ripgrep = S.package(.homebrew, .formula, "ripgrep", onRequest: false)
        let pcre2 = S.package(.homebrew, .formula, "pcre2", onRequest: false)
        let s = S(homebrew: [droid, ripgrep, pcre2])
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrewxPortCoreTests/Fixtures/homebrew/info-cask-droid.json")
        let runner = UIFakeRunner()
        runner.respond(["info", "--json=v2", "--cask", "droid"],
                       CommandResult(exitCode: 0, stdout: try String(contentsOf: fixture, encoding: .utf8), stderr: ""))
        let engine = HomebrewEngine(runner: runner, executable: URL(fileURLWithPath: PlanFixtures.brewPath),
                                    arch: .arm64)
        s.catalog.scriptInfo(droid.id, .init(result: .success(try await engine.info(droid.id))))
        s.dependencies(.homebrew, .formula, "ripgrep", ["pcre2"])
        s.dependencies(.homebrew, .formula, "pcre2", [])
        s.brew.setDependents("ripgrep", ["droid"])
        s.brew.setDependents("pcre2", ["ripgrep"])

        await s.start([droid])
        let plan = try #require(await s.ready())
        #expect(plan.sections[0].leftovers.map(\.id.name) == ["pcre2", "ripgrep"])
        #expect(plan.sections[0].removeLeftovers)
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(s.executor.runs[0].steps.map(\.spec.arguments) == [["uninstall", "--cask", "droid"],
                                                                   ["uninstall", "--formula", "ripgrep"],
                                                                   ["uninstall", "--formula", "pcre2"]])
    }

    @Test func untickingLeavesTheLeftovers() async throws {
        let s = S()
        await s.start([S.wget, S.curl])
        _ = try #require(await s.ready())
        s.model.uninstall.setRemoveLeftovers(false, engine: .homebrew)
        guard case .ready(let plan) = s.model.uninstall.state else { Issue.record("not ready"); return }
        #expect(plan.sections[0].removeLeftovers == false)
        // A manager without leftovers can't be ticked.
        s.model.uninstall.setRemoveLeftovers(true, engine: .macports)
        guard case .ready(let after) = s.model.uninstall.state else { Issue.record("not ready"); return }
        #expect(after.sections[1].removeLeftovers == false)
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(Self.names(s.executor.runs[0].steps) == ["wget", "curl"])
    }

    @Test func installedFailedForAManagerSaysLeftoversUnknown() async throws {
        // Installed couldn't list Homebrew, so wget is picked from Updates. Without Installed's rows BrewxPort can't
        // tell what's a leftover: the sheet says so instead of showing no box and no note.
        let s = S()
        s.catalog.script(.installed, .homebrew,
                         .init(result: .failure(EngineError(engine: .homebrew, message: "brew list failed"))))
        s.catalog.script(.outdated, .homebrew, packages: [S.wget])
        s.catalog.scriptEmpty(.outdated)
        s.model.updates.reload()
        await s.model.updates.list.settled()
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.sections.map(\.engine) == [.homebrew])
        #expect(plan.sections[0].picks.map(\.id.name) == ["wget"])
        #expect(plan.sections[0].leftovers.isEmpty)
        #expect(plan.sections[0].note == "Couldn't work out leftovers for Homebrew.")
        // wget is still removed.
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(Self.names(s.executor.runs[0].steps) == ["wget"])
    }

    @Test func nanobrewPickWithADependentIsBlocked() async throws {
        let s = S()
        let oniguruma = S.package(.nanobrew, .formula, "oniguruma", onRequest: nil)
        s.catalog.script(.installed, .nanobrew, packages: [S.jq, oniguruma])
        s.nb.setDependents("oniguruma", ["jq"])
        await s.start([oniguruma])
        let plan = try #require(await s.ready())
        #expect(plan.sections[0].picks.isEmpty)
        #expect(plan.sections[0].blocked.map(\.reason) == ["needed by jq."])
        // Nothing would be removed, so confirming starts nothing.
        s.model.uninstall.confirm()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.executor.runs.isEmpty)
        #expect(!s.model.run.isRunning)
    }

    @Test func cancelWhileCheckingRunsNothing() async throws {
        let s = S()
        let gate = Gate()
        s.brew.gate = gate
        await s.start()
        #expect(await waitUntil { gate.waiting == 1 })
        s.model.uninstall.cancel()
        #expect(s.model.uninstall.state == .hidden)
        #expect(!s.model.confirmingRemoval)
        s.brew.gate = nil
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        // The check that was going is dropped, and a confirm now does nothing.
        #expect(s.model.uninstall.state == .hidden)
        s.model.uninstall.confirm()
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.executor.runs.isEmpty)

        // The next start is a fresh check, not the dropped one's sheet.
        await s.start([S.curl])
        let plan = try #require(await s.ready())
        #expect(plan.sections.map(\.engine) == [.macports])
        s.model.uninstall.cancel()
        #expect(s.model.uninstall.state == .hidden)
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.executor.runs.isEmpty)
    }

    @Test func confirmStartsOneRun() async throws {
        let s = S(executor: FakeRunExecutor(events: [.started(0)], hang: true))
        await s.start()
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        #expect(s.model.uninstall.state == .running)
        #expect(!s.model.uninstall.sheetShown)
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(s.executor.runs[0].reason == "BrewxPort needs an administrator password to uninstall these packages.")
        #expect(Self.names(s.executor.runs[0].steps) == ["wget", "libidn2"])
        #expect(s.executor.runs[0].steps.allSatisfy { $0.userEnvironment == ["HOMEBREW_NO_AUTOREMOVE": "1"] })
        // A second confirm, or a new uninstall, while it runs does nothing.
        s.model.uninstall.confirm()
        s.model.perform(.uninstall, on: [S.curl.id])
        try await Task.sleep(for: .milliseconds(50))
        #expect(s.executor.runs.count == 1)
        #expect(s.model.uninstall.state == .running)
        s.model.run.cancel()
        #expect(await waitUntil { s.model.uninstall.state == .hidden && !s.model.run.isRunning })
    }

    @Test func installedReloadedAfter() async throws {
        let s = S()
        await s.start()
        _ = try #require(await s.ready())
        let before = s.model.installed.reloadCount
        let queries = s.installedQueries
        s.model.uninstall.confirm()
        #expect(await waitUntil { !s.model.run.isRunning && s.executor.runs.count == 1 })
        #expect(await waitUntil { s.model.installed.reloadCount == before + 1 })
        #expect(await waitUntil { s.installedQueries == queries + 1 })
        #expect(s.model.uninstall.state == .hidden)
    }

    @Test func failedRemovalSaysWhatStayed() async throws {
        let s = S(executor: FakeRunExecutor(events: [.started(0), .finished(0, 1), .done]))
        await s.start()
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        let line = "Removing wget from Homebrew failed, so wget and libidn2 are still installed."
        #expect(await waitUntil { s.model.run.problems.contains(line) })
        #expect(s.model.uninstall.state == .hidden)
    }

    @Test func successfulUninstallAddsNoLine() async throws {
        let events: [RunEvent] = [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .done]
        let s = S(executor: FakeRunExecutor(events: events))
        await s.start()
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.model.uninstall.state == .hidden && !s.model.run.isRunning })
        #expect(s.model.run.problems.isEmpty)
    }

    @Test func demoModeStillUninstalls() async throws {
        // Uninstall worked in demo mode before the sheet, and still does (Move to is the one that's off there).
        let s = S(isDemo: true)
        await s.start()
        let plan = try #require(await s.ready())
        #expect(plan.sections[0].leftovers.map(\.id.name) == ["libidn2"])
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
    }

    @Test func nothingStartsWhenThisCopyCannotRun() async {
        let s = S(executor: nil)
        await s.start()
        #expect(s.model.uninstall.state == .hidden)
        s.model.uninstall.start([S.wget.id])
        #expect(s.model.uninstall.state == .hidden)
    }

    @Test func unknownRefsOpenNothing() async {
        let s = S()
        await s.start([S.package(.homebrew, .formula, "nothere", onRequest: true)])
        #expect(s.model.uninstall.state == .hidden)
    }

    // MARK: Standard account

    static let adminLine = "Removing these needs an administrator account."

    @Test func standardUserSeesAdminLine() async throws {
        let s = S(isAdministrator: false)
        await s.start([S.wget, S.curl])
        let plan = try #require(await s.ready())
        let confirmation = s.model.uninstall.confirmation(for: plan)
        #expect(confirmation.line == Self.adminLine)
        // Only Homebrew's wget and its leftover will go; MacPorts' curl is left out and its section says so.
        #expect(confirmation.button == "Uninstall 2 packages")
        #expect(confirmation.enabled)
        #expect(confirmation.skipped == [.macports])
        // An administrator gets the password line instead.
        let admin = S()
        await admin.start([S.wget, S.curl])
        let adminPlan = try #require(await admin.ready())
        let adminConfirmation = admin.model.uninstall.confirmation(for: adminPlan)
        #expect(adminConfirmation.line == UninstallSheetText.password)
        #expect(adminConfirmation.button == "Uninstall 3 packages")
        #expect(adminConfirmation.skipped.isEmpty)
    }

    @Test func standardUserRootOnlyUninstallDisabled() async throws {
        let s = S(isAdministrator: false)
        await s.start([S.curl])
        let plan = try #require(await s.ready())
        let confirmation = s.model.uninstall.confirmation(for: plan)
        #expect(confirmation.line == Self.adminLine)
        #expect(!confirmation.enabled)
        #expect(confirmation.skipped == [.macports])
    }

    @Test func standardUserHomebrewFormulaStillAllowed() async throws {
        let s = S(isAdministrator: false)
        await s.start([S.wget])
        let plan = try #require(await s.ready())
        let confirmation = s.model.uninstall.confirmation(for: plan)
        // A Homebrew formula is removed as you: no password, no administrator needed.
        #expect(confirmation.line == nil)
        #expect(confirmation.enabled)
        #expect(confirmation.button == "Uninstall 2 packages")
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.executor.runs.count == 1 })
        #expect(Self.names(s.executor.runs[0].steps) == ["wget", "libidn2"])
    }

    @Test func standardUserMixedUninstallRunsOnlyWhatItCan() async throws {
        let events: [RunEvent] = [.started(0), .finished(0, 0), .started(1), .finished(1, 0), .done]
        let s = S(executor: FakeRunExecutor(events: events), isAdministrator: false)
        await s.start([S.wget, S.curl])
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        #expect(await waitUntil { s.model.uninstall.state == .hidden && !s.model.run.isRunning })
        #expect(Self.names(s.executor.runs[0].steps) == ["wget", "libidn2"])
        // The left-out MacPorts removal is said once, and not reported as a failed removal.
        #expect(s.model.run.problems.count == 1)
        #expect(s.model.run.problems[0].contains("need an administrator account"))
        #expect(!s.model.run.problems.contains { $0.contains("failed") })
    }

    @Test func standardUserUninstallThatCannotRunSaysWhy() async throws {
        // The button is off for this one, but a confirm that gets through anyway still says why nothing happened.
        let s = S(isAdministrator: false)
        await s.start([S.curl])
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        #expect(s.model.uninstall.state == .hidden)
        #expect(s.executor.runs.isEmpty)
        #expect(s.model.run.panelVisible)
        #expect(s.model.run.headline == "Nothing ran")
        #expect(s.model.run.problems == ["Skipped MacPorts: curl: they need an administrator account, and this one isn't."])
    }
}
