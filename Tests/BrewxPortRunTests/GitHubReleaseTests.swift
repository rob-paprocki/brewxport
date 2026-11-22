import Foundation
import Testing
import BrewxPortCore
@testable import BrewxPortRun

@Suite struct GitHubReleaseTests {
    static func fixtureText(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/setup/\(name)-release.json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func release(_ name: String) throws -> GitHubRelease {
        try GitHubRelease.decode(Data(fixtureText(name).utf8))
    }

    let apple = HostInfo(appleSilicon: true, macOSMajor: 15)
    let intel = HostInfo(appleSilicon: false, macOSMajor: 15)

    @Test func homebrewPicksHomebrewPkg() throws {
        let release = try Self.release("homebrew")
        let asset = try GitHubRelease.asset(for: .homebrew, in: release, host: apple)
        #expect(asset.name == "Homebrew.pkg")
        #expect(asset.sha256 == "af0827528fda9e8b653ac57815e1a003af588b7153749e8eb23d474afc60976c")
        #expect(asset.url.host == "github.com")
        #expect(release.tag == "7.0.15")
    }

    @Test func homebrewRefusedOnIntel() throws {
        let release = try Self.release("homebrew")
        var thrown: SetupError?
        do {
            _ = try GitHubRelease.asset(for: .homebrew, in: release, host: intel)
        } catch let error as SetupError {
            thrown = error
        }
        guard case .unsupportedHost = thrown else {
            Issue.record("expected unsupportedHost, got \(String(describing: thrown))")
            return
        }
    }

    @Test func macportsPicksThisMacOS() throws {
        let release = try Self.release("macports")
        let sequoia = try GitHubRelease.asset(for: .macports, in: release, host: HostInfo(appleSilicon: true, macOSMajor: 15))
        #expect(sequoia.name == "MacPorts-2.12.7-15-Sequoia.pkg")
        let golden = try GitHubRelease.asset(for: .macports, in: release, host: HostInfo(appleSilicon: true, macOSMajor: 27))
        #expect(golden.name == "MacPorts-2.12.7-27-GoldenGate.pkg")
    }

    @Test func macportsNoAssetForNewMacOS() throws {
        let release = try Self.release("macports")
        #expect(throws: SetupError.noAsset("MacPorts has no installer for macOS 28 yet")) {
            try GitHubRelease.asset(for: .macports, in: release, host: HostInfo(appleSilicon: true, macOSMajor: 28))
        }
    }

    @Test func nanobrewPicksArch() throws {
        let release = try Self.release("nanobrew")
        let arm = try GitHubRelease.asset(for: .nanobrew, in: release, host: apple)
        #expect(arm.name == "nb-arm64-apple-darwin.tar.gz")
        let x86 = try GitHubRelease.asset(for: .nanobrew, in: release, host: intel)
        #expect(x86.name == "nb-x86_64-apple-darwin.tar.gz")
    }

    @Test func offListHostDropsOnlyThatAsset() throws {
        let text = try Self.fixtureText("nanobrew")
        let full = try GitHubRelease.decode(Data(text.utf8))
        let changed = text.replacingOccurrences(
            of: "\"https://github.com/justrach/nanobrew/releases/download/v0.1.216/nb-x86_64-linux.tar.gz\"",
            with: "\"https://example.com/justrach/nanobrew/releases/download/v0.1.216/nb-x86_64-linux.tar.gz\"")
        #expect(changed != text)
        let release = try GitHubRelease.decode(Data(changed.utf8))
        #expect(release.assets.map(\.name) == full.assets.map(\.name).filter { $0 != "nb-x86_64-linux.tar.gz" })
        #expect(try GitHubRelease.asset(for: .nanobrew, in: release, host: apple).name == "nb-arm64-apple-darwin.tar.gz")
    }

    @Test func offListHostOnTheNeededAssetFailsClosed() throws {
        let text = try Self.fixtureText("homebrew")
        let changed = text.replacingOccurrences(of: "https://github.com/Homebrew/brew/releases/download/7.0.15/Homebrew.pkg",
                                                with: "https://example.com/Homebrew/brew/releases/download/7.0.15/Homebrew.pkg")
        #expect(changed != text)
        let release = try GitHubRelease.decode(Data(changed.utf8))
        #expect(release.assets.isEmpty)
        #expect(throws: SetupError.noAsset("The Homebrew release has no installer package")) {
            try GitHubRelease.asset(for: .homebrew, in: release, host: apple)
        }
    }

    @Test func plainHttpAssetDropped() throws {
        let text = try Self.fixtureText("homebrew")
        let changed = text.replacingOccurrences(of: "\"https://github.com/Homebrew/brew/releases/download",
                                                with: "\"http://github.com/Homebrew/brew/releases/download")
        #expect(changed != text)
        let release = try GitHubRelease.decode(Data(changed.utf8))
        #expect(release.assets.isEmpty)
        #expect(throws: SetupError.noAsset("The Homebrew release has no installer package")) {
            try GitHubRelease.asset(for: .homebrew, in: release, host: apple)
        }
    }

    @Test func assetsWithoutSha256DigestAreDropped() throws {
        let text = try Self.fixtureText("homebrew")
        let changed = text.replacingOccurrences(of: "\"digest\":\"sha256:", with: "\"digest\":\"md5:")
        #expect(changed != text)
        let release = try GitHubRelease.decode(Data(changed.utf8))
        #expect(release.assets.isEmpty)
    }

    @Test func targetsKnowTheirRepoAndEngine() {
        #expect(SetupTarget.commandLineTools.repo == nil)
        #expect(SetupTarget.commandLineTools.engine == nil)
        #expect(SetupTarget.homebrew.repo == "Homebrew/brew")
        #expect(SetupTarget.macports.repo == "macports/macports-base")
        #expect(SetupTarget.nanobrew.repo == "justrach/nanobrew")
        #expect(SetupTarget.macports.engine == .macports)
    }
}
