import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/mas/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let mas = URL(fileURLWithPath: "/opt/homebrew/bin/mas")
private func ok(_ out: String, err: String = "") -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: err) }
private func ref(_ name: String, engine: EngineID = .mas, kind: PackageKind = .app) -> PackageRef {
    PackageRef(engine: engine, kind: kind, name: name)
}

private let expectedIDs = ["640199958", "899247664", "1496833156"]
private let expectedNames = ["Apple Developer", "TestFlight", "Swift Playground"]
private let expectedVersions = ["11.1.2", "4.4.0", "4.7"]

@Suite struct MasEngineTests {
    @Test func detectsVersion() async throws {
        let text = try fixture("version.txt")
        let engine = MasEngine(runner: FakeRunner([["version"]: ok(text)]), executable: mas)
        #expect(await engine.detect() == .present(path: mas, version: "7.0.0"))
    }

    @Test func detectMissingWithoutExecutable() async {
        let runner = FakeRunner([:])
        #expect(await MasEngine(runner: runner, executable: nil).detect() == .missing)
        #expect(runner.calls.isEmpty)
    }

    @Test func detectUnusableOnFailureOrBlank() async {
        let fail = MasEngine(runner: FakeRunner([["version"]: CommandResult(exitCode: 1, stdout: "7.0.0", stderr: "")]), executable: mas)
        #expect(isUnusable(await fail.detect(), at: mas))
        let blank = MasEngine(runner: FakeRunner([["version"]: ok("\n")]), executable: mas)
        #expect(isUnusable(await blank.detect(), at: mas))
    }

    @Test func parsesSearch() async throws {
        let text = try fixture("search.json")
        let engine = MasEngine(runner: FakeRunner([["search", "--json", "xcode"]: ok(text)]), executable: mas)
        let found = try await engine.search("xcode")
        #expect(found.map(\.id.name) == expectedIDs)
        #expect(found.map(\.displayName) == expectedNames)
        #expect(found.map(\.latestVersion) == expectedVersions)
        #expect(found.allSatisfy { $0.id.engine == .mas && $0.id.kind == .app })
    }

    // Not a capture: the real fixture's `name` equals its `censoredName`, so this record makes them differ.
    @Test func displayNamePrefersName() async throws {
        let lines = [
            #"{"adamID":1,"name":"Name","trackName":"Track","censoredName":"Censored","version":"1"}"#,
            #"{"adamID":2,"trackName":"Track","censoredName":"Censored","version":"1"}"#,
            #"{"adamID":3,"censoredName":"Censored","version":"1"}"#,
            #"{"adamID":4,"version":"1"}"#,
        ].joined(separator: "\n")
        let engine = MasEngine(runner: FakeRunner([["search", "--json", "x"]: ok(lines)]), executable: mas)
        #expect(try await engine.search("x").map(\.displayName) == ["Name", "Track", "Censored", "4"])
    }

    @Test func searchQueryStartingWithDashGetsSeparator() async throws {
        let runner = FakeRunner([["search", "--json", "--", "-x"]: ok("")])
        let engine = MasEngine(runner: runner, executable: mas)
        #expect(try await engine.search("-x").isEmpty)
        #expect(runner.calls == [["search", "--json", "--", "-x"]])
    }

    @Test func noMatchIsEmpty() async throws {
        let err = try fixture("search-nomatch-stderr.txt")
        let runner = FakeRunner([["search", "--json", "ripgrep"]: CommandResult(exitCode: 1, stdout: "", stderr: err)])
        #expect(try await MasEngine(runner: runner, executable: mas).search("ripgrep").isEmpty)
    }

