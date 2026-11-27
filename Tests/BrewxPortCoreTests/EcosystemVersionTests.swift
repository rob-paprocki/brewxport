import Foundation
import Testing
@testable import BrewxPortCore

@Suite struct EcosystemVersionTests {
    /// Each pair is (lower, higher): compared both ways.
    static func expectOrder(_ pairs: [(String, String)], _ scheme: EcosystemVersion.Scheme,
                            sourceLocation: SourceLocation = #_sourceLocation) {
        for (low, high) in pairs {
            #expect(EcosystemVersion.compare(low, high, scheme: scheme) == .orderedAscending, "\(low) < \(high)",
                    sourceLocation: sourceLocation)
            #expect(EcosystemVersion.compare(high, low, scheme: scheme) == .orderedDescending, "\(high) > \(low)",
                    sourceLocation: sourceLocation)
        }
    }

    static func expectSame(_ pairs: [(String, String)], _ scheme: EcosystemVersion.Scheme,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        for (a, b) in pairs {
            #expect(EcosystemVersion.compare(a, b, scheme: scheme) == .orderedSame, "\(a) == \(b)",
                    sourceLocation: sourceLocation)
            #expect(EcosystemVersion.compare(b, a, scheme: scheme) == .orderedSame, "\(b) == \(a)",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: semver (npm, Bun, Cargo, Mint tags)

    @Test func semverOrder() {
        Self.expectOrder([("1.9", "1.10"), ("1.0.0-rc.1", "1.0.0")], .semver)
        // The SemVer 2.0.0 spec's own precedence example, plus numbers past Int64.
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0",
                     "10.0.99999999999999999999999"]
        Self.expectOrder(Array(zip(chain, chain.dropFirst())), .semver)
        Self.expectOrder([("0.65.1", "0.66.0"), ("1.2.3", "1.2.10"), ("1.0.0-rc.2", "1.0.0-rc.10")], .semver)
    }

    @Test func semverIsTolerant() {
        // Partial versions count missing parts as 0; a leading v (Mint tags) and build metadata are ignored.
        Self.expectSame([("1.2", "1.2.0"), ("1", "1.0.0"), ("v1.2.3", "1.2.3"), ("V1.2.3", "1.2.3"),
                         ("1.0.0+build.5", "1.0.0"), ("1.0.0-rc.1+abc", "1.0.0-rc.1"), ("01.2.3", "1.2.3")],
                        .semver)
        #expect(EcosystemVersion.isPrerelease("1.0.0-rc.1", scheme: .semver))
        #expect(EcosystemVersion.isPrerelease("v2.0-beta", scheme: .semver))
        #expect(!EcosystemVersion.isPrerelease("1.0.0", scheme: .semver))
        #expect(!EcosystemVersion.isPrerelease("1.0.0+build", scheme: .semver))
    }

    @Test func semverRefusesWhatIsntAVersion() {
        for text in ["", "latest", "linked", "github:x/y", "file:../x", "swift-DEVELOPMENT-SNAPSHOT-2026-01-01-a",
                     "1.2.3.4.5", "1..2", "1.2.x", "1.0.0-", "1.0.0-rc..1", "1.0.0+", "master", "-1.0.0"] {
            #expect(!EcosystemVersion.isValid(text, scheme: .semver), "\(text)")
            #expect(!EcosystemVersion.isPrerelease(text, scheme: .semver), "\(text)")
            // Never "newer" than a real version, either way round.
            #expect(EcosystemVersion.compare(text, "1.0.0", scheme: .semver) == .orderedSame, "\(text)")
            #expect(EcosystemVersion.compare("1.0.0", text, scheme: .semver) == .orderedSame, "\(text)")
        }
        for text in ["1.0.0", "v0.65.1", "1.2", "0.0.1-alpha.0", "1.0.0-x-y-z.--"] {
            #expect(EcosystemVersion.isValid(text, scheme: .semver), "\(text)")
        }
    }

    // MARK: PEP 440 (pipx, uv)

    @Test func pep440Order() {
        Self.expectOrder([("26.5.1", "26.10.1"), ("1.0rc1", "1.0"), ("1.0", "1.0.post1")], .pep440)
        // packaging's ordering: dev < pre < final < post, with dev releases of each before it.
        let chain = ["1.0.dev0", "1.0.dev1", "1.0a1.dev1", "1.0a1", "1.0a2", "1.0b1", "1.0rc1", "1.0rc1.post1",
                     "1.0", "1.0+abc", "1.0+abc.5", "1.0+abc.10", "1.0+5", "1.0.post1.dev1", "1.0.post1",
                     "1.0.post2", "1.0.1", "1.1", "2!0.1"]
        Self.expectOrder(Array(zip(chain, chain.dropFirst())), .pep440)
    }

    @Test func pep440Normalizes() {
        Self.expectSame([("1.0", "1.0.0"), ("v1.0", "1.0"), ("1.0a1", "1.0.alpha1"), ("1.0a1", "1.0-a.1"),
                         ("1.0A1", "1.0a1"), ("1.0c1", "1.0rc1"), ("1.0pre1", "1.0rc1"), ("1.0preview1", "1.0rc1"),
                         ("1.0b", "1.0b0"), ("1.0-1", "1.0.post1"), ("1.0rev1", "1.0.post1"), ("1.0r1", "1.0.post1"),
                         ("1.0.post", "1.0.post0"), ("1.0-dev", "1.0.dev0"), ("0!1.0", "1.0"), (" 1.0 ", "1.0")],
                        .pep440)
        #expect(EcosystemVersion.isPrerelease("1.0rc1", scheme: .pep440))
        #expect(EcosystemVersion.isPrerelease("1.0.dev0", scheme: .pep440))
        #expect(EcosystemVersion.isPrerelease("1.0.post1.dev2", scheme: .pep440))
        #expect(!EcosystemVersion.isPrerelease("1.0.post1", scheme: .pep440))
        #expect(!EcosystemVersion.isPrerelease("26.10.1", scheme: .pep440))
        for text in ["", "latest", "1.0-beta-extra", "1.0+", "abc", "1.0.x"] {
            #expect(!EcosystemVersion.isValid(text, scheme: .pep440), "\(text)")
            #expect(EcosystemVersion.compare(text, "1.0", scheme: .pep440) == .orderedSame, "\(text)")
        }
    }

    // MARK: Gem::Version (RubyGems)

    @Test func gemOrder() {
        Self.expectOrder([("1.0.a", "1.0")], .gem)
        Self.expectSame([("1.0", "1"), ("1.0.0", "1"), ("1.0.a", "1.a")], .gem)
        let chain = ["1.0.0.pre1", "1.0.0.rc1", "1.0.0", "1.9", "1.10", "2.0.0.beta.2", "2.0.0.beta.10", "2.0.0",
                     "4.1.0", "4.1.1"]
        Self.expectOrder(Array(zip(chain, chain.dropFirst())), .gem)
        // A dash starts a prerelease, as Gem::Version reads "1.0.0-rc1" as "1.0.0.pre.rc1".
        Self.expectSame([("1.0.0-rc1", "1.0.0.pre.rc1")], .gem)
        Self.expectOrder([("1.0.0-rc1", "1.0.0")], .gem)
        #expect(EcosystemVersion.isPrerelease("1.0.a", scheme: .gem))
        #expect(EcosystemVersion.isPrerelease("1.0.0-rc1", scheme: .gem))
        #expect(!EcosystemVersion.isPrerelease("1.19.7", scheme: .gem))
        for text in ["", "abc", "1..2", "v1.0", "1.0 beta", "-1"] {
            #expect(!EcosystemVersion.isValid(text, scheme: .gem), "\(text)")
            #expect(EcosystemVersion.compare(text, "1.0", scheme: .gem) == .orderedSame, "\(text)")
        }
    }

    // MARK: Picking an update

    @Test func latestLowerThanInstalledIsNoUpdate() {
        // npm's `latest` tag can sit below an installed pre-release or a newer install.
        #expect(EcosystemVersion.newerVersion(than: "2.0.0-beta.1", among: ["1.9.0"], scheme: .semver) == nil)
        #expect(EcosystemVersion.newerVersion(than: "3.1.0", among: ["3.0.9"], scheme: .semver) == nil)
        #expect(EcosystemVersion.newerVersion(than: "3.1.0", among: ["3.1.0"], scheme: .semver) == nil)
        #expect(EcosystemVersion.newerVersion(than: "26.5.1", among: ["26.10.1", "26.5.1"], scheme: .pep440)
                == "26.10.1")
        #expect(EcosystemVersion.newerVersion(than: "1.9", among: ["1.10"], scheme: .semver) == "1.10")
    }

    @Test func prereleasesOnlyWhenInstalledIsOne() {
        let crates = ["1.0.0", "1.0.5", "1.1.0-rc.1", "1.1.0-rc.2"]
        #expect(EcosystemVersion.newerVersion(than: "1.0.0", among: crates, scheme: .semver) == "1.0.5")
        #expect(EcosystemVersion.newerVersion(than: "1.1.0-rc.1", among: crates, scheme: .semver) == "1.1.0-rc.2")
        #expect(EcosystemVersion.newerVersion(than: "1.0rc1", among: ["1.0", "1.1rc1"], scheme: .pep440) == "1.1rc1")
        #expect(EcosystemVersion.newerVersion(than: "1.0", among: ["1.1rc1", "1.0.post1"], scheme: .pep440)
                == "1.0.post1")
        #expect(EcosystemVersion.newerVersion(than: "4.0.0", among: ["4.1.0.rc1"], scheme: .gem) == nil)
    }

    @Test func noUpdateFromOrToSomethingThatIsntAVersion() {
        // A git or linked install isn't compared; tags that aren't versions are skipped.
        #expect(EcosystemVersion.newerVersion(than: "linked", among: ["9.9.9"], scheme: .semver) == nil)
        #expect(EcosystemVersion.newerVersion(than: "0.64.1", among: ["swift-DEVELOPMENT-SNAPSHOT-2026", "0.65.1"],
                                              scheme: .semver) == "0.65.1")
        #expect(EcosystemVersion.newerVersion(than: "0.64.1", among: ["nightly"], scheme: .semver) == nil)
        #expect(EcosystemVersion.newerVersion(than: "1.0", among: [], scheme: .gem) == nil)
    }
}
