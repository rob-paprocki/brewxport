import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/nanobrew/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let nb = URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }
private func ref(_ name: String, engine: EngineID = .nanobrew, kind: PackageKind = .formula) -> PackageRef {
    PackageRef(engine: engine, kind: kind, name: name)
}

@Suite struct NanobrewEngineTests {
    private func engine(_ responses: [[String]: CommandResult] = [:]) -> (NanobrewEngine, FakeRunner) {
        let runner = FakeRunner(responses)
        return (NanobrewEngine(runner: runner, executable: nb), runner)
    }

    @Test func detectsVersionFromHelp() async throws {
        let (e, runner) = engine([["help"]: ok(try fixture("version.txt"))])
        #expect(await e.detect() == .present(path: nb, version: "0.1.216"))
        #expect(runner.calls == [["help"]])
    }

    @Test func detectMissingWithoutExecutable() async {
        let runner = FakeRunner([:])
        #expect(await NanobrewEngine(runner: runner, executable: nil).detect() == .missing)
        #expect(runner.calls.isEmpty)
    }

    @Test func detectUnusableOnFailureOrGarbage() async {
        let (failing, _) = engine([["help"]: CommandResult(exitCode: 1, stdout: "nanobrew v0.1.216\n", stderr: "")])
        #expect(isUnusable(await failing.detect(), at: nb))
        let (garbage, _) = engine([["help"]: ok("usage: something else\n")])
        #expect(isUnusable(await garbage.detect(), at: nb))
        let (empty, _) = engine([["help"]: ok("")])
        #expect(isUnusable(await empty.detect(), at: nb))
    }

    @Test func parsesSearch() async throws {
        let (e, runner) = engine([["search", "--json", "ripgrep"]: ok(try fixture("search.json"))])
        let found = try await e.search("ripgrep")
        #expect(runner.calls == [["search", "--json", "ripgrep"]])
        #expect(found.map(\.id.name) == ["ripgrep", "ripgrep-all"])
        let rg = found[0]
        #expect(rg.id == ref("ripgrep"))
        #expect(rg.latestVersion == "15.2.0")
        #expect(rg.summary == "Search tool like grep and The Silver Searcher")
        #expect(rg.installedVersion == nil)
    }

    // nb doesn't honour `--` (it would search for "--"), and it doesn't parse the query as an option.
    @Test func searchQueryStartingWithDashHasNoSeparator() async throws {
        let (e, runner) = engine([["search", "--json", "-x"]: ok("{\"schema\":1,\"query\":\"-x\",\"packages\":[]}")])
        #expect(try await e.search("-x").isEmpty)
        #expect(runner.calls == [["search", "--json", "-x"]])
        await #expect(throws: EngineError.self) { _ = try await e.search("  ") }
    }

    @Test func parsesList() async throws {
        let (e, _) = engine([["list", "--json"]: ok(try fixture("list.json"))])
        let pkgs = try await e.listInstalled()
        #expect(pkgs.map(\.id.name) == ["figlet", "tree", "oniguruma", "jq"])
        #expect(pkgs.map(\.installedVersion) == ["2.2.5", "2.3.2", "6.9.10", "1.8.2"])
        #expect(pkgs.allSatisfy { $0.id.engine == .nanobrew && $0.id.kind == .formula && $0.latestVersion == nil })
    }

    // Inline, not a capture: the VM's list had no casks or debs. Follows docs/json-output.md.
    @Test func listKeepsCasksAndSkipsDebs() async throws {
        let json = #"{"schema":1,"packages":[{"name":"firefox","kind":"cask","version":"1.0","pinned":false},{"name":"curl","kind":"deb","version":"8.5.0-2","pinned":false}]}"#
        let (e, _) = engine([["list", "--json"]: ok(json)])
        let pkgs = try await e.listInstalled()
        #expect(pkgs.map(\.id) == [ref("firefox", kind: .cask)])
    }

    @Test func parsesOutdatedNone() async throws {
        let (e, _) = engine([["outdated", "--json"]: ok(try fixture("outdated.json"))])
        #expect(try await e.listOutdated().isEmpty)
    }

    // TODO: no real outdated entry could be produced in the VM; this inline example follows the shape in docs/json-output.md.
    @Test func parsesOutdated() async throws {
        let json = #"{"schema":1,"packages":[{"name":"node","kind":"formula","installed":"26.13.0_2","latest":"26.14.0","pinned":false,"upgrade_supported":true,"unsupported_reason":null},{"name":"tool","kind":"cask","installed":"1.0","latest":"2.0","pinned":false,"upgrade_supported":false,"unsupported_reason":"external installers cannot be rolled back"}]}"#
        let (e, _) = engine([["outdated", "--json"]: ok(json)])
        let pkgs = try await e.listOutdated()
        #expect(pkgs.map(\.id) == [ref("node"), ref("tool", kind: .cask)])
        #expect(pkgs.map(\.installedVersion) == ["26.13.0_2", "1.0"])
        #expect(pkgs.map(\.latestVersion) == ["26.14.0", "2.0"])
    }

