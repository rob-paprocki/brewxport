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

    public init(engine: EngineID, kind: PackageKind = .formula, operation: PackageOperation,
                spec: CommandSpec, title: String) {
        self.engine = engine
        self.kind = kind
        self.operation = operation
        self.spec = spec
        self.title = title
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
}

public enum RunRouting {
    /// brew and nb never run as root, whatever the spec says: a cask goes through askpass, anything else runs
    /// as the user. MacPorts and mas follow `needsRoot`.
    public static func route(for step: RunStep) -> RunRoute {
        switch step.engine {
        case .macports: step.spec.needsRoot ? .helper : .user
        case .mas: step.spec.needsRoot ? .sudoAskpass : .user
        case .homebrew: step.kind == .cask ? .userWithAskpass : .user
        case .nanobrew: .user
        }
    }
}
