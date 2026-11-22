import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ engine: String, _ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(engine)/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
private let port = URL(fileURLWithPath: "/opt/local/bin/port")
private let nb = URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
private let mas = URL(fileURLWithPath: "/opt/homebrew/bin/mas")
private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }
private func ref(_ engine: EngineID, _ kind: PackageKind, _ name: String) -> PackageRef {
    PackageRef(engine: engine, kind: kind, name: name)
}

@Suite struct DependentsTests {
    // MARK: Homebrew

    @Test func homebrewDependentsFromFixture() async throws {
        let runner = FakeRunner([["uses", "--installed", "openssl@4"]: ok(try fixture("homebrew", "uses-installed-openssl.txt"))])
        let engine = HomebrewEngine(runner: runner, executable: brew)
        #expect(try await engine.installedDependents(of: "openssl@4") == ["wget"])
        #expect(runner.calls == [["uses", "--installed", "openssl@4"]])
    }

    @Test func homebrewNoDependents() async throws {
        let runner = FakeRunner([["uses", "--installed", "wget"]: ok(try fixture("homebrew", "uses-installed-none.txt"))])
        let engine = HomebrewEngine(runner: runner, executable: brew)
        #expect(try await engine.installedDependents(of: "wget").isEmpty)
    }

    @Test func homebrewDependentsThrowOnFailure() async {
        let runner = FakeRunner([["uses", "--installed", "x"]: CommandResult(exitCode: 1, stdout: "", stderr: "boom")])
        let engine = HomebrewEngine(runner: runner, executable: brew)
        await #expect(throws: EngineError.self) { try await engine.installedDependents(of: "x") }
    }

    // MARK: MacPorts

    @Test func macportsDependentsFromFixture() async throws {
        let runner = FakeRunner([["-q", "dependents", "zlib"]: ok(try fixture("macports", "dependents-zlib.txt"))])
        let engine = MacPortsEngine(runner: runner, executable: port)
        #expect(try await engine.installedDependents(of: "zlib") == ["libmagic", "nano", "zstd"])
    }

    @Test func macportsNoDependents() async throws {
        let runner = FakeRunner([["-q", "dependents", "nano"]: ok(try fixture("macports", "dependents-none.txt"))])
        let engine = MacPortsEngine(runner: runner, executable: port)
        #expect(try await engine.installedDependents(of: "nano").isEmpty)
    }

    @Test func macportsDependentsThrowWhenNotInstalled() async throws {
        let err = try fixture("macports", "dependents-notinstalled-stderr.txt")
        let runner = FakeRunner([["-q", "dependents", "pcre2"]: CommandResult(exitCode: 1, stdout: "", stderr: err)])
        let engine = MacPortsEngine(runner: runner, executable: port)
        await #expect(throws: EngineError.self) { try await engine.installedDependents(of: "pcre2") }
    }

    // MARK: nanobrew

    private static func emptyDeps(_ name: String) -> String {
        "{\"schema\":1,\"name\":\"\(name)\",\"dependencies\":[]}"
    }

    private func healthyNanobrew() throws -> [[String]: CommandResult] {
        [
            ["list", "--json"]: ok(try fixture("nanobrew", "list-chain.json")),
            ["deps", "--json", "figlet"]: ok(Self.emptyDeps("figlet")),
            ["deps", "--json", "tree"]: ok(Self.emptyDeps("tree")),
            ["deps", "--json", "jq"]: ok(try fixture("nanobrew", "deps-jq.json")),
            ["deps", "--json", "oniguruma"]: ok(Self.emptyDeps("oniguruma")),
        ]
    }

    private func nanobrewEngine(_ responses: [[String]: CommandResult]) -> NanobrewEngine {
        NanobrewEngine(runner: FakeRunner(responses), executable: nb)
    }

    @Test func nanobrewDependentsFromDeps() async throws {
        let engine = nanobrewEngine(try healthyNanobrew())
        #expect(try await engine.installedDependents(of: "oniguruma") == ["jq"])
        #expect(try await engine.installedDependents(of: "ONIGURUMA") == ["jq"])
        #expect(try await engine.installedDependents(of: "jq").isEmpty)
    }