    @Test func otherExit1StillThrows() async {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: "Error: not signed in")
        let engine = MasEngine(runner: FakeRunner([["search", "--json", "x"]: bad]), executable: mas)
        await #expect(throws: EngineError.self) { _ = try await engine.search("x") }
    }

    @Test func searchRejectsEmptyQuery() async {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        await #expect(throws: EngineError.self) { _ = try await engine.search("  ") }
    }

    @Test func parsesList() async throws {
        let text = try fixture("list.json") // real `mas list --json` capture, mas 7.0.0
        let engine = MasEngine(runner: FakeRunner([["list", "--json"]: ok(text)]), executable: mas)
        let apps = try await engine.listInstalled()
        #expect(apps.map(\.id.name) == ["1176074088"])
        #expect(apps.map(\.displayName) == ["Termius"])
        #expect(apps.map(\.installedVersion) == ["10.4.1"])
    }

    /// Input is the real list.json capture with the `"adamID":1176074088,` key removed, plus the intact record.
    @Test func listSkipsRecordWithoutAdamID() async throws {
        let text = try fixture("list.json")
        let stripped = text.replacingOccurrences(of: "\"adamID\":1176074088,", with: "")
        #expect(stripped != text)
        let engine = MasEngine(runner: FakeRunner([["list", "--json"]: ok(stripped + "\n" + text)]), executable: mas)
        let apps = try await engine.listInstalled()
        #expect(apps.map(\.id.name) == ["1176074088"])
    }

    @Test func emptyListIsEmpty() async throws {
        let text = try fixture("list-empty.txt")
        let warning = "Warning: No installed apps found\n"
        let engine = MasEngine(runner: FakeRunner([["list", "--json"]: ok(text, err: warning)]), executable: mas)
        #expect(try await engine.listInstalled().isEmpty)
    }

    /// outdated.json is a real capture of `mas outdated --json` with nothing outdated: empty stdout.
    @Test func parsesOutdated() async throws {
        let text = try fixture("outdated.json")
        let engine = MasEngine(runner: FakeRunner([["outdated", "--json"]: ok(text)]), executable: mas)
        #expect(try await engine.listOutdated().isEmpty)
    }

    /// DERIVED input, not a capture: the real list.json record (mas 7.0.0) with `"newVersion":"99.0"` appended,
    /// which is the shape mas 7's OutdatedApp gives (the installed app's JSON plus `newVersion`). No real
    /// `mas outdated --json` with an outdated app has been captured yet.
    @Test func outdatedMapsInstalledVersionAndNewVersion() async throws {
        let line = try fixture("list.json").trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(line.hasSuffix("}"))
        let derived = String(line.dropLast()) + ",\"newVersion\":\"99.0\"}"
        let engine = MasEngine(runner: FakeRunner([["outdated", "--json"]: ok(derived + "\n")]), executable: mas)
        let apps = try await engine.listOutdated()
        #expect(apps.map(\.id) == [ref("1176074088")])
        #expect(apps.map(\.displayName) == ["Termius"])
        #expect(apps.map(\.installedVersion) == ["10.4.1"])
        #expect(apps.map(\.latestVersion) == ["99.0"])
    }

    @Test func emptyOutdatedIsEmpty() async throws {
        let engine = MasEngine(runner: FakeRunner([["outdated", "--json"]: ok("", err: "Warning: No installed apps found\n")]), executable: mas)
        #expect(try await engine.listOutdated().isEmpty)
    }

    @Test func nonZeroExitThrowsWithStderr() async {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: "Error: not signed in")
        let engine = MasEngine(runner: FakeRunner([["list", "--json"]: bad]), executable: mas)
        do {
            _ = try await engine.listInstalled()
            Issue.record("expected throw")
        } catch let e as EngineError {
            #expect(e.engine == .mas)
            #expect(e.message.contains("not signed in"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func malformedLineThrows() async {
        let engine = MasEngine(runner: FakeRunner([["outdated", "--json"]: ok("{\"adamID\":1,\"censoredName\":\"A\",\"version\":\"1\"}\nnot json\n")]), executable: mas)
        await #expect(throws: EngineError.self) { _ = try await engine.listOutdated() }
    }

    @Test func idsAreArgvAsIs() throws {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        let spec = try engine.command(for: .install, [ref("640199958")], options: InstallOptions())
        #expect(spec == CommandSpec(executable: mas, arguments: ["install", "640199958"], needsRoot: true))
        let up = try engine.command(for: .upgrade, [ref("1"), ref("2")], options: InstallOptions())
        #expect(up.arguments == ["upgrade", "1", "2"])
        let rm = try engine.command(for: .remove, [ref("3")], options: InstallOptions())
        #expect(rm.arguments == ["uninstall", "3"])
    }

    @Test func masRejectsExtraArgs() throws {
        // mas commands run as root, so no extra arguments are allowed.
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        #expect(throws: EngineError.self) {
            try engine.command(for: .install, [ref("5")], options: InstallOptions(extraArgs: ["--force"]))
        }
        #expect(throws: EngineError.self) {
            try engine.command(for: .upgrade, [ref("5")], options: InstallOptions(extraArgs: ["-s"]))
        }
    }

    @Test func commandRejectsBadInput() {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        #expect(throws: EngineError.self) { try engine.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try engine.command(for: .install, [ref("1", engine: .homebrew)], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try engine.command(for: .install, [ref("-1")], options: InstallOptions()) }
        #expect(throws: EngineError.self) { try engine.command(for: .install, [ref("1")], options: InstallOptions(version: "1.0")) }
        #expect(throws: EngineError.self) { try engine.command(for: .install, [ref("1")], options: InstallOptions(variants: ["x"])) }
        #expect(throws: EngineError.self) { try MasEngine(runner: FakeRunner([:]), executable: nil).command(for: .install, [ref("1")], options: InstallOptions()) }
    }

    @Test func nonNumericIdsRejected() {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        for bad in ["abc", "12a", "1 2", "١٢", "+1", "1.0"] {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(bad)") { try engine.command(for: op, [ref(bad)], options: InstallOptions()) }
            }
            #expect(throws: EngineError.self, "\(bad)") { try engine.command(for: .install, [ref("1"), ref(bad)], options: InstallOptions()) }
        }
    }

    @Test func privilegeMatchesSpike() throws {
        let engine = MasEngine(runner: FakeRunner([:]), executable: mas)
        #expect(engine.capabilities == [.jsonOutput])
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, ref("1")) == .always)
            let spec = try engine.command(for: op, [ref("1")], options: InstallOptions())
            #expect(spec.needsRoot == true)
        }
    }
}

