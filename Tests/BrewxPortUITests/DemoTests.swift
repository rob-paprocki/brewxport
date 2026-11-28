import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Keeps the buffer it hands over, so a test can check the executor wiped it.
@MainActor private final class KeepingPrompter: PasswordPrompting {
    private(set) var reasons: [String] = []
    private(set) var given: [SecretBuffer] = []
    var password: String?

    init(password: String?) { self.password = password }

    func askForPassword(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer? {
        reasons.append(reason)
        guard let password else { return nil }
        let buffer = SecretBuffer(copying: Array(password.utf8))
        given.append(buffer)
        return buffer
    }
}

/// Counts the demo executor's pauses, from whatever thread it pauses on.
private final class PauseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@MainActor @Suite struct DemoTests {
    static let program = "/Applications/BrewxPort.app/Contents/MacOS/BrewxPort"

    static func options(_ host: Arch = .arm64) -> DemoOptions {
        var options = DemoOptions()
        options.fixtures = UIFixtures.directory
        options.host = host
        return options
    }

    static func services(_ host: Arch = .arm64) throws -> Services {
        try DemoServices.make(options(host), delay: .zero)
    }

    static func engine(_ services: Services, _ id: EngineID) -> any Engine {
        services.engines.first { $0.id == id }!
    }

    static func merged(_ services: Services, _ query: CatalogQuery) async -> CatalogResult {
        var outcomes: [EngineOutcome] = []
        for await outcome in services.catalog.stream(query) { outcomes.append(outcome) }
        return PackageCatalog.merge(outcomes, order: PackageCatalog.defaultOrder(for: services.host))
    }

    static func step(_ services: Services, _ operation: PackageOperation, _ ref: PackageRef) throws -> RunStep {
        let spec = try engine(services, ref.engine).command(for: operation, [ref], options: InstallOptions())
        return RunStep(engine: ref.engine, kind: ref.kind, operation: operation, spec: spec, title: ref.name)
    }

