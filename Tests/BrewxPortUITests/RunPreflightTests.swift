import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct RunPreflightTests {
    typealias F = PlanFixtures

    // MARK: Ported from the old withoutHelper cases

    @Test func helperStepsAreDroppedWhenTheHelperIsNotReady() {
        let mixed = [F.port("curl"), F.cask(), F.formula()]
        let (kept, notes) = RunPreflight.filter(mixed, helperState: .requiresApproval, isAdministrator: true)
        #expect(kept == [F.cask(), F.formula()])
        #expect(notes.count == 1)
        let text = notes.first ?? ""
        #expect(text.contains("Upgrade curl"))
        #expect(text.contains("MacPorts updates need BrewxPort's helper"))
        #expect(text.contains(HelperStateDisplay.text(for: .requiresApproval)))

        // A helper-only run keeps nothing, so it never asks for the password.
        let (none, onlyNotes) = RunPreflight.filter([F.port()], helperState: .failed("x"), isAdministrator: true)
        #expect(none.isEmpty)
        #expect(onlyNotes.count == 1)

        // Nothing for the helper: unchanged, no note.
        let rootless = [F.cask(), F.mas()]
        let (same, noNotes) = RunPreflight.filter(rootless, helperState: nil, isAdministrator: true)
        #expect(same == rootless)
        #expect(noNotes.isEmpty)
    }

    // MARK: Standard users

    @Test func standardUserRunsUserStepsAndNamesSkipped() {
        let steps = [F.formula("wget"), F.cask("zoom"), F.port("curl"), F.mas("497799835")]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .enabled, isAdministrator: false)
        #expect(kept == [F.formula("wget")])
        #expect(notes == [
            "Skipped Upgrade zoom; Upgrade curl; Upgrade 497799835: they need an administrator account, and this one isn't."
        ])
    }

    @Test func standardUserWithOnlyUserStepsHasNoNote() {
        let (kept, notes) = RunPreflight.filter([F.formula()], helperState: nil, isAdministrator: false)
        #expect(kept == [F.formula()])
        #expect(notes.isEmpty)
    }

    // MARK: Helper

    @Test func helperNotReadyDropsPortSteps() {
        let steps = [F.formula(), F.port("curl"), F.mas()]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .notRegistered, isAdministrator: true)
        #expect(kept == [F.formula(), F.mas()])
        #expect(notes == [
            "Skipped Upgrade curl. MacPorts updates need BrewxPort's helper, and it isn't ready: "
                + HelperStateDisplay.text(for: .notRegistered)
        ])
    }

    @Test func helperNoteIsWordedFromTheStepOperations() {
        func note(_ steps: [RunStep]) -> String {
            RunPreflight.filter(steps, helperState: .notRegistered, isAdministrator: true).notes.first ?? ""
        }
        let install = F.step(.macports, .port, F.portPath, ["-N", "install", "curl"], needsRoot: true,
                             title: "Install curl", operation: .install)
        let remove = F.step(.macports, .port, F.portPath, ["-N", "uninstall", "tree"], needsRoot: true,
                            title: "Remove tree", operation: .remove)
        #expect(note([install]).contains("Skipped Install curl. MacPorts installs need BrewxPort's helper"))
        #expect(note([remove]).contains("Skipped Remove tree. MacPorts removals need BrewxPort's helper"))
        #expect(note([F.port("wget")]).contains("MacPorts updates need BrewxPort's helper"))
        #expect(note([install, remove, F.port("wget")]).hasPrefix(
            "Skipped Install curl; Remove tree; Upgrade wget. MacPorts changes need BrewxPort's helper, and it isn't ready: "))
    }

    @Test func helperUnavailableReasonReplacesStateText() {
        let (kept, notes) = RunPreflight.filter([F.port("curl")], helperState: nil, isAdministrator: true,
                                                helperUnavailableReason: "Not signed.")
        #expect(kept.isEmpty)
        #expect(notes == ["Skipped Upgrade curl. MacPorts updates need BrewxPort's helper, and it isn't ready: Not signed."])
    }

    @Test func adminWithHelperKeepsAll() {
        let steps = [F.formula(), F.cask(), F.port(), F.mas()]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .enabled, isAdministrator: true)
        #expect(kept == steps)
        #expect(notes.isEmpty)
    }

    @Test func unknownAdminKeepsEverything() {
        let steps = [F.formula(), F.cask(), F.port(), F.mas()]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .enabled, isAdministrator: nil)
        #expect(kept == steps)
        #expect(notes.isEmpty)
    }
}
