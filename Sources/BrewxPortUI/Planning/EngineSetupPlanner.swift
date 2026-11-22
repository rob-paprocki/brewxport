import Foundation
import BrewxPortCore
import BrewxPortRun

/// Turns "set up <engine>" into the steps of a run.
///
/// The setup steps (`setupTarget != nil`) go to the helper's `setUpEngine` request, which does the work as root. Their
/// `CommandSpec` is never executed: it is an inert placeholder (the engine's expected executable, no arguments, root).
/// Only the `nb init` step and mas's install run a real command.
public enum EngineSetupPlanner {
    private static let reason = "BrewxPort needs an administrator password to set up this package manager."

    /// What the first-run card suggests: Homebrew on Apple silicon, MacPorts on Intel.
    public static func recommended(host: HostInfo) -> EngineID {
        host.appleSilicon ? .homebrew : .macports
    }

    /// The package managers the app can set up here. Homebrew doesn't support Intel Macs.
    public static func offered(host: HostInfo) -> [EngineID] {
        let all: [EngineID] = [.homebrew, .macports, .nanobrew, .mas]
        return host.appleSilicon ? all : all.filter { $0 != .homebrew }
    }

    public static func plan(_ engine: EngineID, statuses: [EngineID: EngineStatus], host: HostInfo,
                            cltPresent: Bool, engines: [any Engine]) -> ActionPlan {
        func present(_ id: EngineID) -> Bool {
            if case .present = statuses[id] { return true }
            return false
        }
        func result(_ steps: [RunStep] = [], problems: [String] = [], notes: [String] = []) -> ActionPlan {
            ActionPlan(steps: steps, problems: problems, notes: notes, reason: reason)
        }
        if present(engine) { return result(notes: ["\(engine.displayName) is already set up."]) }

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
            let nb = "/opt/nanobrew/prefix/bin/nb"
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
        }
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
