import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// Builds `MoveFacts` for a Homebrew → nanobrew move over a small, hand-drawn dependency graph.
private struct MoveGraph {
    var dependents: [String: Set<String>] = [:]
    var dependencies: [String: Set<String>] = [:]
    var requested: Set<String>? = []
    var installed: [String] = []
    var onTarget: [String: TargetLookup] = [:]
    var pathEntries = ["/usr/bin", "/opt/nanobrew/prefix/bin"]
    let targetBin = "/opt/nanobrew/prefix/bin"

    static func brew(_ name: String) -> Package {
        Package(id: PackageRef(engine: .homebrew, kind: .formula, name: name), displayName: name,
                installedVersion: "1")
    }

    static func nb(_ name: String) -> Package {
        Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: name), displayName: name,
                latestVersion: "1")
    }

    /// `user` depends on `library`.
    mutating func uses(_ user: String, _ library: String) {
        dependents[library, default: []].insert(user)
        dependencies[user, default: []].insert(library)
        for name in [user, library] where !installed.contains(name) { installed.append(name) }
    }

    mutating func install(_ names: String...) {
        for name in names where !installed.contains(name) { installed.append(name) }
    }

    mutating func availableOnTarget(_ names: String...) {
        for name in names { onTarget[name] = .found(Self.nb(name)) }
    }

    func facts(_ picked: String) -> MoveFacts {
        var source: [String: Package] = [:]
        for name in installed { source[name] = Self.brew(name) }
        if source[picked] == nil { source[picked] = Self.brew(picked) }
        return MoveFacts(picked: source[picked]!, target: .nanobrew, dependents: dependents,
                         dependencies: dependencies, requested: requested, sourceInstalled: source,
                         onTarget: onTarget, pathEntries: pathEntries, targetBin: targetBin)
    }
}

private func names(_ items: [MoveItem]) -> [String] { items.map(\.old.id.name) }

