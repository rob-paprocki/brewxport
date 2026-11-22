import Foundation
import BrewxPortCore
import BrewxPortRun

/// Why a move couldn't be turned into steps.
public enum MoveRunError: Error, Equatable, Sendable {
    /// The plan has nothing in `moving` (the picked package can't move), so there is nothing to run.
    case nothingToMove
    /// The source or target package manager isn't available.
    case engineMissing(EngineID)
}

/// A move's steps, and what the run's summary needs to say what happened (`MoveRunSummary`).
public struct MoveRun: Sendable, Equatable {
    public let actions: ActionPlan
    /// The check step's title.
    public let checkTitle: String
    /// Each removal step's title → the name of the package it removes.
    public let removalNames: [String: String]
}

/// Turns a confirmed `MovePlan` into run steps: install on the target, check the target has everything, remove from
/// the source, then mark on the target.
///
/// Installs batch per kind, like `ActionPlanner`; the check step covers every package in `plan.moving`. Each removal
/// is a step of its own with `requiresAllEarlier`, so one failure stops exactly the removals after it and a failed
/// install or check stops them all. Removal order: the dependents in the move set, each after everything in the set
/// that depends on it; then the picked package (unless `keepPicked`); then the leftovers (when `removeLeftovers`),
/// dependents first among themselves. Homebrew removals run with `HOMEBREW_NO_AUTOREMOVE=1`, so `brew uninstall`
/// removes only the package the step names, never other unused dependencies the preview didn't list.
///
/// Marks come last and run only when the check passed (`requiresPassedCheck`). They never gate anything, so a failed
/// mark never undoes a move. Only Homebrew and MacPorts can mark, so a nanobrew target gets none. A package that was
/// already on the target is never marked as a dependency: the person may have asked for it there.
///
/// An empty `plan.moving`, or one without the picked package, throws `MoveRunError.nothingToMove` (a check over no
/// packages would pass vacuously). An engine that can't build a command throws its own `EngineError`.
public enum MoveRunBuilder {
    /// What every Homebrew removal in a move adds to the environment: no autoremove of unrelated unused dependencies.
    static let homebrewRemovalEnvironment = ["HOMEBREW_NO_AUTOREMOVE": "1"]

    /// `dependents` and `dependencies` are the source's lower-cased maps (the same ones `MoveFacts` holds). Both are
    /// merged into one "who uses X" relation, because `dependents` alone has no edges between leftovers. They only order the removals.
    public static func steps(for plan: MovePlan, engines: [any Engine],
                             dependents: [String: Set<String>],
                             dependencies: [String: Set<String>]) throws -> ActionPlan {
        try run(for: plan, engines: engines, dependents: dependents, dependencies: dependencies).actions
    }

    /// `steps(for:…)` with the titles the run's summary needs.
    public static func run(for plan: MovePlan, engines: [any Engine],
                           dependents: [String: Set<String>],
                           dependencies: [String: Set<String>]) throws -> MoveRun {
        var users = dependents
        for (user, needs) in dependencies { for name in needs { users[name, default: []].insert(user) } }
        guard let picked = plan.moving.first(where: { $0.old.id == plan.picked.id }) else {
            throw MoveRunError.nothingToMove
        }
        guard let source = engines.first(where: { $0.id == plan.picked.id.engine }) else {
            throw MoveRunError.engineMissing(plan.picked.id.engine)
        }
        guard let target = engines.first(where: { $0.id == plan.target }) else {
            throw MoveRunError.engineMissing(plan.target)
        }
        var steps: [RunStep] = []

        // Installs: what isn't on the target yet, one step per kind.
        let needed = plan.moving.filter(\.needsInstall)
        for kind in kinds(of: needed) {
            let items = needed.filter { $0.new.id.kind == kind }
            steps.append(try step(target, .install, items.map(\.new)))
        }

        // The check covers every package that moves, those already on the target too.
        let checkTitle = "Check \(target.id.displayName): \(plan.moving.map(\.new.displayName).joined(separator: ", "))"
        steps.append(.check(plan.moving.map(\.new.id), on: plan.target, title: checkTitle))

        // Removals.
        let others = plan.moving.filter { $0.old.id != picked.old.id }.map(\.old)
        var removals = dependentsFirst(others, dependents: users)
        if !plan.keepPicked { removals.append(picked.old) }
        if plan.removeLeftovers { removals += dependentsFirst(plan.leftovers, dependents: users) }
        let environment = source.id == .homebrew ? homebrewRemovalEnvironment : [:]
        var removalNames: [String: String] = [:]
        for package in removals {
            let removal = try step(source, .remove, [package], requiresAllEarlier: true, userEnvironment: environment)
            removalNames[removal.title] = package.displayName
            steps.append(removal)
        }

        // Marks, only where the target can, and only once the check passed. Something already on the target keeps
        // its own flag unless the move makes it asked-for.
        if target.id == .homebrew || target.id == .macports {
            for (operation, wanted) in [(PackageOperation.markRequested, true), (.markDependency, false)] {
                let marked = plan.moving.filter { $0.wasRequested == wanted && (wanted || $0.needsInstall) }
                for kind in kinds(of: marked) {
                    let items = marked.filter { $0.new.id.kind == kind }
                    steps.append(try step(target, operation, items.map(\.new), requiresPassedCheck: true))
                }
            }
        }

        let actions = ActionPlan(steps: steps, problems: [], notes: [],
                                 reason: "BrewxPort needs an administrator password to move these packages.")
        return MoveRun(actions: actions, checkTitle: checkTitle, removalNames: removalNames)
    }

