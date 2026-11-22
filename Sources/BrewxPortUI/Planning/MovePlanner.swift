import Foundation
import BrewxPortCore

/// What looking a package up on the target package manager found.
public enum TargetLookup: Sendable, Equatable {
    /// Available on the target; the payload is the target's package.
    case found(Package)
    /// Already installed on the target: nothing to install, the old copy is still removed.
    case alreadyInstalled(Package)
    case notFound
    /// The lookup itself failed; the payload is what to show.
    case failed(String)
}

/// Everything `MovePlanner` needs, gathered by the caller. Every map is keyed by lower-cased name, and every name in a
/// value is lower-cased too. `dependents` and `dependencies` describe the source package manager only.
public struct MoveFacts: Sendable {
    public var picked: Package
    public var target: EngineID
    /// Name → the installed packages that depend on it directly.
    public var dependents: [String: Set<String>]
    /// Name → the installed packages it depends on directly.
    public var dependencies: [String: Set<String>]
    /// The packages the person asked for on the source. nil when the source can't say (nanobrew): no leftovers then.
    public var requested: Set<String>?
    public var sourceInstalled: [String: Package]
    /// The target lookup for the picked package and each of its dependents. A missing entry counts as `.notFound`.
    public var onTarget: [String: TargetLookup]
    /// The person's login-shell PATH.
    public var pathEntries: [String]
    /// The target's `bin` directory.
    public var targetBin: String

    public init(picked: Package, target: EngineID, dependents: [String: Set<String>],
                dependencies: [String: Set<String>], requested: Set<String>?, sourceInstalled: [String: Package],
                onTarget: [String: TargetLookup], pathEntries: [String], targetBin: String) {
        self.picked = picked
        self.target = target
        self.dependents = dependents
        self.dependencies = dependencies
        self.requested = requested
        self.sourceInstalled = sourceInstalled
        self.onTarget = onTarget
        self.pathEntries = pathEntries
        self.targetBin = targetBin
    }
}

/// One package that moves: `old` is removed from the source, `new` is installed on the target unless it's there.
public struct MoveItem: Sendable, Equatable {
    public let old: Package
    public let new: Package
    public let needsInstall: Bool
    /// Whether the person asked for it on the source (true when the source can't say).
    public let wasRequested: Bool

    public init(old: Package, new: Package, needsInstall: Bool, wasRequested: Bool) {
        self.old = old
        self.new = new
        self.needsInstall = needsInstall
        self.wasRequested = wasRequested
    }
}

/// A package in the move set that stays on the source, and why: the target doesn't have it ("not on nanobrew", or
/// the lookup's error), or a package that can't move needs it ("needed by <name>").
public struct CantMove: Sendable, Equatable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// The worked-out move, for the preview and the run.
public struct MovePlan: Sendable, Equatable {
    public let picked: Package
    public let target: EngineID
    /// The picked package first (when it can move), then its dependents in breadth-first order, sorted by name within
    /// each level.
    public let moving: [MoveItem]
    public let cantMove: [CantMove]
    /// True when anything in the set can't move: the picked package's old copy stays for it.
    public let keepPicked: Bool
    /// Source packages that only the removed ones needed and the person never asked for, sorted by name.
    public let leftovers: [Package]
    public var removeLeftovers: Bool
    public let pathWarning: String?
    /// The bin directory the PATH warning is about, for "Add to PATH"; nil without a warning.
    public let pathBin: String?

    public init(picked: Package, target: EngineID, moving: [MoveItem], cantMove: [CantMove], keepPicked: Bool,
                leftovers: [Package], removeLeftovers: Bool, pathWarning: String?, pathBin: String? = nil) {
        self.picked = picked
        self.target = target
        self.moving = moving
        self.cantMove = cantMove
        self.keepPicked = keepPicked
        self.leftovers = leftovers
        self.removeLeftovers = removeLeftovers
        self.pathWarning = pathWarning
        self.pathBin = pathWarning == nil ? nil : pathBin
    }
}

/// Works out a move from one package manager to another. Pure: the caller gathers `MoveFacts`.
///
/// The move set is the picked package plus everything on the source that depends on it, directly or further down.
/// Each needs the target's lookup to be `.found` or `.alreadyInstalled`; the rest go in `cantMove`. A package that
/// can't move stays where it is, and so does every package between it and the picked one (it still needs them), and
/// the picked package's old copy is kept. Only dependents that no unmovable package needs move. If the picked package
/// itself can't move, nothing moves.
public enum MovePlanner {
    /// Whether `package` can be offered a move at all: core formulae and ports, from a package manager that can list
    /// dependents. Never casks, apps, taps, mas, or Homebrew formulae from a third-party tap.
    public static func isMovable(_ package: Package, engineHasDependents: Bool) -> Bool {
        guard engineHasDependents, package.id.engine != .mas else { return false }
        guard package.id.kind == .formula || package.id.kind == .port else { return false }
        if package.id.engine == .homebrew && package.fullName != nil { return false }
        return true
    }

