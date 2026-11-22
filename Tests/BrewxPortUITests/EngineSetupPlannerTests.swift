import Testing
import Foundation
import BrewxPortCore
import BrewxPortRun
@testable import BrewxPortUI

@Suite struct EngineSetupPlannerTests {
    typealias P = PlanFixtures
    static let arm = HostInfo(appleSilicon: true, macOSMajor: 15)
    static let intel = HostInfo(appleSilicon: false, macOSMajor: 15)
    static func present(_ path: String) -> EngineStatus { .present(path: URL(fileURLWithPath: path), version: "1") }

    func plan(_ engine: EngineID, statuses: [EngineID: EngineStatus] = [:], host: HostInfo = arm,
              clt: Bool = true) -> ActionPlan {
        EngineSetupPlanner.plan(engine, statuses: statuses, host: host, cltPresent: clt, engines: P.engines)
    }

    @Test func homebrewIsOneSetupStep() {
        let result = plan(.homebrew)
        #expect(result.steps.map(\.setupTarget) == [.homebrew])
        #expect(result.steps.map(\.title) == ["Set up Homebrew"])
    }

    @Test func macportsAddsCLTWhenMissing() {
        let result = plan(.macports, clt: false)
        #expect(result.steps.map(\.setupTarget) == [.commandLineTools, .macports])
        #expect(result.steps.map(\.title) == ["Install Apple's Command Line Tools", "Set up MacPorts"])
        #expect(result.steps.map(\.dependsOnPrevious) == [false, true])
    }

    @Test func macportsSkipsCLTWhenPresent() {
        let result = plan(.macports, clt: true)
        #expect(result.steps.map(\.setupTarget) == [.macports])
        #expect(result.steps.map(\.dependsOnPrevious) == [false])
    }

    @Test func nanobrewAddsInit() {
        let result = plan(.nanobrew)
        #expect(result.steps.count == 2)
        #expect(result.steps[0].setupTarget == .nanobrew)
        let initStep = result.steps[1]
        #expect(initStep.engine == .nanobrew)
        #expect(initStep.setupTarget == nil)
        #expect(initStep.spec.executable.path == "/opt/nanobrew/prefix/bin/nb")
        #expect(initStep.spec.arguments == ["init"])
        #expect(initStep.spec.needsRoot)
        #expect(initStep.dependsOnPrevious)
        #expect(initStep.title == "Run nb init")
        #expect(RunRouting.route(for: initStep) == .sudoAskpass)
    }

    @Test func masViaHomebrew() throws {
        let statuses: [EngineID: EngineStatus] = [.homebrew: Self.present(P.brewPath),
                                                  .macports: Self.present(P.portPath)]
        let result = plan(.mas, statuses: statuses)
        #expect(result.problems.isEmpty)
        #expect(result.steps.map(\.engine) == [.homebrew])
        let step = try #require(result.steps.first)
        #expect(step.kind == .formula)
        #expect(step.operation == .install)
        #expect(step.setupTarget == nil)
        #expect(step.spec.executable.path == P.brewPath)
        #expect(step.spec.arguments == ["install", "--formula", "mas"])
        #expect(!step.spec.needsRoot)
    }

    @Test func masViaMacPortsWhenNoHomebrew() {
        let result = plan(.mas, statuses: [.macports: Self.present(P.portPath), .homebrew: .missing])
        #expect(result.steps.map(\.engine) == [.macports])
        #expect(result.steps[0].spec.arguments.contains("mas"))
    }

    @Test func masNeedsAManager() {
        let result = plan(.mas, statuses: [.homebrew: .missing])
        #expect(result.steps.isEmpty)
        #expect(result.problems == ["Set up Homebrew or MacPorts first: mas installs through one of them."])
    }

    @Test func homebrewIntelRefused() {
        let result = plan(.homebrew, host: Self.intel)
        #expect(result.steps.isEmpty)
        #expect(result.problems == ["Homebrew doesn't support Intel Macs. MacPorts does the same job."])
    }

    @Test func alreadyPresentNote() {
        let result = plan(.nanobrew, statuses: [.nanobrew: Self.present(P.nbPath)])
        #expect(result.steps.isEmpty)
        #expect(result.problems.isEmpty)
        #expect(result.notes == ["\(EngineID.nanobrew.displayName) is already set up."])
    }

    @Test func recommendedPerArch() {
        #expect(EngineSetupPlanner.recommended(host: Self.arm) == .homebrew)
        #expect(EngineSetupPlanner.recommended(host: Self.intel) == .macports)
        #expect(EngineSetupPlanner.offered(host: Self.arm).count == 4)
        #expect(EngineSetupPlanner.offered(host: Self.intel) == [.macports, .nanobrew, .mas])
    }
}
