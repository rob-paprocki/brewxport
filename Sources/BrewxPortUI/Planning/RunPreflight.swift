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
            let kept = steps.filter { RunRouting.route(for: $0) == .user }
            let dropped = steps.filter { RunRouting.route(for: $0) != .user }.map(\.title)
            guard !dropped.isEmpty else { return (steps, []) }
            return (kept, ["Skipped \(dropped.joined(separator: "; ")): they need an administrator account, and "
                           + "this one isn't."])
        }
        guard helperState != .enabled else { return (steps, []) }
        let kept = steps.filter { RunRouting.route(for: $0) != .helper }
        let droppedSteps = steps.filter { RunRouting.route(for: $0) == .helper }
        guard !droppedSteps.isEmpty else { return (steps, []) }
        let dropped = droppedSteps.map(\.title)
        let why = helperUnavailableReason ?? HelperStateDisplay.text(for: helperState)
        return (kept, ["Skipped \(dropped.joined(separator: "; ")). \(helperWork(droppedSteps)) need BrewxPort's helper, "
                       + "and it isn't ready: \(why)"])
    }

    /// What the helper steps do, for the note: "MacPorts installs", "MacPorts updates" or "MacPorts removals" when
    /// they all do one thing, "MacPorts changes" for a mix.
    static func helperWork(_ steps: [RunStep]) -> String {
        let operations = Set(steps.map(\.operation))
        guard operations.count == 1, let operation = operations.first else { return "MacPorts changes" }
        switch operation {
        case .install: return "MacPorts installs"
        case .upgrade: return "MacPorts updates"
        case .remove: return "MacPorts removals"
        }
    }
}
