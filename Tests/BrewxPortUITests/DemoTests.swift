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

    func askForPassword(reason: String) async -> SecretBuffer? {
        reasons.append(reason)
        guard let password else { return nil }
        let buffer = SecretBuffer(copying: Array(password.utf8))
        given.append(buffer)
        return buffer
    }
}

@MainActor @Suite struct DemoTests {
    static let program = "/Applications/BrewxPort.app/Contents/MacOS/BrewxPort"

    static func options(_ host: Arch = .arm64) -> DemoOptions {
        var options = DemoOptions()
        options.fixtures = UIFixtures.directory
        options.host = host
        return options
    }

    static func services(_ host: Arch = .arm64, delay: Duration = .zero) throws -> Services {
        try DemoServices.make(options(host), delay: delay)
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
        #expect(services.engines.map(\.id) == [.homebrew, .nanobrew, .macports, .mas])
        for engine in services.engines {
            let demo = engine as? DemoEngine
            #expect(demo != nil)
            #expect(demo?.runner.fixtures == UIFixtures.directory)
        }
        let path = await services.path.resolve()
        #expect(path == ResolvedPath(entries: ["/opt/homebrew/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                                               "/usr/bin", "/bin"], source: .loginShell))
        // Every engine answers its version command from the fixtures.
        let statuses = await services.catalog.presentEngines()
        for id in EngineID.allCases {
            if case .present? = statuses[id] {} else { Issue.record("\(id) is \(String(describing: statuses[id]))") }
        }
        // fileExists follows the fixture inventory, never the disk.
        #expect(services.fileExists("/opt/homebrew/bin/ada-url"))
        #expect(services.fileExists("/opt/local/bin/figlet"))
        #expect(services.fileExists("/opt/nanobrew/prefix/bin/jq"))
        #expect(!services.fileExists("/opt/homebrew/bin/jq"))
        #expect(!services.fileExists("/bin/sh"))
        #expect(!services.fileExists("/opt/local/bin/ripgrep"))
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

    // MARK: Lists

    @Test func demoSearchRipgrepHasThreeEngines() async throws {
        let services = try Self.services()
        let result = await Self.merged(services, .search("ripgrep"))
        #expect(result.errors.isEmpty)
        #expect(!result.packages.isEmpty)
        #expect(result.packages.allSatisfy { $0.displayName.lowercased().contains("ripgrep") })
        let exact = result.packages.enumerated().filter { $0.element.displayName == "ripgrep" }
        #expect(exact.map(\.element.id.engine) == [.nanobrew, .homebrew, .macports])
        let positions = exact.map(\.offset)
        #expect(positions == Array((positions.first ?? 0)..<((positions.first ?? 0) + 3)))
    }

    @Test func demoOutdatedFromFixtures() async throws {
        let services = try Self.services()
        let result = await Self.merged(services, .outdated)
        #expect(result.errors.isEmpty)
        let rows = result.packages.map { "\($0.id.engine.rawValue)/\($0.id.name)" }
        #expect(Set(rows) == ["homebrew/ada-url", "homebrew/mediamtx", "homebrew/merve", "macports/figlet"])
        #expect(rows.count == 4)
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
        #expect(after.packages.count == 2)
        let installed = await Self.merged(services, .installed)
        #expect(installed.packages.first { $0.id == Self.adaURL }?.installedVersion == latest)
        #expect(installed.packages.first { $0.id == Self.figlet }?.installedVersion == "2.2.6_0")
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

    @Test func demoCancelEndsWithCancelledDone() async throws {
        let services = try Self.services(delay: .milliseconds(100))
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
        let statuses = await services.catalog.presentEngines()
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
}
