import Foundation
import BrewxPortCore
import BrewxPortRun

/// How a language engine's Set Up gets what it needs on this Mac, as the last engine check found it (Plan 9 Task 11).
public enum LanguageSetupRoute: Equatable, Sendable {
    /// Homebrew's formula, installed like any other: as the user, no password. `prefix` is Homebrew's
    /// (`/opt/homebrew`, or `/usr/local` on an Intel Mac).
    case homebrew(formula: String, prefix: String)
    /// MacPorts' port, installed like any other: through the helper, with the administrator password.
    case macports(port: String)
    /// npm, Bun or RubyGems without Homebrew: not set up through MacPorts (`SetupCopy.homebrewOnly`).
    case homebrewOnly
    /// pipx, uv, Cargo or Mint with neither Homebrew nor MacPorts working: one of them first.
    case needsManager
}

/// Turns "set up <engine>" into the steps of a run.
///
/// The system package managers' setup steps (`setupTarget != nil`) go to the helper's `setUpEngine` request, which
/// does the work as root. Their `CommandSpec` is never executed: it is an inert placeholder (the engine's expected
/// executable, no arguments, root). Only the `nb init` step, mas's install and the language engines' steps run a real
/// command.
///
/// A language engine's Set Up installs its prerequisite through Homebrew, else MacPorts (`languageRoute`), exactly as
/// installing any other package would (`ActionPlanner`), then for Cargo installs Rust's stable toolchain as the user
/// (`RunStep.rustToolchain`). None of its steps has a `setupTarget`, so none goes to the helper's setup, and none
/// downloads or runs an installer script.
public enum EngineSetupPlanner {
    private static let reason = "BrewxPort needs an administrator password to set up this package manager."

    /// What the first-run card suggests: Homebrew on Apple silicon, MacPorts on Intel.
    public static func recommended(host: HostInfo) -> EngineID {
        host.appleSilicon ? .homebrew : .macports
    }

    /// What the app can set up here: the system package managers (Homebrew doesn't support Intel Macs), then the seven
    /// language engines, each through one of them (`languageRoute` says whether it can on this Mac).
    public static func offered(host: HostInfo) -> [EngineID] {
        let all: [EngineID] = [.homebrew, .macports, .nanobrew, .mas]
        return (host.appleSilicon ? all : all.filter { $0 != .homebrew }) + EngineID.allCases.filter(\.isLanguage)
    }

    /// The language engines MacPorts sets up when there's no Homebrew. Their tools still live in the home folder. Node
    /// (npm) and Ruby from MacPorts keep their global tools in root-owned /opt/local, and MacPorts builds Bun for hours.
    static let macPortsLanguages: Set<EngineID> = [.pipx, .uv, .cargo, .mint]

    /// The Homebrew formula a language engine's Set Up installs (`node` includes npm, `ruby` RubyGems). MacPorts' ports
    /// for pipx, uv, rustup and mint have the same names.
    static func formula(_ engine: EngineID) -> String? {
        switch engine {
        case .npm: "node"
        case .pipx: "pipx"
        case .uv: "uv"
        case .cargo: "rustup"
        case .bun: "bun"
        case .gem: "ruby"
        case .mint: "mint"
        case .homebrew, .macports, .nanobrew, .mas: nil
        }
    }

    /// How `engine`'s Set Up goes here: Homebrew when it's there and working, else MacPorts for the four it sets up.
    /// Nil for a system package manager.
    public static func languageRoute(_ engine: EngineID, statuses: [EngineID: EngineStatus]) -> LanguageSetupRoute? {
        guard let formula = formula(engine) else { return nil }
        if case .present(let brew, _)? = statuses[.homebrew] {
            // brew is `<prefix>/bin/brew` (`EngineLocator`).
            return .homebrew(formula: formula, prefix: brew.deletingLastPathComponent().deletingLastPathComponent().path)
        }
        guard macPortsLanguages.contains(engine) else { return .homebrewOnly }
        if case .present? = statuses[.macports] { return .macports(port: formula) }
        return .needsManager
    }

    /// R31: Cargo is there but not working, and its cargo has a `rustup` beside it: that's rustup's cargo proxy with no
    /// toolchain. The person's own rustup (`~/.cargo/bin`, CARGO_HOME's `bin`), or Homebrew's keg (as `ToolLocator`
    /// resolves it, through the Cellar) left so by a toolchain step that failed. Set Up then runs that rustup's
    /// `default stable` and nothing else: never a second rustup on top. Nil otherwise.
    public static func rustupWithoutToolchain(_ status: EngineStatus?, fileExists: (String) -> Bool) -> URL? {
        guard case .unusable(let cargo, _)? = status, cargo.lastPathComponent == "cargo" else { return nil }
        let rustup = cargo.deletingLastPathComponent().appendingPathComponent("rustup")
        return fileExists(rustup.path) ? rustup : nil
    }

