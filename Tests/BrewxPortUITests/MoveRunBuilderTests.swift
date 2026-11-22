import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

private func pkg(_ engine: EngineID, _ name: String) -> Package {
    let kind: PackageKind = engine == .macports ? .port : .formula
    return Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1")
}

private func item(_ source: EngineID, _ target: EngineID, _ name: String, install: Bool, requested: Bool) -> MoveItem {
    MoveItem(old: pkg(source, name), new: pkg(target, name), needsInstall: install, wasRequested: requested)
}

private func plan(source: EngineID = .homebrew, target: EngineID = .nanobrew, moving: [String],
                  keepPicked: Bool = false, leftovers: [String] = [], removeLeftovers: Bool = true,
                  notInstall: Set<String> = [], dependencyOnly: Set<String> = []) -> MovePlan {
    MovePlan(picked: pkg(source, moving.first ?? "x"), target: target,
             moving: moving.map {
                 item(source, target, $0, install: !notInstall.contains($0), requested: !dependencyOnly.contains($0))
             },
             cantMove: [], keepPicked: keepPicked, leftovers: leftovers.map { pkg(source, $0) },
             removeLeftovers: removeLeftovers, pathWarning: nil)
}

/// `dependents["lib"] = ["mid"]` means mid depends on lib.
private let chain: [String: Set<String>] = ["lib": ["mid"], "mid": ["app"]]

private func ops(_ steps: [RunStep]) -> [String] {
    steps.map { $0.verifyInstalled != nil ? "check" : "\($0.operation)" }
}

private func removed(_ result: ActionPlan) -> [String?] {
    result.steps.filter { $0.operation == .remove }.map { $0.spec.arguments.last }
}

@Suite struct MoveRunBuilderTests {
    private func build(_ plan: MovePlan, dependents: [String: Set<String>] = [:],
                       dependencies: [String: Set<String>] = [:]) throws -> ActionPlan {
        try MoveRunBuilder.steps(for: plan, engines: PlanFixtures.engines, dependents: dependents,
                                 dependencies: dependencies)
    }

    @Test func orderInstallCheckRemoveMark() throws {
        let result = try build(plan(source: .macports, target: .homebrew, moving: ["lib", "mid", "app"]),
                               dependents: chain)
        #expect(ops(result.steps) == ["install", "check", "remove", "remove", "remove", "markRequested"])
        #expect(result.reason == "BrewxPort needs an administrator password to move these packages.")
        #expect(result.problems.isEmpty)
    }

    @Test func dependentsRemovedBeforePicked() throws {
        let result = try build(plan(moving: ["lib", "mid", "app"]), dependents: chain)
        #expect(removed(result) == ["app", "mid", "lib"])
    }

    @Test func keepPickedSkipsItsRemoval() throws {
        let result = try build(plan(moving: ["lib", "mid", "app"], keepPicked: true), dependents: chain)
        #expect(removed(result) == ["app", "mid"])
        let check = try #require(result.steps.first { $0.verifyInstalled != nil })
        #expect(check.verifyInstalled?.map(\.name) == ["lib", "mid", "app"])
    }

    @Test func leftoversOnlyWhenTicked() throws {
        let on = try build(plan(moving: ["lib"], leftovers: ["z", "y"]), dependencies: ["z": ["y"]])
        #expect(removed(on) == ["lib", "z", "y"])
        let off = try build(plan(moving: ["lib"], leftovers: ["z", "y"], removeLeftovers: false))
        #expect(removed(off) == ["lib"])
    }

    @Test func leftoverOrderUsesDependenciesMap() throws {
        // c needs b, b needs a: the edges exist only in `dependencies`, so a name sort would remove a first.
        let result = try build(plan(moving: ["lib"], leftovers: ["a", "b", "c"]),
                               dependencies: ["c": ["b"], "b": ["a"]])
        #expect(removed(result) == ["lib", "c", "b", "a"])
    }

    @Test func removalsAreGated() throws {
        let result = try build(plan(moving: ["lib", "mid", "app"], leftovers: ["z"]), dependents: chain)
        #expect(removed(result).count == 4)
        for step in result.steps {
            #expect(step.requiresAllEarlier == (step.operation == .remove))
        }
    }

