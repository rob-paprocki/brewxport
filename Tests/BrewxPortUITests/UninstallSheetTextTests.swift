import Testing
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct UninstallSheetTextTests {
    static func pkg(_ engine: EngineID, _ name: String, version: String? = "1.0", kind: PackageKind? = nil) -> Package {
        let kind = kind ?? (engine == .macports ? .port : engine == .mas ? .app : .formula)
        return Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                       installedVersion: version, latestVersion: version)
    }

    static func section(_ engine: EngineID = .homebrew, picks: [String] = ["wget"], kind: PackageKind? = nil,
                        blocked: [BlockedPick] = [], leftovers: [String] = [], ticked: Bool = true,
                        note: String? = nil) -> UninstallSection {
        UninstallSection(engine: engine, picks: picks.map { pkg(engine, $0, version: "1.25.0", kind: kind) },
                         blocked: blocked, leftovers: leftovers.map { pkg(engine, $0) },
                         removeLeftovers: ticked && !leftovers.isEmpty, note: note)
    }

    static func plan(_ sections: UninstallSection...) -> UninstallPlan { UninstallPlan(sections: sections) }

    @Test func titles() {
        #expect(UninstallSheetText.title(Self.plan(Self.section())) == "Uninstall wget?")
        #expect(UninstallSheetText.title(Self.plan(Self.section(picks: ["a", "b"]))) == "Uninstall 2 packages?")
        #expect(UninstallSheetText.title(Self.plan(Self.section(picks: ["a"]), Self.section(.macports, picks: ["b"])))
                == "Uninstall 2 packages?")
        // Blocked picks aren't counted.
        let blocked = BlockedPick(package: Self.pkg(.nanobrew, "jq"), reason: "x")
        let nb = Self.section(.nanobrew, picks: [], blocked: [blocked])
        #expect(UninstallSheetText.title(Self.plan(Self.section(), nb)) == "Uninstall wget?")
        let both = Self.section(.nanobrew, picks: [], blocked: [blocked, BlockedPick(package: Self.pkg(.nanobrew, "yq"), reason: "x")])
        #expect(UninstallSheetText.title(Self.plan(both)) == "Uninstall packages?")
    }

    @Test func singleBlockedPickTitleUsesName() {
        // Nothing can be removed, but there was one pick: the title still names it.
        let blocked = BlockedPick(package: Self.pkg(.nanobrew, "oniguruma"), reason: "needed by jq.")
        #expect(UninstallSheetText.title(Self.plan(Self.section(.nanobrew, picks: [], blocked: [blocked])))
                == "Uninstall oniguruma?")
    }

    @Test func accountLine() throws {
        let port = UninstallRunBuilder.steps(for: Self.plan(Self.section(.macports)), engines: PlanFixtures.engines,
                                             facts: [:]).steps
        let brew = UninstallRunBuilder.steps(for: Self.plan(Self.section()), engines: PlanFixtures.engines,
                                             facts: [:]).steps
        #expect(UninstallSheetText.accountLine(port, isAdministrator: false) == "Removing these needs an administrator account.")
        #expect(UninstallSheetText.accountLine(port, isAdministrator: true) == UninstallSheetText.password)
        // A failed account check goes ahead and lets the password prompt decide, as the run does.
        #expect(UninstallSheetText.accountLine(port, isAdministrator: nil) == UninstallSheetText.password)
        #expect(UninstallSheetText.accountLine(brew, isAdministrator: false) == nil)
    }

    @Test func lines() {
        #expect(UninstallSheetText.pickLine(Self.pkg(.homebrew, "wget", version: "1.25.0")) == "wget 1.25.0")
        #expect(UninstallSheetText.pickLine(Self.pkg(.homebrew, "wget", version: nil)) == "wget")
        #expect(UninstallSheetText.leftoversToggle(Self.section()) == "Also remove leftovers from Homebrew")
        #expect(UninstallSheetText.leftoverNames([Self.pkg(.homebrew, "openssl@4")])
                == "openssl@4 (nothing else uses it)")
        #expect(UninstallSheetText.leftoverNames([Self.pkg(.homebrew, "openssl@4"), Self.pkg(.homebrew, "libidn2")])
                == "openssl@4, libidn2 (nothing else uses them)")
    }

    /// The blocked line, with the reasons the planner really gives.
    @Test func blockedLinesFromThePlanner() throws {
        let jq = Self.pkg(.nanobrew, "jq")
        let yq = Self.pkg(.nanobrew, "yq")
        let facts = DependencyFacts(affected: ["jq", "yq"], dependents: ["jq": ["yq"]], dependencies: [:],
                                    requested: nil, installed: ["jq": jq, "yq": yq], dependenciesComplete: true)
        let needed = try #require(UninstallPlanner.plan(picks: [jq], facts: [.nanobrew: .success(facts)])
            .sections.first?.blocked.first)
        #expect(UninstallSheetText.blockedLine(needed) == "jq stays: needed by yq.")
        let unchecked = try #require(UninstallPlanner.plan(picks: [jq], facts: [:]).sections.first?.blocked.first)
        #expect(UninstallSheetText.blockedLine(unchecked) == "jq stays: BrewxPort couldn't check what needs it.")
    }

    /// The password line for the steps the sheet would run.
    static func passwordLine(_ sections: UninstallSection...) -> String? {
        let steps = UninstallRunBuilder.steps(for: UninstallPlan(sections: sections), engines: PlanFixtures.engines,
                                              facts: [:]).steps
        return UninstallSheetText.passwordLine(steps)
    }

    @Test func passwordLine() {
        let line = "You'll be asked for your password once."
        #expect(Self.passwordLine(Self.section()) == nil)
        #expect(Self.passwordLine(Self.section(), Self.section(.nanobrew)) == nil)
        #expect(Self.passwordLine(Self.section(.macports)) == line)
        #expect(Self.passwordLine(Self.section(), Self.section(.mas, picks: ["497799835"])) == line)
        // A Homebrew cask is removed through the password prompt.
        #expect(Self.passwordLine(Self.section(picks: ["droid"], kind: .cask)) == line)
        // A MacPorts section that removes nothing needs no password.
        #expect(Self.passwordLine(Self.section(.macports, picks: [])) == nil)
    }

    @Test func button() {
        #expect(UninstallSheetText.uninstallButton(Self.plan(Self.section())) == "Uninstall")
        #expect(UninstallSheetText.uninstallButton(Self.plan(Self.section(picks: ["a", "b"]))) == "Uninstall 2 packages")
        // Ticked leftovers count; unticked ones don't.
        #expect(UninstallSheetText.uninstallButton(Self.plan(Self.section(leftovers: ["x", "y"]))) == "Uninstall 3 packages")
        #expect(UninstallSheetText.uninstallButton(Self.plan(Self.section(leftovers: ["x", "y"], ticked: false)))
                == "Uninstall")
        #expect(UninstallSheetText.canUninstall(Self.plan(Self.section())))
        #expect(!UninstallSheetText.canUninstall(Self.plan(Self.section(picks: []))))
        #expect(!UninstallSheetText.canUninstall(Self.plan()))
    }

    @Test func checkingText() {
        #expect(UninstallSheetText.checking == "Checking…")
    }
}
