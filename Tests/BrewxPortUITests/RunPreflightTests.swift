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

    // MARK: Setup steps

    static let setupStep = RunStep(
        engine: .macports, kind: .port, operation: .install,
        spec: CommandSpec(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], needsRoot: true),
        title: "Set up MacPorts", setupTarget: .macports)

    @Test func standardAccountDropsSetupStep() {
        let (kept, notes) = RunPreflight.filter([F.formula(), Self.setupStep], helperState: .enabled,
                                                isAdministrator: false)
        #expect(kept == [F.formula()])
        #expect(notes == ["Skipped Set up MacPorts: they need an administrator account, and this one isn't."])
    }

    @Test func helperNotEnabledDropsSetupStep() {
        let (kept, notes) = RunPreflight.filter([F.formula(), Self.setupStep], helperState: .requiresApproval,
                                                isAdministrator: true)
        #expect(kept == [F.formula()])
        #expect(notes.count == 1)
        #expect(notes.first?.contains("Skipped Set up MacPorts.") == true)
        #expect(notes.first?.contains("need BrewxPort's helper") == true)
        let (all, none) = RunPreflight.filter([Self.setupStep], helperState: .enabled, isAdministrator: true)
        #expect(all == [Self.setupStep])
        #expect(none.isEmpty)
    }

    @Test func dependentStepIsDroppedWithItsSetupStep() {
        let nbInit = RunStep(engine: .nanobrew, kind: .formula, operation: .install,
                             spec: CommandSpec(executable: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb"),
                                               arguments: ["init"], needsRoot: true),
                             title: "Run nb init", dependsOnPrevious: true)
        let (kept, notes) = RunPreflight.filter([F.formula(), Self.setupStep, nbInit], helperState: .notRegistered,
                                                isAdministrator: true)
        #expect(kept == [F.formula()])
        #expect(notes.count == 1)
        #expect(notes.first?.hasPrefix("Skipped Set up MacPorts; Run nb init. Engine setup steps need") == true)
        // With the helper ready both stay.
        let all = [Self.setupStep, nbInit]
        #expect(RunPreflight.filter(all, helperState: .enabled, isAdministrator: true).steps == all)
    }

    @Test func dependencyChainOfThreeIsDroppedLinkByLink() {
        // The helper's port step is dropped; the two user steps chained behind it go with it, the free one stays.
        func dependent(_ name: String) -> RunStep {
            RunStep(engine: .homebrew, operation: .upgrade,
                    spec: CommandSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                      arguments: ["upgrade", name], needsRoot: false),
                    title: name, dependsOnPrevious: true)
        }
        let steps = [F.port("curl"), dependent("b"), dependent("c"), F.formula()]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .notRegistered, isAdministrator: true)
        #expect(kept == [F.formula()])
        #expect(notes.first?.hasPrefix("Skipped Upgrade curl; b; c.") == true, "\(notes)")
    }

    @Test func gatedStepIsDroppedWhenAnyEarlierStepIs() {
        let remove = RunStep(engine: .homebrew, operation: .remove,
                             spec: CommandSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                               arguments: ["uninstall", "wget"], needsRoot: false),
                             title: "Remove wget", requiresAllEarlier: true)
        // The dropped port step is not right before the gated one.
        let steps = [F.port("curl"), F.formula(), remove]
        let (kept, notes) = RunPreflight.filter(steps, helperState: .notRegistered, isAdministrator: true)
        #expect(kept == [F.formula()])
        #expect(notes.first?.contains("Remove wget") == true)
        // Same for a standard account.
        let (userKept, _) = RunPreflight.filter(steps, helperState: .enabled, isAdministrator: false)
        #expect(userKept == [F.formula()])
        // Nothing dropped: the gated step stays.
        #expect(RunPreflight.filter(steps, helperState: .enabled, isAdministrator: true).steps == steps)
    }

    static func groupedRemove(_ engine: EngineID, _ kind: PackageKind, _ name: String) -> RunStep {
        let (path, arguments): (String, [String]) = switch engine {
        case .macports: ("/opt/local/bin/port", ["-N", "uninstall", name])
        default: ("/opt/homebrew/bin/brew", kind == .cask ? ["uninstall", "--cask", name] : ["uninstall", "--formula", name])
        }
        return RunStep(engine: engine, kind: kind, operation: .remove,
                       spec: CommandSpec(executable: URL(fileURLWithPath: path), arguments: arguments,
                                         needsRoot: engine == .macports),
                       title: "Remove \(name)", requiresAllEarlier: true, gateGroup: engine.rawValue)
    }

    @Test func groupedGateDropsOnlyWithItsOwnGroup() {
        // A standard account can't run the droid cask removal (askpass), so its formula leftovers go with it.
        let droid = Self.groupedRemove(.homebrew, .cask, "droid")
        let ripgrep = Self.groupedRemove(.homebrew, .formula, "ripgrep")
        let pcre2 = Self.groupedRemove(.homebrew, .formula, "pcre2")
        let (kept, _) = RunPreflight.filter([droid, ripgrep, pcre2], helperState: .enabled, isAdministrator: false)
        #expect(kept.isEmpty)

        // A dropped MacPorts removal leaves the Homebrew removals after it in place.
        let curl = Self.groupedRemove(.macports, .port, "curl")
        let wget = Self.groupedRemove(.homebrew, .formula, "wget")
        let (helperKept, notes) = RunPreflight.filter([curl, wget, ripgrep], helperState: .notRegistered,
                                                      isAdministrator: true)
        #expect(helperKept == [wget, ripgrep])
        #expect(notes.first?.contains("Remove curl") == true)
        #expect(notes.first?.contains("wget") == false)
    }

    @Test func checkStepIsNeverDroppedForTheHelper() {
        let check = RunStep.check([PackageRef(engine: .macports, kind: .port, name: "curl")], on: .macports,
                                  title: "Check MacPorts has the packages")
        let (kept, notes) = RunPreflight.filter([F.formula(), check], helperState: .notRegistered,
                                                isAdministrator: false)
        #expect(kept == [F.formula(), check])
        #expect(notes.isEmpty)
    }

    @Test func passedCheckStepGoesWithItsCheck() {
        let check = RunStep.check([PackageRef(engine: .homebrew, kind: .formula, name: "wget")], on: .homebrew,
                                  title: "Check Homebrew has the packages")
        let mark = RunStep(engine: .homebrew, operation: .markRequested,
                           spec: CommandSpec(executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                                             arguments: ["tab", "--installed-on-request", "wget"], needsRoot: false),
                           title: "Mark wget", requiresPassedCheck: true)
        // A dropped check takes the step with it.
        let (kept, dropped) = RunPreflight.split([check, mark], dropping: { $0.verifyInstalled != nil })
        #expect(kept.isEmpty)
        #expect(dropped == [check, mark])
        // Any other dropped step leaves it: the check decides at run time.
        let (keptAfterPort, _) = RunPreflight.split([F.port("curl"), check, mark], dropping: RunPreflight.usesHelper)
        #expect(keptAfterPort == [check, mark])
    }
}
