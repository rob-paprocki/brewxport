import Foundation
import BrewxPortCore
import BrewxPortRun

/// The steps that can actually run, decided just before a run starts.
public enum RunPreflight {
    /// A standard account (`isAdministrator == false`) keeps only the steps that run as the user: `RunSession`
    /// refuses a whole run that has any root route, so filtering here is what lets the user's own steps run.
    /// Otherwise, while the helper isn't `.enabled`, the steps for the helper are left out. A nil
    /// `isAdministrator` keeps everything, and `RunSession` decides. Each note names the steps it left out.
    ///
    /// `helperUnavailableReason` replaces the helper-state text in the note (Task 6 passes `services.setupProblem`
    /// when there's no helper outside demo mode).
    public static func filter(_ steps: [RunStep], helperState: HelperState?, isAdministrator: Bool?,
                              helperUnavailableReason: String? = nil) -> (steps: [RunStep], notes: [String]) {
        if isAdministrator == false {
            let (kept, droppedSteps) = split(steps, dropping: { RunRouting.route(for: $0) != .user })
            let dropped = droppedSteps.map(\.title)
            guard !dropped.isEmpty else { return (steps, []) }
            return (kept, ["Skipped \(dropped.joined(separator: "; ")): they need an administrator account, and "
                           + "this one isn't."])
        }
        guard helperState != .enabled else { return (steps, []) }
        let (kept, droppedSteps) = split(steps, dropping: usesHelper)
        guard !droppedSteps.isEmpty else { return (steps, []) }
        let dropped = droppedSteps.map(\.title)
        let why = helperUnavailableReason ?? HelperStateDisplay.text(for: helperState)
        return (kept, ["Skipped \(dropped.joined(separator: "; ")). \(helperWork(droppedSteps)) need BrewxPort's helper, "
                       + "and it isn't ready: \(why)"])
    }

    /// Splits `steps` into kept and dropped, in order. A step is dropped when `drop` says so, when it
    /// `dependsOnPrevious` and the step before it (in the original order) was dropped, or when it
    /// `requiresAllEarlier` and any earlier step was dropped, or when it `requiresPassedCheck` and an earlier check
    /// step was dropped.
    static func split(_ steps: [RunStep], dropping drop: (RunStep) -> Bool) -> (kept: [RunStep], dropped: [RunStep]) {
        var kept: [RunStep] = [], dropped: [RunStep] = []
        var previousDropped = false
        for step in steps {
            previousDropped = drop(step) || (step.dependsOnPrevious && previousDropped)
                || (step.requiresAllEarlier && !dropped.isEmpty)
                || (step.requiresPassedCheck && dropped.contains { $0.verifyInstalled != nil })
            if previousDropped { dropped.append(step) } else { kept.append(step) }
        }
        return (kept, dropped)
    }

    /// True for the MacPorts steps and the setup steps, which both go through the helper.
    public static func usesHelper(_ step: RunStep) -> Bool {
        let route = RunRouting.route(for: step)
        return route == .helper || route == .helperSetup
    }

    /// What the helper steps do, for the note: "MacPorts installs", "MacPorts updates" or "MacPorts removals" when
    /// they all do one thing, "MacPorts changes" for a mix, "Engine setup steps" when all are setup.
    static func helperWork(_ steps: [RunStep]) -> String {
        if steps.allSatisfy({ $0.setupTarget != nil || $0.dependsOnPrevious }) { return "Engine setup steps" }
        if steps.contains(where: { $0.setupTarget != nil }) { return "MacPorts changes and engine setup steps" }
        let operations = Set(steps.map(\.operation))
        guard operations.count == 1, let operation = operations.first else { return "MacPorts changes" }
        switch operation {
        case .install: return "MacPorts installs"
        case .upgrade: return "MacPorts updates"
        case .remove: return "MacPorts removals"
        case .markRequested, .markDependency: return "MacPorts changes"
        }
    }
}
