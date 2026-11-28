import Foundation
import Testing
@testable import BrewxPortCore

@Test func refsFromDifferentEnginesDiffer() {
    #expect(PackageRef(engine: .homebrew, kind: .formula, name: "ripgrep")
         != PackageRef(engine: .macports, kind: .port, name: "ripgrep"))
}

@Test func refRoundTripsThroughJSON() throws {
    let r = PackageRef(engine: .mas, kind: .app, name: "640199958")
    #expect(try JSONDecoder().decode(PackageRef.self, from: JSONEncoder().encode(r)) == r)
}

// MARK: - Language engines (Plan 9)

private let systemEngines: [EngineID] = [.homebrew, .nanobrew, .macports, .mas]
private let languageEngines: [EngineID] = [.npm, .pipx, .uv, .cargo, .bun, .gem, .mint]

@Test func languageEnginesHaveDisplayNames() {
    #expect(languageEngines.map(\.rawValue) == ["npm", "pipx", "uv", "cargo", "bun", "gem", "mint"])
    #expect(languageEngines.map(\.displayName) == ["npm", "pipx", "uv", "Cargo", "Bun", "RubyGems", "Mint"])
    #expect(languageEngines.allSatisfy { $0.group == .languages && $0.isLanguage })
    // Every engine is in one of the two groups, the system managers first.
    #expect(EngineID.allCases == systemEngines + languageEngines)
}

/// Post-VM fix: a package manager's name ending in "s" takes the apostrophe alone ("RubyGems' tools", never
/// "RubyGems's"), as the copy already wrote "MacPorts' uv"; every other manager's name takes "'s". R49: only managers'
/// names do; a package's name always takes "'s" ("less's Homebrew copy", `MoveSheetTextTests`, `MintEngineTests`).
@Test func possessivesOfNamesEndingInS() {
    let expected = ["Homebrew's", "nanobrew's", "MacPorts'", "Mac App Store's", "npm's", "pipx's", "uv's", "Cargo's",
                    "Bun's", "RubyGems'", "Mint's"]
    #expect(EngineID.allCases.map(\.possessive) == expected)
}

@Test func existingEnginesUnchanged() throws {
    #expect(systemEngines.map(\.rawValue) == ["homebrew", "nanobrew", "macports", "mas"])
    #expect(systemEngines.map(\.displayName) == ["Homebrew", "nanobrew", "MacPorts", "Mac App Store"])
    #expect(systemEngines.allSatisfy { $0.group == .system && !$0.isLanguage })
    #expect(Array(EngineID.allCases.prefix(4)) == systemEngines)
    // Refs stored before Plan 9 (ignored, skipped, notified, bundles) still decode as they did.
    let stored = #"[{"engine":"homebrew","kind":"formula","name":"jq"},{"engine":"mas","kind":"app","name":"1"}]"#
    #expect(try JSONDecoder().decode([PackageRef].self, from: Data(stored.utf8))
            == [PackageRef(engine: .homebrew, kind: .formula, name: "jq"),
                PackageRef(engine: .mas, kind: .app, name: "1")])
}

@Test func toolKindRoundTrips() throws {
    #expect(PackageKind.tool.rawValue == "tool")
    let ref = PackageRef(engine: .cargo, kind: .tool, name: "ripgrep")
    #expect(try JSONDecoder().decode(PackageRef.self, from: JSONEncoder().encode(ref)) == ref)
}

@Test func engineGroupsHaveSidebarTitles() {
    #expect(EngineGroup.allCases == [.system, .languages])
    #expect(EngineGroup.allCases.map(\.title) == ["Engines", "Languages"])
}

@Test func languageStubsReportNotInstalled() async throws {
    for id in languageEngines {
        let engine = NotInstalledEngine(id: id)
        let notInstalled = EngineError(engine: id, message: "\(id.displayName) isn't installed")
        let ref = PackageRef(engine: id, kind: .tool, name: "x")
        #expect(engine.id == id)
        #expect(engine.executableURL == nil)
        #expect(engine.capabilities.isEmpty)
        #expect(await engine.detect() == .missing)
        #expect(try await engine.listInstalled().isEmpty)
        #expect(try await engine.listOutdated().isEmpty)
        #expect(try await engine.search("x").isEmpty)
        #expect(engine.privilege(for: .install, ref) == .never)
        await #expect(throws: notInstalled) { try await engine.info(ref) }
        #expect(throws: notInstalled) { try engine.command(for: .install, [ref], options: InstallOptions()) }
    }
}

/// Final review: a home page from a registry (any package's author sets it) is a link only when it's a web page, an
/// `https` or `http` URL with a host. Any other scheme (an SMB share, ssh, a local file or app, another app's own
/// scheme) is dropped, so a click never hands it to the system.
@Test func webURLTakesOnlyWebPages() {
    for text in ["https://github.com/busyloop/lolcat", "http://example.com/x", "HTTPS://Example.com", " https://x.org "] {
        #expect(webURL(text) != nil, "\(text)")
    }
    #expect(webURL(" https://x.org ") == URL(string: "https://x.org"))
    for text in ["smb://attacker.example/share", "ssh://attacker.example", "file:///Applications/Calculator.app",
                 "javascript:alert(1)", "someapp://open?x=1", "mailto:someone@example.com", "git+https://github.com/x/y",
                 "git+ssh://git@github.com/x/y.git", "https://", "https:///path", "github.com/x", "", "   "] {
        #expect(webURL(text) == nil, "\(text)")
    }
    #expect(webURL(nil) == nil)
}