    /// `loginEnvironment`: the login shell's allowlisted variables (`ResolvedPath.environment`), for Cargo's toolchain
    /// step (CARGO_HOME, RUSTUP_HOME); nothing else uses them. `fileExists` finds a rustup beside a Cargo that isn't
    /// working (`rustupWithoutToolchain`).
    public static func plan(_ engine: EngineID, statuses: [EngineID: EngineStatus], host: HostInfo,
                            cltPresent: Bool, engines: [any Engine],
                            loginEnvironment: [String: String] = [:],
                            fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
        -> ActionPlan {
        func present(_ id: EngineID) -> Bool {
            if case .present = statuses[id] { return true }
            return false
        }
        func result(_ steps: [RunStep] = [], problems: [String] = [], notes: [String] = []) -> ActionPlan {
            ActionPlan(steps: steps, problems: problems, notes: notes, reason: reason)
        }
        if present(engine) { return result(notes: ["\(engine.displayName) is already set up."]) }
        if engine == .cargo, let rustup = rustupWithoutToolchain(statuses[.cargo], fileExists: fileExists) {
            let spec = CargoEngine.toolchainSetup(from: .installed(rustup), captured: loginEnvironment)
            return result([RunStep.rustToolchain(spec, afterPackage: false)])
        }

        switch engine {
        case .homebrew:
            guard host.appleSilicon else {
                return result(problems: ["Homebrew doesn't support Intel Macs. MacPorts does the same job."])
            }
            return result([setupStep(.homebrew, engine: .homebrew, title: "Set up Homebrew",
                                     placeholder: "/opt/homebrew/bin/brew")])
        case .macports:
            var steps: [RunStep] = []
            if !cltPresent { steps.append(commandLineToolsStep()) }
            steps.append(setupStep(.macports, engine: .macports, title: "Set up MacPorts",
                                   placeholder: "/opt/local/bin/port", dependsOnPrevious: !cltPresent))
            return result(steps)
        case .nanobrew:
            let nb = EngineLocator.nanobrewPath
            let initStep = RunStep(
                engine: .nanobrew, operation: .install,
                spec: CommandSpec(executable: URL(fileURLWithPath: nb), arguments: ["init"], needsRoot: true),
                title: "Run nb init", dependsOnPrevious: true)
            return result([setupStep(.nanobrew, engine: .nanobrew, title: "Set up nanobrew", placeholder: nb),
                           initStep])
        case .mas:
            let source: (EngineID, PackageKind)
            if present(.homebrew) {
                source = (.homebrew, .formula)
            } else if present(.macports) {
                source = (.macports, .port)
            } else {
                return result(problems: ["Set up Homebrew or MacPorts first: mas installs through one of them."])
            }
            let package = Package(id: PackageRef(engine: source.0, kind: source.1, name: "mas"), displayName: "mas")
            return ActionPlanner.make([ActionRequest(operation: .install, package: package)],
                                      engines: engines, order: [.homebrew, .macports])
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint:
            return languagePlan(engine, statuses: statuses, host: host, engines: engines,
                                loginEnvironment: loginEnvironment)
        }
    }

    /// A language engine's Set Up: the prerequisite installed through Homebrew or MacPorts by the plan any install of
    /// it would get, then, for Cargo, Rust's stable toolchain as the user (only if the install worked). Whether the
    /// engine is already there isn't asked: the app also runs it to put Homebrew's Ruby or Node beside a read-only
    /// RubyGems or npm (R30).
    static func languagePlan(_ engine: EngineID, statuses: [EngineID: EngineStatus], host: HostInfo,
                                     engines: [any Engine], loginEnvironment: [String: String]) -> ActionPlan {
        let package: PackageRef
        let rustup: CargoEngine.RustupSource
        switch languageRoute(engine, statuses: statuses) {
        case .homebrew(let formula, let prefix)?:
            package = PackageRef(engine: .homebrew, kind: .formula, name: formula)
            rustup = .homebrew(prefix: prefix)
        case .macports(let port)?:
            package = PackageRef(engine: .macports, kind: .port, name: port)
            rustup = .macports
        case .homebrewOnly?:
            return ActionPlan(steps: [], problems: [SetupCopy.homebrewOnly(engine, appleSilicon: host.appleSilicon)],
                              notes: [], reason: reason)
        case .needsManager?, nil:
            return ActionPlan(steps: [],
                              problems: [SetupCopy.languageNeedsManager(engine, appleSilicon: host.appleSilicon)],
                              notes: [], reason: reason)
        }
        let install = ActionPlanner.make([ActionRequest(operation: .install,
                                                        package: Package(id: package, displayName: package.name))],
                                         engines: engines, order: [.homebrew, .macports])
        guard engine == .cargo, !install.steps.isEmpty else { return install }
        let toolchain = RunStep.rustToolchain(CargoEngine.toolchainSetup(from: rustup, captured: loginEnvironment))
        return ActionPlan(steps: install.steps + [toolchain], problems: install.problems, notes: install.notes,
                          reason: install.reason)
    }

    private static func commandLineToolsStep() -> RunStep {
        RunStep(engine: .macports, operation: .install, spec: placeholderSpec(CommandLineTools.marker),
                title: "Install Apple's Command Line Tools", setupTarget: .commandLineTools)
    }

    private static func setupStep(_ target: SetupTarget, engine: EngineID, title: String, placeholder: String,
                                  dependsOnPrevious: Bool = false) -> RunStep {
        RunStep(engine: engine, operation: .install, spec: placeholderSpec(placeholder), title: title,
                setupTarget: target, dependsOnPrevious: dependsOnPrevious)
    }

    private static func placeholderSpec(_ path: String) -> CommandSpec {
        CommandSpec(executable: URL(fileURLWithPath: path), arguments: [], needsRoot: true)
    }
}
