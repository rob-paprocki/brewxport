import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(path)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }

/// Which installed packages the user asked for, from real captures (Homebrew 7.0.15, MacPorts 2.12.7): see
/// `private/spikes/2026-11-plan4-fixtures.md`.
@Suite struct InstalledOnRequestTests {
    @Test func homebrewMarksRequestedFormulaeAndDependencies() async throws {
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: ok(try fixture("homebrew/info-installed-requested.json"))])
        let installed = try await HomebrewEngine(runner: runner, executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))
            .listInstalled()
        let flags = Dictionary(uniqueKeysWithValues: installed.map { ($0.id.name, $0.installedOnRequest) })
        // `brew install jq` pulled in oniguruma; the cask counts as asked for.
        #expect(flags["jq"] == true)
        #expect(flags["oniguruma"] == false)
        #expect(flags["rectangle"] == true)
    }

    private func macports(requested: CommandResult?) async throws -> [Package] {
        var responses = [["-v", "-q", "installed", "active"]: ok(try fixture("macports/installed-v-after.txt"))]
        if let requested { responses[["-q", "installed", "requested"]] = requested }
        return try await MacPortsEngine(runner: FakeRunner(responses),
                                        executable: URL(fileURLWithPath: "/opt/local/bin/port")).listInstalled()
    }

    @Test func macportsMarksRequestedPortsAndDependencies() async throws {
        let installed = try await macports(requested: ok(try fixture("macports/installed-requested.txt")))
        let flags = Dictionary(uniqueKeysWithValues: installed.map { ($0.id.name, $0.installedOnRequest) })
        // `port install pkgconfig` pulled in libiconv; figlet was installed earlier on request.
        #expect(flags == ["figlet": true, "pkgconfig": true, "libiconv": false])
    }

    @Test func macportsWithNothingRequestedMarksEveryPortADependency() async throws {
        let installed = try await macports(requested: ok(try fixture("macports/installed-requested-none.txt")))
        #expect(installed.count == 3)
        #expect(installed.allSatisfy { $0.installedOnRequest == false })
    }

    @Test func macportsRequestedQueryFailingLeavesItUnknown() async throws {
        let installed = try await macports(requested: CommandResult(exitCode: 1, stdout: "", stderr: "Error: boom"))
        #expect(installed.count == 3)
        #expect(installed.allSatisfy { $0.installedOnRequest == nil })
    }
}
