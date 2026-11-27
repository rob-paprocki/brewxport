import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct EngineSetupPlannerTests {
    typealias P = PlanFixtures
    static let arm = HostInfo(appleSilicon: true, macOSMajor: 15)
    static let intel = HostInfo(appleSilicon: false, macOSMajor: 15)
    static func present(_ path: String) -> EngineStatus { .present(path: URL(fileURLWithPath: path), version: "1") }

    func plan(_ engine: EngineID, statuses: [EngineID: EngineStatus] = [:], host: HostInfo = arm,
              clt: Bool = true) -> ActionPlan {
        EngineSetupPlanner.plan(engine, statuses: statuses, host: host, cltPresent: clt, engines: P.engines)
    }

    @Test func homebrewIsOneSetupStep() {
        let result = plan(.homebrew)
        #expect(result.steps.map(\.setupTarget) == [.homebrew])
        #expect(result.steps.map(\.title) == ["Set up Homebrew"])
    }

    @Test func macportsAddsCLTWhenMissing() {
        let result = plan(.macports, clt: false)
        #expect(result.steps.map(\.setupTarget) == [.commandLineTools, .macports])
        #expect(result.steps.map(\.title) == ["Install Apple's Command Line Tools", "Set up MacPorts"])
        #expect(result.steps.map(\.dependsOnPrevious) == [false, true])
    }

    @Test func macportsSkipsCLTWhenPresent() {
        let result = plan(.macports, clt: true)
        #expect(result.steps.map(\.setupTarget) == [.macports])
        #expect(result.steps.map(\.dependsOnPrevious) == [false])
    }

    @Test func nanobrewAddsInit() {
        let result = plan(.nanobrew)
        #expect(result.steps.count == 2)
        #expect(result.steps[0].setupTarget == .nanobrew)
        let initStep = result.steps[1]
        #expect(initStep.engine == .nanobrew)
        #expect(initStep.setupTarget == nil)
        #expect(initStep.spec.executable.path == "/opt/nanobrew/prefix/bin/nb")
        #expect(initStep.spec.arguments == ["init"])
        #expect(initStep.spec.needsRoot)
        #expect(initStep.dependsOnPrevious)
        #expect(initStep.title == "Run nb init")
        #expect(RunRouting.route(for: initStep) == .sudoAskpass)
    }

    @Test func masViaHomebrew() throws {
        let statuses: [EngineID: EngineStatus] = [.homebrew: Self.present(P.brewPath),
                                                  .macports: Self.present(P.portPath)]
        let result = plan(.mas, statuses: statuses)
        #expect(result.problems.isEmpty)
        #expect(result.steps.map(\.engine) == [.homebrew])
        let step = try #require(result.steps.first)
        #expect(step.kind == .formula)
        #expect(step.operation == .install)
        #expect(step.setupTarget == nil)
        #expect(step.spec.executable.path == P.brewPath)
        #expect(step.spec.arguments == ["install", "--formula", "mas"])
        #expect(!step.spec.needsRoot)
    }

    @Test func masViaMacPortsWhenNoHomebrew() {
        let result = plan(.mas, statuses: [.macports: Self.present(P.portPath), .homebrew: .missing])
        #expect(result.steps.map(\.engine) == [.macports])
        #expect(result.steps[0].spec.arguments.contains("mas"))
    }

    @Test func masNeedsAManager() {
        let result = plan(.mas, statuses: [.homebrew: .missing])
        #expect(result.steps.isEmpty)
        #expect(result.problems == ["Set up Homebrew or MacPorts first: mas installs through one of them."])
    }

    @Test func homebrewIntelRefused() {
        let result = plan(.homebrew, host: Self.intel)
        #expect(result.steps.isEmpty)
        #expect(result.problems == ["Homebrew doesn't support Intel Macs. MacPorts does the same job."])
    }

    @Test func alreadyPresentNote() {
        let result = plan(.nanobrew, statuses: [.nanobrew: Self.present(P.nbPath)])
        #expect(result.steps.isEmpty)
        #expect(result.problems.isEmpty)
        #expect(result.notes == ["\(EngineID.nanobrew.displayName) is already set up."])
    }

    @Test func recommendedPerArch() {
        #expect(EngineSetupPlanner.recommended(host: Self.arm) == .homebrew)
        #expect(EngineSetupPlanner.recommended(host: Self.intel) == .macports)
        #expect(EngineSetupPlanner.offered(host: Self.arm) == [.homebrew, .macports, .nanobrew, .mas] + Self.languages)
        #expect(EngineSetupPlanner.offered(host: Self.intel) == [.macports, .nanobrew, .mas] + Self.languages)
    }

    // MARK: Language engines (Plan 9 Task 11)

    static let languages: [EngineID] = [.npm, .pipx, .uv, .cargo, .bun, .gem, .mint]
    static let intelBrewPath = "/usr/local/bin/brew"
    /// Homebrew in /usr/local, as on an Intel Mac.
    static let intelEngines: [any Engine] = [
        HomebrewEngine(runner: P.runner, executable: URL(fileURLWithPath: intelBrewPath), arch: .x86_64),
        MacPortsEngine(runner: P.runner, executable: URL(fileURLWithPath: P.portPath)),
    ]
    static let withHomebrew: [EngineID: EngineStatus] = [.homebrew: present(P.brewPath), .macports: .missing]
    static let intelHomebrew: [EngineID: EngineStatus] = [.homebrew: present(intelBrewPath)]
    /// A Mac without Homebrew (every Intel Mac), with MacPorts.
    static let macPortsOnly: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: present(P.portPath)]
    static let neither: [EngineID: EngineStatus] = [.homebrew: .missing, .macports: .missing]
    static let formulae: [EngineID: String] = [.npm: "node", .pipx: "pipx", .uv: "uv", .cargo: "rustup", .bun: "bun",
                                               .gem: "ruby", .mint: "mint"]
    static let login = ["CARGO_HOME": "/Users/tester/rust/cargo", "RUSTUP_HOME": "/Users/tester/rust/rustup",
                        "GEM_HOME": "/Users/tester/gems"]

    func languagePlan(_ engine: EngineID, statuses: [EngineID: EngineStatus], host: HostInfo = arm,
                      engines: [any Engine] = P.engines) -> ActionPlan {
        EngineSetupPlanner.plan(engine, statuses: statuses, host: host, cltPresent: true, engines: engines,
                                loginEnvironment: Self.login)
    }

    /// Every one of the seven, on each kind of Mac: Homebrew's formula when Homebrew is there (Apple silicon, or an
    /// Intel Mac that has it in /usr/local); MacPorts' port for pipx, uv, rustup and mint when only MacPorts is.
    @Test func setupTargetsPerHost() throws {
        for engine in Self.languages {
            let formula = try #require(Self.formulae[engine])
            for (host, statuses, engines, brew) in [(Self.arm, Self.withHomebrew, P.engines, P.brewPath),
                                                    (Self.intel, Self.intelHomebrew, Self.intelEngines,
                                                     Self.intelBrewPath)] {
                let result = languagePlan(engine, statuses: statuses, host: host, engines: engines)
                #expect(result.problems.isEmpty)
                let install = try #require(result.steps.first)
                #expect(install.engine == .homebrew)
                #expect(install.kind == .formula)
                #expect(install.operation == .install)
                #expect(install.spec.executable.path == brew)
                #expect(install.spec.arguments == ["install", "--formula", formula])
                #expect(RunRouting.route(for: install) == .user)
                #expect(result.steps.count == (engine == .cargo ? 2 : 1))
            }
        }
        for engine in [EngineID.pipx, .uv, .cargo, .mint] {
            let result = languagePlan(engine, statuses: Self.macPortsOnly, host: Self.intel)
            #expect(result.problems.isEmpty)
            let install = try #require(result.steps.first)
            #expect(install.engine == .macports)
            #expect(install.kind == .port)
            #expect(install.spec.executable.path == P.portPath)
            #expect(install.spec.arguments.last == Self.formulae[engine])
            #expect(install.spec.arguments.contains("install"))
            // MacPorts' normal password route: through the helper, which asks once.
            #expect(RunRouting.route(for: install) == .helper)
            #expect(result.steps.count == (engine == .cargo ? 2 : 1))
        }
    }

    /// Without Homebrew, npm, Bun and RubyGems aren't set up through MacPorts (its Node and Ruby keep their global
    /// folders in root-owned /opt/local; it builds Bun for hours): nothing runs, and the plan says why and what to do.
    @Test func macPortsOnlyHostSkipsNodeBunRuby() {
        for engine in [EngineID.npm, .bun, .gem] {
            for host in [Self.intel, Self.arm] {
                let result = languagePlan(engine, statuses: Self.macPortsOnly, host: host)
                #expect(result.steps.isEmpty)
                #expect(result.problems == [SetupCopy.homebrewOnly(engine, appleSilicon: host.appleSilicon)])
                #expect(EngineSetupPlanner.languageRoute(engine, statuses: Self.macPortsOnly) == .homebrewOnly)
            }
        }
        #expect(SetupCopy.homebrewOnly(.npm, appleSilicon: false)
                == "BrewxPort sets up npm only through Homebrew: MacPorts' Node keeps its global tools in /opt/local, "
                + "which only an administrator can change. Install Node in your home folder instead, with a version "
                + "manager such as nvm.")
        #expect(SetupCopy.homebrewOnly(.npm, appleSilicon: true)
                == "BrewxPort sets up npm only through Homebrew: MacPorts' Node keeps its global tools in /opt/local, "
                + "which only an administrator can change. Set up Homebrew, or install Node in your home folder with a "
                + "version manager such as nvm.")
        #expect(SetupCopy.homebrewOnly(.bun, appleSilicon: false)
                == "BrewxPort sets up Bun only through Homebrew: MacPorts builds Bun from source, which takes hours. "
                + "Install Bun in your home folder instead, as bun.com describes.")
        #expect(SetupCopy.homebrewOnly(.gem, appleSilicon: true)
                == "BrewxPort sets up RubyGems only through Homebrew: MacPorts' Ruby keeps its gems in /opt/local, "
                + "which only an administrator can change. Set up Homebrew, or install Ruby in your home folder with a "
                + "version manager such as rbenv.")
        // The other four go through MacPorts there.
        for engine in [EngineID.pipx, .uv, .cargo, .mint] {
            #expect(EngineSetupPlanner.languageRoute(engine, statuses: Self.macPortsOnly)
                    == .macports(port: Self.formulae[engine]!))
        }
    }

    /// With neither Homebrew nor MacPorts there's nothing to install through: the plan says which to set up first.
    @Test func languageSetUpNeedsAPackageManager() {
        for engine in [EngineID.pipx, .uv, .cargo, .mint] {
            let result = languagePlan(engine, statuses: Self.neither)
            #expect(result.steps.isEmpty)
            #expect(result.problems == [SetupCopy.languageNeedsManager(engine, appleSilicon: true)])
            #expect(EngineSetupPlanner.languageRoute(engine, statuses: Self.neither) == .needsManager)
        }
        #expect(SetupCopy.languageNeedsManager(.pipx, appleSilicon: true)
                == "Set Up installs pipx through Homebrew or MacPorts. Set up one of them first.")
        #expect(SetupCopy.languageNeedsManager(.mint, appleSilicon: false)
                == "Set Up installs Mint through MacPorts. Set up MacPorts first.")
        // A Homebrew that isn't working doesn't count.
        let broken: [EngineID: EngineStatus] = [.homebrew: .unusable(path: URL(fileURLWithPath: P.brewPath),
                                                                     reason: "bad"),
                                                .macports: Self.present(P.portPath)]
        #expect(EngineSetupPlanner.languageRoute(.uv, statuses: broken) == .macports(port: "uv"))
        #expect(EngineSetupPlanner.languageRoute(.npm, statuses: broken) == .homebrewOnly)
        #expect(EngineSetupPlanner.languageRoute(.homebrew, statuses: broken) == nil)
    }

    @Test func languageAlreadyPresentNote() {
        let statuses = Self.withHomebrew.merging([.uv: Self.present("/opt/homebrew/bin/uv")]) { $1 }
        let result = languagePlan(.uv, statuses: statuses)
        #expect(result.steps.isEmpty)
        #expect(result.notes == ["uv is already set up."])
    }

    /// Cargo's Set Up: Homebrew's keg-only rustup, then `rustup default stable` as the user, with the Cargo engine's
    /// environment, except that RUSTUP_AUTO_INSTALL isn't 0 for this one step: installing the toolchain is its point.
    @Test func rustupSetsDefaultStable() throws {
        for (host, statuses, engines, prefix) in [(Self.arm, Self.withHomebrew, P.engines, "/opt/homebrew"),
                                                  (Self.intel, Self.intelHomebrew, Self.intelEngines, "/usr/local")] {
            let result = languagePlan(.cargo, statuses: statuses, host: host, engines: engines)
            #expect(result.steps.count == 2)
            let toolchain = try #require(result.steps.last)
            #expect(toolchain.engine == .cargo)
            #expect(toolchain.setupTarget == nil)
            #expect(toolchain.dependsOnPrevious)
            #expect(toolchain.title == "Install Rust's stable toolchain")
            #expect(toolchain.spec.executable.path == prefix + "/opt/rustup/bin/rustup")
            #expect(toolchain.spec.arguments == ["default", "stable"])
            #expect(!toolchain.spec.needsRoot)
            #expect(RunRouting.route(for: toolchain) == .user)
            #expect(toolchain == RunStep.rustToolchain(toolchain.spec))
            let environment = try #require(toolchain.spec.environment)
            #expect(environment["RUSTUP_AUTO_INSTALL"] == "1")
            #expect(environment["PATH"]?.hasPrefix(prefix + "/opt/rustup/bin:") == true)
            #expect(environment["CARGO_HOME"] == "/Users/tester/rust/cargo")
            #expect(environment["RUSTUP_HOME"] == "/Users/tester/rust/rustup")
            #expect(environment["GEM_HOME"] == nil)
            #expect(environment["NO_COLOR"] == "1")
            #expect(toolchain.spec.workingDirectory == ProcessRunner.baseEnvironment["HOME"] ?? NSHomeDirectory())
        }
        // MacPorts' rustup port installs only rustup-init: it installs rustup in the home folder and the stable
        // toolchain, without touching the shell's startup files (Add to PATH is the person's choice).
        let ports = languagePlan(.cargo, statuses: Self.macPortsOnly, host: Self.intel)
        let toolchain = try #require(ports.steps.last)
        #expect(toolchain.spec.executable.path == "/opt/local/bin/rustup-init")
        #expect(toolchain.spec.arguments == ["-y", "--no-modify-path", "--default-toolchain", "stable"])
        #expect(toolchain.spec.environment?["RUSTUP_AUTO_INSTALL"] == "1")
        #expect(toolchain.spec.environment?["RUSTUP_HOME"] == "/Users/tester/rust/rustup")
        #expect(RunRouting.route(for: toolchain) == .user)
        #expect(toolchain.dependsOnPrevious)
        // The Cargo engine's own commands still never let rustup download a toolchain.
        let cargo = ToolEnvironment.make(for: .cargo, executable: URL(fileURLWithPath: "/x/cargo"), captured: [:],
                                         base: [:])
        #expect(cargo["RUSTUP_AUTO_INSTALL"] == "0")
    }

    /// No Set Up ever downloads or runs an installer script: every step is the package manager's own install, or
    /// rustup's toolchain step from the rustup a package manager installed.
    @Test func noScriptDownloads() {
        let cases: [(HostInfo, [EngineID: EngineStatus], [any Engine])] = [
            (Self.arm, Self.withHomebrew, P.engines), (Self.intel, Self.intelHomebrew, Self.intelEngines),
            (Self.intel, Self.macPortsOnly, P.engines), (Self.arm, Self.macPortsOnly, P.engines),
            (Self.arm, Self.neither, P.engines),
        ]
        let toolchain: Set<[String]> = [["default", "stable"], ["-y", "--no-modify-path", "--default-toolchain", "stable"]]
        var steps = 0
        for (host, statuses, engines) in cases {
            for engine in Self.languages {
                for step in languagePlan(engine, statuses: statuses, host: host, engines: engines).steps {
                    steps += 1
                    let name = step.spec.executable.lastPathComponent
                    #expect(!["curl", "wget", "sh", "bash", "zsh", "python3", "ruby", "node"].contains(name))
                    #expect(!step.spec.arguments.contains { $0.contains("://") || $0.contains("http") })
                    switch step.engine {
                    case .homebrew:
                        #expect(name == "brew")
                        #expect(step.spec.arguments.prefix(2) == ["install", "--formula"])
                    case .macports:
                        #expect(name == "port")
                        #expect(step.spec.arguments.contains("install"))
                    case .cargo:
                        #expect(["rustup", "rustup-init"].contains(name))
                        #expect(toolchain.contains(step.spec.arguments))
                    default:
                        Issue.record("unexpected step on \(step.engine)")
                    }
                }
            }
        }
        // 8 with Homebrew (Cargo has two) on each arch, 5 with MacPorts only (pipx, uv, mint, Cargo's two) on each.
        #expect(steps == 8 + 8 + 5 + 5)
    }

    /// RunRouting sends any step with a setupTarget to the helper's setUpEngine, as root. No language Set Up step has
    /// one, so none goes that way (and none reaches EngineSetupRunner, whose output isn't scrubbed).
    @Test func languageSetUpNeverUsesHelperSetup() {
        for statuses in [Self.withHomebrew, Self.macPortsOnly] {
            for engine in Self.languages {
                for step in languagePlan(engine, statuses: statuses, host: Self.arm).steps {
                    #expect(step.setupTarget == nil)
                    #expect(RunRouting.route(for: step) != .helperSetup)
                    #expect(!RunPreflight.usesHelper(step) || step.engine == .macports)
                }
            }
        }
    }

    /// R31: Cargo is "not working" because a rustup has no toolchain: the person's own (`~/.cargo/bin`, CARGO_HOME's
    /// bin) or Homebrew's keg, as found through the Cellar, left so by a toolchain step that failed. Set Up runs that
    /// rustup's `default stable` as the user, with Cargo's environment and RUSTUP_AUTO_INSTALL=1, and nothing else:
    /// never a second rustup through Homebrew or MacPorts, and with neither of them needed.
    @Test func ownRustupGetsToolchainWithoutSecondCopy() throws {
        func unusable(_ path: String) -> EngineStatus { .unusable(path: URL(fileURLWithPath: path), reason: "no toolchain") }
        for folder in ["/Users/tester/.cargo/bin", "/Users/tester/rust/cargo/bin",
                       "/opt/homebrew/Cellar/rustup/1.29.2/bin", "/opt/homebrew/opt/rustup/bin"] {
            let rustup = folder + "/rustup"
            #expect(EngineSetupPlanner.rustupWithoutToolchain(unusable(folder + "/cargo"),
                                                              fileExists: { $0 == rustup })?.path == rustup)
            for system in [Self.withHomebrew, Self.macPortsOnly, Self.neither] {
                let result = EngineSetupPlanner.plan(
                    .cargo, statuses: system.merging([.cargo: unusable(folder + "/cargo")]) { $1 }, host: Self.arm,
                    cltPresent: true, engines: P.engines, loginEnvironment: Self.login, fileExists: { $0 == rustup })
                #expect(result.problems.isEmpty)
                #expect(result.steps.count == 1)
                let step = try #require(result.steps.first)
                #expect(step.engine == .cargo)
                #expect(step.setupTarget == nil)
                #expect(!step.dependsOnPrevious)
                #expect(step.spec.executable.path == rustup)
                #expect(step.spec.arguments == ["default", "stable"])
                #expect(step.spec.environment?["RUSTUP_AUTO_INSTALL"] == "1")
                #expect(step.spec.environment?["RUSTUP_HOME"] == "/Users/tester/rust/rustup")
                #expect(step.spec.environment?["PATH"]?.hasPrefix(folder + ":") == true)
                #expect(RunRouting.route(for: step) == .user)
            }
        }
        // A cargo with no rustup beside it isn't rustup's: not set up again.
        #expect(EngineSetupPlanner.rustupWithoutToolchain(unusable("/opt/local/bin/cargo"), fileExists: { _ in false })
                == nil)
        // Only a cargo that's there and not working.
        #expect(EngineSetupPlanner.rustupWithoutToolchain(.missing, fileExists: { _ in true }) == nil)
        #expect(EngineSetupPlanner.rustupWithoutToolchain(Self.present("/Users/tester/.cargo/bin/cargo"),
                                                          fileExists: { _ in true }) == nil)
        #expect(EngineSetupPlanner.rustupWithoutToolchain(unusable("/Users/tester/.cargo/bin/rustc"),
                                                          fileExists: { _ in true }) == nil)
    }
}
