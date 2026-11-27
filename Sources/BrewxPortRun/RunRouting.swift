import Foundation
import BrewxPortCore

/// One command in a run, as an engine's `command(for:…)` built it.
public struct RunStep: Sendable, Equatable {
    public let engine: EngineID
    /// What the step acts on. Only Homebrew uses it, to tell casks (which may call sudo) from formulae.
    public let kind: PackageKind
    /// What the step does. The run log words the step by it.
    public let operation: PackageOperation
    public let spec: CommandSpec
    /// What the UI shows for the step.
    public let title: String
    /// Set on a "set up this engine" step. It runs through the helper's `setUpEngine`, never through `spec`.
    public let setupTarget: SetupTarget?
    /// True when the step only makes sense if the step before it worked (`nb init` after setting up nanobrew). The
    /// preflight drops it with the step before it, and a run skips it when that step failed or didn't run.
    public let dependsOnPrevious: Bool
    /// True when the step runs only if every earlier step started and finished with exit code 0 (a removal in a
    /// move). A skipped step counts as not succeeded. The preflight drops it whenever it drops any earlier step.
    public let requiresAllEarlier: Bool
    /// Narrows `requiresAllEarlier` to the earlier steps with the same group: the step runs only if every earlier step
    /// in its group started and finished with 0, and steps in other groups (or in none) don't count. An uninstall puts
    /// each package manager's removals in a group of their own, so one manager's failure stops only its own later
    /// removals. nil keeps the whole-run meaning. Without `requiresAllEarlier` it gates nothing, but a failed or
    /// skipped step still counts against its group.
    public let gateGroup: String?
    /// Set on a check step: it launches nothing (`spec` is never run) and asks the run's verifier whether these
    /// packages are installed. It finishes with 0 when none is missing, 1 otherwise. It always runs as the user.
    public let verifyInstalled: [PackageRef]?
    /// True when the step runs only if an earlier check step ran and every earlier check step finished with 0 (a
    /// move's marks: they only make sense once the target has the packages). Unlike `requiresAllEarlier`, a failed
    /// install or removal doesn't stop it, and no other step waits on it.
    public let requiresPassedCheck: Bool
    /// Added to the runner's base environment when the step runs as the user (`.user` or `.userWithAskpass`). Never
    /// passed to a step that runs through sudo or the helper. A move or an uninstall sets `HOMEBREW_NO_AUTOREMOVE` on
    /// its Homebrew removals here.
    public let userEnvironment: [String: String]
    /// The packages the step acts on, as the person asked for them (`ActionPlanner` sets it), so a run's result can be
    /// read per package. Empty for a step that isn't about named packages (a catalogue refresh, a setup).
    public let refs: [PackageRef]

    public init(engine: EngineID, kind: PackageKind = .formula, operation: PackageOperation,
                spec: CommandSpec, title: String, setupTarget: SetupTarget? = nil, dependsOnPrevious: Bool = false,
                requiresAllEarlier: Bool = false, verifyInstalled: [PackageRef]? = nil,
                requiresPassedCheck: Bool = false, userEnvironment: [String: String] = [:], gateGroup: String? = nil,
                refs: [PackageRef] = []) {
        self.refs = refs
        self.dependsOnPrevious = dependsOnPrevious
        self.requiresAllEarlier = requiresAllEarlier
        self.gateGroup = gateGroup
        self.verifyInstalled = verifyInstalled
        self.requiresPassedCheck = requiresPassedCheck
        self.userEnvironment = userEnvironment
        self.engine = engine
        self.kind = kind
        self.operation = operation
        self.spec = spec
        self.title = title
        self.setupTarget = setupTarget
    }
}

extension RunStep {
    /// This step with `extra` added to `userEnvironment` (its own values win): a Homebrew update that mustn't
    /// autoremove a runtime language tools use (R29, `HOMEBREW_NO_AUTOREMOVE`).
    public func addingUserEnvironment(_ extra: [String: String]) -> RunStep {
        RunStep(engine: engine, kind: kind, operation: operation, spec: spec, title: title, setupTarget: setupTarget,
                dependsOnPrevious: dependsOnPrevious, requiresAllEarlier: requiresAllEarlier,
                verifyInstalled: verifyInstalled, requiresPassedCheck: requiresPassedCheck,
                userEnvironment: userEnvironment.merging(extra) { own, _ in own }, gateGroup: gateGroup, refs: refs)
    }