@Suite struct MovePlannerTests {
    @Test func singleToolNoDependents() {
        var graph = MoveGraph()
        graph.install("ripgrep")
        graph.requested = ["ripgrep"]
        graph.availableOnTarget("ripgrep")
        let plan = MovePlanner.plan(graph.facts("ripgrep"))
        #expect(plan.picked == MoveGraph.brew("ripgrep"))
        #expect(plan.target == .nanobrew)
        #expect(plan.moving == [MoveItem(old: MoveGraph.brew("ripgrep"), new: MoveGraph.nb("ripgrep"),
                                         needsInstall: true, wasRequested: true)])
        #expect(plan.cantMove.isEmpty)
        #expect(plan.keepPicked == false)
        #expect(plan.leftovers.isEmpty)
        #expect(plan.removeLeftovers == true)
        #expect(plan.pathWarning == nil)
    }

    @Test func libraryMovesWithDependent() {
        var graph = MoveGraph()
        graph.uses("ripgrep-all", "ripgrep")
        graph.uses("tool", "ripgrep-all")
        graph.requested = ["tool"]
        graph.availableOnTarget("ripgrep", "ripgrep-all", "tool")
        let plan = MovePlanner.plan(graph.facts("ripgrep"))
        #expect(names(plan.moving) == ["ripgrep", "ripgrep-all", "tool"])
        #expect(plan.moving.map(\.wasRequested) == [false, false, true])
        #expect(plan.moving.map(\.needsInstall) == [true, true, true])
        #expect(plan.keepPicked == false)
        #expect(plan.cantMove.isEmpty)
    }

    @Test func diamondDependentsListedOnce() {
        var graph = MoveGraph()
        graph.uses("b", "a")
        graph.uses("c", "a")
        graph.uses("d", "b")
        graph.uses("d", "c")
        graph.availableOnTarget("a", "b", "c", "d")
        let plan = MovePlanner.plan(graph.facts("a"))
        #expect(names(plan.moving) == ["a", "b", "c", "d"])
    }

    @Test func dependentCycleTerminates() {
        var graph = MoveGraph()
        graph.uses("b", "a")
        graph.uses("c", "b")
        graph.uses("b", "c")
        graph.uses("a", "c")
        graph.availableOnTarget("a", "b", "c")
        let plan = MovePlanner.plan(graph.facts("a"))
        #expect(names(plan.moving) == ["a", "b", "c"])
    }

    @Test func unmovableDependentKeepsPickedAndChain() {
        // lib ← mid ← stuck (not on nanobrew); lib ← free (movable, nothing unmovable needs it).
        // lib ← other ← broken (lookup failed).
        var graph = MoveGraph()
        graph.uses("mid", "lib")
        graph.uses("stuck", "mid")
        graph.uses("free", "lib")
        graph.uses("other", "lib")
        graph.uses("broken", "other")
        graph.requested = ["stuck", "free", "broken"]
        graph.availableOnTarget("lib", "mid", "free", "other")
        graph.onTarget["stuck"] = .notFound
        graph.onTarget["broken"] = .failed("nanobrew info failed")
        let plan = MovePlanner.plan(graph.facts("lib"))
        #expect(plan.keepPicked == true)
        #expect(names(plan.moving) == ["lib", "free"])
        #expect(plan.cantMove == [CantMove(name: "mid", reason: "needed by stuck"),
                                  CantMove(name: "other", reason: "needed by broken"),
                                  CantMove(name: "broken", reason: "nanobrew info failed"),
                                  CantMove(name: "stuck", reason: "not on nanobrew")])
        #expect(plan.leftovers.isEmpty)
    }

    @Test func keptChainMembersListedAsCantMove() {
        // lib ← a ← b ← far (not on nanobrew); a ← near (not on nanobrew): a names the nearer one.
        // lib ← c ← q-stuck, c ← p-stuck (both not on nanobrew, same distance): c names the first by name.
        var graph = MoveGraph()
        graph.uses("a", "lib")
        graph.uses("b", "a")
        graph.uses("far", "b")
        graph.uses("near", "a")
        graph.uses("c", "lib")
        graph.uses("q-stuck", "c")
        graph.uses("p-stuck", "c")
        graph.requested = ["far", "near", "q-stuck", "p-stuck"]
        graph.availableOnTarget("lib", "a", "b", "c")
        let plan = MovePlanner.plan(graph.facts("lib"))
        #expect(plan.keepPicked == true)
        #expect(names(plan.moving) == ["lib"])
        #expect(plan.cantMove == [CantMove(name: "a", reason: "needed by near"),
                                  CantMove(name: "c", reason: "needed by p-stuck"),
                                  CantMove(name: "b", reason: "needed by far"),
                                  CantMove(name: "near", reason: "not on nanobrew"),
                                  CantMove(name: "p-stuck", reason: "not on nanobrew"),
                                  CantMove(name: "q-stuck", reason: "not on nanobrew"),
                                  CantMove(name: "far", reason: "not on nanobrew")])
    }

    @Test func dependentMissingFromSourceIsUnmovable() {
        // lib ← mid ← ghost; ghost is in the dependents map and on nanobrew, but not in the source's installed list.
        var graph = MoveGraph()
        graph.uses("mid", "lib")
        graph.uses("ghost", "mid")
        graph.installed.removeAll { $0 == "ghost" }
        graph.requested = ["ghost"]
        graph.availableOnTarget("lib", "mid", "ghost")
        let plan = MovePlanner.plan(graph.facts("lib"))
        #expect(plan.keepPicked == true)
        #expect(names(plan.moving) == ["lib"])
        #expect(plan.cantMove == [CantMove(name: "mid", reason: "needed by ghost"),
                                  CantMove(name: "ghost", reason: "not listed on Homebrew")])
        #expect(plan.leftovers.isEmpty)
    }

    @Test func pickedNotOnTargetMovesNothing() {
        for lookup in [TargetLookup.notFound, .failed("nanobrew info failed"), nil] {
            var graph = MoveGraph()
            graph.uses("tool", "lib")
            graph.uses("lib", "base")
            graph.requested = ["tool"]
            graph.availableOnTarget("tool")
            graph.onTarget["lib"] = lookup
            let plan = MovePlanner.plan(graph.facts("lib"))
            let reason = if case .failed(let message) = lookup { message } else { "not on nanobrew" }
            #expect(plan.moving.isEmpty)
            #expect(plan.keepPicked == true)
            #expect(plan.leftovers.isEmpty)
            #expect(plan.cantMove == [CantMove(name: "lib", reason: reason)])
        }
    }

    @Test func alreadyOnTargetOnlyRemoves() {
        var graph = MoveGraph()
        graph.uses("tool", "lib")
        graph.requested = ["tool"]
        graph.onTarget["lib"] = .alreadyInstalled(MoveGraph.nb("lib"))
        graph.availableOnTarget("tool")
        let plan = MovePlanner.plan(graph.facts("lib"))
        #expect(plan.moving == [
            MoveItem(old: MoveGraph.brew("lib"), new: MoveGraph.nb("lib"), needsInstall: false, wasRequested: false),
            MoveItem(old: MoveGraph.brew("tool"), new: MoveGraph.nb("tool"), needsInstall: true, wasRequested: true),
        ])
        #expect(plan.keepPicked == false)
    }

    @Test func requestedLibraryNeverLeftover() {
        // tool → pcre2 (dependency only), tool → openssl (asked for).
        var graph = MoveGraph()
        graph.uses("tool", "pcre2")
        graph.uses("tool", "openssl")
        graph.requested = ["tool", "openssl"]
        graph.availableOnTarget("tool")
        let plan = MovePlanner.plan(graph.facts("tool"))
        #expect(plan.leftovers == [MoveGraph.brew("pcre2")])
        #expect(plan.removeLeftovers == true)
    }

    @Test func sharedLibraryNotLeftover() {
        // tool → zlib, other (staying) → zlib; tool → pcre2 → libdeep, both only for tool.
        var graph = MoveGraph()
        graph.uses("tool", "zlib")
        graph.uses("other", "zlib")
        graph.uses("tool", "pcre2")
        graph.uses("pcre2", "libdeep")
        graph.requested = ["tool", "other"]
        graph.availableOnTarget("tool")
        let plan = MovePlanner.plan(graph.facts("tool"))
        #expect(plan.leftovers == [MoveGraph.brew("libdeep"), MoveGraph.brew("pcre2")])
    }

    @Test func sharedLibraryFoundOnlyThroughDependenciesNotLeftover() {
        // The dependents map misses `other` → zlib; the dependencies map still shows it.
        var graph = MoveGraph()
        graph.uses("tool", "zlib")
        graph.install("other")
        graph.dependencies["other"] = ["zlib"]
        graph.requested = ["tool", "other"]
        graph.availableOnTarget("tool")
        let plan = MovePlanner.plan(graph.facts("tool"))
        #expect(plan.leftovers.isEmpty)
    }

    @Test func keptPickedNeverLeftover() {
        // stuck → lib → base. lib stays (kept for stuck), so base isn't a leftover either.
        var graph = MoveGraph()
        graph.uses("stuck", "lib")
        graph.uses("lib", "base")
        graph.requested = ["stuck"]
        graph.availableOnTarget("lib")
        graph.onTarget["stuck"] = .notFound
        let plan = MovePlanner.plan(graph.facts("lib"))
        #expect(plan.keepPicked == true)
        #expect(names(plan.moving) == ["lib"])
        #expect(plan.leftovers.isEmpty)
    }

    @Test func noRequestedInfoNoLeftovers() {
        var graph = MoveGraph()
        graph.uses("tool", "pcre2")
        graph.requested = nil
        graph.availableOnTarget("tool")
        let plan = MovePlanner.plan(graph.facts("tool"))
        #expect(plan.leftovers.isEmpty)
        #expect(plan.moving.map(\.wasRequested) == [true])
    }

    @Test func pathWarningWhenBinMissing() {
        var graph = MoveGraph()
        graph.install("ripgrep")
        graph.availableOnTarget("ripgrep")
        graph.pathEntries = ["/usr/bin", "/opt/homebrew/bin"]
        let plan = MovePlanner.plan(graph.facts("ripgrep"))
        #expect(plan.pathWarning == "ripgrep won't run from Terminal until /opt/nanobrew/prefix/bin is on your PATH.")
    }

    @Test func noPathWarningWhenPresent() {
        var graph = MoveGraph()
        graph.install("ripgrep")
        graph.availableOnTarget("ripgrep")
        graph.pathEntries = ["/usr/bin", "/opt/nanobrew/prefix/bin/"]
        let plan = MovePlanner.plan(graph.facts("ripgrep"))
        #expect(plan.pathWarning == nil)
    }

    @Test func isMovableRules() {
        let cask = Package(id: PackageRef(engine: .homebrew, kind: .cask, name: "firefox"), displayName: "Firefox")
        let app = Package(id: PackageRef(engine: .mas, kind: .app, name: "497799835"), displayName: "Xcode")
        let tapFormula = Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "borders"),
                                 displayName: "borders", fullName: "felixkratz/formulae/borders")
        let tap = Package(id: PackageRef(engine: .homebrew, kind: .tap, name: "felixkratz/formulae"),
                          displayName: "felixkratz/formulae")
        let core = MoveGraph.brew("ripgrep")
        let nanobrew = MoveGraph.nb("ripgrep")
        let port = Package(id: PackageRef(engine: .macports, kind: .port, name: "wget"), displayName: "wget")
        #expect(MovePlanner.isMovable(cask, engineHasDependents: true) == false)
        #expect(MovePlanner.isMovable(app, engineHasDependents: true) == false)
        #expect(MovePlanner.isMovable(tapFormula, engineHasDependents: true) == false)
        #expect(MovePlanner.isMovable(tap, engineHasDependents: true) == false)
        #expect(MovePlanner.isMovable(nanobrew, engineHasDependents: false) == false)
        #expect(MovePlanner.isMovable(core, engineHasDependents: false) == false)
        #expect(MovePlanner.isMovable(core, engineHasDependents: true) == true)
        #expect(MovePlanner.isMovable(nanobrew, engineHasDependents: true) == true)
        #expect(MovePlanner.isMovable(port, engineHasDependents: true) == true)
    }
}
