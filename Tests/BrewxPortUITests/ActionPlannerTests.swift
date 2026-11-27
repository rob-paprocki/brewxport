import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

/// Engine paths and ready-made steps for the planner, preflight and controller tests.
enum PlanFixtures {
    static let brewPath = "/opt/homebrew/bin/brew"
    static let nbPath = "/opt/nanobrew/prefix/bin/nb"
    static let portPath = "/opt/local/bin/port"
    static let masPath = "/opt/homebrew/bin/mas"

    static let runner = UIFakeRunner()
    static let engines: [any Engine] = [
        HomebrewEngine(runner: runner, executable: URL(fileURLWithPath: brewPath), arch: .arm64),
        NanobrewEngine(runner: runner, executable: URL(fileURLWithPath: nbPath)),
        MacPortsEngine(runner: runner, executable: URL(fileURLWithPath: portPath)),
        MasEngine(runner: runner, executable: URL(fileURLWithPath: masPath)),
    ]
    static let order = PackageCatalog.defaultOrder(for: .arm64)

    static func package(_ engine: EngineID, _ kind: PackageKind, _ name: String) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                installedVersion: "1", latestVersion: "2")
    }

    static func request(_ operation: PackageOperation, _ engine: EngineID, _ kind: PackageKind, _ name: String,
                        options: InstallOptions = InstallOptions()) -> ActionRequest {
        ActionRequest(operation: operation, package: package(engine, kind, name), options: options)
    }

    static func step(_ engine: EngineID, _ kind: PackageKind, _ path: String, _ arguments: [String],
                     needsRoot: Bool, title: String, operation: PackageOperation = .upgrade) -> RunStep {
        RunStep(engine: engine, kind: kind, operation: operation,
                spec: CommandSpec(executable: URL(fileURLWithPath: path), arguments: arguments, needsRoot: needsRoot),
                title: title)
    }

    static func port(_ name: String = "wget") -> RunStep {
        step(.macports, .port, portPath, ["-N", "upgrade", name], needsRoot: true, title: "Upgrade \(name)")
    }
    static func cask(_ name: String = "blackhole-2ch") -> RunStep {
        step(.homebrew, .cask, brewPath, ["upgrade", "--cask", name], needsRoot: false, title: "Upgrade \(name)")
    }
    static func formula(_ name: String = "wget") -> RunStep {
        step(.homebrew, .formula, brewPath, ["upgrade", name], needsRoot: false, title: "Upgrade \(name)")
    }
    static func mas(_ id: String = "497799835") -> RunStep {
        step(.mas, .app, masPath, ["upgrade", id], needsRoot: true, title: "Upgrade \(id)")
    }
}

@Suite struct ActionPlannerTests {
    typealias F = PlanFixtures

    static func upgrades(_ packages: [Package]) -> [ActionRequest] {
        packages.map { ActionRequest(operation: .upgrade, package: $0, options: InstallOptions()) }
    }

    static let outdated = [
        F.package(.homebrew, .formula, "wget"), F.package(.homebrew, .cask, "blackhole-2ch"),
        F.package(.homebrew, .formula, "jq"), F.package(.macports, .port, "curl"),
        F.package(.mas, .app, "497799835"), F.package(.nanobrew, .formula, "ripgrep"),
    ]

    static func shapes(_ plan: ActionPlan) -> [[String]] {
        plan.steps.map { [$0.engine.rawValue, $0.kind.rawValue] + [$0.spec.executable.path] + $0.spec.arguments }
    }

    // MARK: Ported from the old make cases

