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
    /// Set on a check step: it launches nothing (`spec` is never run) and asks the run's verifier whether these
    /// packages are installed. It finishes with 0 when none is missing, 1 otherwise. It always runs as the user.
    public let verifyInstalled: [PackageRef]?
    /// True when the step runs only if an earlier check step ran and every earlier check step finished with 0 (a
    /// move's marks: they only make sense once the target has the packages). Unlike `requiresAllEarlier`, a failed
    /// install or removal doesn't stop it, and no other step waits on it.
    public let requiresPassedCheck: Bool
    /// Added to the runner's base environment when the step runs as the user (`.user` or `.userWithAskpass`). Never
    /// passed to a step that runs through sudo or the helper. A move sets `HOMEBREW_NO_AUTOREMOVE` on its Homebrew
    /// removals here.
    public let userEnvironment: [String: String]

    public init(engine: EngineID, kind: PackageKind = .formula, operation: PackageOperation,
                spec: CommandSpec, title: String, setupTarget: SetupTarget? = nil, dependsOnPrevious: Bool = false,
                requiresAllEarlier: Bool = false, verifyInstalled: [PackageRef]? = nil,
                requiresPassedCheck: Bool = false, userEnvironment: [String: String] = [:]) {
        self.dependsOnPrevious = dependsOnPrevious
        self.requiresAllEarlier = requiresAllEarlier
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
    /// A check step on `engine`: launches nothing and asks the run's verifier whether `refs` are installed. Its spec is
    /// `/usr/bin/false`, so an executor that launched it instead of asking the verifier would still fail closed.
    public static func check(_ refs: [PackageRef], on engine: EngineID, title: String) -> RunStep {
        RunStep(engine: engine, kind: .formula, operation: .install,
                spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], needsRoot: false),
                title: title, verifyInstalled: refs)
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
    /// `needsRoot`. A step with a `setupTarget` goes to the helper. A check step (`verifyInstalled`) launches nothing,
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
                && step.spec.executable.path == "/opt/nanobrew/prefix/bin/nb" ? .sudoAskpass : .user
        }
    }
}
