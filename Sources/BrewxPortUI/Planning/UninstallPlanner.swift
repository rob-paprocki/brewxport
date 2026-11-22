import Foundation
import BrewxPortCore

/// A pick that won't be removed, and why, in words for the sheet.
public struct BlockedPick: Equatable, Sendable {
    public var package: Package
    /// Why it stays, without the package's name ("needed by yq."): the sheet puts "<name> stays: " in front.
    public var reason: String

    public init(package: Package, reason: String) {
        self.package = package
        self.reason = reason
    }
}

/// What uninstalling some picks does on one package manager.
public struct UninstallSection: Equatable, Sendable {
    public var engine: EngineID
    /// The picks that will be removed, sorted by name. On Homebrew and MacPorts this includes a pick something else
    /// still needs: the package manager refuses that one when the run gets to it.
    public var picks: [Package]
    /// The picks that won't be removed (nanobrew only), sorted by name.
    public var blocked: [BlockedPick]
    /// The leftovers offered under the tick box, sorted by name. Empty means no box.
    public var leftovers: [Package]
    /// Whether the tick box is ticked. Ticked by default when there are leftovers; false when there's no box.
    public var removeLeftovers: Bool
    /// Why there's no box when leftovers couldn't be worked out.
    public var note: String?
    /// The picks (also in `picks`) that something staying still needs, so Homebrew or MacPorts will refuse them.
    /// The run removes them last, so their refusal doesn't stop the rest. Sorted by name.
    public var refused: [Package]

    public init(engine: EngineID, picks: [Package], blocked: [BlockedPick], leftovers: [Package],
                removeLeftovers: Bool, note: String?, refused: [Package] = []) {
        self.engine = engine
        self.picks = picks
        self.blocked = blocked
        self.leftovers = leftovers
        self.removeLeftovers = removeLeftovers
        self.note = note
        self.refused = refused
    }
}

/// The uninstall sheet's contents: one section per package manager with picks, in `EngineID` order.
public struct UninstallPlan: Equatable, Sendable {
    public var sections: [UninstallSection]

    public init(sections: [UninstallSection]) { self.sections = sections }
}

/// Works out what an uninstall removes. Pure.
///
/// - Homebrew and MacPorts: every pick is removed (the package manager itself refuses one something else still needs),
///   and the dependencies only the removed picks and other leftovers use, and that weren't asked for, are offered as
///   leftovers. A pick something that stays still needs counts as staying, so nothing it needs is offered. A package
///   whose install record doesn't say whether it was asked for counts as asked for. When the facts failed or the
///   dependencies couldn't all be read, there are no leftovers and the section says so.
/// - nanobrew: `nb remove` doesn't refuse, so a pick with an installed dependent that stays is blocked, and every pick
///   is blocked when the facts failed. Never any leftovers.
/// - Mac App Store: the picks, nothing else.
public enum UninstallPlanner {
    /// - Parameters:
    ///   - picks: The packages picked for removal, any package managers.
    ///   - facts: Each package manager's facts for its picks; a failure is the dependents walk failing. A
    ///     missing entry counts as a failure.
    public static func plan(picks: [Package],
                            facts: [EngineID: Result<DependencyFacts, DependencyGatherer.Failure>]) -> UninstallPlan {
        var byEngine: [EngineID: [Package]] = [:]
        var seen: Set<PackageRef> = []
        for pick in picks where seen.insert(pick.id).inserted { byEngine[pick.id.engine, default: []].append(pick) }

        let sections = EngineID.allCases.compactMap { engine -> UninstallSection? in
            guard let enginePicks = byEngine[engine] else { return nil }
            let sorted = enginePicks.sorted { key($0) < key($1) }
            let engineFacts = facts[engine].flatMap { try? $0.get() }
            switch engine {
            case .nanobrew: return nanobrewSection(sorted, engineFacts)
            case .mas:
                return UninstallSection(engine: engine, picks: sorted, blocked: [], leftovers: [],
                                        removeLeftovers: false, note: nil)
            case .homebrew, .macports: return leftoverSection(engine, sorted, engineFacts)
            }
        }
        return UninstallPlan(sections: sections)
    }

    private static func key(_ package: Package) -> String { package.id.name.lowercased() }

    /// The picks that can go: every pick whose installed dependents all go too, worked out until nothing changes.
    private static func removable(_ picks: [Package], dependents: [String: Set<String>]) -> Set<String> {
        var going = Set(picks.map(key))
        var changed = true
        while changed {
            changed = false
            for name in going where !(dependents[name] ?? []).isSubset(of: going) {
                going.remove(name)
                changed = true
            }
        }
        return going
    }

    private static func nanobrewSection(_ picks: [Package], _ facts: DependencyFacts?) -> UninstallSection {
        guard let facts else {
            let blocked = picks.map { BlockedPick(package: $0, reason: "BrewxPort couldn't check what needs it.") }
            return UninstallSection(engine: .nanobrew, picks: [], blocked: blocked, leftovers: [],
                                    removeLeftovers: false, note: nil)
        }
        let going = removable(picks, dependents: facts.dependents)
        var kept: [Package] = []
        var blocked: [BlockedPick] = []
        for pick in picks {
            if going.contains(key(pick)) {
                kept.append(pick)
            } else {
                let staying = (facts.dependents[key(pick)] ?? []).subtracting(going)
                let users = staying.map { facts.installed[$0]?.displayName ?? $0 }.sorted()
                let reason = "needed by \(users.joined(separator: ", "))."
                blocked.append(BlockedPick(package: pick, reason: reason))
            }
        }
        return UninstallSection(engine: .nanobrew, picks: kept, blocked: blocked, leftovers: [],
                                removeLeftovers: false, note: nil)
    }

    private static func leftoverSection(_ engine: EngineID, _ picks: [Package],
                                        _ facts: DependencyFacts?) -> UninstallSection {
        guard let facts, facts.dependenciesComplete else {
            return UninstallSection(engine: engine, picks: picks, blocked: [], leftovers: [], removeLeftovers: false,
                                    note: "Couldn't work out leftovers for \(engine.displayName).")
        }
        let going = removable(picks, dependents: facts.dependents)
        let staying = Set(picks.map(key)).subtracting(going)
        // Only a package recorded as not asked for can be a leftover.
        let requested = Set(facts.installed.filter { $0.value.installedOnRequest != false }.keys)
        let leftovers = LeftoverFinder.leftovers(removed: going, keep: staying, requested: requested,
                                                 dependents: facts.dependents, dependencies: facts.dependencies,
                                                 installed: facts.installed)
        return UninstallSection(engine: engine, picks: picks, blocked: [], leftovers: leftovers,
                                removeLeftovers: !leftovers.isEmpty, note: nil,
                                refused: picks.filter { staying.contains(key($0)) })
    }
}