// MARK: info

@Suite struct MasInfoTests {
    @Test func infoFromCapture() async throws {
        let runner = FakeRunner([["info", "--json", "1176074088"]: ok(try fixture("info.json"))])
        let e = MasEngine(runner: runner, executable: mas)
        let d = try await e.info(ref("1176074088"))
        #expect(runner.calls == [["info", "--json", "1176074088"]])
        #expect(d.ref == ref("1176074088"))
        #expect(d.latestVersion == "10.4.1")
        #expect(d.installedVersion == nil)
        #expect(d.homepage == URL(string: "https://apps.apple.com/us/app/termius-ssh-client-terminal/id1176074088?mt=12&uo=4"))
        #expect(d.summary?.hasPrefix("Termius is a modern SSH client designed for productivity and collaboration.") == true)
        #expect(d.summary?.contains("\n") == false)
        #expect(d.dependencies == nil)
        #expect(d.variants.isEmpty)
        #expect(d.installerNeedsRoot == nil)
    }

    @Test func infoFailsOnUnreadableOutput() async {
        for result in [ok(""), ok("App Termius\n"), ok("[]"), ok("{}"),
                       CommandResult(exitCode: 1, stdout: "", stderr: "Error: no app")] {
            let e = MasEngine(runner: FakeRunner([["info", "--json", "1176074088"]: result]), executable: mas)
            await #expect(throws: EngineError.self) { try await e.info(ref("1176074088")) }
        }
    }

    @Test func infoRejectsNonNumericIDsWithoutRunning() async {
        let runner = FakeRunner([:])
        let e = MasEngine(runner: runner, executable: mas)
        for name in ["--evil", "12ab", "Termius", ""] {
            await #expect(throws: EngineError.self) { try await e.info(ref(name)) }
        }
        await #expect(throws: EngineError.self) { try await e.info(ref("1176074088", engine: .homebrew)) }
        #expect(runner.calls.isEmpty)
    }
}
