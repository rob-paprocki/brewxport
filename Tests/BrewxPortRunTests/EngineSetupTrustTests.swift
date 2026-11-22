import Foundation
import Testing
@testable import BrewxPortRun

@Suite struct EngineSetupTrustTests {
    static func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/setup/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func homebrewPkgTrusted() throws {
        let verdict = EngineSetupTrust.pkgVerdict(target: .homebrew,
                                                  pkgutil: try Self.fixture("pkgutil-homebrew.txt"),
                                                  spctl: try Self.fixture("spctl-homebrew.txt"))
        #expect(verdict == nil)
    }

    @Test func homebrewWrongTeamRefused() throws {
        let pkgutil = try Self.fixture("pkgutil-homebrew.txt")
            .replacingOccurrences(of: EngineSetupTrust.homebrewTeamID, with: "AAAAAAAAAA")
        let verdict = EngineSetupTrust.pkgVerdict(target: .homebrew, pkgutil: pkgutil,
                                                  spctl: try Self.fixture("spctl-homebrew.txt"))
        guard case .verification = verdict else { Issue.record("expected verification, got \(String(describing: verdict))"); return }
    }

    @Test func homebrewMissingTeamRefused() throws {
        let verdict = EngineSetupTrust.pkgVerdict(target: .homebrew, pkgutil: "Package \"x.pkg\":\n   Status: no signature\n",
                                                  spctl: try Self.fixture("spctl-homebrew.txt"))
        guard case .verification = verdict else { Issue.record("expected verification"); return }
    }

    @Test func notNotarizedRefused() throws {
        let spctl = "Homebrew.pkg: rejected\nsource=Unnotarized Developer ID\n"
        let verdict = EngineSetupTrust.pkgVerdict(target: .homebrew,
                                                  pkgutil: try Self.fixture("pkgutil-homebrew.txt"), spctl: spctl)
        guard case .verification = verdict else { Issue.record("expected verification"); return }
    }

    @Test func acceptedWithoutNotarizationRefused() throws {
        let spctl = "MacPorts.pkg: accepted\nsource=Developer ID\n"
        let verdict = EngineSetupTrust.pkgVerdict(target: .macports,
                                                  pkgutil: try Self.fixture("pkgutil-macports.txt"), spctl: spctl)
        guard case .verification = verdict else { Issue.record("expected verification"); return }
    }

    /// Replaces the first (`Package "..."`) line of a pkgutil capture.
    static func withPackageLine(_ pkgutil: String, _ line: String) -> String {
        var lines = pkgutil.components(separatedBy: "\n")
        lines[0] = line
        return lines.joined(separator: "\n")
    }

    @Test func hostileFileNameCannotSupplyTeam() throws {
        let swapped = try Self.fixture("pkgutil-homebrew.txt")
            .replacingOccurrences(of: EngineSetupTrust.homebrewTeamID, with: "AAAAAAAAAA")
        let hostile = Self.withPackageLine(swapped,
            "Package \"Developer ID Installer: x (\(EngineSetupTrust.homebrewTeamID)).pkg\":")
        let verdict = EngineSetupTrust.pkgVerdict(target: .homebrew, pkgutil: hostile,
                                                  spctl: try Self.fixture("spctl-homebrew.txt"))
        guard case .verification = verdict else { Issue.record("expected verification"); return }
    }

    @Test func hostileFileNameCannotSupplyNotarization() throws {
        let stripped = try Self.fixture("pkgutil-macports.txt")
            .replacingOccurrences(of: "   Notarization: trusted by the Apple notary service\n", with: "")
        let hostile = Self.withPackageLine(stripped,
            "Package \"Notarization: trusted by the Apple notary service.pkg\":")
        let verdict = EngineSetupTrust.pkgVerdict(target: .macports, pkgutil: hostile,
                                                  spctl: try Self.fixture("spctl-macports.txt"))
        guard case .verification = verdict else { Issue.record("expected verification"); return }
    }

    @Test func sha256AcrossChunkBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-big-\(UUID().uuidString)")
        try (Data(count: 1_048_576) + Data("hello".utf8)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Computed independently: (head -c 1048576 /dev/zero; printf hello) | shasum -a 256
        #expect(try EngineSetupTrust.sha256(of: url) == "cb19a49528518518ad13dad3787b92cbc544fbf743287e11fc7e377d85851d42")
    }

    @Test func macportsTeamNotPinned() throws {
        let verdict = EngineSetupTrust.pkgVerdict(target: .macports,
                                                  pkgutil: try Self.fixture("pkgutil-macports.txt"),
                                                  spctl: try Self.fixture("spctl-macports.txt"))
        #expect(verdict == nil)
    }

    @Test func cltLabelFound() throws {
        let label = CommandLineTools.label(fromSoftwareUpdateList: try Self.fixture("softwareupdate-list-clt.txt"))
        #expect(label == "Command Line Tools for Xcode-16.4")
    }

    @Test func cltLabelComparesNumerically() {
        let text = "* Label: Command Line Tools for Xcode-16.10\n* Label: Command Line Tools for Xcode-16.9\n"
        #expect(CommandLineTools.label(fromSoftwareUpdateList: text) == "Command Line Tools for Xcode-16.10")
    }

    @Test func cltLabelMissing() throws {
        #expect(CommandLineTools.label(fromSoftwareUpdateList: try Self.fixture("softwareupdate-list-none.txt")) == nil)
    }

    @Test func sha256OfKnownFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try EngineSetupTrust.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func homebrewUserPlistRoundTrips() throws {
        let data = try HomebrewPkgUser.plist(user: "tester")
        let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        #expect(decoded == ["HOMEBREW_PKG_USER": "tester"])
    }
}
