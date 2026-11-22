import Foundation
import BrewxPortCore

/// Which installed packages become leftovers when some are removed. Pure. Every map is keyed by lower-cased name, and
/// every name in a value is lower-cased too; all of them describe one package manager.
///
/// A leftover is a dependency (direct or further down) of the removed packages that the person never asked for, that
/// isn't in `keep`, that's installed, and that nothing outside the removed packages and the leftovers themselves needs.
/// Who needs a package comes from both maps, so a gap in one never removes a shared library.
public enum LeftoverFinder {
    /// - Parameters:
    ///   - removed: The packages being removed.
    ///   - keep: Packages that are never leftovers (for Move to: everything in the move set). One that isn't removed
    ///     still counts as a package that stays, so what it needs stays too.
    ///   - requested: The packages the person asked for.
    ///   - dependents: Name → the installed packages that depend on it directly.
    ///   - dependencies: Name → the installed packages it depends on directly.
    ///   - installed: The installed packages by name.
    /// - Returns: The leftovers, sorted by name.
    public static func leftovers(removed: Set<String>, keep: Set<String>, requested: Set<String>,
                                 dependents: [String: Set<String>], dependencies: [String: Set<String>],
                                 installed: [String: Package]) -> [Package] {
        // Starts from every candidate and drops any with a dependent that stays, until nothing changes, so leftovers
        // that need each other still go together.
        var candidates: Set<String> = []
        var queue = Array(removed)
        var seen = removed
        while let name = queue.popLast() {
            for dependency in dependencies[name] ?? [] where !seen.contains(dependency) {
                seen.insert(dependency)
                queue.append(dependency)
                candidates.insert(dependency)
            }
        }
        candidates = candidates.filter {
            !keep.contains($0) && !requested.contains($0) && installed[$0] != nil
        }

        // Who depends on each candidate, from both maps, so a gap in one doesn't remove a shared library.
        var users: [String: Set<String>] = [:]
        for name in candidates { users[name] = dependents[name] ?? [] }
        for (user, needs) in dependencies {
            for name in needs where candidates.contains(name) { users[name, default: []].insert(user) }
        }

        var leftovers = candidates
        var changed = true
        while changed {
            changed = false
            for name in leftovers
            where !(users[name] ?? []).allSatisfy({ removed.contains($0) || leftovers.contains($0) }) {
                leftovers.remove(name)
                changed = true
            }
        }
        return leftovers.sorted().compactMap { installed[$0] }
    }
}