    static func collect(_ stream: AsyncStream<RunEvent>) async -> [RunEvent] {
        var events: [RunEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    static let adaURL = PackageRef(engine: .homebrew, kind: .formula, name: "ada-url")
    static let figlet = PackageRef(engine: .macports, kind: .port, name: "figlet")

    // MARK: Flags

    @Test func parsesDemoFlags() {
        let all = LaunchMode.parse([Self.program, "--demo", "--demo-fixtures", "/tmp/fixtures", "--appearance", "dark",
                                    "--snapshot", "/tmp/snaps", "--demo-arch", "x86_64"])
        var want = DemoOptions()
        want.fixtures = URL(fileURLWithPath: "/tmp/fixtures")
        want.appearance = .dark
        want.snapshot = URL(fileURLWithPath: "/tmp/snaps")
        want.host = .x86_64
        #expect(all == .demo(want))

        var light = DemoOptions()
        light.appearance = .light
        light.host = .arm64
        #expect(LaunchMode.parse([Self.program, "--demo", "--appearance", "light", "--demo-arch", "arm64"])
                == .demo(light))

        // Unknown values, and a flag with no value, are ignored.
        #expect(LaunchMode.parse([Self.program, "--demo", "--appearance", "purple", "--demo-arch", "ppc"])
                == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo", "--snapshot"]) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-fixtures", "--appearance", "dark"])
                == .demo({ var o = DemoOptions(); o.appearance = .dark; return o }()))
        // Demo flags without --demo don't make a demo launch.
        #expect(LaunchMode.parse([Self.program, "--appearance", "dark", "--snapshot", "/tmp/s"]) == .normal)
    }

    /// `--demo-missing ENGINE` (once per engine) shows a language engine as not installed, so its Set Up can be seen.
    /// Only language engines: the demo's system engines are what everything else stands on.
    @Test func parsesDemoMissing() {
        var want = DemoOptions()
        want.missing = [.cargo, .mint]
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-missing", "cargo", "--demo-missing", "mint"])
                == .demo(want))
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-missing", "homebrew"]) == .demo(DemoOptions()))
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-missing", "rust"]) == .demo(DemoOptions()))
    }

    @Test func demoMissingEngineIsNotInstalled() async throws {
        var options = Self.options()
        options.missing = [.cargo]
        let services = try DemoServices.make(options, delay: .zero)
        let statuses = await services.catalog.presentEngines()
        #expect(statuses[.cargo] == .missing)
        #expect(statuses[.npm] != .missing)
        let model = BrewxPortAppModel(services: services)
        model.checkEnginesAgain()
        _ = await waitUntil { model.enginesChecked }
        #expect(model.setupButton(for: .cargo) == .disabled(title: "Set Up Cargo…", help: "Not available in demo mode"))
        #expect(model.setupLine(for: .cargo) == "Set Up installs Homebrew's rustup, then Rust's stable toolchain.")
    }

    @Test func demoStartupWinsOverMarker() {
        let mode = LaunchMode.parse([Self.program, "--demo", "--appearance", "dark"])
        #expect(StartupPolicy.decide(mode: mode, developmentMac: true) == .demo)
        #expect(StartupPolicy.decide(mode: mode, developmentMac: false) == .demo)
    }

    // MARK: Services

    @Test func demoServicesAreAllDemoTypes() async throws {
        let services = try DemoServices.make(Self.options())
        #expect(services.executor is DemoRunExecutor)
        #expect(services.helper == nil)
        #expect(services.store is MemoryStore)
        #expect(services.isDemo)
        #expect(services.setupProblem == nil)
        #expect(services.isAdministrator() == true)
        #expect(services.engines.map(\.id) == EngineID.allCases)
        for engine in services.engines {
            let demo = engine as? DemoEngine
            #expect(demo != nil)
            #expect(demo?.runner.fixtures == UIFixtures.directory)
            // The demo plans like the real app: each engine's own command limits.
            for operation in [PackageOperation.install, .upgrade, .remove] {
                #expect(engine.maxTargetsPerCommand(for: operation)
                        == demo?.wrapped.maxTargetsPerCommand(for: operation), "\(engine.id) \(operation)")
            }
        }
        #expect(services.engines.first { $0.id == .mint }?.maxTargetsPerCommand(for: .remove) == 1)
        let path = await services.path.resolve()
        #expect(path == ResolvedPath(entries: ["/opt/homebrew/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                                               "/usr/bin", "/bin"], source: .loginShell))
        // Every engine, the system ones and all seven language ones, answers its version command from the fixtures.
        let statuses = await services.catalog.presentEngines()
        for id in EngineID.allCases {
            if case .present? = statuses[id] {} else { Issue.record("\(id) is \(String(describing: statuses[id]))") }
        }
        // fileExists follows the fixture inventory, never the disk.
        #expect(services.fileExists("/opt/homebrew/bin/ada-url"))
        #expect(services.fileExists("/opt/local/bin/figlet"))
        #expect(services.fileExists("/opt/nanobrew/prefix/bin/jq"))
        #expect(services.fileExists("/opt/homebrew/bin/cowsay"))
        #expect(services.fileExists("/opt/homebrew/bin/isort"))
        #expect(!services.fileExists("/opt/homebrew/bin/jq"))
        #expect(!services.fileExists("/bin/sh"))
        #expect(!services.fileExists("/opt/local/bin/ripgrep"))
        // The background seams never reach the system: no schedule, notification or login item is registered.
        #expect(services.scheduler is DemoScheduler)
        #expect(services.notifier is DemoNotifier)
        #expect(services.loginItem is DemoLoginItem)
        #expect(services.conditions is DemoConditions)
        // The person is at the Mac, and it's on power.
        #expect(services.conditions.userIsActive(within: 600))
        #expect(services.conditions.screenLocked == false)
        #expect(services.conditions.batteryLow == false)
        #expect(services.conditions.lowPowerMode == false)
    }

    @Test func demoSeamsOnlyRecord() async throws {
        let services = try DemoServices.make(Self.options())
        let scheduler = try #require(services.scheduler as? DemoScheduler)
        var fired = false
        scheduler.schedule(every: 60, firstAfter: 30) { fired = true }
        #expect(scheduler.interval == 60)
        await Task.yield()
        #expect(fired == false)
        scheduler.cancel()
        #expect(scheduler.interval == nil)

        let notifier = try #require(services.notifier as? DemoNotifier)
        // Granted, so a demo Notifications switch stays on.
        #expect(await notifier.requestPermission())
        notifier.post(id: "check-1", title: "3 updates available", body: "Homebrew 3", target: .updates)
        #expect(notifier.permissionRequests == 1)
        #expect(notifier.posted == [DemoNotifier.Post(id: "check-1", title: "3 updates available",
                                                      body: "Homebrew 3", target: .updates)])

        let loginItem = try #require(services.loginItem as? DemoLoginItem)
        #expect(loginItem.isEnabled == false)
        #expect(loginItem.needsApproval == false)
        try loginItem.setEnabled(true)
        #expect(loginItem.isEnabled)
        try loginItem.setEnabled(false)
        #expect(loginItem.isEnabled == false)
        #expect(loginItem.changes == [true, false])
    }

    @Test func demoWithoutFixturesThrows() {
        var options = DemoOptions()
        options.fixtures = URL(fileURLWithPath: "/nonexistent/brewxport-demo-fixtures")
        #expect(throws: DemoServicesError.noFixtures) { try DemoServices.make(options) }
        #expect(DemoServices.noFixturesMessage.contains("scripts/demo.sh"))
    }

    @Test func demoTextsForTheWindow() throws {
        let model = BrewxPortAppModel(services: try Self.services())
        #expect(model.helperText == "Demo mode: BrewxPort's helper isn't used.")
        #expect(model.passwordNote == "Demo mode: type anything. Nothing is checked or kept.")
        #expect(model.windowTitle == "BrewxPort (demo)")
        let live = BrewxPortAppModel(services: AppFixtures.services())
        #expect(live.passwordNote == nil)
        #expect(live.windowTitle == "BrewxPort")
    }

    // MARK: FixtureRunner

    @Test func fixtureRunnerRejectsUnmappedArgv() async {
        let runner = FixtureRunner(fixtures: UIFixtures.directory, host: .arm64)
        let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        await #expect(throws: FixtureRunnerError.unmapped(["install", "wget"])) {
            try await runner.run(brew, ["install", "wget"])
        }
        await #expect(throws: FixtureRunnerError.unmapped(["info", "--json=v2", "--formula", "wget"])) {
            try await runner.run(brew, ["info", "--json=v2", "--formula", "wget"])
        }
        // The table is per tool: `version` is port's and mas's, not brew's.
        await #expect(throws: FixtureRunnerError.unmapped(["version"])) { try await runner.run(brew, ["version"]) }
        await #expect(throws: FixtureRunnerError.unmapped(["--version"])) {
            try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["--version"])
        }
        let mapped = try? await runner.run(brew, ["--version"])
        #expect(mapped?.exitCode == 0)
        #expect(mapped?.stdout.hasPrefix("Homebrew ") == true)
    }

    @Test func fixtureRunnerNeverStreams() async {
        let runner = FixtureRunner(fixtures: UIFixtures.directory, host: .arm64)
        await #expect(throws: FixtureRunnerError.self) {
            _ = try await runner.stream(URL(fileURLWithPath: "/opt/homebrew/bin/brew"), ["--version"],
                                        options: RunOptions()) { _ in }
        }
    }

    /// Every engine has a folder for its tools in demo mode, whichever Mac the demo pretends to be, so nothing the demo
    /// lists can stop it (Task 1 review: no force unwrap).
    @Test func demoBinDirectoryForEveryEngine() {
        for host in [Arch.arm64, .x86_64] {
            for id in EngineID.allCases {
                #expect(DemoServices.binDirectory(id, host: host).hasPrefix("/"), "\(id) \(host)")
            }
        }
        #expect(DemoServices.binDirectory(.homebrew, host: .arm64) == "/opt/homebrew/bin")
        #expect(DemoServices.binDirectory(.homebrew, host: .x86_64) == "/usr/local/bin")
        #expect(DemoServices.binDirectory(.npm, host: .x86_64) == "/usr/local/bin")
        #expect(DemoServices.binDirectory(.cargo, host: .arm64) == "/opt/homebrew/opt/rustup/bin")
        #expect(DemoServices.binDirectory(.cargo, host: .x86_64) == "/usr/local/opt/rustup/bin")
        #expect(DemoServices.binDirectory(.macports, host: .arm64) == "/opt/local/bin")
        #expect(DemoServices.binDirectory(.nanobrew, host: .arm64) == "/opt/nanobrew/prefix/bin")
    }

    /// Only a registry answer the fixtures don't have makes an empty search (pipx's and uv's exact-name lookup on
    /// PyPI). A command the table doesn't map is a gap in the fixtures, and shows as that engine's error (Task 4
    /// review).
    @Test func demoSearchHidesOnlyRegistryMisses() async throws {
        let services = try Self.services()
        #expect(try await Self.engine(services, .pipx).search("jq").isEmpty)
        #expect(try await Self.engine(services, .uv).search("jq").isEmpty)

        let runner = FixtureRunner(fixtures: UIFixtures.directory, host: .arm64)
        let inventory = DemoInventory(installed: [:], outdated: [EngineID: [Package]]())
        func demo(_ error: FixtureRunnerError) -> DemoEngine {
            DemoEngine(wrapping: SearchFailingEngine(error: error), runner: runner, inventory: inventory, host: .arm64)
        }
        await #expect(throws: FixtureRunnerError.unmapped(["search", "jq"])) {
            _ = try await demo(.unmapped(["search", "jq"])).search("jq")
        }
        #expect(try await demo(.unmappedURL("https://pypi.org/pypi/jq/json")).search("jq").isEmpty)
    }

    // MARK: Lists

    /// Three system engines and Cargo (its crate is ripgrep too) have the exact name.
    @Test func demoSearchRipgrepHasFourEngines() async throws {
        let services = try Self.services()
        let result = await Self.merged(services, .search("ripgrep"))
        #expect(result.errors.isEmpty)
        #expect(!result.packages.isEmpty)
        #expect(result.packages.allSatisfy { $0.displayName.lowercased().contains("ripgrep") })
        let exact = result.packages.enumerated().filter { $0.element.displayName == "ripgrep" }
        #expect(exact.map(\.element.id.engine) == [.nanobrew, .homebrew, .macports, .cargo])
        let positions = exact.map(\.offset)
        #expect(positions == Array((positions.first ?? 0)..<((positions.first ?? 0) + 4)))
    }

    @Test func demoOutdatedFromFixtures() async throws {
        let services = try Self.services()
        let result = await Self.merged(services, .outdated)
        #expect(result.errors.isEmpty)
        let rows = result.packages.map { "\($0.id.engine.rawValue)/\($0.id.name)" }
        // npm's own update isn't offered: the demo's npm is Homebrew's.
        #expect(Set(rows) == ["homebrew/ada-url", "homebrew/mediamtx", "homebrew/merve", "macports/figlet",
                              "npm/cowsay", "npm/semver", "pipx/black", "pipx/cowsay", "uv/isort", "cargo/ripgrep",
                              "bun/cowsay", "bun/semver", "gem/lolcat", "gem/thor", "mint/JohnSundell/Ink"])
        #expect(rows.count == 15)
        // The captures hold nothing back and checked everything (Rust 1.100 builds ripgrep 16; Homebrew's Ruby keeps
        // its own gems apart), so the demo shows no held row and no "couldn't be checked".
        #expect(result.holds.isEmpty)
        #expect(result.unchecked.isEmpty)
    }

    /// The demo's engines answer the catalog's outdated check with the fixtures' own report, less what a demo run
    /// updated: an engine's report reaches the catalog as the real one would.
    @Test func demoOutdatedReportFollowsTheInventory() async throws {
        let services = try Self.services()
        let cargo = try #require(services.engines.first { $0.id == .cargo } as? DemoEngine)
        let report = try await cargo.checkOutdated()
        #expect(report.packages.map(\.id.name) == ["ripgrep"])
        #expect(report == OutdatedReport(packages: try await cargo.listOutdated()))
        await cargo.inventory.apply(try Self.step(services, .upgrade, PackageRef(engine: .cargo, kind: .tool,
                                                                                name: "ripgrep")))
        #expect(try await cargo.checkOutdated().packages.isEmpty)
    }

    @Test func demoInfoUsesCapturesThenTheRow() async throws {
        let services = try Self.services()
        let ripgrep = try await services.catalog.info(PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep"))
        #expect(ripgrep.summary != nil)
        #expect(ripgrep.dependencies != nil)
        // figlet's info isn't captured on arm64: the row's own fields.
        let figlet = try await services.catalog.info(Self.figlet)
        #expect(figlet.ref == Self.figlet)
        #expect(figlet.installedVersion == "2.2.5_0")
        #expect(figlet.latestVersion == "2.2.6_0")
    }

    // MARK: Runs

    @Test func demoRunPromptsOnceForPortStep() async throws {
        let services = try Self.services()
        let prompter = KeepingPrompter(password: "anything")
        services.passwords.prompter = prompter
        let executor = try #require(services.executor)
        let steps = [try Self.step(services, .upgrade, Self.figlet),
                     try Self.step(services, .remove, PackageRef(engine: .macports, kind: .port, name: "autoconf"))]
        #expect(steps.allSatisfy { RunRouting.route(for: $0) == .helper })
        let events = await Self.collect(executor.run(steps, reason: "Demo reason"))
        #expect(prompter.reasons == ["Demo reason"])
        #expect(prompter.given.count == 1)
        #expect(prompter.given.allSatisfy { $0.isWiped })
        let note = "(demo mode: nothing was changed on this Mac)"
        #expect(events == [
            .needsPassword,
            .started(0), .output(0, .stdout("Simulated: port -N upgrade figlet")), .output(0, .stdout(note)),
            .finished(0, 0),
            .started(1), .output(1, .stdout("Simulated: port -N uninstall autoconf")), .output(1, .stdout(note)),
            .finished(1, 0),
            .done,
        ])

        // A run with only user steps never asks.
        let brewOnly = await Self.collect(executor.run([try Self.step(services, .upgrade, Self.adaURL)], reason: "r"))
        #expect(!brewOnly.contains(.needsPassword))
        #expect(brewOnly.last == .done)
        #expect(prompter.reasons.count == 1)
    }

    @Test func demoRunCancelledAtThePromptRunsNothing() async throws {
        let services = try Self.services()
        let prompter = KeepingPrompter(password: nil)
        services.passwords.prompter = prompter
        let executor = try #require(services.executor)
        let events = await Self.collect(executor.run([try Self.step(services, .upgrade, Self.figlet)], reason: "r"))
        #expect(events == [.needsPassword, .cancelled, .done])
        #expect(prompter.reasons == ["r"])
        let outdated = await Self.merged(services, .outdated)
        #expect(outdated.packages.contains { $0.id == Self.figlet })
    }

    @Test func demoCheckStepAsksTheVerifierAndGatesRemovals() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let upgrade = try Self.step(services, .upgrade, Self.adaURL)
        let remove = RunStep(engine: .homebrew, operation: .remove, spec: upgrade.spec, title: "Remove ada-url",
                             requiresAllEarlier: true)
        let check = RunStep.check([Self.adaURL], on: .homebrew, title: "Check Homebrew has the packages")

        let failed = await Self.collect(executor.run([check, remove], reason: "r"))
        #expect(failed == [.started(0), .output(0, .stderr("Not found on Homebrew: ada-url")), .finished(0, 1), .done])

        let passed = await Self.collect(executor.run([check, remove], reason: "r", verify: { _ in [] }))
        #expect(passed.first == .started(0))
        #expect(passed.contains(.finished(0, 0)))
        #expect(!passed.contains { if case .output(0, _) = $0 { true } else { false } })
        #expect(passed.contains(.finished(1, 0)))
    }

    @Test func demoGroupedGateWaitsOnlyOnItsGroup() async throws {
        // As in RunSession: a failed step outside the group doesn't stop a grouped removal; an ungrouped one stops.
        let services = try Self.services()
        let executor = try #require(services.executor)
        let upgrade = try Self.step(services, .upgrade, Self.adaURL)
        let grouped = RunStep(engine: .homebrew, operation: .remove, spec: upgrade.spec, title: "Remove ada-url",
                              requiresAllEarlier: true, gateGroup: "homebrew")
        let ungrouped = RunStep(engine: .homebrew, operation: .remove, spec: upgrade.spec, title: "Remove ada-url too",
                                requiresAllEarlier: true)
        let check = RunStep.check([Self.adaURL], on: .homebrew, title: "Check Homebrew has the packages")

        let events = await Self.collect(executor.run([check, grouped, ungrouped], reason: "r"))
        #expect(events.contains(.finished(0, 1)))
        #expect(events.contains(.finished(1, 0)))
        #expect(!events.contains(.started(2)))
    }

    @Test func demoUninstallStillRemoves() async throws {
        // Uninstall worked in demo mode before the sheet. Homebrew's pick still goes (its leftovers can't be worked
        // out from the captures, so there's no box).
        let model = BrewxPortAppModel(services: try Self.services())
        model.installed.reload()
        await model.installed.settled()
        let rows = model.installed.list.all.map(\.package)
        let picks = [EngineID.nanobrew, .homebrew].compactMap { engine in rows.first { $0.id.engine == engine } }
        #expect(picks.map(\.id.name) == ["figlet", "abseil"])
        model.perform(.uninstall, on: Set(picks.map(\.id)))
        _ = await waitUntil { if case .checking = model.uninstall.state { false } else { true } }
        guard case .ready(let plan) = model.uninstall.state else {
            Issue.record("no plan: \(model.uninstall.state)")
            return
        }
        let homebrew = try #require(plan.sections.first { $0.engine == .homebrew })
        #expect(homebrew.picks.map(\.id.name) == ["abseil"])
        #expect(homebrew.note == "Couldn't work out leftovers for Homebrew.")
        // nanobrew's dependents come from the demo inventory: nothing installed needs figlet, so it goes.
        let nanobrew = try #require(plan.sections.first { $0.engine == .nanobrew })
        #expect(nanobrew.blocked.isEmpty)
        #expect(nanobrew.picks.map(\.id.name) == ["figlet"])
        model.uninstall.confirm()
        #expect(await waitUntil { model.uninstall.state == .hidden && !model.run.isRunning })
        await model.installed.settled()
        let left = Set(model.installed.list.all.map(\.id))
        #expect(picks.allSatisfy { !left.contains($0.id) })
    }

    /// The first installed demo package another installed demo package of the same engine needs (per its captured
    /// details), with that dependent; nil when the captures have no such pair.
    static func neededPair(_ services: Services) async -> (needed: Package, by: String)? {
        for engine in services.engines where engine is any DependentsListing {
            for package in (try? await engine.listInstalled()) ?? [] {
                if let user = (try? await (engine as! any DependentsListing).installedDependents(of: package.id.name))?
                    .sorted().first {
                    return (package, user)
                }
            }
        }
        return nil
    }

    @Test func demoPackageAnotherNeedsIsBlockedOrKept() async throws {
        let services = try Self.services()
        guard let (needed, user) = await Self.neededPair(services) else {
            // The demo captures have no installed package that another installed one lists as a dependency.
            return
        }
        let model = BrewxPortAppModel(services: services)
        model.installed.reload()
        await model.installed.settled()
        model.perform(.uninstall, on: [needed.id])
        _ = await waitUntil { if case .checking = model.uninstall.state { false } else { true } }
        guard case .ready(let plan) = model.uninstall.state else {
            Issue.record("no plan: \(model.uninstall.state)")
            return
        }
        let section = try #require(plan.sections.first)
        if needed.id.engine == .nanobrew {
            // nanobrew doesn't refuse, so BrewxPort blocks it and names what needs it.
            #expect(section.picks.isEmpty)
            #expect(section.blocked.first?.reason.contains(user) == true)
        } else {
            // Homebrew and MacPorts refuse it themselves when the run gets to it; it's never offered as a leftover.
            #expect(section.picks.map(\.id) == [needed.id])
            #expect(section.leftovers.allSatisfy { $0.id != needed.id })
        }
    }

    @Test func demoMarksWaitForAPassedCheckAndEmptyChecksFail() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let upgrade = try Self.step(services, .upgrade, Self.adaURL)
        let mark = RunStep(engine: .homebrew, operation: .markRequested, spec: upgrade.spec, title: "Mark ada-url",
                           requiresPassedCheck: true)
        let check = RunStep.check([Self.adaURL], on: .homebrew, title: "Check Homebrew has the packages")

        let failed = await Self.collect(executor.run([check, mark], reason: "r"))
        #expect(failed.contains(.finished(0, 1)))
        #expect(!failed.contains(.started(1)))

        let passed = await Self.collect(executor.run([check, mark], reason: "r", verify: { _ in [] }))
        #expect(passed.contains(.finished(1, 0)))

        let empty = RunStep.check([], on: .homebrew, title: "Check nothing")
        let vacuous = await Self.collect(executor.run([empty, mark], reason: "r", verify: { _ in [] }))
        #expect(vacuous.contains(.finished(0, 1)))
        #expect(!vacuous.contains(.started(1)))
    }

    @Test func demoUpgradeRemovesFromOutdated() async throws {
        let services = try Self.services()
        let prompter = KeepingPrompter(password: "x")
        services.passwords.prompter = prompter
        let executor = try #require(services.executor)
        let before = await Self.merged(services, .outdated)
        let latest = try #require(before.packages.first { $0.id == Self.adaURL }?.latestVersion)
        let events = await Self.collect(executor.run([try Self.step(services, .upgrade, Self.adaURL),
                                                      try Self.step(services, .upgrade, Self.figlet)], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id == Self.adaURL })
        #expect(!after.packages.contains { $0.id == Self.figlet })
        #expect(after.packages.count == 13)
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.first { $0.id == Self.adaURL }?.installedVersion == latest)
        #expect(installed.packages.first { $0.id == Self.figlet }?.installedVersion == "2.2.6_0")
    }

    @Test func demoUpgradeKeepsSelfupdateStep() async throws {
        let services = try Self.services()
        let prompter = KeepingPrompter(password: "x")
        services.passwords.prompter = prompter
        let executor = try #require(services.executor)
        let figlet = Package(id: Self.figlet, displayName: "figlet", installedVersion: "2.2.5_0", latestVersion: "2.2.6_0")
        let plan = ActionPlanner.make([ActionRequest(operation: .upgrade, package: figlet)], engines: services.engines,
                                      order: PackageCatalog.defaultOrder(for: services.host))
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.spec.arguments) == [["-N", "selfupdate"], ["-N", "upgrade", "figlet"]])
        #expect(plan.steps[0].title == "MacPorts: refresh the port catalogue")
        #expect(plan.steps.map(RunRouting.route(for:)) == [.helper, .helper])

        // Like any password step: one prompt, then the refresh succeeds and the upgrade runs after it.
        let events = await Self.collect(executor.run(plan.steps, reason: plan.reason))
        #expect(prompter.reasons == [plan.reason])
        let note = "(demo mode: nothing was changed on this Mac)"
        #expect(events == [
            .needsPassword,
            .started(0), .output(0, .stdout("Simulated: port -N selfupdate")), .output(0, .stdout(note)),
            .finished(0, 0),
            .started(1), .output(1, .stdout("Simulated: port -N upgrade figlet")), .output(1, .stdout(note)),
            .finished(1, 0),
            .done,
        ])
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id == Self.figlet })
    }

    /// npm upgrades by installing `name@latest`; the demo still knows which package that is.
    @Test func demoNpmUpgradeInstallsTheLatestTag() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let cowsay = PackageRef(engine: .npm, kind: .tool, name: "cowsay")
        let step = try Self.step(services, .upgrade, cowsay)
        #expect(step.spec.arguments == ["install", "-g", "cowsay@latest"])
        #expect(RunRouting.route(for: step) == .user)
        let events = await Self.collect(executor.run([step], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id == cowsay })
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.first { $0.id == cowsay }?.installedVersion == "1.6.0")
        // The global prefix npm reported, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .npm) as? any InstallLocationReporting
        #expect(location?.installLocation == URL(fileURLWithPath: "/opt/homebrew"))
    }

    /// pipx in the demo: Homebrew's pipx on the captures from Fixtures/pipx, with PyPI's captured answer for cowsay.
    @Test func demoPipxUpgradeSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let cowsay = PackageRef(engine: .pipx, kind: .tool, name: "cowsay")
        let black = PackageRef(engine: .pipx, kind: .tool, name: "black")
        let step = try Self.step(services, .upgrade, cowsay)
        #expect(step.spec.arguments == ["upgrade", "cowsay"])
        #expect(step.spec.executable.path == "/opt/homebrew/bin/pipx")
        #expect(RunRouting.route(for: step) == .user)
        let events = await Self.collect(executor.run([step], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id == cowsay })
        #expect(after.packages.contains { $0.id == black })
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.first { $0.id == cowsay }?.installedVersion == "6.1")

        // Discover looks the exact name up on PyPI; a name without a captured answer finds nothing, without an error.
        let found = await Self.merged(services, .search("cowsay"))
        #expect(found.errors.isEmpty)
        #expect(found.packages.contains { $0.id == cowsay && $0.latestVersion == "6.1" })
        let missing = await Self.merged(services, .search("httpie"))
        #expect(missing.errors.isEmpty)
        #expect(!missing.packages.contains { $0.id.engine == .pipx })

        // Details from PyPI's captured answer; black's isn't captured, so its row's own fields.
        let details = try await services.catalog.info(cowsay)
        #expect(details.summary == "The famous cowsay for GNU/Linux is now available for python")
        #expect(details.installedVersion == "6.1")
        let blackDetails = try await services.catalog.info(black)
        #expect(blackDetails.installedVersion == "24.2.0")
        #expect(blackDetails.latestVersion == "26.10.1")

        // PIPX_HOME as pipx reported it, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .pipx) as? any InstallLocationReporting
        #expect(location?.installLocation?.path == "/Users/tester/Library/Application Support/pipx")
    }

    /// uv in the demo: Homebrew's uv on the captures from Fixtures/uv. ruff is pinned, so only isort is an update;
    /// installs and searches use PyPI's captured answer for cowsay.
    @Test func demoUvUpgradeInstallSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let isort = PackageRef(engine: .uv, kind: .tool, name: "isort")
        let ruff = PackageRef(engine: .uv, kind: .tool, name: "ruff")
        let cowsay = PackageRef(engine: .uv, kind: .tool, name: "cowsay")
        let before = await Self.merged(services, .outdated)
        #expect(before.packages.filter { $0.id.engine == .uv }.map(\.id) == [isort])

        let upgrade = try Self.step(services, .upgrade, isort)
        #expect(upgrade.spec.arguments == ["tool", "upgrade", "--color", "never", "--no-progress", "isort"])
        #expect(upgrade.spec.executable.path == "/opt/homebrew/bin/uv")
        #expect(RunRouting.route(for: upgrade) == .user)
        // An install of a tool no search showed: its row comes from the step's arguments, which also carry uv's
        // `tool` and `--color never`.
        let install = try Self.step(services, .install, cowsay)
        #expect(install.spec.arguments == ["tool", "install", "--color", "never", "--no-progress", "cowsay"])
        let events = await Self.collect(executor.run([upgrade, install], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id.engine == .uv })
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.filter { $0.id.engine == .uv }.map(\.id.name).sorted()
                == ["cowsay", "isort", "ruff"])
        #expect(installed.packages.first { $0.id == isort }?.installedVersion == "9.0.2")
        #expect(installed.packages.first { $0.id == ruff }?.installedVersion == "0.6.0")

        // Discover looks the exact name up on PyPI; a name without a captured answer finds nothing, without an error.
        let found = await Self.merged(services, .search("cowsay"))
        #expect(found.errors.isEmpty)
        #expect(found.packages.contains { $0.id == cowsay && $0.latestVersion == "6.1" })
        let missing = await Self.merged(services, .search("httpie"))
        #expect(missing.errors.isEmpty)
        #expect(!missing.packages.contains { $0.id.engine == .uv })

        // Details from PyPI's captured answer; ruff's isn't captured, so its row's own fields.
        let details = try await services.catalog.info(cowsay)
        #expect(details.summary == "The famous cowsay for GNU/Linux is now available for python")
        let ruffDetails = try await services.catalog.info(ruff)
        #expect(ruffDetails.installedVersion == "0.6.0")

        // uv's folders as it reported them, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .uv) as? any InstallLocationReporting
        #expect(location?.installLocation?.path == "/Users/tester/.local/share/uv/tools")
        let demo = try #require(Self.engine(services, .uv) as? DemoEngine)
        #expect((demo.wrapped as? UvEngine)?.binLocation?.path == "/Users/tester/.local/bin")
    }

    /// Cargo in the demo: Homebrew rustup's cargo on the captures from Fixtures/cargo. The installed list is the
    /// captured record (never this Mac's own), ripgrep's newer version comes from crates.io's captured index, and
    /// details from its captured API answer.
    @Test func demoCargoUpgradeSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let ripgrep = PackageRef(engine: .cargo, kind: .tool, name: "ripgrep")
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.filter { $0.id.engine == .cargo }.map(\.id) == [ripgrep])
        #expect(installed.packages.first { $0.id == ripgrep }?.installedVersion == "14.1.0")
        let before = await Self.merged(services, .outdated)
        #expect(before.packages.filter { $0.id.engine == .cargo }.map(\.latestVersion) == ["16.0.0"])

        // R36: the version the captured index offered.
        let upgrade = try Self.step(services, .upgrade, ripgrep)
        #expect(upgrade.spec.arguments == ["install", "--version", "=16.0.0", "ripgrep"])
        #expect(upgrade.spec.executable.path == "/opt/homebrew/opt/rustup/bin/cargo")
        #expect(upgrade.spec.environment?["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(RunRouting.route(for: upgrade) == .user)
        let events = await Self.collect(executor.run([upgrade], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id.engine == .cargo })
        let upgraded = await Self.merged(services, .installed)
        #expect(upgraded.packages.first { $0.id == ripgrep }?.installedVersion == "16.0.0")

        // Discover runs the captured `cargo search`; the demo keeps the rows whose name has the query.
        let found = await Self.merged(services, .search("ripgrep"))
        #expect(found.errors.isEmpty)
        #expect(found.packages.contains { $0.id == ripgrep && $0.latestVersion == "16.0.0" })
        #expect(found.packages.contains { $0.id == PackageRef(engine: .cargo, kind: .tool, name: "ripgrep_all") })
        // R43: installing a Discover row installs the version it showed; the demo adds that one crate, nothing else.
        let ripgrepAll = PackageRef(engine: .cargo, kind: .tool, name: "ripgrep_all")
        let install = try Self.step(services, .install, ripgrepAll)
        #expect(install.spec.arguments == ["install", "--version", "=0.10.10", "ripgrep_all"])
        #expect(await Self.collect(executor.run([install], reason: "r")).last == .done)
        let added = await Self.merged(services, .installed).packages.filter { $0.id.engine == .cargo }
        #expect(added.map(\.id.name).sorted() == ["ripgrep", "ripgrep_all"])
        #expect(added.first { $0.id == ripgrepAll }?.installedVersion == "0.10.10")

        let details = try await services.catalog.info(ripgrep)
        #expect(details.summary?.hasPrefix("ripgrep is a line-oriented search tool") == true)
        #expect(details.executables == ["rg"])
        #expect(details.installedVersion == "16.0.0")

        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .cargo) as? any InstallLocationReporting
        // The captures' install root (SOURCES.md), not this Mac's.
        #expect(location?.installLocation?.path == "/Users/tester/.cargo")
    }

    /// Repair tools in the demo: the real engines' repair steps (npm rebuilds every global), simulated, each finishing 0,
    /// and what the demo has installed doesn't change.
    @Test func demoRepairToolsRunSimulated() async throws {
        let services = try Self.services()
        let model = BrewxPortAppModel(services: services)
        model.refreshLists()
        await model.updates.reloaded()
        await model.installed.settled()
        let before = await Self.merged(services, .installed).packages

        #expect(model.canRepair(.npm))
        model.repairTools(.npm)
        #expect(await waitUntil { !model.run.isRunning && !model.run.steps.isEmpty })
        #expect(model.run.steps.map(\.title) == ["npm: all tools"])
        #expect(model.run.steps.allSatisfy { $0.state == .succeeded && $0.operation == .repair })

        await model.updates.reloaded()
        await model.installed.settled()
        #expect(model.canRepair(.uv))
        // No uv receipt was captured (T13), and the demo never reads this Mac's: uv's Repair runs nothing and says
        // why for each tool (R28).
        model.repairTools(.uv)
        #expect(await waitUntil { model.run.problems.count == 2 })
        #expect(model.run.problems == ["uv has no record of isort, so BrewxPort doesn't repair it.",
                                       "uv has no record of ruff, so BrewxPort doesn't repair it."])
        #expect(model.run.steps.isEmpty)
        #expect(await Self.merged(services, .installed).packages == before)
    }

    /// Bun in the demo: Homebrew's bun on the captures from Fixtures/bun. cowsay and semver are outdated (Bun's own
    /// check); Discover reads the npm registry's captured search, and details come from `bun info`.
    @Test func demoBunUpgradeInstallSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let cowsay = PackageRef(engine: .bun, kind: .tool, name: "cowsay")
        let semver = PackageRef(engine: .bun, kind: .tool, name: "semver")
        let cowsay2 = PackageRef(engine: .bun, kind: .tool, name: "cowsay2")
        let installed = await Self.merged(services, .installed)
        #expect(Set(installed.packages.filter { $0.id.engine == .bun }.map(\.id)) == [cowsay, semver])
        #expect(installed.packages.first { $0.id == cowsay }?.installedVersion == "1.5.0")
        let before = await Self.merged(services, .outdated)
        #expect(Set(before.packages.filter { $0.id.engine == .bun }.map(\.latestVersion)) == ["1.6.0", "7.8.6"])

        // Discover: the npm registry's captured search, whatever the query; the demo keeps the rows whose name has it.
        let found = await Self.merged(services, .search("cowsay"))
        #expect(found.errors.isEmpty)
        #expect(found.packages.contains { $0.id == cowsay && $0.latestVersion == "1.6.0" })
        #expect(found.packages.contains { $0.id == cowsay2 && $0.latestVersion == "2.0.4" })

        let upgrade = try Self.step(services, .upgrade, cowsay)
        #expect(upgrade.spec.arguments == ["update", "-g", "--latest", "cowsay"])
        #expect(upgrade.spec.executable.path == "/opt/homebrew/bin/bun")
        #expect(RunRouting.route(for: upgrade) == .user)
        let remove = try Self.step(services, .remove, semver)
        #expect(remove.spec.arguments == ["remove", "-g", "semver"])
        // An install's verb is `add`, which names no package.
        let install = try Self.step(services, .install, cowsay2)
        #expect(install.spec.arguments == ["add", "-g", "cowsay2"])
        let events = await Self.collect(executor.run([upgrade, remove, install], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id.engine == .bun })
        let changed = await Self.merged(services, .installed)
        #expect(Set(changed.packages.filter { $0.id.engine == .bun }.map(\.id)) == [cowsay, cowsay2])
        #expect(changed.packages.first { $0.id == cowsay }?.installedVersion == "1.6.0")
        #expect(changed.packages.first { $0.id == cowsay2 }?.installedVersion == "2.0.4")

        let details = try await services.catalog.info(cowsay)
        #expect(details.summary == "cowsay is a configurable talking cow")
        #expect(details.latestVersion == "1.6.0")
        #expect(details.installedVersion == "1.6.0")

        // Bun's folders as it reported them, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .bun) as? any InstallLocationReporting
        #expect(location?.installLocation?.path == "/Users/tester/.bun/install/global")
        let demo = try #require(Self.engine(services, .bun) as? DemoEngine)
        #expect((demo.wrapped as? BunEngine)?.binLocation?.path == "/Users/tester/.bun/bin")
    }

    /// RubyGems in the demo: Homebrew's gem on the captures from Fixtures/gem. The executables script's answer is made
    /// from the captures (`FixtureRunner.gemExecutables`): Ruby's bundled irb, rake, rbs, rdoc and typeprof are there
    /// at the version Ruby shipped, and `gem outdated` names them, but only lolcat and thor are tools (R18). Both are
    /// outdated: the captured compact index has 100.0.1 and 1.5.0 for this Ruby. Discover reads the captured
    /// `gem search --remote lolcat`, and details come from RubyGems.org's captured API answer.
    @Test func demoGemUpgradeInstallRemoveSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let thor = PackageRef(engine: .gem, kind: .tool, name: "thor")
        let lolcat = PackageRef(engine: .gem, kind: .tool, name: "lolcat")
        let other = PackageRef(engine: .gem, kind: .tool, name: "can-has-lolcat")
        let script = try FixtureRunner(fixtures: UIFixtures.directory, host: .arm64).gemExecutables()
        #expect(script.hasPrefix("ruby-gems-separate\n"))
        for line in ["rake (13.3.1) ruby", "rbs (3.10.0) ruby", "irb (1.16.0) ruby", "bundler (4.1.0) default",
                     "lolcat (100.0.0) user", "thor (1.3.2) user"] {
            #expect(script.contains(line + "\n"), "\(line)")
        }
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.filter { $0.id.engine == .gem }.map(\.id) == [lolcat, thor])
        #expect(installed.packages.first { $0.id == thor }?.installedVersion == "1.3.2")
        let before = await Self.merged(services, .outdated)
        #expect(before.packages.filter { $0.id.engine == .gem }.map(\.id) == [lolcat, thor])
        #expect(before.packages.filter { $0.id.engine == .gem }.map(\.latestVersion) == ["100.0.1", "1.5.0"])

        let found = await Self.merged(services, .search("lolcat"))
        #expect(found.errors.isEmpty)
        #expect(found.packages.contains { $0.id == lolcat && $0.latestVersion == "100.0.1" })
        #expect(found.packages.contains { $0.id == other && $0.latestVersion == "1.1.1" })

        let upgrade = try Self.step(services, .upgrade, thor)
        #expect(upgrade.spec.arguments == ["update", "--remote", "--no-document", "thor"])
        #expect(upgrade.spec.executable.path == "/opt/homebrew/bin/gem")
        #expect(RunRouting.route(for: upgrade) == .user)
        // Ruby's own gems are never updated, even when asked by name.
        #expect(throws: EngineError.self) { _ = try Self.step(services, .upgrade, PackageRef(engine: .gem, kind: .tool,
                                                                                            name: "rake")) }
        let install = try Self.step(services, .install, other)
        #expect(install.spec.arguments == ["install", "--remote", "--no-document", "can-has-lolcat"])
        // A removal is confirmed afterwards by the Ruby beside gem.
        let remove = try Self.step(services, .remove, lolcat)
        #expect(remove.spec.arguments == ["uninstall", "--all", "--executables", "--abort-on-dependent", "lolcat"])
        #expect(remove.spec.confirmation?.executable.path == "/opt/homebrew/bin/ruby")
        let events = await Self.collect(executor.run([upgrade, install, remove], reason: "r"))
        #expect(events.last == .done)
        let after = await Self.merged(services, .outdated)
        #expect(!after.packages.contains { $0.id.engine == .gem })
        let changed = await Self.merged(services, .installed)
        #expect(changed.packages.filter { $0.id.engine == .gem }.map(\.id) == [other, thor])
        #expect(changed.packages.first { $0.id == thor }?.installedVersion == "1.5.0")
        #expect(changed.packages.first { $0.id == other }?.installedVersion == "1.1.1")

        // thor's API answer isn't captured: the row's own fields.
        let details = try await services.catalog.info(thor)
        #expect(details.latestVersion == "1.5.0")
        let lolcatDetails = try await services.catalog.info(lolcat)
        #expect(lolcatDetails.summary == "Rainbows and unicorns!")
        #expect(lolcatDetails.latestVersion == "100.0.1")

        // Where gem installs, and which Ruby, as the captured `gem environment` says, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .gem) as? any InstallLocationReporting
        #expect(location?.installLocation?.path == "/opt/homebrew/lib/ruby/gems/4.0.0")
        let demo = try #require(Self.engine(services, .gem) as? DemoEngine)
        #expect((demo.wrapped as? GemEngine)?.rubySource == .homebrew)
    }

    /// Mint in the demo: Homebrew's mint on the captures from Fixtures/mint, with Mint's captured metadata and the
    /// captured `git ls-remote` of JohnSundell/Ink (0.5.0 installed, 0.6.0 its newest tag). Each change is a tag the
    /// lookup found, and the uninstall names the repository's URL.
    @Test func demoMintUpgradeRemoveInstallSearchAndDetails() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let ink = PackageRef(engine: .mint, kind: .tool, name: "JohnSundell/Ink")
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.filter { $0.id.engine == .mint }.map(\.id) == [ink])
        #expect(installed.packages.first { $0.id == ink }?.installedVersion == "0.5.0")
        let before = await Self.merged(services, .outdated)
        #expect(before.packages.first { $0.id == ink }?.latestVersion == "0.6.0")

        let upgrade = try Self.step(services, .upgrade, ink)
        #expect(upgrade.spec.arguments == ["install", "--overwrite", "n", "JohnSundell/Ink@0.6.0"])
        #expect(upgrade.spec.executable.path == "/opt/homebrew/bin/mint")
        #expect(upgrade.spec.confirmation?.check == .mintLinked(package: "JohnSundell/Ink", version: "0.6.0",
                                                                metadata: "/Users/tester/.mint/metadata.json"))
        #expect(RunRouting.route(for: upgrade) == .user)
        #expect(await Self.collect(executor.run([upgrade], reason: "r")).last == .done)
        #expect(!(await Self.merged(services, .outdated)).packages.contains { $0.id == ink })
        let upgraded = await Self.merged(services, .installed)
        #expect(upgraded.packages.first { $0.id == ink }?.installedVersion == "0.6.0")

        let remove = try Self.step(services, .remove, ink)
        #expect(remove.spec.arguments == ["uninstall", "https://github.com/JohnSundell/Ink.git"])
        #expect(await Self.collect(executor.run([remove], reason: "r")).last == .done)
        #expect(!(await Self.merged(services, .installed)).packages.contains { $0.id == ink })

        // Discover takes owner/repo and finds its newest tag, which the install uses.
        let found = await Self.merged(services, .search("JohnSundell/Ink"))
        #expect(found.packages.filter { $0.id.engine == .mint }
                == [Package(id: ink, displayName: "JohnSundell/Ink", latestVersion: "0.6.0")])
        let install = try Self.step(services, .install, ink)
        #expect(install.spec.arguments == ["install", "--overwrite", "n", "JohnSundell/Ink@0.6.0"])
        #expect(await Self.collect(executor.run([install], reason: "r")).last == .done)
        let after = await Self.merged(services, .installed)
        #expect(after.packages.filter { $0.id.engine == .mint }.map(\.id) == [ink])
        #expect(after.packages.first { $0.id == ink }?.installedVersion == "0.6.0")

        let details = try await services.catalog.info(ink)
        #expect(details.homepage == URL(string: "https://github.com/JohnSundell/Ink"))
        #expect(details.latestVersion == "0.6.0")
        #expect(details.executables == ["ink-cli"])

        // Mint's folders as the captures had them, through the demo's wrapper.
        _ = await services.catalog.presentEngines()
        let location = Self.engine(services, .mint) as? any InstallLocationReporting
        #expect(location?.installLocation?.path == "/Users/tester/.mint")
        let demo = try #require(Self.engine(services, .mint) as? DemoEngine)
        #expect((demo.wrapped as? MintEngine)?.binLocation?.path == "/Users/tester/.mint/bin")
        // Mint's metadata comes from the fixtures whatever folder it's asked for, and only that file.
        #expect(try demo.runner.mintMetadata("/Users/someone/.mint/metadata.json")
                == (try Data(contentsOf: UIFixtures.directory.appendingPathComponent("mint/metadata.json"))))
        #expect(try demo.runner.mintMetadata("/Users/someone/.mint/packages") == nil)
    }

    @Test func fixtureRunnerAnswersOnlyCapturedRegistryURLs() async throws {
        let runner = FixtureRunner(fixtures: UIFixtures.directory, host: .arm64)
        let cowsay = try await runner.get(try #require(URL(string: "https://pypi.org/pypi/cowsay/json")))
        #expect(String(decoding: cowsay, as: UTF8.self).contains("\"name\":\"cowsay\""))
        let index = try await runner.get(try #require(URL(string: "https://index.crates.io/ri/pg/ripgrep")))
        #expect(String(decoding: index, as: UTF8.self).hasPrefix("{\"name\":\"ripgrep\""))
        let gemIndex = try await runner.get(try #require(URL(string: "https://index.rubygems.org/info/thor")))
        #expect(String(decoding: gemIndex, as: UTF8.self).hasPrefix("---\n0.9.7 |"))
        let gemAPI = try await runner.get(try #require(URL(string: "https://rubygems.org/api/v1/gems/lolcat.json")))
        #expect(String(decoding: gemAPI, as: UTF8.self).hasPrefix("{\"name\":\"lolcat\""))
        // Cargo's record comes from the fixtures whatever the install root, and only its two files.
        #expect(try runner.cargoRecord("/Users/someone/.cargo/.crates2.json")
                == (try Data(contentsOf: UIFixtures.directory.appendingPathComponent("cargo/crates2.json"))))
        #expect(try runner.cargoRecord("/Users/someone/.cargo/.crates.toml") != nil)
        #expect(try runner.cargoRecord("/Users/someone/.cargo/config.toml") == nil)
        // Every npm registry search gets the one captured search, as an engine's search command does.
        let search = try await runner.get(try #require(URL(
            string: "https://registry.npmjs.org/-/v1/search?text=anything%20else&size=50")))
        #expect(String(decoding: search, as: UTF8.self).contains("\"name\":\"cowsay\""))
        // A registry answer the fixtures don't have is its own kind of miss, which a demo search finds nothing for.
        let black = "https://pypi.org/pypi/black/json"
        await #expect(throws: FixtureRunnerError.unmappedURL(black)) {
            _ = try await runner.get(try #require(URL(string: black)))
        }
        #expect(FixtureRunnerError.unmappedURL(black).localizedDescription
                == "Demo mode has no captured answer for https://pypi.org/pypi/black/json.")
    }

    @Test func demoInstallAndRemoveChangeInstalled() async throws {
        let services = try Self.services()
        let executor = try #require(services.executor)
        let ripgrep = PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep")
        let jq = PackageRef(engine: .nanobrew, kind: .formula, name: "jq")
        _ = await Self.merged(services, .search("ripgrep"))
        _ = await Self.collect(executor.run([try Self.step(services, .install, ripgrep),
                                             try Self.step(services, .remove, jq)], reason: "r"))
        let installed = await Self.merged(services, .installed)
        let row = installed.packages.first { $0.id == ripgrep }
        #expect(row?.installedVersion == "15.2.0")
        #expect(!installed.packages.contains { $0.id == jq })
    }

    @Test(.timeLimit(.minutes(1))) func demoCancelEndsWithCancelledDone() async throws {
        // The run doesn't wait for the reader, so the pause before the second line must outlast any lag in reading
        // the first one (100 ms, then 3 s, didn't always on a busy CI runner). So the first line comes at once and the
        // pause before the second lasts until the cancel interrupts it, however slowly the first is read.
        let pauses = PauseCount()
        let services = try DemoServices.make(Self.options(), delay: .zero, pause: { _ in
            if pauses.next() > 1 { try await Task.sleep(for: .seconds(3600)) }
        })
        let executor = try #require(services.executor)
        var events: [RunEvent] = []
        for await event in executor.run([try Self.step(services, .upgrade, Self.adaURL)], reason: "r") {
            events.append(event)
            if case .output = event { executor.cancel() }
        }
        #expect(events == [.started(0), .output(0, .stdout("Simulated: brew upgrade ada-url")),
                           .cancelled, .done])
        let outdated = await Self.merged(services, .outdated)
        #expect(outdated.packages.contains { $0.id == Self.adaURL })
    }

    @Test func demoArchColumnFollowsCapturedArchs() async throws {
        // Captured `port -v -q installed active`: arm64 MacPorts with +universal and noarch ports; x86_64 figlet.
        let arm = BrewxPortAppModel(services: try Self.services(.arm64))
        arm.start()
        #expect(await waitUntil { !arm.installed.list.loading && !arm.installed.list.all.isEmpty })
        await arm.installed.settled()
        let macports = arm.installed.rows.filter { $0.id.engine == .macports }
        let archs = Dictionary(uniqueKeysWithValues: macports.map { ($0.name, $0.archName) })
        #expect(archs["nano"] == "universal")
        #expect(archs["figlet"] == "arm64")
        #expect(archs["autoconf"] == "arm64")      // noarch: the engine's arch
        #expect(await waitUntil { arm.updates.list.byRef[Self.figlet]?.archName == "arm64" })
        // R34: language tools show no arch; their engines don't say what a tool was built for.
        let languageRows = arm.installed.rows.filter { $0.id.engine.isLanguage }
        #expect(!languageRows.isEmpty)
        #expect(languageRows.allSatisfy { $0.archName.isEmpty })
        let cowsay = PackageRef(engine: .npm, kind: .tool, name: "cowsay")
        #expect(await waitUntil { arm.updates.list.byRef[cowsay]?.archName == "" })
        let intel = BrewxPortAppModel(services: try Self.services(.x86_64))
        intel.start()
        #expect(await waitUntil { !intel.installed.list.loading && !intel.installed.list.all.isEmpty })
        await intel.installed.settled()
        #expect(intel.installed.rows.first { $0.id == Self.figlet }?.archName == "x86_64")
    }

    @Test func demoArchX86UsesHostEverywhere() async throws {
        let services = try DemoServices.make(Self.options(.x86_64), delay: .zero)
        #expect(services.host == .x86_64)
        #expect(services.engines.allSatisfy { $0.runArch == .x86_64 })
        #expect(Self.engine(services, .homebrew).executableURL?.path == "/usr/local/bin/brew")
        #expect(BrewxPortAppModel(services: services).engineOrder.first == .macports)
        let statuses = await services.catalog.presentEngines().filter { !$0.key.isLanguage }
        #expect(statuses.count == 4)
        #expect(statuses.values.allSatisfy { if case .present = $0 { true } else { false } })
        // MacPorts' x86_64 captures: figlet is installed by both MacPorts and nanobrew, and MacPorts sorts first.
        let installed = await Self.merged(services, .installed)
        let figlets = installed.packages.filter { $0.id.name == "figlet" }.map(\.id.engine)
        #expect(figlets == [.macports, .nanobrew])
        #expect(installed.packages.filter { $0.id.engine == .macports }.map(\.id.name) == ["figlet"])
        #expect(services.fileExists("/usr/local/bin/ada-url"))
        let outdated = await Self.merged(services, .outdated)
        #expect(outdated.packages.contains { $0.id == Self.figlet })
        // On arm64 the same row order is the other way round.
        let arm = await Self.merged(try Self.services(.arm64), .installed)
        #expect(arm.packages.filter { $0.id.name == "figlet" }.map(\.id.engine) == [.nanobrew, .macports])
    }
}

