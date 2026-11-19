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
}
