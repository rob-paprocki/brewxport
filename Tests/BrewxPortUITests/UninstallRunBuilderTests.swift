import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct UninstallRunBuilderTests {
    static func pkg(_ engine: EngineID, _ name: String, _ kind: PackageKind? = nil) -> Package {
        let kind = kind ?? (engine == .macports ? .port : engine == .mas ? .app : .formula)
        return Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: "1")
    }

    static func section(_ engine: EngineID, picks: [Package], blocked: [BlockedPick] = [], leftovers: [Package] = [],
                        removeLeftovers: Bool? = nil) -> UninstallSection {
        UninstallSection(engine: engine, picks: picks, blocked: blocked, leftovers: leftovers,
                         removeLeftovers: removeLeftovers ?? !leftovers.isEmpty, note: nil)
    }

    static func facts(dependents: [String: Set<String>] = [:], dependencies: [String: Set<String>] = [:])
        -> DependencyFacts {
        DependencyFacts(affected: [], dependents: dependents, dependencies: dependencies, requested: nil,
                        installed: [:], dependenciesComplete: true)
    }

    /// Homebrew: wget needs libidn2 (both picked); ripgrep needs pcre2 (both leftovers).
    static let homebrewFacts = facts(dependents: ["libidn2": ["wget"], "pcre2": ["ripgrep"]],
                                     dependencies: ["wget": ["libidn2"], "ripgrep": ["pcre2"]])

    static func homebrewSection(removeLeftovers: Bool = true) -> UninstallSection {
        section(.homebrew, picks: [pkg(.homebrew, "libidn2"), pkg(.homebrew, "wget")],
                leftovers: [pkg(.homebrew, "pcre2"), pkg(.homebrew, "ripgrep")], removeLeftovers: removeLeftovers)
    }

    static func build(_ sections: [UninstallSection], facts: [EngineID: DependencyFacts] = [.homebrew: homebrewFacts])
        -> UninstallRun {
        UninstallRunBuilder.run(for: UninstallPlan(sections: sections), engines: PlanFixtures.engines, facts: facts)
    }

    @Test func orderDependentsFirstThenLeftovers() {
        let steps = Self.build([Self.homebrewSection()]).actions.steps
        // wget before libidn2 (it needs it), then the leftovers, ripgrep before pcre2: name order would be the reverse.
        #expect(steps.map(\.title) == ["Homebrew: wget", "Homebrew: libidn2", "Homebrew: ripgrep", "Homebrew: pcre2"])
        #expect(steps.allSatisfy { $0.operation == .remove })
        #expect(steps.map(\.spec.arguments) == [["uninstall", "--formula", "wget"], ["uninstall", "--formula", "libidn2"],
                                                ["uninstall", "--formula", "ripgrep"],
                                                ["uninstall", "--formula", "pcre2"]])
    }

    @Test func caskPickBeforeItsFormulaLeftovers() {
        // The droid capture: the cask needs ripgrep, which needs pcre2; `brew uses` lists the cask as a dependent.
        let facts = Self.facts(dependents: ["ripgrep": ["droid"], "pcre2": ["ripgrep"]],
                               dependencies: ["droid": ["ripgrep"], "ripgrep": ["pcre2"]])
        let section = Self.section(.homebrew, picks: [Self.pkg(.homebrew, "droid", .cask)],
                                   leftovers: [Self.pkg(.homebrew, "pcre2"), Self.pkg(.homebrew, "ripgrep")])
        let steps = Self.build([section], facts: [.homebrew: facts]).actions.steps
        #expect(steps.map(\.spec.arguments) == [["uninstall", "--cask", "droid"], ["uninstall", "--formula", "ripgrep"],
                                                ["uninstall", "--formula", "pcre2"]])
    }

    @Test func gatedWithinManagerOnly() {
        let curl = Self.section(.macports, picks: [Self.pkg(.macports, "curl")])
        let steps = Self.build([Self.homebrewSection(), curl]).actions.steps
        #expect(steps.count == 5)
        #expect(steps.allSatisfy { $0.requiresAllEarlier })
        #expect(steps.map(\.gateGroup) == ["homebrew", "homebrew", "homebrew", "homebrew", "macports"])
    }

    @Test func managersIndependent() {
        // MacPorts first: with the helper not ready its removal is left out, and Homebrew's still run.
        let curl = Self.section(.macports, picks: [Self.pkg(.macports, "curl")])
        let jq = Self.section(.nanobrew, picks: [Self.pkg(.nanobrew, "jq")])
        let steps = Self.build([jq, Self.homebrewSection(), curl]).actions.steps
        #expect(steps.map(\.engine) == [.nanobrew, .homebrew, .homebrew, .homebrew, .homebrew, .macports])
        let reordered = [steps[5]] + steps.dropLast()
        let (kept, _) = RunPreflight.filter(reordered, helperState: .notRegistered, isAdministrator: true)
        #expect(kept == Array(steps.dropLast()))
    }

    @Test func homebrewStepsNoAutoremove() {
        let jq = Self.section(.nanobrew, picks: [Self.pkg(.nanobrew, "jq")])
        let curl = Self.section(.macports, picks: [Self.pkg(.macports, "curl")])
        let steps = Self.build([jq, Self.homebrewSection(), curl]).actions.steps
        for step in steps {
            #expect(step.userEnvironment == (step.engine == .homebrew ? ["HOMEBREW_NO_AUTOREMOVE": "1"] : [:]))
        }
    }

    @Test func untickedNoLeftoverSteps() {
        let steps = Self.build([Self.homebrewSection(removeLeftovers: false)]).actions.steps
        #expect(steps.map(\.title) == ["Homebrew: wget", "Homebrew: libidn2"])
    }

    @Test func refusedPicksGoLast() {
        // wget stays and needs aaa-lib, so Homebrew will refuse aaa-lib. It runs after zsh and the leftovers, so its
        // refusal can't stop them; name order alone would put it first.
        let facts = Self.facts(dependents: ["aaa-lib": ["wget"], "pcre2": ["zsh"]],
                               dependencies: ["wget": ["aaa-lib"], "zsh": ["pcre2"]])
        let aaa = Self.pkg(.homebrew, "aaa-lib")
        let section = UninstallSection(engine: .homebrew, picks: [aaa, Self.pkg(.homebrew, "zsh")], blocked: [],
                                       leftovers: [Self.pkg(.homebrew, "pcre2")], removeLeftovers: true, note: nil,
                                       refused: [aaa])
        let steps = Self.build([section], facts: [.homebrew: facts]).actions.steps
        #expect(steps.map(\.title) == ["Homebrew: zsh", "Homebrew: pcre2", "Homebrew: aaa-lib"])
        // Leftovers unticked: still after zsh.
        var unticked = section
        unticked.removeLeftovers = false
        #expect(Self.build([unticked], facts: [.homebrew: facts]).actions.steps.map(\.title)
                == ["Homebrew: zsh", "Homebrew: aaa-lib"])
    }

    @Test func blockedPicksNotRemoved() {
        let blocked = BlockedPick(package: Self.pkg(.nanobrew, "oniguruma"), reason: "needed by jq.")
        let section = Self.section(.nanobrew, picks: [Self.pkg(.nanobrew, "fd")], blocked: [blocked])
        let run = Self.build([section])
        #expect(run.actions.steps.map(\.spec.arguments) == [["remove", "fd"]])
        // Everything blocked: nothing to run.
        let none = Self.section(.nanobrew, picks: [], blocked: [blocked])
        #expect(Self.build([none]).actions.steps.isEmpty)
    }

    @Test func uninstallCommandsCarryNoForceFlags() {
        // A pick something else still needs must be refused by the package manager, so no command forces it.
        let sections = [
            Self.section(.nanobrew, picks: [Self.pkg(.nanobrew, "jq"), Self.pkg(.nanobrew, "firefox", .cask)]),
            Self.section(.homebrew, picks: [Self.pkg(.homebrew, "wget"), Self.pkg(.homebrew, "droid", .cask)]),
            Self.section(.macports, picks: [Self.pkg(.macports, "curl")]),
            Self.section(.mas, picks: [Self.pkg(.mas, "497799835")]),
        ]
        let steps = Self.build(sections, facts: [:]).actions.steps
        #expect(steps.map { [$0.spec.executable.path] + $0.spec.arguments } == [
            [PlanFixtures.nbPath, "remove", "--cask", "firefox"],
            [PlanFixtures.nbPath, "remove", "jq"],
            [PlanFixtures.brewPath, "uninstall", "--cask", "droid"],
            [PlanFixtures.brewPath, "uninstall", "--formula", "wget"],
            [PlanFixtures.portPath, "-N", "uninstall", "curl"],
            [PlanFixtures.masPath, "uninstall", "497799835"],
        ])
        let forcing: Set<String> = ["--force", "-f", "--ignore-dependencies", "--follow-dependents", "--zap"]
        #expect(steps.allSatisfy { forcing.isDisjoint(with: $0.spec.arguments) })
    }

    @Test func passwordReasonAndNoProblems() {
        let actions = Self.build([Self.homebrewSection()]).actions
        #expect(actions.reason == "BrewxPort needs an administrator password to uninstall these packages.")
        #expect(actions.problems.isEmpty)
        #expect(actions.notes.isEmpty)
    }

    @Test func missingEngineIsAProblemAndTheOthersStillRun() {
        let curl = Self.section(.macports, picks: [Self.pkg(.macports, "curl")])
        let engines = PlanFixtures.engines.filter { $0.id != .macports }
        let run = UninstallRunBuilder.run(for: UninstallPlan(sections: [Self.homebrewSection(), curl]),
                                          engines: engines, facts: [.homebrew: Self.homebrewFacts])
        #expect(run.actions.steps.map(\.engine) == [.homebrew, .homebrew, .homebrew, .homebrew])
        #expect(run.actions.problems == ["MacPorts isn't available, so curl wasn't removed."])
    }

    @Test func missingFactsFallBackToNameOrder() {
        let steps = Self.build([Self.homebrewSection()], facts: [:]).actions.steps
        #expect(steps.map(\.title) == ["Homebrew: libidn2", "Homebrew: wget", "Homebrew: pcre2", "Homebrew: ripgrep"])
    }

    // MARK: Summary

    /// wget, libidn2, ripgrep, pcre2 on Homebrew, then curl on MacPorts.
    static func summary(_ states: [StepState]) -> String? {
        let curl = section(.macports, picks: [pkg(.macports, "curl")])
        let run = build([homebrewSection(), curl])
        let rows = zip(run.actions.steps.indices, states).map { index, state in
            RunStepRow(id: index, title: run.actions.steps[index].title, operation: .remove, state: state)
        }
        return UninstallRunSummary.note(for: run, rows: rows)
    }

    @Test func summaryNamesWhatStayedAfterAFailure() {
        #expect(Self.summary([.succeeded, .failed(1), .skipped, .skipped, .succeeded])
                == "Removing libidn2 from Homebrew failed, so libidn2, ripgrep and pcre2 are still installed.")
        #expect(Self.summary([.succeeded, .succeeded, .succeeded, .failed(1), .failed(1)])
                == "Removing pcre2 from Homebrew failed, so pcre2 is still installed. "
                + "Removing curl from MacPorts failed, so curl is still installed.")
    }

    @Test func summarySaysCancelled() {
        #expect(Self.summary([.succeeded, .stopped, .skipped, .skipped, .skipped])
                == "libidn2, ripgrep and pcre2 are still installed from Homebrew because the uninstall was cancelled. "
                + "curl is still installed from MacPorts because the uninstall was cancelled.")
    }

    @Test func noSummaryWhenAllWentOrNothingRan() {
        #expect(Self.summary(Array(repeating: .succeeded, count: 5)) == nil)
        #expect(Self.summary(Array(repeating: .skipped, count: 5)) == nil)
    }
}
