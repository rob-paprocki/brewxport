import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortRun

@Suite struct RunLogTests {
    @Test func helperRowOffersLoginItemsOnlyWhenApprovalIsNeeded() {
        #expect(HelperStateDisplay.offersLoginItems(.requiresApproval))
        for state: HelperState? in [nil, .notRegistered, .enabled, .outdated, .failed("x")] {
            #expect(!HelperStateDisplay.offersLoginItems(state))
        }
        #expect(HelperStateDisplay.text(for: .requiresApproval).contains("Login Items"))
        #expect(HelperStateDisplay.text(for: .failed("boom")).hasSuffix("boom"))
    }

    @Test func cancelledClosesTheOpenStep() {
        var log = RunLog(titles: ["MacPorts: curl", "Mac App Store: 1"])
        log.apply(.needsPassword)
        log.apply(.started(0))
        log.apply(.output(0, .stdout("fetching")))
        log.apply(.cancelled)
        log.apply(.done)
        #expect(log.openStep == nil)
        #expect(log.lines.map(\.text) == [
            "Waiting for the administrator password.", "Updating MacPorts: curl", "fetching",
            "Stopped MacPorts: curl before it finished.", "Cancelled. Nothing more will run.", "Done.",
        ])
        #expect(log.lines[3].isError)
    }

    @Test func finishedStepsAndRejectionAreLogged() {
        var log = RunLog(titles: ["a", "b"])
        log.apply(.started(0))
        log.apply(.output(0, .stderr("warning")))
        log.apply(.finished(0, 0))
        log.apply(.started(1))
        log.apply(.finished(1, 3))
        log.apply(.cancelled)
        #expect(log.lines.map(\.text) == ["Updating a", "warning", "Finished a.", "Updating b", "b failed (exit code 3).",
                                          "Cancelled. Nothing more will run."])
        var rejected = RunLog()
        rejected.apply(.passwordRejected)
        #expect(rejected.lines.first?.text == "That password didn't work. Nothing was changed.")
    }

    @Test func privilegeUnavailableIsLoggedWithItsReason() {
        var log = RunLog()
        log.apply(.privilegeUnavailable(RunSession.notAnAdministrator))
        #expect(log.lines.map(\.text) == [RunSession.notAnAdministrator, "Nothing was changed."])
        #expect(log.lines.allSatisfy { $0.isError })
    }

    @Test func runLogUsesOperationVerb() {
        let spec = CommandSpec(executable: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb"),
                               arguments: ["install", "ripgrep"], needsRoot: false)
        let install = RunStep(engine: .nanobrew, kind: .formula, operation: .install, spec: spec,
                              title: "nanobrew: ripgrep")
        let remove = RunStep(engine: .nanobrew, kind: .formula, operation: .remove, spec: spec, title: "nanobrew: fd")
        let upgrade = RunStep(engine: .nanobrew, operation: .upgrade, spec: spec, title: "nanobrew: jq")
        #expect(upgrade.operation == .upgrade)
        var log = RunLog(steps: [install, remove, upgrade])
        log.apply(.started(0))
        log.apply(.finished(0, 0))
        log.apply(.started(1))
        log.apply(.started(2))
        #expect(log.lines.map(\.text) == ["Installing nanobrew: ripgrep", "Finished nanobrew: ripgrep.",
                                          "Removing nanobrew: fd", "Updating nanobrew: jq"])
    }

    @Test func checkStepIsLoggedByItsTitleAlone() {
        let check = RunStep.check([PackageRef(engine: .homebrew, kind: .formula, name: "jq")], on: .homebrew,
                                  title: "Check Homebrew has the packages")
        var log = RunLog(steps: [check])
        log.apply(.started(0))
        log.apply(.output(0, .stderr("Not found on Homebrew: jq")))
        log.apply(.finished(0, 1))
        #expect(log.lines.map(\.text) == ["Check Homebrew has the packages", "Not found on Homebrew: jq",
                                          "Check Homebrew has the packages failed (exit code 1)."])
    }

    @Test func catalogueRefreshNotesTheSkipOnlyWhenUpgradesWaitOnIt() {
        let port = URL(fileURLWithPath: "/opt/local/bin/port")
        let refresh = RunStep.macPortsCatalogueRefresh(
            CommandSpec(executable: port, arguments: ["-N", "selfupdate"], needsRoot: true))
        func upgrade(_ name: String) -> RunStep {
            RunStep(engine: .macports, kind: .port, operation: .upgrade,
                    spec: CommandSpec(executable: port, arguments: ["-N", "upgrade", name], needsRoot: true),
                    title: "MacPorts: \(name)", requiresAllEarlier: true,
                    gateGroup: RunStep.macPortsCatalogueRefreshGroup)
        }

        // "Refresh MacPorts…" alone: nothing waits on it, so its failure is only a failure. Its title is logged
        // without a verb, like a check's.
        var alone = RunLog(steps: [refresh])
        alone.apply(.started(0))
        alone.apply(.finished(0, 1))
        alone.apply(.done)
        #expect(alone.lines.map(\.text) == ["MacPorts: refresh the port catalogue",
                                            "MacPorts: refresh the port catalogue failed (exit code 1).", "Done."])

        // A refresh that worked or was stopped part way, or a failed upgrade after it, skips nothing for that reason.
        var worked = RunLog(steps: [refresh, upgrade("curl"), upgrade("bzip2")])
        worked.apply(.started(0))
        worked.apply(.finished(0, 0))
        worked.apply(.started(1))
        worked.apply(.finished(1, 1))
        worked.apply(.done)
        var stopped = RunLog(steps: [refresh, upgrade("curl")])
        stopped.apply(.started(0))
        stopped.apply(.cancelled)
        stopped.apply(.done)
        for log in [worked, stopped] {
            #expect(!log.lines.contains { $0.text.hasPrefix("Skipped") })
        }

        // With upgrades waiting, one line says why they won't run.
        var waited = RunLog(steps: [refresh, upgrade("curl"), upgrade("bzip2")])
        waited.apply(.started(0))
        waited.apply(.finished(0, 1))
        waited.apply(.done)
        #expect(waited.lines.map(\.text) == ["MacPorts: refresh the port catalogue",
                                             "MacPorts: refresh the port catalogue failed (exit code 1).",
                                             "Skipped: the MacPorts catalogue refresh failed.", "Done."])
        #expect(waited.lines[2].isError)
    }
}