    @Test func oneStepPerEngineWithCasksSeparateAndMarked() {
        let plan = ActionPlanner.make(Self.upgrades(Self.outdated), engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["nanobrew", "formula", F.nbPath, "upgrade", "ripgrep"],
            ["homebrew", "formula", F.brewPath, "upgrade", "wget", "jq"],
            ["homebrew", "cask", F.brewPath, "upgrade", "--cask", "blackhole-2ch"],
            ["macports", "port", F.portPath, "-N", "selfupdate"],
            ["macports", "port", F.portPath, "-N", "upgrade", "curl"],
            ["mas", "app", F.masPath, "upgrade", "497799835"],
        ])
        #expect(plan.steps.map(RunRouting.route(for:)) == [.user, .user, .userWithAskpass, .helper, .helper,
                                                           .sudoAskpass])
        #expect(plan.steps[2].title == "Homebrew casks: blackhole-2ch")
        #expect(plan.steps.allSatisfy { $0.operation == .upgrade })
    }

    @Test func engineThatCantBuildItsCommandIsReportedNotFatal() {
        let engines: [any Engine] = [
            HomebrewEngine(runner: F.runner, executable: nil, arch: .arm64),  // not installed: command throws
            MacPortsEngine(runner: F.runner, executable: URL(fileURLWithPath: F.portPath)),
        ]
        let plan = ActionPlanner.make(Self.upgrades(Self.outdated), engines: engines, order: [.homebrew, .macports])
        #expect(plan.steps.map(\.engine) == [.macports, .macports])
        #expect(plan.steps.map(\.spec.arguments) == [["-N", "selfupdate"], ["-N", "upgrade", "curl"]])
        #expect(plan.problems.count == 4)  // brew formulae, brew casks, then nanobrew and mas with no engine
        #expect(plan.problems[0].hasPrefix("Homebrew: wget, jq: "))
        #expect(plan.problems[1].hasPrefix("Homebrew casks: blackhole-2ch: "))
    }

    @Test func nothingRequestedMeansNoSteps() {
        let plan = ActionPlanner.make([], engines: F.engines, order: [])
        #expect(plan.steps.isEmpty)
        #expect(plan.problems.isEmpty)
        #expect(plan.notes.isEmpty)
    }

    // MARK: Order and batching

    @Test func removesThenInstallsThenUpgrades() {
        let requests = [
            F.request(.upgrade, .homebrew, .formula, "jq"),
            F.request(.install, .macports, .port, "figlet"),
            F.request(.remove, .homebrew, .cask, "zoom"),
            F.request(.install, .nanobrew, .formula, "fd"),
            F.request(.remove, .nanobrew, .formula, "bat"),
            F.request(.upgrade, .nanobrew, .formula, "ripgrep"),
            F.request(.remove, .homebrew, .formula, "wget"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["nanobrew", "formula", F.nbPath, "remove", "bat"],
            ["homebrew", "formula", F.brewPath, "uninstall", "--formula", "wget"],
            ["homebrew", "cask", F.brewPath, "uninstall", "--cask", "zoom"],
            ["nanobrew", "formula", F.nbPath, "install", "fd"],
            ["macports", "port", F.portPath, "-N", "install", "figlet"],
            ["nanobrew", "formula", F.nbPath, "upgrade", "ripgrep"],
            ["homebrew", "formula", F.brewPath, "upgrade", "jq"],
        ])
        #expect(plan.steps.map(\.operation) == [.remove, .remove, .remove, .install, .install, .upgrade, .upgrade])
        #expect(plan.steps.map(\.title) == [
            "nanobrew: bat", "Homebrew: wget", "Homebrew casks: zoom", "nanobrew: fd", "MacPorts: figlet",
            "nanobrew: ripgrep", "Homebrew: jq",
        ])
    }

    @Test func macPortsVariantsGetOwnStep() {
        let requests = [
            F.request(.install, .macports, .port, "curl", options: InstallOptions(variants: ["+universal"])),
            F.request(.install, .macports, .port, "figlet"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Set(Self.shapes(plan)) == [
            ["macports", "port", F.portPath, "-N", "install", "figlet"],
            ["macports", "port", F.portPath, "-N", "install", "curl", "+universal"],
        ])
        #expect(plan.steps.count == 2)
    }

    // MARK: Duplicates

    @Test func sameNameInstallFromTwoEnginesIsRefused() {
        let requests = [
            F.request(.install, .nanobrew, .formula, "figlet"),
            F.request(.install, .macports, .port, "Figlet"),
            F.request(.install, .homebrew, .formula, "jq"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems == ["figlet is selected from nanobrew and MacPorts. Pick one."])
        #expect(Self.shapes(plan) == [["homebrew", "formula", F.brewPath, "install", "--formula", "jq"]])
    }

    @Test func duplicateKeySharedWithPreview() {
        // The same key as the import preview (`BundleRules.duplicateKey`): the last name segment, lowercased.
        let requests = [
            F.request(.install, .homebrew, .formula, "felixkratz/formulae/borders"),
            F.request(.install, .nanobrew, .formula, "Borders"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems == ["felixkratz/formulae/borders is selected from nanobrew and Homebrew. Pick one."])
        #expect(plan.steps.isEmpty)
    }

    @Test func formulaAndCaskSameNameBothPlanned() {
        // Discover: ticking formula `docker` and cask `docker` installs both; they live side by side.
        let requests = [
            F.request(.install, .homebrew, .formula, "docker"),
            F.request(.install, .homebrew, .cask, "docker"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Set(Self.shapes(plan).map { $0[1] }) == ["formula", "cask"])
        #expect(Self.shapes(plan).allSatisfy { $0.last == "docker" })

        // Two formulae with that name still clash; the cask is planned.
        let three = ActionPlanner.make(requests + [F.request(.install, .homebrew, .formula, "foo/bar/docker")],
                                       engines: F.engines, order: F.order)
        #expect(three.problems == ["docker is selected twice from Homebrew (docker and foo/bar/docker). Pick one."])
        #expect(Self.shapes(three).map { $0[1] } == ["cask"])
    }

    @Test func tapAndPackageWithSameNameAreNotDuplicates() {
        let requests = [
            F.request(.install, .homebrew, .tap, "felixkratz/formulae"),
            F.request(.install, .nanobrew, .formula, "formulae"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.count == 2)
    }

    // MARK: Taps

    @Test func tapsRunBeforeFormulae() {
        let requests = [
            F.request(.install, .homebrew, .cask, "rectangle"),
            F.request(.install, .homebrew, .formula, "felixkratz/formulae/borders"),
            F.request(.install, .homebrew, .tap, "felixkratz/formulae"),
            F.request(.install, .homebrew, .formula, "jq"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["homebrew", "tap", F.brewPath, "tap", "felixkratz/formulae"],
            ["homebrew", "formula", F.brewPath, "install", "--formula", "felixkratz/formulae/borders", "jq"],
            ["homebrew", "cask", F.brewPath, "install", "--cask", "rectangle"],
        ])
        #expect(plan.steps[0].title == "Add tap `felixkratz/formulae`")
        #expect(plan.steps.map(RunRouting.route(for:)) == [.user, .user, .userWithAskpass])
    }

    @Test func twoTapsAreTwoSteps() {
        let requests = [
            F.request(.install, .homebrew, .tap, "felixkratz/formulae"),
            F.request(.install, .homebrew, .tap, "hashicorp/tap"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["homebrew", "tap", F.brewPath, "tap", "felixkratz/formulae"],
            ["homebrew", "tap", F.brewPath, "tap", "hashicorp/tap"],
        ])
        #expect(plan.steps.map(\.title) == ["Add tap `felixkratz/formulae`", "Add tap `hashicorp/tap`"])
    }

    @Test func tapTitleSaysAddOnlyForInstalls() {
        let plan = ActionPlanner.make([F.request(.remove, .homebrew, .tap, "felixkratz/formulae")],
                                      engines: F.engines, order: F.order)
        #expect(plan.steps.isEmpty)
        #expect(plan.problems == ["Homebrew: felixkratz/formulae: BrewxPort only adds taps"])
    }

    @Test func sameNameUpgradeFromTwoEnginesAllowed() {
        let requests = [
            F.request(.upgrade, .nanobrew, .formula, "figlet"),
            F.request(.upgrade, .macports, .port, "figlet"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["nanobrew", "formula", F.nbPath, "upgrade", "figlet"],
            ["macports", "port", F.portPath, "-N", "selfupdate"],
            ["macports", "port", F.portPath, "-N", "upgrade", "figlet"],
        ])
    }

    // MARK: MacPorts catalogue refresh

    @Test func macportsUpgradeStartsWithSelfupdate() {
        let requests = [
            F.request(.upgrade, .macports, .port, "curl"),
            F.request(.upgrade, .homebrew, .formula, "wget"),
            F.request(.upgrade, .macports, .port, "figlet"),
            F.request(.upgrade, .macports, .port, "bzip2", options: InstallOptions(extraArgs: ["-s"])),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [
            ["homebrew", "formula", F.brewPath, "upgrade", "wget"],
            ["macports", "port", F.portPath, "-N", "selfupdate"],
            ["macports", "port", F.portPath, "-N", "upgrade", "curl", "figlet"],
            ["macports", "port", F.portPath, "-N", "upgrade", "-s", "bzip2"],
        ])
        let refresh = plan.steps[1]
        #expect(refresh.title == "MacPorts: refresh the port catalogue")
        #expect(refresh.operation == .upgrade)
        #expect(RunRouting.route(for: refresh) == .helper)
        #expect(refresh.gateGroup == "macports-selfupdate")
        #expect(!refresh.requiresAllEarlier)
        // Every MacPorts upgrade waits on the refresh's group; Homebrew's step waits on nothing.
        #expect(plan.steps[2...].allSatisfy { $0.requiresAllEarlier && $0.gateGroup == "macports-selfupdate" })
        #expect(plan.steps[0].gateGroup == nil)
        #expect(!plan.steps[0].requiresAllEarlier)
        #expect(plan.reason == "BrewxPort needs an administrator password to update these packages.")
    }

    @Test func noSelfupdateWithoutMacportsUpgrades() {
        let requests = [
            F.request(.install, .macports, .port, "figlet"),
            F.request(.remove, .macports, .port, "curl"),
            F.request(.upgrade, .homebrew, .formula, "wget"),
            F.request(.upgrade, .homebrew, .cask, "blackhole-2ch"),
            F.request(.upgrade, .nanobrew, .formula, "ripgrep"),
            F.request(.upgrade, .mas, .app, "497799835"),
        ]
        let plan = ActionPlanner.make(requests, engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.count == 6)
        #expect(!plan.steps.contains { $0.spec.arguments.contains("selfupdate") })
        #expect(plan.steps.allSatisfy { $0.gateGroup == nil && !$0.requiresAllEarlier })

        // A MacPorts upgrade that can't be planned leaves no refresh behind it.
        let variants = F.request(.upgrade, .macports, .port, "curl", options: InstallOptions(variants: ["+universal"]))
        let refused = ActionPlanner.make([variants], engines: F.engines, order: F.order)
        #expect(refused.steps.isEmpty)
        #expect(refused.problems == ["MacPorts: curl: Variants only apply to install"])
    }

    @Test func macportsUpgradesWithoutARefreshAreLeftOut() {
        // An engine that can't refresh its catalogue (only a stand-in can't) never updates against a stale one.
        let engines: [any Engine] = [F.engines[0], MoveFakeEngine(wrapping: F.engines[2])]
        let requests = [F.request(.upgrade, .macports, .port, "curl"), F.request(.upgrade, .homebrew, .formula, "wget")]
        let plan = ActionPlanner.make(requests, engines: engines, order: F.order)
        #expect(Self.shapes(plan) == [["homebrew", "formula", F.brewPath, "upgrade", "wget"]])
        #expect(plan.problems == ["MacPorts: curl: left out, because MacPorts can't refresh its port catalogue here."])
    }

    // MARK: nanobrew casks

    @Test func nanobrewCaskNeedingRootInstallsWithHomebrew() {
        let request = F.request(.install, .nanobrew, .cask, "zoom")
        let plan = ActionPlanner.make([request], engines: F.engines, order: F.order,
                                      caskRoutes: [request.package.id: .homebrew])
        #expect(plan.problems.isEmpty)
        #expect(Self.shapes(plan) == [["homebrew", "cask", F.brewPath, "install", "--cask", "zoom"]])
        #expect(plan.steps.map(RunRouting.route(for:)) == [.userWithAskpass])
        #expect(plan.steps.first?.title == "Homebrew casks: zoom")
        #expect(plan.notes == [
            "zoom: installed with Homebrew, because its installer needs administrator rights and nanobrew can't use them."
        ])
    }

    @Test func nanobrewCaskWithoutHomebrewNeedsHomebrew() {
        let request = F.request(.install, .nanobrew, .cask, "zoom")
        let plan = ActionPlanner.make([request], engines: F.engines, order: F.order,
                                      caskRoutes: [request.package.id: .needsHomebrew])
        #expect(plan.steps.isEmpty)
        #expect(plan.problems == [
            "zoom needs Homebrew: its installer needs administrator rights, which nanobrew can't use."
        ])
    }

    @Test func nanobrewCaskWithoutRouteStaysOnNanobrew() {
        let request = F.request(.install, .nanobrew, .cask, "iterm2")
        let plan = ActionPlanner.make([request], engines: F.engines, order: F.order,
                                      caskRoutes: [PackageRef(engine: .nanobrew, kind: .cask, name: "other"): .homebrew])
        #expect(Self.shapes(plan) == [["nanobrew", "cask", F.nbPath, "install", "--cask", "iterm2"]])
        #expect(plan.notes.isEmpty)
    }

    @Test func nanobrewCaskUpgradeStaysOnNanobrew() {
        let upgrade = F.request(.upgrade, .nanobrew, .cask, "zoom")
        let remove = F.request(.remove, .nanobrew, .cask, "slack")
        let plan = ActionPlanner.make([upgrade, remove], engines: F.engines, order: F.order,
                                      caskRoutes: [upgrade.package.id: .homebrew, remove.package.id: .needsHomebrew])
        #expect(plan.problems.isEmpty)
        #expect(plan.notes.isEmpty)
        #expect(Self.shapes(plan) == [
            ["nanobrew", "cask", F.nbPath, "remove", "--cask", "slack"],
            ["nanobrew", "cask", F.nbPath, "upgrade", "--cask", "zoom"],
        ])
    }

    @Test func caskRoutingTable() {
        #expect(CaskRouting.route(needsRoot: false, homebrewPresent: true) == .nanobrew)
        #expect(CaskRouting.route(needsRoot: false, homebrewPresent: false) == .nanobrew)
        #expect(CaskRouting.route(needsRoot: true, homebrewPresent: true) == .homebrew)
        #expect(CaskRouting.route(needsRoot: true, homebrewPresent: false) == .needsHomebrew)
        #expect(CaskRouting.route(needsRoot: nil, homebrewPresent: true) == .homebrew)
        #expect(CaskRouting.route(needsRoot: nil, homebrewPresent: false) == .needsHomebrew)
    }

    // MARK: One target per command

    /// No registry: building commands never reads one.
    struct NoRegistry: RegistryFetching {
        func get(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
    }

    /// Not a capture: crates.io's index with one version per crate, in the index's line shape (the fields BrewxPort
    /// reads), so Cargo's outdated check offers that version. Only ripgrep's index file was captured.
    struct IndexRegistry: RegistryFetching {
        let versions: [String: String]

        func get(_ url: URL) async throws -> Data {
            let name = url.lastPathComponent
            guard url.host == "index.crates.io", let vers = versions[name] else { throw RegistryFetchError.status(404) }
            return Data((#"{"name":"\#(name)","vers":"\#(vers)","deps":[],"cksum":"","features":{},"yanked":false}"#
                         + "\n").utf8)
        }
    }

    static let toolBin = "/opt/homebrew/bin"

    static func tool(_ engine: EngineID, _ name: String) -> Package {
        Package(id: PackageRef(engine: engine, kind: .tool, name: name), displayName: name, installedVersion: "1",
                latestVersion: "2")
    }

    static func requests(_ operation: PackageOperation, _ engine: EngineID, _ names: [String]) -> [ActionRequest] {
        names.map { ActionRequest(operation: operation, package: tool(engine, $0)) }
    }

    /// pipx before 1.6.0 upgrades one tool per command, and a step per tool gives each its own result. Installs still
    /// share one command.
    @Test func plannerSplitsPipxUpgrades() {
        let pipx = PipxEngine(runner: F.runner, registry: NoRegistry(),
                              executable: URL(fileURLWithPath: Self.toolBin + "/pipx"))
        let plan = ActionPlanner.make(Self.requests(.upgrade, .pipx, ["black", "ruff"])
                                      + Self.requests(.install, .pipx, ["isort", "httpie"]),
                                      engines: [pipx], order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.spec.arguments) == [["install", "isort", "httpie"], ["upgrade", "black"],
                                                     ["upgrade", "ruff"]])
        #expect(plan.steps.map(\.title) == ["pipx: isort, httpie", "pipx: black", "pipx: ruff"])
    }

    /// `uv tool install` takes one package: two installs are two steps; upgrades share one.
    @Test func plannerSplitsUvInstalls() {
        let uv = UvEngine(runner: F.runner, registry: NoRegistry(), executable: URL(fileURLWithPath: Self.toolBin + "/uv"))
        let plan = ActionPlanner.make(Self.requests(.install, .uv, ["isort", "ruff"])
                                      + Self.requests(.upgrade, .uv, ["black", "httpie"]),
                                      engines: [uv], order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.spec.arguments) == [
            ["tool", "install", "--color", "never", "--no-progress", "isort"],
            ["tool", "install", "--color", "never", "--no-progress", "ruff"],
            ["tool", "upgrade", "--color", "never", "--no-progress", "black", "httpie"],
        ])
    }

    /// Not a capture: the captured `.crates2.json` (Fixtures/cargo) with ripgrep's `"features":[]` changed to
    /// `["pcre2"]` and a plain `bat` install added as a copy of ripgrep's entry, in cargo's own shape. T13 recorded
    /// `--features` only for a path install (`t13-path-features-crates2.json`), which is never upgraded.
    static func cargoRecord() throws -> Data {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BrewxPortCoreTests/Fixtures/cargo/crates2.json")
        let captured = try String(contentsOf: fixture, encoding: .utf8)
        try #require(captured.contains(#""features":[]"#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any])
        var installs = try #require(object["installs"] as? [String: Any])
        let (key, value) = try #require(installs.first)
        var ripgrep = try #require(value as? [String: Any])
        installs["bat 0.24.0 (registry+https://github.com/rust-lang/crates.io-index)"] = ripgrep
            .merging(["bins": ["bat"]]) { $1 }
        ripgrep["features"] = ["pcre2"]
        installs[key] = ripgrep
        return try JSONSerialization.data(withJSONObject: ["installs": installs])
    }

    /// Cargo upgrades one crate per command, each with the options cargo recorded for it and the version its check
    /// offered (R36): a crate with options among others is no longer refused, and nothing is reported.
    @Test func plannerSplitsCargoUpgradesWithRecordedOptions() async throws {
        let record = try Self.cargoRecord()
        let cargo = CargoEngine(runner: F.runner, registry: IndexRegistry(versions: ["ripgrep": "16.0.0",
                                                                                    "bat": "0.25.0"]),
                                executable: URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/cargo"),
                                base: ["HOME": "/Users/someone", "PATH": "/usr/bin:/bin"],
                                readRecord: { $0 == "/Users/someone/.cargo/.crates2.json" ? record : nil })
        _ = try await cargo.checkOutdated()
        let plan = ActionPlanner.make(Self.requests(.upgrade, .cargo, ["ripgrep", "bat"])
                                      + Self.requests(.install, .cargo, ["fd-find", "tokei"]),
                                      engines: [cargo], order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.spec.arguments) == [["install", "fd-find"], ["install", "tokei"],
                                                     ["install", "--features", "pcre2", "--version", "=16.0.0",
                                                      "ripgrep"],
                                                     ["install", "--version", "=0.25.0", "bat"]])
        #expect(plan.steps.map(\.title) == ["Cargo: fd-find", "Cargo: tokei", "Cargo: ripgrep", "Cargo: bat"])
    }

    /// Homebrew, which takes many names per command, keeps one step per kind: formulae, then casks.
    @Test func homebrewBatchesUnchanged() {
        let plan = ActionPlanner.make([F.request(.upgrade, .homebrew, .formula, "wget"),
                                       F.request(.upgrade, .homebrew, .formula, "jq"),
                                       F.request(.upgrade, .homebrew, .cask, "firefox"),
                                       F.request(.upgrade, .homebrew, .cask, "zoom"),
                                       F.request(.install, .homebrew, .formula, "fd"),
                                       F.request(.install, .homebrew, .formula, "bat"),
                                       F.request(.install, .homebrew, .cask, "iterm2"),
                                       F.request(.install, .homebrew, .cask, "rectangle")],
                                      engines: F.engines, order: F.order)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.spec.arguments) == [["install", "--formula", "fd", "bat"],
                                                     ["install", "--cask", "iterm2", "rectangle"],
                                                     ["upgrade", "wget", "jq"],
                                                     ["upgrade", "--cask", "firefox", "zoom"]])
        #expect(plan.steps.map(\.kind) == [.formula, .cask, .formula, .cask])
        for engine in F.engines {
            for operation in [PackageOperation.install, .upgrade, .remove] {
                #expect(engine.maxTargetsPerCommand(for: operation) == nil, "\(engine.id) \(operation)")
            }
        }
    }

    /// The limits the language engines declare: Mint does everything one package at a time.
    @Test func languageEnginesDeclareTheirLimits() {
        let url = URL(fileURLWithPath: Self.toolBin + "/x")
        let engines: [any Engine] = [
            NpmEngine(runner: F.runner, executable: url),
            PipxEngine(runner: F.runner, registry: NoRegistry(), executable: url),
            UvEngine(runner: F.runner, registry: NoRegistry(), executable: url),
            CargoEngine(runner: F.runner, registry: NoRegistry(), executable: url, readRecord: { _ in nil }),
            BunEngine(runner: F.runner, registry: NoRegistry(), executable: url),
            GemEngine(runner: F.runner, registry: NoRegistry(), executable: url),
            MintEngine(runner: F.runner, executable: url, git: nil, readMetadata: { _ in nil }),
        ]
        func limits(_ id: EngineID) -> [Int?] {
            let engine = engines.first { $0.id == id }!
            return [PackageOperation.install, .upgrade, .remove].map { engine.maxTargetsPerCommand(for: $0) }
        }
        #expect(limits(.npm) == [nil, nil, nil])
        #expect(limits(.pipx) == [nil, 1, 1])
        #expect(limits(.uv) == [1, nil, nil])
        #expect(limits(.cargo) == [1, 1, nil])
        #expect(limits(.bun) == [nil, nil, nil])
        #expect(limits(.gem) == [nil, nil, nil])
        #expect(limits(.mint) == [1, 1, 1])
    }

    /// An engine's limit splits a plain batch into steps of that size, in request order. (A request with options of
    /// its own already gets a step to itself.)
    @Test func plannerSplitsToTheEnginesLimit() {
        let pipx = PipxEngine(runner: F.runner, registry: NoRegistry(),
                              executable: URL(fileURLWithPath: Self.toolBin + "/pipx"))
        let plan = ActionPlanner.make(Self.requests(.upgrade, .pipx, ["a", "b", "c"]), engines: [pipx],
                                      order: F.order)
        #expect(plan.steps.map(\.spec.arguments) == [["upgrade", "a"], ["upgrade", "b"], ["upgrade", "c"]])
    }

    // MARK: Reason

    @Test func reasonNamesOperation() {
        func reason(_ requests: [ActionRequest]) -> String {
            ActionPlanner.make(requests, engines: F.engines, order: F.order).reason
        }
        #expect(reason([F.request(.install, .homebrew, .cask, "zoom")])
                == "BrewxPort needs an administrator password to install these packages.")
        #expect(reason([F.request(.upgrade, .macports, .port, "curl")])
                == "BrewxPort needs an administrator password to update these packages.")
        #expect(reason([F.request(.remove, .mas, .app, "497799835")])
                == "BrewxPort needs an administrator password to remove these packages.")
        #expect(reason([F.request(.remove, .mas, .app, "497799835"), F.request(.upgrade, .macports, .port, "curl")])
                == "BrewxPort needs an administrator password to make these changes.")
    }
}
