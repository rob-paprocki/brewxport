import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct MoveRunSummaryTests {
    private static func pkg(_ engine: EngineID, _ name: String) -> Package {
        Package(id: PackageRef(engine: engine, kind: .formula, name: name), displayName: name, installedVersion: "1")
    }

    /// jq (picked) and its dependent jq-tools move from Homebrew to nanobrew; oniguruma is a leftover.
    private static func move() throws -> MoveRun {
        let moving = ["jq", "jq-tools"].map {
            MoveItem(old: pkg(.homebrew, $0), new: pkg(.nanobrew, $0), needsInstall: true, wasRequested: true)
        }
        let plan = MovePlan(picked: pkg(.homebrew, "jq"), target: .nanobrew, moving: moving, cantMove: [],
                            keepPicked: false, leftovers: [pkg(.homebrew, "oniguruma")], removeLeftovers: true,
                            pathWarning: nil)
        return try MoveRunBuilder.run(for: plan, engines: PlanFixtures.engines, dependents: ["jq": ["jq-tools"]],
                                      dependencies: ["jq": ["oniguruma"]])
    }

    /// The run's rows with the given states, in step order: install, check, remove jq-tools, remove jq, remove
    /// oniguruma.
    private static func rows(_ run: MoveRun, _ states: [StepState]) -> [RunStepRow] {
        zip(run.actions.steps.indices, states).map { index, state in
            RunStepRow(id: index, title: run.actions.steps[index].title, operation: run.actions.steps[index].operation,
                       state: state)
        }
    }

    private static func note(_ states: [StepState], missing: [String]? = nil) throws -> String? {
        let run = try move()
        return MoveRunSummary.note(for: run, rows: rows(run, states), missing: missing, source: .homebrew,
                                   target: .nanobrew)
    }

    @Test func stepsAreInTheOrderTheseTestsAssume() throws {
        let run = try Self.move()
        #expect(run.actions.steps.map(\.title) == ["nanobrew: jq, jq-tools", run.checkTitle, "Homebrew: jq-tools",
                                                   "Homebrew: jq", "Homebrew: oniguruma"])
    }

    @Test func noNoteWhenEverythingWasRemoved() throws {
        #expect(try Self.note([.succeeded, .succeeded, .succeeded, .succeeded, .succeeded]) == nil)
    }

    @Test func noNoteWhenNothingRan() throws {
        // A rejected password: every step is skipped, and the log already says nothing changed.
        #expect(try Self.note([.skipped, .skipped, .skipped, .skipped, .skipped]) == nil)
    }

    @Test func failedCheckNamesWhatIsMissing() throws {
        #expect(try Self.note([.failed(1), .failed(1), .skipped, .skipped, .skipped], missing: ["jq-tools"])
                == "Nothing was removed because jq-tools isn't on nanobrew.")
        #expect(try Self.note([.failed(1), .failed(1), .skipped, .skipped, .skipped], missing: ["jq", "jq-tools"])
                == "Nothing was removed because jq and jq-tools aren't on nanobrew.")
        #expect(try Self.note([.failed(1), .failed(1), .skipped, .skipped, .skipped])
                == "Nothing was removed because the check on nanobrew failed.")
    }

    @Test func failedInstallWithAPassingCheck() throws {
        #expect(try Self.note([.failed(1), .succeeded, .skipped, .skipped, .skipped])
                == "Nothing was removed because an install on nanobrew failed.")
    }

    @Test func failedRemovalSaysWhichCopiesStay() throws {
        #expect(try Self.note([.succeeded, .succeeded, .succeeded, .failed(1), .skipped])
                == "The Homebrew copies of jq and oniguruma are still installed because removing jq failed.")
        #expect(try Self.note([.succeeded, .succeeded, .succeeded, .succeeded, .failed(1)])
                == "The Homebrew copy of oniguruma is still installed because removing oniguruma failed.")
    }

    @Test func cancelledMove() throws {
        #expect(try Self.note([.succeeded, .stopped, .skipped, .skipped, .skipped])
                == "Nothing was removed because the move was cancelled.")
        #expect(try Self.note([.succeeded, .succeeded, .succeeded, .stopped, .skipped])
                == "The Homebrew copies of jq and oniguruma are still installed because the move was cancelled.")
    }

    @Test func listWording() {
        #expect(MoveRunSummary.list(["a"]) == "a")
        #expect(MoveRunSummary.list(["a", "b"]) == "a and b")
        #expect(MoveRunSummary.list(["a", "b", "c"]) == "a, b and c")
    }
}