// MARK: taps (Plan 4 Task 3)

extension DemoTests {
    @Test func demoCatalogListsCapturedTaps() async throws {
        let services = try Self.services()
        #expect(try await services.catalog.installedTaps() == ["felixkratz/formulae"])
    }

    @Test func fakeCatalogTapsAreScripted() async throws {
        let fake = FakeCatalog()
        #expect(try await fake.installedTaps() == [])
        fake.taps = .failure(EngineError(engine: .homebrew, message: "no"))
        await #expect(throws: EngineError(engine: .homebrew, message: "no")) { try await fake.installedTaps() }
    }
}

// MARK: sample bundle and Brewfile (Plan 4 Task 8)

extension DemoTests {
    static let felixTap = PackageRef(engine: .homebrew, kind: .tap, name: "felixkratz/formulae")

    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: UIFixtures.directory.appendingPathComponent(path))
    }

    /// A started demo window whose engines have been checked.
    static func startedModel() async throws -> BrewxPortAppModel {
        let model = BrewxPortAppModel(services: try services())
        model.start()
        _ = await waitUntil { model.enginesChecked }
        return model
    }

    @Test func demoSampleNames() async throws {
        #expect(DemoSamples.names == ["inventory", "brewfile"])
        let services = try Self.services()
        #expect(await DemoSamples.data("nope", catalog: services.catalog, fixtures: UIFixtures.directory) == nil)
        // The Brewfile is the captured one, byte for byte.
        let brewfile = try #require(await DemoSamples.data("brewfile", catalog: services.catalog,
                                                           fixtures: UIFixtures.directory))
        #expect(brewfile.fileName == "dump-describe.Brewfile")
        #expect(brewfile.data == (try Self.fixture("brewfile/dump-describe.Brewfile")))
        #expect(await DemoSamples.data("brewfile", catalog: services.catalog, fixtures: nil) == nil)
        // The inventory is the exporter's bundle of what the demo has installed, taps included; nothing on disk.
        let inventory = try #require(await DemoSamples.data("inventory", catalog: services.catalog,
                                                            fixtures: UIFixtures.directory, host: .arm64))
        #expect(inventory.fileName.hasSuffix(".brewxportbundle"))
        let bundle = try BundleFile.decode(inventory.data)
        #expect(bundle.unhandled.isEmpty)
        #expect(bundle.arch == .arm64)
        #expect(bundle.entries.contains { $0.kind == .tap && $0.name == "felixkratz/formulae" })
        #expect(bundle.entries.contains { $0.engine == .macports && $0.name == "figlet" })
    }

    @Test func demoBundleOpensFromInventoryExport() async throws {
        let model = try await Self.startedModel()
        await model.openDemoSample("inventory")
        #expect(model.sidebar == .bundles)
        #expect(await waitUntil { model.bundles.preview != nil })
        guard case .ready(let preview, let name) = model.bundles.state else {
            Issue.record("not ready: \(model.bundles.state)")
            return
        }
        #expect(name.hasSuffix(".brewxportbundle"))
        #expect(model.bundles.rowState(Self.felixTap) == .alreadyInstalled(version: nil))
        // It's the demo's own inventory: everything is already installed.
        #expect(preview.toInstallCount == 0)
        #expect(preview.installedCount > 0)
        #expect(preview.unhandled.isEmpty)
    }

    @Test func demoBrewfileOpensWithUnhandledLines() async throws {
        let model = try await Self.startedModel()
        await model.openDemoSample("brewfile")
        #expect(await waitUntil { model.bundles.preview != nil })
        let preview = try #require(model.bundles.preview)
        #expect(model.bundles.state.name == "dump-describe.Brewfile")
        let read = try BrewfileReader.read(try Self.fixture("brewfile/dump-describe.Brewfile"))
        #expect(!read.unhandled.isEmpty)
        #expect(preview.unhandled.count == read.unhandled.count)
        #expect(preview.unhandled.allSatisfy { $0.location.hasPrefix("line ") })
    }

    @Test func demoInstallUsesDemoExecutor() async throws {
        let model = try await Self.startedModel()
        #expect(model.services.executor is DemoRunExecutor)
        // A real `brew bundle dump`: jq and mas aren't in the demo's Homebrew inventory, the tap is.
        model.bundles.open(data: try Self.fixture("brewfile/dump-basic.Brewfile"), name: "dump-basic.Brewfile")
        #expect(await waitUntil { model.bundles.preview != nil })
        #expect(model.bundles.rowState(Self.felixTap) == .alreadyInstalled(version: nil))
        let jq = PackageRef(engine: .homebrew, kind: .formula, name: "jq")
        let mas = PackageRef(engine: .homebrew, kind: .formula, name: "mas")
        #expect(model.bundles.rowState(jq) == .willInstall)
        // Formulae only, so no step needs the password sheet.
        model.bundles.list.selection.checked = [jq, mas]
        #expect(model.bundles.canInstall)
        model.bundles.installChecked()
        #expect(model.run.isRunning)
        #expect(model.run.steps.count == 1)
        #expect(await waitUntil { !model.run.isRunning })
        #expect(model.run.log.lines.contains { $0.text == "Simulated: brew install --formula jq mas" })
        // The run changed the demo inventory, so after the Installed reload both rows are installed.
        #expect(await waitUntil { model.bundles.rowState(jq)?.isAlreadyInstalled == true })
        #expect(model.bundles.rowState(mas)?.isAlreadyInstalled == true)
    }

    /// The binding carry: a demo `brew tap` adds the tap, and a formula named with that tap's prefix installs and
    /// then matches. The names are the README Brewfile's (`denji/nginx/nginx-full`); the bundle is built here by
    /// the exporter, not stored.
    @Test func demoTapAndTapFormulaInstall() async throws {
        let model = try await Self.startedModel()
        let tap = PackageRef(engine: .homebrew, kind: .tap, name: "denji/nginx")
        let formula = PackageRef(engine: .homebrew, kind: .formula, name: "denji/nginx/nginx-full")
        let made = BundleExporter.make(
            installed: [Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "nginx-full"),
                                displayName: "nginx-full", fullName: "denji/nginx/nginx-full")],
            taps: ["denji/nginx"], appVersion: "1.0", arch: .arm64)
        #expect(made.refused.isEmpty)
        model.bundles.open(data: try made.bundle.encoded(), name: "nginx.brewxportbundle")
        #expect(await waitUntil { model.bundles.preview != nil })
        #expect(model.bundles.rowState(tap) == .willInstall)
        #expect(model.bundles.rowState(formula) == .willInstall)
        model.bundles.list.selection.checked = [tap, formula]
        model.bundles.installChecked()
        #expect(model.run.steps.count == 2)
        #expect(await waitUntil { !model.run.isRunning })
        #expect(await waitUntil { model.bundles.rowState(tap)?.isAlreadyInstalled == true })
        #expect(model.bundles.rowState(formula)?.isAlreadyInstalled == true)
        #expect(try await model.services.catalog.installedTaps() == ["felixkratz/formulae", "denji/nginx"])
        // Installed shows it the way `brew info --installed` would: bare name, tap-qualified full name.
        let installed = await Self.merged(model.services, .installed)
        let row = try #require(installed.packages.first { $0.id.name == "nginx-full" })
        #expect(row.id.engine == .homebrew)
        #expect(row.fullName == "denji/nginx/nginx-full")
    }

    @Test func prepareSnapshotBundlesWaitsForPreview() async throws {
        // Not started: prepareSnapshot starts what it needs.
        let model = BrewxPortAppModel(services: try Self.services())
        await model.prepareSnapshot(.bundles)
        #expect(model.sidebar == .bundles)
        #expect(model.bundles.preview != nil)
        #expect(model.bundles.state.name?.hasSuffix(".brewxportbundle") == true)
        #expect(model.bundles.rowState(Self.felixTap) == .alreadyInstalled(version: nil))
    }

    // MARK: --demo-states

    @Test func parsesDemoStates() {
        var want = DemoOptions()
        want.states = true
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-states"]) == .demo(want))
        // It takes no value, so the next flag is read as usual.
        want.appearance = .dark
        #expect(LaunchMode.parse([Self.program, "--demo", "--demo-states", "--appearance", "dark"]) == .demo(want))
        #expect(LaunchMode.parse([Self.program, "--demo"]) == .demo(DemoOptions()))
    }

    static func statesServices() throws -> Services {
        var options = Self.options()
        options.states = true
        return try DemoServices.make(options, delay: .zero)
    }

    /// `--demo-states` shows what the captures alone can't (`DemoStates`): a row held from every update with its
    /// reason, a section with tools its check couldn't look up, a gem that came with Ruby, and Homebrew's node held
    /// back for npm's tools. Everything else is the default demo's.
    @Test func demoStatesShowEachNewState() async throws {
        let services = try Self.statesServices()
        let result = await Self.merged(services, .outdated)
        #expect(result.errors.isEmpty)

        // Cargo: ripgrep 16.0.0 needs Rust 1.96 (the captured index), held from every update.
        let ripgrep = PackageRef(engine: .cargo, kind: .tool, name: "ripgrep")
        #expect(result.holds[ripgrep] == UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true,
                                                    blocksManual: true))
        #expect(result.packages.first { $0.id == ripgrep }?.latestVersion == "16.0.0")

        // RubyGems installs into Ruby's own gem folder, as with rbenv: Ruby's bundled gems with executables are tools
        // that came with Ruby. rake is offered at the version the captured `gem outdated` names, held from automatic
        // updates only; the other bundled gems `gem outdated` names couldn't be looked up (no captured index).
        let rake = PackageRef(engine: .gem, kind: .tool, name: "rake")
        #expect(result.holds[rake] == UpdateHold(reason: "Came with Ruby, so BrewxPort updates it only when you ask.",
                                                 blocksAutomatic: true, blocksManual: false))
        let rakeRow = try #require(result.packages.first { $0.id == rake })
        #expect([rakeRow.installedVersion, rakeRow.latestVersion] == ["13.3.1", "13.4.2"])
        #expect(result.packages.filter { $0.id.engine == .gem }.map(\.id.name) == ["lolcat", "rake", "thor"])
        let unchecked = try #require(result.unchecked[.gem])
        #expect(unchecked.names == ["irb", "minitest", "rbs", "rdoc", "test-unit", "typeprof"])
        #expect(unchecked.reasons["irb"] == "Demo mode has no captured answer for https://index.rubygems.org/info/irb.")
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.filter { $0.id.engine == .gem }.map(\.id.name)
                == ["debug", "irb", "lolcat", "minitest", "racc", "rake", "rbs", "rdoc", "test-unit", "thor", "typeprof"])
        // The engine knows rake came with Ruby: it updates it when asked, and won't remove it.
        #expect(try Self.step(services, .upgrade, rake).spec.arguments == ["update", "--remote", "--no-document", "rake"])
        #expect(throws: EngineError.self) { _ = try Self.step(services, .remove, rake) }

        // Homebrew: node at the captured `node --version`, with a newer major version.
        let node = PackageRef(engine: .homebrew, kind: .formula, name: "node")
        let nodeRow = try #require(result.packages.first { $0.id == node })
        #expect([nodeRow.installedVersion, nodeRow.latestVersion] == ["26.13.1", "27.0.0"])
        #expect(installed.packages.first { $0.id == node }?.installedOnRequest == true)

        // The rest is the default demo's: every other engine's updates, and nothing else held or unchecked.
        #expect(Set(result.holds.keys) == [ripgrep, rake])
        #expect(Set(result.unchecked.keys) == [.gem])
        #expect(result.packages.count == 17)
    }

    /// The app works out the rest itself, as on a real Mac: npm runs on Homebrew's node, so node's update is held
    /// from automatic updates and says why, and Updates says what RubyGems couldn't check.
    @Test func demoStatesHoldNodeForNpmsTools() async throws {
        let model = BrewxPortAppModel(services: try Self.statesServices())
        model.refreshLists()
        await model.updates.reloaded()
        let node = PackageRef(engine: .homebrew, kind: .formula, name: "node")
        let hold = try #require(model.updates.runtimeHolds[node])
        #expect(hold.hold == UpdateHold(reason: "Updating it needs your npm tools rebuilt.", blocksAutomatic: true,
                                        blocksManual: false))
        #expect(hold.noticeTitle == "Node 27 is ready")
        #expect(model.updates.uncheckedNote(for: .gem) == "6 tools couldn't be checked")
        // The default demo has none of this.
        let plain = BrewxPortAppModel(services: try Self.services())
        plain.refreshLists()
        await plain.updates.reloaded()
        #expect(plain.updates.runtimeHolds.isEmpty)
        #expect(plain.updates.uncheckedNote(for: .gem) == nil)
    }
}

/// An engine whose search fails with `error`, for what `DemoEngine.search` lets through.
private struct SearchFailingEngine: Engine {
    let error: FixtureRunnerError
    var id: EngineID { .pipx }
    var capabilities: EngineCapabilities { [] }
    var executableURL: URL? { nil }
    func detect() async -> EngineStatus { .missing }
    func search(_ query: String) async throws -> [Package] { throw error }
    func listInstalled() async throws -> [Package] { [] }
    func listOutdated() async throws -> [Package] { [] }
    func info(_ ref: PackageRef) async throws -> PackageDetails { throw error }
    func privilege(for op: PackageOperation, _ ref: PackageRef) -> Privilege { .never }
    func command(for op: PackageOperation, _ refs: [PackageRef], options: InstallOptions) throws -> CommandSpec {
        throw error
    }
}
