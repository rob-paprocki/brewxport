import Foundation
import BrewxPortCore
import BrewxPortRun

/// An uninstall's steps, and what the run's summary needs to say what stayed (`UninstallRunSummary`).
public struct UninstallRun: Sendable, Equatable {
    public struct Removal: Sendable, Equatable {
        public let engine: EngineID
        public let name: String
    }

    public let actions: ActionPlan
    /// Each removal step's title → the package it removes.
    public let removals: [String: Removal]
}

/// Turns a confirmed `UninstallPlan` into run steps.
///
/// Per package manager, in the plan's section order: the picks, each after every pick that depends on it; then, when
/// the section's box is ticked, the leftovers, dependents first among themselves; last, the picks the package manager
/// will refuse (`refused`), so their refusal doesn't stop the others. Blocked picks never get a step. One
/// package per step, each `requiresAllEarlier` within its manager's `gateGroup` (the engine's raw value), so a
/// failure stops that manager's later removals and no other manager's. Homebrew steps run with
/// `HOMEBREW_NO_AUTOREMOVE=1`, so `brew uninstall` removes only the package it names.
///
/// Commands are the engines' own plain removals, with no force or ignore-dependencies flags: Homebrew and MacPorts
/// refuse a pick something else still needs. A manager that isn't available, or a step whose command can't be built,
/// is reported in `problems`; that manager's removals after it are left out, as the gate would stop them anyway.
public enum UninstallRunBuilder {
    static let reason = "BrewxPort needs an administrator password to uninstall these packages."

    /// `facts` are the successful facts per manager; they only order the removals (dependents and dependencies merged
    /// into one "who uses X" relation, as Move to does). A manager without facts goes in name order.
    public static func steps(for plan: UninstallPlan, engines: [any Engine],
                             facts: [EngineID: DependencyFacts]) -> ActionPlan {
        run(for: plan, engines: engines, facts: facts).actions
    }

    /// `steps(for:…)` with the step titles the run's summary needs.
    public static func run(for plan: UninstallPlan, engines: [any Engine],
                           facts: [EngineID: DependencyFacts]) -> UninstallRun {
        var steps: [RunStep] = []
        var problems: [String] = []
        var removals: [String: UninstallRun.Removal] = [:]
        for section in plan.sections {
            var users = facts[section.engine]?.dependents ?? [:]
            for (user, needs) in facts[section.engine]?.dependencies ?? [:] {
                for name in needs { users[name, default: []].insert(user) }
            }
            let refused = Set(section.refused.map(\.id))
            var packages = MoveRunBuilder.dependentsFirst(section.picks.filter { !refused.contains($0.id) },
                                                          dependents: users)
            if section.removeLeftovers {
                packages += MoveRunBuilder.dependentsFirst(section.leftovers, dependents: users)
            }
            packages += MoveRunBuilder.dependentsFirst(section.picks.filter { refused.contains($0.id) },
                                                       dependents: users)
            guard !packages.isEmpty else { continue }
            guard let engine = engines.first(where: { $0.id == section.engine }) else {
                let names = MoveRunSummary.list(packages.map(\.displayName))
                problems.append("\(section.engine.displayName) isn't available, so \(names) "
                                + (packages.count == 1 ? "wasn't" : "weren't") + " removed.")
                continue
            }
            let environment = engine.id == .homebrew ? MoveRunBuilder.homebrewRemovalEnvironment : [:]
            for package in packages {
                let kind = package.id.kind
                let title = ActionPlanner.title(engine.id, kind: kind, names: [package.displayName])
                do {
                    let spec = try engine.command(for: .remove, [package.id], options: InstallOptions())
                    steps.append(RunStep(engine: engine.id, kind: kind, operation: .remove, spec: spec, title: title,
                                         requiresAllEarlier: true, userEnvironment: environment,
                                         gateGroup: engine.id.rawValue, refs: [package.id]))
                    removals[title] = UninstallRun.Removal(engine: engine.id, name: package.displayName)
                } catch {
                    let message = (error as? EngineError).map(EngineErrorText.line) ?? "\(error)"
                    problems.append("BrewxPort couldn't remove \(package.displayName) from "
                                    + "\(engine.id.displayName): \(message)")
                    break
                }
            }
        }
        return UninstallRun(actions: ActionPlan(steps: steps, problems: problems, notes: [], reason: reason),
                            removals: removals)
    }
}

/// The line a finished uninstall adds to the run log for each package manager whose removals didn't all work, saying
/// what's still installed and why. Nil when every removal worked or when nothing ran (the log already says why).
public enum UninstallRunSummary {
    /// `rows` are the run's step rows after it ended.
    public static func note(for run: UninstallRun, rows: [RunStepRow]) -> String? {
        guard rows.contains(where: { $0.state != .skipped && $0.state != .waiting }) else { return nil }
        let removalRows = rows.filter { $0.operation == .remove && run.removals[$0.title] != nil }
        var lines: [String] = []
        for engine in EngineID.allCases {
            let mine = removalRows.filter { run.removals[$0.title]?.engine == engine }
            let kept = mine.filter { $0.state != .succeeded }.compactMap { run.removals[$0.title]?.name }
            guard !kept.isEmpty else { continue }
            let list = MoveRunSummary.list(kept)
            let verb = kept.count == 1 ? "is" : "are"
            if let failed = mine.first(where: { if case .failed = $0.state { true } else { false } }),
               let name = run.removals[failed.title]?.name {
                lines.append("Removing \(name) from \(engine.displayName) failed, so \(list) \(verb) still installed.")
            } else {
                lines.append("\(list) \(verb) still installed from \(engine.displayName) because the uninstall was "
                             + "cancelled.")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}
