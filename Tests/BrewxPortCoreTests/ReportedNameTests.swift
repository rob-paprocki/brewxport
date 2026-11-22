import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ engine: String, _ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(engine)/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }

/// `PackageDetails.reportedName`: the name the engine itself answered with, which a move compares against the
/// package it wants (an alias must not count as the same package).
@Suite struct ReportedNameTests {
    private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    private let nb = URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
    private let port = URL(fileURLWithPath: "/opt/local/bin/port")

    @Test func homebrewAliasReportsTheFormulaItStandsFor() async throws {
        // Real `brew info --json=v2 --formula python3`: one formula, python@3.15, through the single-result fallback.
        let args = ["info", "--json=v2", "--formula", "python3"]
        let engine = HomebrewEngine(runner: FakeRunner([args: ok(try fixture("homebrew", "info-alias-python3.json"))]),
                                    executable: brew)
        let ref = PackageRef(engine: .homebrew, kind: .formula, name: "python3")
        let details = try await engine.info(ref)
        #expect(details.ref == ref)
        #expect(details.reportedName == "python@3.15")
    }

    @Test func homebrewReportsItsOwnName() async throws {
        let formula = ["info", "--json=v2", "--formula", "ripgrep"]
        let cask = ["info", "--json=v2", "--cask", "firefox"]
        let engine = HomebrewEngine(runner: FakeRunner([formula: ok(try fixture("homebrew", "info-ripgrep.json")),
                                                        cask: ok(try fixture("homebrew", "info-cask-firefox.json"))]),
                                    executable: brew)
        #expect(try await engine.info(PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")).reportedName
                == "ripgrep")
        #expect(try await engine.info(PackageRef(engine: .homebrew, kind: .cask, name: "firefox")).reportedName
                == "firefox")
    }

    @Test func nanobrewReportsItsOwnName() async throws {
        let formula = ["info", "--json", "jq"]
        let cask = ["info", "--cask", "--json", "firefox"]
        let engine = NanobrewEngine(runner: FakeRunner([formula: ok(try fixture("nanobrew", "info-jq.json")),
                                                        cask: ok(try fixture("nanobrew", "info-cask-firefox.json"))]),
                                    executable: nb)
        #expect(try await engine.info(PackageRef(engine: .nanobrew, kind: .formula, name: "jq")).reportedName == "jq")
        #expect(try await engine.info(PackageRef(engine: .nanobrew, kind: .cask, name: "firefox")).reportedName
                == "firefox")
    }

    @Test func nanobrewDoesNotResolveAliases() async throws {
        // Real `nb info --json python3`: exit 1, an empty package list and "not found" on stderr.
        let result = CommandResult(exitCode: 1, stdout: try fixture("nanobrew", "info-alias-python3.json"),
                                   stderr: try fixture("nanobrew", "info-alias-python3-stderr.txt"))
        let engine = NanobrewEngine(runner: FakeRunner([["info", "--json", "python3"]: result]), executable: nb)
        await #expect(throws: EngineError.self) {
            try await engine.info(PackageRef(engine: .nanobrew, kind: .formula, name: "python3"))
        }
    }

    @Test func macportsReportsThePortsOwnSpelling() async throws {
        let info = ["info", "--name", "--description", "--homepage", "--version", "--variants", "--depends_lib",
                    "--depends_run"]
        let engine = MacPortsEngine(runner: FakeRunner([info + ["ripgrep"]: ok(try fixture("macports", "info-ripgrep.txt")),
                                                        info + ["imagemagick"]: ok(try fixture("macports", "info-imagemagick.txt"))]),
                                    executable: port)
        #expect(try await engine.info(PackageRef(engine: .macports, kind: .port, name: "ripgrep")).reportedName
                == "ripgrep")
        let magick = try await engine.info(PackageRef(engine: .macports, kind: .port, name: "imagemagick"))
        #expect(magick.reportedName == "ImageMagick")
        #expect(magick.ref.name == "imagemagick")
    }
}

@Suite struct ConcurrentMapTests {
    /// Counts calls in flight and the most at once.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var now = 0
        private(set) var peak = 0
        func enter() { lock.withLock { now += 1; peak = max(peak, now) } }
        func leave() { lock.withLock { now -= 1 } }
    }

    @Test func atMostLimitAtOnce() async throws {
        let meter = Meter()
        let names = (0..<30).map { "p\($0)" }
        let answers = try await concurrentMap(names, limit: 6) { name -> String in
            meter.enter()
            try await Task.sleep(for: .milliseconds(5))
            meter.leave()
            return name.uppercased()
        }
        #expect(answers.count == 30)
        #expect(answers["p7"] == "P7")
        #expect(meter.peak <= 6)
        #expect(meter.peak > 1)
    }

    @Test func firstErrorEndsIt() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await concurrentMap((0..<20).map { $0 }, limit: 3) { n -> Int in
                if n == 4 { throw Boom() }
                return n
            }
        }
    }
}
