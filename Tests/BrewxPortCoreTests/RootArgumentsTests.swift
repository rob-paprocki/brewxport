import Testing
import Foundation
@testable import BrewxPortCore

struct RootArgumentsTests {
    @Test func macPortsExtraArgsAllowList() throws {
        #expect(RootArguments.macPortsExtraArgs == ["-s", "-b", "-n", "-R", "-u", "-c"])
        for flag in RootArguments.macPortsExtraArgs {
            try RootArguments.validateMacPorts(names: ["figlet"], variants: [], extraArgs: [flag])
        }
        for bad in ["-f", "--force", "-d", "-sb", "-D", "-F", "", "install"] {
            #expect(throws: EngineError.self) {
                try RootArguments.validateMacPorts(names: ["figlet"], variants: [], extraArgs: [bad])
            }
        }
    }

    @Test func errorNamesTheOffendingToken() {
        do {
            try RootArguments.validateMacPorts(names: ["figlet"], variants: [], extraArgs: ["-s", "--force"])
            Issue.record("expected a throw")
        } catch let e as EngineError {
            #expect(e.engine == .macports)
            #expect(e.message.contains("--force"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test func validatesNamesAndVariants() throws {
        #expect(RootArguments.isValidPortName("gtk3"))
        #expect(RootArguments.isValidPortName("g++"))
        for bad in ["", "-f", "all", "actinact", "Installed", "ACTINACT", "a b", "a*", "name:re", "é"] {
            #expect(!RootArguments.isValidPortName(bad), "\(bad)")
        }
        #expect(RootArguments.isValidVariant("+x11"))
        #expect(RootArguments.isValidVariant("-mp_3"))
        for bad in ["x11", "+x", "+", "+a-b", "+é1"] {
            #expect(!RootArguments.isValidVariant(bad), "\(bad)")
        }
        try RootArguments.validateMacPorts(names: ["a"], variants: ["+x11"], extraArgs: [])
        #expect(throws: EngineError.self) { try RootArguments.validateMacPorts(names: ["-f"], variants: [], extraArgs: []) }
        #expect(throws: EngineError.self) { try RootArguments.validateMacPorts(names: ["a"], variants: ["+x"], extraArgs: []) }
    }

    @Test func engineRejectsDisallowedExtraArgs() {
        let e = MacPortsEngine(runner: FakeRunner([:]), executable: URL(fileURLWithPath: "/opt/local/bin/port"))
        let ref = PackageRef(engine: .macports, kind: .port, name: "figlet")
        #expect(throws: EngineError.self) {
            try e.command(for: .install, [ref], options: InstallOptions(extraArgs: ["--force"]))
        }
    }
}