    public static func plan(_ facts: MoveFacts) -> MovePlan {
        let pickedKey = facts.picked.id.name.lowercased()
        let moveSet = discoverMoveSet(from: pickedKey, dependents: facts.dependents)
        let members = Set(moveSet)

        // Each member has its source package and its target package, or a reason it can't move.
        var sourcePackages: [String: Package] = [pickedKey: facts.picked]
        var targetPackages: [String: (package: Package, needsInstall: Bool)] = [:]
        var unmovableReasons: [String: String] = [:]
        for name in moveSet {
            if name != pickedKey {
                // Without its source package it can't be removed, so it has to stay (and so does what it needs).
                guard let old = facts.sourceInstalled[name] else {
                    unmovableReasons[name] = "not listed on \(facts.picked.id.engine.displayName)"
                    continue
                }
                sourcePackages[name] = old
            }
            switch facts.onTarget[name] ?? .notFound {
            case .found(let package): targetPackages[name] = (package, true)
            case .alreadyInstalled(let package): targetPackages[name] = (package, false)
            case .notFound: unmovableReasons[name] = "not on \(facts.target.displayName)"
            case .failed(let message): unmovableReasons[name] = message
            }
        }

        // The picked package can't move: nothing moves and nothing is removed.
        if let reason = unmovableReasons[pickedKey] {
            return MovePlan(picked: facts.picked, target: facts.target, moving: [],
                            cantMove: [CantMove(name: pickedKey, reason: reason)], keepPicked: true, leftovers: [],
                            removeLeftovers: true, pathWarning: pathWarning(facts),
                            pathBin: facts.targetBin)
        }

        // A member stays when an unmovable member depends on it, directly or further down, and names the nearest one
        // (breadth-first over its dependents in the move set, names sorted within each level).
        func nearestUnmovable(above start: String) -> String? {
            var seen: Set<String> = [start]
            var level = [start]
            while !level.isEmpty {
                var next: Set<String> = []
                for name in level {
                    for dependent in facts.dependents[name] ?? []
                    where members.contains(dependent) && !seen.contains(dependent) {
                        next.insert(dependent)
                    }
                }
                let sorted = next.sorted()
                if let hit = sorted.first(where: { unmovableReasons[$0] != nil }) { return hit }
                seen.formUnion(sorted)
                level = sorted
            }
            return nil
        }

        // Unmovable packages, and the ones kept for them, in move-set order. The picked package isn't listed: it
        // still moves, only its old copy is kept.
        var cantMove: [CantMove] = []
        var staying: Set<String> = []
        for name in moveSet {
            if let reason = unmovableReasons[name] {
                cantMove.append(CantMove(name: name, reason: reason))
                staying.insert(name)
            } else if name != pickedKey, !unmovableReasons.isEmpty, let holder = nearestUnmovable(above: name) {
                cantMove.append(CantMove(name: name, reason: "needed by \(holder)"))
                staying.insert(name)
            }
        }
        let keepPicked = !unmovableReasons.isEmpty

        var moving: [MoveItem] = []
        // Every member not in `cantMove` has both packages; the picked one moves even when its old copy stays.
        for name in moveSet where name == pickedKey || !staying.contains(name) {
            guard let old = sourcePackages[name], let target = targetPackages[name] else { continue }
            moving.append(MoveItem(old: old, new: target.package, needsInstall: target.needsInstall,
                                   wasRequested: facts.requested?.contains(name) ?? true))
        }

        let movingKeys = Set(moving.map { $0.old.id.name.lowercased() })
        var removed = movingKeys
        if keepPicked { removed.remove(pickedKey) }
        var excluded = movingKeys.union(staying)
        excluded.insert(pickedKey)
        let leftovers = facts.requested.map {
            LeftoverFinder.leftovers(removed: removed, keep: excluded, requested: $0, dependents: facts.dependents,
                                     dependencies: facts.dependencies, installed: facts.sourceInstalled)
        } ?? []

        return MovePlan(picked: facts.picked, target: facts.target, moving: moving, cantMove: cantMove,
                        keepPicked: keepPicked, leftovers: leftovers, removeLeftovers: true,
                        pathWarning: pathWarning(facts), pathBin: facts.targetBin)
    }

    /// The picked package then its dependents, breadth-first, names sorted within a level, each listed once.
    private static func discoverMoveSet(from picked: String, dependents: [String: Set<String>]) -> [String] {
        var order = [picked]
        var seen: Set<String> = [picked]
        var level = [picked]
        while !level.isEmpty {
            var next: Set<String> = []
            for name in level {
                for dependent in dependents[name] ?? [] where !seen.contains(dependent) { next.insert(dependent) }
            }
            let sorted = next.sorted()
            seen.formUnion(sorted)
            order.append(contentsOf: sorted)
            level = sorted
        }
        return order
    }

    private static func pathWarning(_ facts: MoveFacts) -> String? {
        func trimmed(_ path: String) -> String {
            var path = path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            return path
        }
        let bin = trimmed(facts.targetBin)
        if facts.pathEntries.contains(where: { trimmed($0) == bin }) { return nil }
        return "\(facts.picked.displayName) won't run from Terminal until \(facts.targetBin) is on your PATH."
    }
}