    @Test func rejectsUnknownSchema() async {
        let v2 = ok(#"{"schema":2,"packages":[]}"#)
        let (e, _) = engine([["list", "--json"]: v2, ["outdated", "--json"]: v2, ["search", "--json", "x"]: v2])
        await #expect(throws: EngineError.self) { _ = try await e.listInstalled() }
        await #expect(throws: EngineError.self) { _ = try await e.listOutdated() }
        await #expect(throws: EngineError.self) { _ = try await e.search("x") }
    }

    private func message(_ e: NanobrewEngine) async -> String? {
        do { _ = try await e.listInstalled(); return nil } catch let err as EngineError { return err.message } catch { return nil }
    }

    @Test func unknownSchemaIsNamedWithoutUpgradeHint() async throws {
        // Schema 2 with a shape schema 1 can't decode: the schema check must come first.
        let (e, _) = engine([["list", "--json"]: ok(#"{"schema":2,"items":[{"id":1}]}"#)])
        let msg = try #require(await message(e))
        #expect(msg.contains("unsupported nanobrew output schema 2"))
        #expect(!msg.contains("0.1.216"))
    }

    @Test func schema1DecodeFailureKeepsCause() async throws {
        let (e, _) = engine([["list", "--json"]: ok(#"{"schema":1,"packages":[{"name":"tree","version":"2.3.2"}]}"#)])
        let msg = try #require(await message(e))
        #expect(msg.contains("kind"))
        #expect(!msg.contains("0.1.216"))
    }

    @Test func missingSchemaMentionsMinimumVersion() async throws {
        let (e, _) = engine([["list", "--json"]: ok(#"{"packages":[]}"#)])
        let msg = try #require(await message(e))
        #expect(msg.contains("0.1.216"))
    }

    @Test func plainTextOutputThrowsMentioningMinimumVersion() async {
        let (e, _) = engine([["list", "--json"]: ok("figlet 2.2.5\ntree 2.3.2\n")])
        do {
            _ = try await e.listInstalled()
            Issue.record("expected throw")
        } catch let err as EngineError {
            #expect(err.engine == .nanobrew)
            #expect(err.message.contains("0.1.216"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func failureAndEmptyOutput() async throws {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: "error: boom")
        let (e, _) = engine([["list", "--json"]: bad, ["outdated", "--json"]: ok("")])
        do {
            _ = try await e.listInstalled()
            Issue.record("expected throw")
        } catch let err as EngineError {
            #expect(err.message.contains("boom"))
        } catch { Issue.record("wrong error \(error)") }
        #expect(try await e.listOutdated().isEmpty)
    }

    @Test func commandsPutVerbFirst() throws {
        let (e, _) = engine()
        #expect(try e.command(for: .install, [ref("tree")], options: InstallOptions())
                == CommandSpec(executable: nb, arguments: ["install", "tree"], needsRoot: false))
        #expect(try e.command(for: .upgrade, [ref("a"), ref("b")], options: InstallOptions()).arguments == ["upgrade", "a", "b"])
        #expect(try e.command(for: .remove, [ref("a")], options: InstallOptions()).arguments == ["remove", "a"])
        #expect(try e.command(for: .install, [ref("a")], options: InstallOptions(extraArgs: ["--x"])).arguments == ["install", "--x", "a"])
    }

    @Test func caskFlag() throws {
        let (e, _) = engine()
        let c = ref("firefox", kind: .cask)
        #expect(try e.command(for: .install, [c], options: InstallOptions()).arguments == ["install", "--cask", "firefox"])
        #expect(try e.command(for: .remove, [c], options: InstallOptions()).arguments == ["remove", "--cask", "firefox"])
        #expect(try e.command(for: .upgrade, [c], options: InstallOptions(extraArgs: ["--x"])).arguments == ["upgrade", "--cask", "--x", "firefox"])
    }

    @Test func neverRootItself() throws {
        let (e, _) = engine()
        #expect(e.id == .nanobrew)
        #expect(e.capabilities == [.casks, .jsonOutput])
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(e.privilege(for: op, ref("tree")) == .never)
            #expect(e.privilege(for: op, ref("firefox", kind: .cask)) == .sometimes)
            #expect(try e.command(for: op, [ref("tree")], options: InstallOptions()).needsRoot == false)
            #expect(try e.command(for: op, [ref("firefox", kind: .cask)], options: InstallOptions()).needsRoot == false)
        }
    }

    @Test func commandRejectsBadInput() {
        let (e, _) = engine()
        #expect(throws: EngineError.self) { try e.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a", engine: .homebrew)], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("-a")], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a")], options: InstallOptions(version: "1.0")) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a")], options: InstallOptions(variants: ["+x"])) }
        #expect(throws: EngineError.self) { try e.command(for: .install, [ref("a"), ref("b", kind: .cask)], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try NanobrewEngine(runner: FakeRunner([:]), executable: nil).command(for: .install, [ref("a")], options: InstallOptions()) }
    }
}

// MARK: info

@Suite struct NanobrewInfoTests {
    private func engine(_ argv: [String], _ fixtureName: String) throws -> (NanobrewEngine, FakeRunner) {
        let runner = FakeRunner([argv: ok(try fixture(fixtureName))])
        return (NanobrewEngine(runner: runner, executable: nb), runner)
    }

    @Test func infoFromCapture() async throws {
        let (e, runner) = try engine(["info", "--json", "ripgrep"], "info-ripgrep.json")
        let d = try await e.info(ref("ripgrep"))
        #expect(runner.calls == [["info", "--json", "ripgrep"]])
        #expect(d.ref == ref("ripgrep"))
        #expect(d.summary == "Search tool like grep and The Silver Searcher")
        #expect(d.homepage == URL(string: "https://github.com/BurntSushi/ripgrep"))
        #expect(d.latestVersion == "15.2.0")
        #expect(d.installedVersion == nil)
        // The capture says "dependencies": [], so the engine does say: none.
        #expect(d.dependencies == [])
        #expect(d.variants.isEmpty)
        #expect(d.installerNeedsRoot == nil)
    }

    /// nb's JSON carries cask artifacts, so the answer comes from the capture: a pkg artifact needs root.
    @Test func infoCaskPkgNeedsRoot() async throws {
        let (e, runner) = try engine(["info", "--cask", "--json", "blackhole-2ch"], "info-cask-blackhole-2ch.json")
        let d = try await e.info(ref("blackhole-2ch", kind: .cask))
        #expect(runner.calls == [["info", "--cask", "--json", "blackhole-2ch"]])
        #expect(d.summary == "Virtual Audio Driver")
        #expect(d.homepage == URL(string: "https://existential.audio/blackhole/"))
        #expect(d.latestVersion == "0.7.1")
        #expect(d.dependencies == nil)
        #expect(d.installerNeedsRoot == true)
    }

    @Test func infoCaskAppOnlyDoesntNeedRoot() async throws {
        let (e, _) = try engine(["info", "--cask", "--json", "firefox"], "info-cask-firefox.json")
        let d = try await e.info(ref("firefox", kind: .cask))
        #expect(d.summary == "Web browser")
        #expect(d.latestVersion == "160.0.1")
        #expect(d.installerNeedsRoot == false)
    }

    @Test func infoLeavesInstallerUnknownWithoutArtifacts() async throws {
        // The ripgrep capture re-labelled as a cask: no "artifacts" key, so nb says nothing about root.
        let text = try fixture("info-ripgrep.json").replacingOccurrences(of: "\"kind\":\"formula\"", with: "\"kind\":\"cask\"")
        let e = NanobrewEngine(runner: FakeRunner([["info", "--cask", "--json", "ripgrep"]: ok(text)]), executable: nb)
        let d = try await e.info(ref("ripgrep", kind: .cask))
        #expect(d.installerNeedsRoot == nil)
    }

    @Test func infoFailsOnUnreadableOutput() async {
        let argv = ["info", "--json", "ripgrep"]
        for result in [ok("ripgrep 15.2.0\n"), ok(#"{"schema":2,"packages":[]}"#), ok(#"{"schema":1,"packages":[]}"#), ok(""),
                       CommandResult(exitCode: 1, stdout: "", stderr: "not found")] {
            let e = NanobrewEngine(runner: FakeRunner([argv: result]), executable: nb)
            await #expect(throws: EngineError.self) { try await e.info(ref("ripgrep")) }
        }
    }

    @Test func infoRejectsBadNamesAndKindsWithoutRunning() async {
        let runner = FakeRunner([:])
        let e = NanobrewEngine(runner: runner, executable: nb)
        await #expect(throws: EngineError.self) { try await e.info(ref("--evil")) }
        await #expect(throws: EngineError.self) { try await e.info(ref("ripgrep", kind: .port)) }
        await #expect(throws: EngineError.self) { try await e.info(ref("ripgrep", engine: .homebrew)) }
        #expect(runner.calls.isEmpty)
    }
}
