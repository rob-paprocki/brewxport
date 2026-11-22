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

    public init(engine: EngineID, kind: PackageKind = .formula, operation: PackageOperation,
                spec: CommandSpec, title: String, setupTarget: SetupTarget? = nil, dependsOnPrevious: Bool = false) {
        self.dependsOnPrevious = dependsOnPrevious
        self.engine = engine
        self.kind = kind
        self.operation = operation
        self.spec = spec
        self.title = title
        self.setupTarget = setupTarget
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
    /// `needsRoot`. A step with a `setupTarget` goes to the helper.
    public static func route(for step: RunStep) -> RunRoute {
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