    @Test func alreadyOnTargetNotInstalled() throws {
        let result = try build(plan(moving: ["lib", "mid"], notInstall: ["mid"]), dependents: chain)
        let install = try #require(result.steps.first { $0.operation == .install && $0.verifyInstalled == nil })
        #expect(install.spec.arguments.contains("lib"))
        #expect(!install.spec.arguments.contains("mid"))
        let check = try #require(result.steps.first { $0.verifyInstalled != nil })
        #expect(check.verifyInstalled?.map(\.name) == ["lib", "mid"])
    }

    @Test func nothingToInstallMeansNoInstallStep() throws {
        let result = try build(plan(moving: ["lib"], notInstall: ["lib"]))
        #expect(ops(result.steps) == ["check", "remove"])
    }

    @Test func homebrewToNanobrewNeedsNoPassword() throws {
        let result = try build(plan(moving: ["lib", "mid"]), dependents: chain)
        #expect(!result.steps.isEmpty)
        #expect(result.steps.allSatisfy { RunRouting.route(for: $0) == .user })
        #expect(!ops(result.steps).contains("markRequested"))
        #expect(!ops(result.steps).contains("markDependency"))
    }

    @Test func macportsMovePasswordOnce() throws {
        let result = try build(plan(source: .macports, target: .homebrew, moving: ["lib", "mid"]), dependents: chain)
        let removals = result.steps.filter { $0.operation == .remove }
        #expect(removals.count == 2)
        #expect(removals.allSatisfy { RunRouting.route(for: $0) == .helper })
        #expect(result.steps.filter { $0.engine == .homebrew }.allSatisfy { RunRouting.route(for: $0) == .user })
    }

    @Test func marksSplitByRequestedAndLastUngated() throws {
        let result = try build(plan(target: .homebrew, moving: ["lib", "mid"], dependencyOnly: ["mid"]),
                               dependents: chain)
        #expect(Array(ops(result.steps).suffix(2)) == ["markRequested", "markDependency"])
        let marks = Array(result.steps.suffix(2))
        #expect(marks.allSatisfy { !$0.requiresAllEarlier && $0.engine == .homebrew })
        #expect(marks[0].spec.arguments.contains("lib"))
        #expect(marks[1].spec.arguments.contains("mid"))
    }

    @Test func marksRunOnlyAfterAPassedCheck() throws {
        let result = try build(plan(source: .macports, target: .homebrew, moving: ["lib", "mid"],
                                    dependencyOnly: ["mid"]), dependents: chain)
        for step in result.steps {
            let isMark = step.operation == .markRequested || step.operation == .markDependency
            #expect(step.requiresPassedCheck == isMark)
        }
        #expect(result.steps.contains { $0.operation == .markDependency })
    }

    @Test func alreadyOnTargetIsNeverMarkedAsADependency() throws {
        // mid was only a dependency on MacPorts, but it was already on Homebrew, maybe asked for there.
        let result = try build(plan(source: .macports, target: .homebrew, moving: ["lib", "mid"],
                                    notInstall: ["mid"], dependencyOnly: ["mid"]), dependents: chain)
        #expect(!result.steps.contains { $0.operation == .markDependency })
        // Marking an already-installed package as asked-for is harmless and stays.
        let requested = try build(plan(source: .macports, target: .homebrew, moving: ["lib", "mid"],
                                       notInstall: ["mid"]), dependents: chain)
        let mark = try #require(requested.steps.first { $0.operation == .markRequested })
        #expect(mark.spec.arguments.contains("mid"))
    }

    @Test func homebrewRemovalsDontAutoremove() throws {
        let result = try build(plan(target: .macports, moving: ["lib", "mid"], leftovers: ["z"]), dependents: chain)
        let removals = result.steps.filter { $0.operation == .remove }
        #expect(removals.count == 3)
        #expect(removals.allSatisfy { $0.userEnvironment == ["HOMEBREW_NO_AUTOREMOVE": "1"] })
        #expect(result.steps.filter { $0.operation != .remove }.allSatisfy { $0.userEnvironment.isEmpty })
        // Other sources keep their removals as they are.
        let fromPorts = try build(plan(source: .macports, target: .homebrew, moving: ["lib"]))
        #expect(fromPorts.steps.allSatisfy { $0.userEnvironment.isEmpty })
        let fromNanobrew = try build(plan(source: .nanobrew, target: .homebrew, moving: ["lib"]))
        #expect(fromNanobrew.steps.allSatisfy { $0.userEnvironment.isEmpty })
    }