    private static func step(_ engine: any Engine, _ operation: PackageOperation, _ packages: [Package],
                             requiresAllEarlier: Bool = false, requiresPassedCheck: Bool = false,
                             userEnvironment: [String: String] = [:]) throws -> RunStep {
        let kind = packages[0].id.kind
        let title = ActionPlanner.title(engine.id, kind: kind, names: packages.map(\.displayName))
        let spec = try engine.command(for: operation, packages.map(\.id), options: InstallOptions())
        return RunStep(engine: engine.id, kind: kind, operation: operation, spec: spec, title: title,
                       requiresAllEarlier: requiresAllEarlier, requiresPassedCheck: requiresPassedCheck,
                       userEnvironment: userEnvironment)
    }

    /// The distinct kinds, in first-seen order.
    private static func kinds(of items: [MoveItem]) -> [PackageKind] {
        var seen: [PackageKind] = []
        for item in items where !seen.contains(item.new.id.kind) { seen.append(item.new.id.kind) }
        return seen
    }

    /// `packages` ordered so each comes after every package in the list that depends on it (directly or further
    /// down). Ties go by name; a dependency cycle (which shouldn't exist) is appended by name. Packages are kept apart
    /// by name and kind, so a formula and a cask of the same name are both removed; the "who uses X" relation is by
    /// name only, so both get the same users.
    static func dependentsFirst(_ packages: [Package], dependents: [String: Set<String>]) -> [Package] {
        struct Key: Hashable, Comparable {
            let name: String
            let kind: String
            static func < (a: Key, b: Key) -> Bool { (a.name, a.kind) < (b.name, b.kind) }
        }
        var byKey: [Key: Package] = [:]
        for package in packages {
            byKey[Key(name: package.id.name.lowercased(), kind: package.id.kind.rawValue)] = package
        }
        // Transitive dependents of each name, restricted to the set.
        func users(of key: Key) -> Set<Key> {
            var seen: Set<String> = []
            var queue = [key.name]
            while let next = queue.popLast() {
                for user in dependents[next] ?? [] where !seen.contains(user) {
                    seen.insert(user)
                    queue.append(user)
                }
            }
            return Set(byKey.keys.filter { seen.contains($0.name) && $0.name != key.name })
        }
        var waiting = byKey.keys.reduce(into: [Key: Set<Key>]()) { $0[$1] = users(of: $1) }
        var ordered: [Package] = []
        while !waiting.isEmpty {
            let ready = waiting.filter { $0.value.isEmpty }.keys.sorted()
            let batch = ready.isEmpty ? waiting.keys.sorted() : ready
            for key in batch {
                waiting[key] = nil
                if let package = byKey[key] { ordered.append(package) }
            }
            for key in waiting.keys { waiting[key]?.subtract(batch) }
        }
        return ordered
    }
}
