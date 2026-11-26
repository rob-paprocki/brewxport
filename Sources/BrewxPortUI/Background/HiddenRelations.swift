import Foundation
import BrewxPortCore

/// Which automatic updates would also change an ignored or skipped package. `brew upgrade` upgrades a formula's
/// outdated dependencies and the outdated installed packages that depend on it (which bring their own outdated
/// dependencies along); `port upgrade` upgrades a port's outdated dependencies. Ignore and Skip live only in
/// BrewxPort, so the package managers don't know about them. An automatic run therefore leaves out every update
/// related that way to an ignored or skipped row on Updates, and the person is told instead. Manual updates are
/// unchanged: the README says what Homebrew does.
///
/// Worked out from the hidden rows' side, since there are usually a few of them against many updates (the relation
/// goes both ways). For one package manager's hidden rows: the installed packages that depend on them, further down
/// (with the rows themselves), and every installed package that an outdated one of those needs, further down. When
/// any of it can't be read (the package manager couldn't answer, more than `DependencyGatherer.maxPackages`, a
/// dependency list it doesn't give, Installed without that package manager), every update from that package manager
/// counts as related: never a guess.
struct HiddenRelations: Sendable {
    private struct Entry: Sendable {
        /// The hidden rows it was worked out for.
        let hidden: Set<PackageRef>
        /// Lower-cased names; nil when it couldn't be read.
        let related: Set<String>?
    }

    private var entries: [EngineID: Entry] = [:]

    /// Nothing worked out: every update from a package manager with a hidden row counts as related.
    static let none = HiddenRelations()

    /// True when updating `ref` could also change an ignored or skipped package. `hidden`: the ignored and skipped
    /// rows on Updates now. A package manager with a hidden row that wasn't there when this was worked out counts as
    /// unread.
    func holds(_ ref: PackageRef, hidden: Set<PackageRef>) -> Bool {
        let hiddenHere = hidden.filter { $0.engine == ref.engine }
        guard !hiddenHere.isEmpty else { return false }
        guard let entry = entries[ref.engine], hiddenHere.isSubset(of: entry.hidden),
              let related = entry.related else { return true }
        return related.contains(ref.name.lowercased())
    }

    /// Works it out for each package manager in `engineIDs` that has a hidden row, all at once.
    /// - Parameters:
    ///   - hidden: The ignored and skipped rows on Updates.
    ///   - outdated: Every row on Updates, hidden or not.
    ///   - installed: Installed's rows; `installedFailed`: the package managers it couldn't list.
    static func gather(for engineIDs: Set<EngineID>, hidden: [Package], outdated: [PackageRef],
                       installed: [Package], installedFailed: Set<EngineID>,
                       engines: [any Engine], catalog: any PackageQuerying) async -> HiddenRelations {
        let picks = Dictionary(grouping: hidden, by: \.id.engine).filter { engineIDs.contains($0.key) }
        let listed = Set(installed.map(\.id.engine)).subtracting(installedFailed)
        let outdatedNames = Dictionary(grouping: outdated, by: \.engine)
            .mapValues { Set($0.map { $0.name.lowercased() }) }
        let gatherer = DependencyGatherer(engines: engines, catalog: catalog)
        let entries = await withTaskGroup(of: (EngineID, Entry).self) { group in
            for (engine, enginePicks) in picks {
                let rows = Set(enginePicks.map(\.id))
                // The Mac App Store's apps don't depend on one another.
                guard engines.contains(where: { $0.id == engine && $0 is any DependentsListing }) else {
                    group.addTask { (engine, Entry(hidden: rows, related: [])) }
                    continue
                }
                // Dependencies are only read among Installed's rows: without them, nothing would look related.
                guard listed.contains(engine) else {
                    group.addTask { (engine, Entry(hidden: rows, related: nil)) }
                    continue
                }
                let stillOutdated = outdatedNames[engine] ?? []
                group.addTask {
                    let facts: DependencyFacts
                    do {
                        facts = try await gatherer.facts(for: enginePicks, engine: engine, installed: installed,
                                                         walkDependenciesWhenRequestedUnknown: true)
                    } catch {
                        return (engine, Entry(hidden: rows, related: nil))
                    }
                    guard facts.dependenciesComplete else { return (engine, Entry(hidden: rows, related: nil)) }
                    return (engine, Entry(hidden: rows, related: related(facts, outdated: stillOutdated)))
                }
            }
            var entries: [EngineID: Entry] = [:]
            for await (engine, entry) in group { entries[engine] = entry }
            return entries
        }
        return HiddenRelations(entries: entries)
    }

    /// The hidden rows and what depends on them (`affected`), plus everything an outdated one of those needs.
    private static func related(_ facts: DependencyFacts, outdated: Set<String>) -> Set<String> {
        var needed = facts.affected.intersection(outdated)
        var queue = Array(needed)
        while let name = queue.popLast() {
            for need in facts.dependencies[name] ?? [] where needed.insert(need).inserted {
                queue.append(need)
            }
        }
        return facts.affected.union(needed)
    }
}