    @Test func macportsTargetMarksThroughTheHelper() throws {
        let result = try build(plan(target: .macports, moving: ["lib", "mid"], dependencyOnly: ["mid"]),
                               dependents: chain)
        #expect(ops(result.steps) == ["install", "check", "remove", "remove", "markRequested", "markDependency"])
        let marks = result.steps.filter { $0.operation == .markRequested || $0.operation == .markDependency }
        #expect(marks.allSatisfy { $0.engine == .macports && RunRouting.route(for: $0) == .helper })
    }

    @Test func missingEngineThrows() {
        let engines = PlanFixtures.engines.filter { $0.id != .nanobrew }
        #expect(throws: MoveRunError.engineMissing(.nanobrew)) {
            try MoveRunBuilder.steps(for: plan(moving: ["lib"]), engines: engines, dependents: [:], dependencies: [:])
        }
        let noBrew = PlanFixtures.engines.filter { $0.id != .homebrew }
        #expect(throws: MoveRunError.engineMissing(.homebrew)) {
            try MoveRunBuilder.steps(for: plan(moving: ["lib"]), engines: noBrew, dependents: [:], dependencies: [:])
        }
    }

    @Test func pickedFoundByIDNotPosition() throws {
        // The picked package is listed second; the builder still removes it last and keeps it when asked.
        let picked = pkg(.homebrew, "lib")
        func reordered(keep: Bool) -> MovePlan {
            MovePlan(picked: picked, target: .nanobrew,
                     moving: [item(.homebrew, .nanobrew, "mid", install: true, requested: true),
                              item(.homebrew, .nanobrew, "lib", install: true, requested: true)],
                     cantMove: [], keepPicked: keep, leftovers: [], removeLeftovers: false, pathWarning: nil)
        }
        #expect(removed(try build(reordered(keep: false), dependents: chain)) == ["mid", "lib"])
        #expect(removed(try build(reordered(keep: true), dependents: chain)) == ["mid"])
        // A plan whose moving list doesn't hold the picked package has nothing it can safely run.
        let without = MovePlan(picked: picked, target: .nanobrew,
                               moving: [item(.homebrew, .nanobrew, "mid", install: true, requested: true)],
                               cantMove: [], keepPicked: true, leftovers: [], removeLeftovers: false, pathWarning: nil)
        #expect(throws: MoveRunError.nothingToMove) { try build(without) }
    }

    @Test func sameNamedFormulaAndCaskAreBothRemoved() throws {
        let cask = Package(id: PackageRef(engine: .homebrew, kind: .cask, name: "foo"), displayName: "foo",
                           installedVersion: "1")
        var leftovers = plan(moving: ["lib"], leftovers: ["foo"])
        leftovers = MovePlan(picked: leftovers.picked, target: .nanobrew, moving: leftovers.moving, cantMove: [],
                             keepPicked: false, leftovers: leftovers.leftovers + [cask], removeLeftovers: true,
                             pathWarning: nil)
        let removals = try build(leftovers).steps.filter { $0.operation == .remove }
        // lib (picked), then the two leftovers: same name, so they're ordered by kind.
        #expect(removals.map(\.kind) == [.formula, .cask, .formula])
        #expect(removals.map { $0.spec.arguments.last } == ["lib", "foo", "foo"])
    }

    @Test func runNamesTheCheckAndEachRemoval() throws {
        let run = try MoveRunBuilder.run(for: plan(moving: ["lib", "mid"]), engines: PlanFixtures.engines,
                                         dependents: chain, dependencies: [:])
        #expect(run.checkTitle == "Check nanobrew: lib, mid")
        #expect(run.actions.steps.contains { $0.title == run.checkTitle && $0.verifyInstalled != nil })
        let removalTitles = run.actions.steps.filter { $0.operation == .remove }.map(\.title)
        #expect(removalTitles.map { run.removalNames[$0] } == ["mid", "lib"])
    }

    @Test func emptyMoveHasNoSteps() {
        let empty = MovePlan(picked: pkg(.homebrew, "x"), target: .nanobrew, moving: [], cantMove: [],
                             keepPicked: true, leftovers: [], removeLeftovers: true, pathWarning: nil)
        #expect(throws: MoveRunError.nothingToMove) {
            try MoveRunBuilder.steps(for: empty, engines: PlanFixtures.engines, dependents: [:],
                                     dependencies: [:])
        }
    }
}