    @Test func nanobrewMapFromOneScan() async throws {
        let runner = FakeRunner(try healthyNanobrew())
        let engine = NanobrewEngine(runner: runner, executable: nb)
        let map = try await engine.installedDependentsMap(callTimeout: .seconds(7))
        #expect(map == ["oniguruma": ["jq"]])
        // One list and one deps per installed formula, each with the call timeout.
        #expect(runner.calls.count == 5)
        #expect(runner.calls.filter { $0.first == "list" }.count == 1)
        #expect(runner.optionsCalls.allSatisfy { $0.timeout == .seconds(7) })
    }

    @Test func nanobrewMapFailsClosed() async throws {
        var failing = try healthyNanobrew()
        failing[["deps", "--json", "figlet"]] = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        await #expect(throws: EngineError.self) {
            try await nanobrewEngine(failing).installedDependentsMap(callTimeout: nil)
        }
        var noList = try healthyNanobrew()
        noList[["list", "--json"]] = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        await #expect(throws: EngineError.self) {
            try await nanobrewEngine(noList).installedDependentsMap(callTimeout: nil)
        }
    }

    @Test func nanobrewDependentsFailClosed() async throws {
        let healthy = try healthyNanobrew()
        var failing = healthy
        failing[["deps", "--json", "tree"]] = CommandResult(exitCode: 1, stdout: "", stderr: "boom")
        await #expect(throws: EngineError.self) {
            try await nanobrewEngine(failing).installedDependents(of: "oniguruma")
        }
        var garbled = healthy
        garbled[["deps", "--json", "tree"]] = ok("{\"schema\":1,\"name\":\"tree\"}")
        await #expect(throws: EngineError.self) {
            try await nanobrewEngine(garbled).installedDependents(of: "oniguruma")
        }
        var text = healthy
        text[["deps", "--json", "tree"]] = ok("tree has no dependencies\n")
        await #expect(throws: EngineError.self) {
            try await nanobrewEngine(text).installedDependents(of: "oniguruma")
        }
    }

    // MARK: marks

    @Test func homebrewMarkCommands() throws {
        let engine = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        let wget = [ref(.homebrew, .formula, "wget")]
        let on = try engine.command(for: .markRequested, wget, options: InstallOptions())
        #expect(on.arguments == ["tab", "--installed-on-request", "wget"])
        #expect(on.needsRoot == false)
        let off = try engine.command(for: .markDependency, wget, options: InstallOptions())
        #expect(off.arguments == ["tab", "--no-installed-on-request", "wget"])
        #expect(off.needsRoot == false)
        #expect(engine.privilege(for: .markRequested, wget[0]) == .never)
        #expect(throws: EngineError.self) {
            try engine.command(for: .markRequested, [ref(.homebrew, .cask, "firefox")], options: InstallOptions())
        }
    }

    @Test func macportsMarkCommands() throws {
        let engine = MacPortsEngine(runner: FakeRunner([:]), executable: port)
        let wget = [ref(.macports, .port, "wget")]
        let on = try engine.command(for: .markRequested, wget, options: InstallOptions())
        #expect(on.arguments == ["-N", "setrequested", "wget"])
        #expect(on.needsRoot == true)
        let off = try engine.command(for: .markDependency, wget, options: InstallOptions())
        #expect(off.arguments == ["-N", "unsetrequested", "wget"])
        #expect(off.needsRoot == true)
        #expect(engine.privilege(for: .markRequested, wget[0]) == .always)
        #expect(throws: EngineError.self) {
            try engine.command(for: .markRequested, wget, options: InstallOptions(variants: ["ssl"]))
        }
    }

    @Test func nanobrewMarkThrows() {
        let engine = NanobrewEngine(runner: FakeRunner([:]), executable: nb)
        for op in [PackageOperation.markRequested, .markDependency] {
            #expect(throws: EngineError(engine: .nanobrew, message: "nanobrew can't mark packages")) {
                try engine.command(for: op, [ref(.nanobrew, .formula, "jq")], options: InstallOptions())
            }
            #expect(engine.privilege(for: op, ref(.nanobrew, .formula, "jq")) == .never)
        }
    }

    @Test func masMarkThrows() {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        for op in [PackageOperation.markRequested, .markDependency] {
            #expect(throws: EngineError.self) {
                try engine.command(for: op, [ref(.mas, .app, "497799835")], options: InstallOptions())
            }
        }
    }
}