    /// A check step on `engine`: launches nothing and asks the run's verifier whether `refs` are installed. Its spec is
    /// `/usr/bin/false`, so an executor that launched it instead of asking the verifier would still fail closed.
    public static func check(_ refs: [PackageRef], on engine: EngineID, title: String) -> RunStep {
        RunStep(engine: engine, kind: .formula, operation: .install,
                spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], needsRoot: false),
                title: title, verifyInstalled: refs)
    }

    /// The gate group of a MacPorts update run: its catalogue refresh, and the upgrades that wait for it.
    public static let macPortsCatalogueRefreshGroup = "macports-selfupdate"

    /// MacPorts' catalogue refresh (`port -N selfupdate`, from `CatalogRefreshing.selfupdateCommand()`): the first
    /// MacPorts step of every MacPorts update run, and all of a "Refresh MacPorts…" run. The upgrades after it carry
    /// `requiresAllEarlier` in its group, so a failed refresh skips them and nothing else.
    public static func macPortsCatalogueRefresh(_ spec: CommandSpec) -> RunStep {
        RunStep(engine: .macports, kind: .port, operation: .upgrade, spec: spec,
                title: "MacPorts: refresh the port catalogue", gateGroup: macPortsCatalogueRefreshGroup)
    }

    /// Cargo's Set Up (Plan 9 Task 11): Rust's stable toolchain, with `spec` from `CargoEngine.toolchainSetup`. A Cargo
    /// step with no `setupTarget`, so it runs as the user (`.user`) through RunSession, which scrubs its output like
    /// any language tool's; never through the helper. After rustup's package (`afterPackage`) it runs only if that
    /// worked; with a rustup that was already there it's the whole run.
    public static func rustToolchain(_ spec: CommandSpec, afterPackage: Bool = true) -> RunStep {
        RunStep(engine: .cargo, kind: .tool, operation: .install, spec: spec, title: "Install Rust's stable toolchain",
                dependsOnPrevious: afterPackage)
    }

    /// True for the step `macPortsCatalogueRefresh` makes: in its group, and waiting on nothing itself.
    var isMacPortsCatalogueRefresh: Bool {
        gateGroup == Self.macPortsCatalogueRefreshGroup && !requiresAllEarlier
    }
}

/// How a step gets the privileges it needs.
public enum RunRoute: Equatable, Sendable {
    /// As the user, with the runner's base environment.
    case user
    /// As the user, with the askpass variables added, so a `sudo` the command runs itself (a cask's pkg
    /// installer) can get the password. Homebrew casks.
    case userWithAskpass
    /// `/usr/bin/sudo -A <command>` with the askpass variables. mas commands that need root.
    case sudoAskpass
    /// Through the BrewxPortHelper daemon. MacPorts commands that need root.
    case helper
    /// Through the helper's `setUpEngine`, as root. A "set up this engine" step.
    case helperSetup
}

public enum RunRouting {
    /// brew never runs as root, whatever the spec says: a cask goes through askpass, anything else runs
    /// as the user. nb runs as root only for `nb init`, the one step that sets `needsRoot`. MacPorts and mas follow
    /// `needsRoot`. Language engines (npm, pipx, uv, Cargo, Bun, RubyGems, Mint) always run as the user, whatever the
    /// spec says. A step with a `setupTarget` goes to the helper. A check step (`verifyInstalled`) launches nothing,
    /// so it runs as the user whatever else it says.
    public static func route(for step: RunStep) -> RunRoute {
        if step.verifyInstalled != nil { return .user }
        if step.setupTarget != nil { return .helperSetup }
        return switch step.engine {
        case .macports: step.spec.needsRoot ? .helper : .user
        case .mas: step.spec.needsRoot ? .sudoAskpass : .user
        case .homebrew: step.kind == .cask ? .userWithAskpass : .user
        case .nanobrew:
            step.spec.needsRoot && step.spec.arguments == ["init"]
                && step.spec.executable.path == EngineLocator.nanobrewPath ? .sudoAskpass : .user
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: .user
        }
    }
}
