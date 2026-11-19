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
            ["macports", "port", F.portPath, "-N", "upgrade", "curl"],
            ["mas", "app", F.masPath, "upgrade", "497799835"],
        ])
        #expect(plan.steps.map(RunRouting.route(for:)) == [.user, .user, .userWithAskpass, .helper, .sudoAskpass])
        #expect(plan.steps[2].title == "Homebrew casks: blackhole-2ch")
        #expect(plan.steps.allSatisfy { $0.operation == .upgrade })
    }

    @Test func engineThatCantBuildItsCommandIsReportedNotFatal() {
        let engines: [any Engine] = [
            HomebrewEngine(runner: F.runner, executable: nil, arch: .arm64),  // not installed: command throws
            MacPortsEngine(runner: F.runner, executable: URL(fileURLWithPath: F.portPath)),
        ]
        let plan = ActionPlanner.make(Self.upgrades(Self.outdated), engines: engines, order: [.homebrew, .macports])
        #expect(plan.steps.map(\.engine) == [.macports])
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
            ["homebrew", "formula", F.brewPath, "uninstall", "wget"],
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
        #expect(Self.shapes(plan) == [["homebrew", "formula", F.brewPath, "install", "jq"]])
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
            ["macports", "port", F.portPath, "-N", "upgrade", "figlet"],
        ])
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
