import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// A small, hand-drawn Homebrew graph for `LeftoverFinder`.
private struct LeftoverGraph {
    var dependents: [String: Set<String>] = [:]
    var dependencies: [String: Set<String>] = [:]
    var installed: Set<String> = []

    static func brew(_ name: String) -> Package {
        Package(id: PackageRef(engine: .homebrew, kind: .formula, name: name), displayName: name,
                installedVersion: "1")
    }

    /// `user` depends on `library`, in both maps.
    mutating func uses(_ user: String, _ library: String) {
        dependents[library, default: []].insert(user)
        dependencies[user, default: []].insert(library)
        installed.formUnion([user, library])
    }

    func leftovers(removed: Set<String>, keep: Set<String> = [], requested: Set<String> = []) -> [String] {
        var packages: [String: Package] = [:]
        for name in installed { packages[name] = Self.brew(name) }
        return LeftoverFinder.leftovers(removed: removed, keep: keep, requested: requested, dependents: dependents,
                                        dependencies: dependencies, installed: packages).map(\.id.name)
    }
}

@Suite struct LeftoverFinderTests {
    @Test func onlyUsedByTheRemovedPackageIsALeftover() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        #expect(g.leftovers(removed: ["ripgrep"]) == ["pcre2"])
    }

    @Test func dependenciesFurtherDownAreLeftoversAndSorted() {
        var g = LeftoverGraph()
        g.uses("tool", "zlib-ng")
        g.uses("zlib-ng", "cmake-lib")
        g.uses("tool", "aaa")
        #expect(g.leftovers(removed: ["tool"]) == ["aaa", "cmake-lib", "zlib-ng"])
    }

    @Test func sharedLibraryIsNotALeftover() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        g.uses("git", "pcre2")
        #expect(g.leftovers(removed: ["ripgrep"]).isEmpty)
    }

    @Test func userKnownOnlyFromTheDependentsMapKeepsTheLibrary() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        // git's own dependencies weren't gathered; only pcre2's dependents name it.
        g.dependents["pcre2", default: []].insert("git")
        g.installed.insert("git")
        #expect(g.leftovers(removed: ["ripgrep"]).isEmpty)
    }

    @Test func userKnownOnlyFromTheDependenciesMapKeepsTheLibrary() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        // pcre2's dependents answer missed git; git's dependencies name it.
        g.dependencies["git", default: []].insert("pcre2")
        g.installed.insert("git")
        #expect(g.leftovers(removed: ["ripgrep"]).isEmpty)
    }

    @Test func requestedIsNeverALeftover() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        g.uses("ripgrep", "xz")
        #expect(g.leftovers(removed: ["ripgrep"], requested: ["pcre2"]) == ["xz"])
    }

    @Test func keptIsNeverALeftoverAndStillCountsAsAUser() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        g.uses("ripgrep", "helper")
        g.uses("helper", "xz")
        // helper stays: neither it nor xz, which it still needs, is a leftover.
        #expect(g.leftovers(removed: ["ripgrep"], keep: ["helper"]) == ["pcre2"])
    }

    @Test func notInstalledIsNotALeftover() {
        var g = LeftoverGraph()
        g.uses("ripgrep", "pcre2")
        g.installed.remove("pcre2")
        #expect(g.leftovers(removed: ["ripgrep"]).isEmpty)
    }

    @Test func leftoversThatNeedEachOtherGoTogether() {
        var g = LeftoverGraph()
        g.uses("tool", "a")
        g.uses("a", "b")
        g.uses("b", "a")
        #expect(g.leftovers(removed: ["tool"]) == ["a", "b"])
    }

    @Test func cycleWithAnOutsideUserStaysAndTerminates() {
        var g = LeftoverGraph()
        g.uses("tool", "a")
        g.uses("a", "b")
        g.uses("b", "a")
        g.uses("git", "b")
        #expect(g.leftovers(removed: ["tool"]).isEmpty)
    }

    @Test func cycleThroughTheRemovedPackageTerminates() {
        var g = LeftoverGraph()
        g.uses("tool", "a")
        g.uses("a", "tool")
        #expect(g.leftovers(removed: ["tool"]) == ["a"])
    }

    @Test func removedPackagesAreNotLeftovers() {
        var g = LeftoverGraph()
        g.uses("ripgrep-all", "ripgrep")
        g.uses("ripgrep", "pcre2")
        #expect(g.leftovers(removed: ["ripgrep-all", "ripgrep"]) == ["pcre2"])
    }
}
