import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// `DependencyGatherer`'s dependency walk: when it runs, and what `dependenciesComplete` says about it.
@Suite struct DependencyGathererTests {
    /// Homebrew has ripgrep (asked for) needing pcre2 (a dependency), and `unknown`, whose install record doesn't say
    /// whether it was asked for.
    private struct Setup {
        let catalog = FakeCatalog()
        let brew = MoveFakeEngine(wrapping: PlanFixtures.engines[0])
        let rows: [Package]

        init(unknownRecord: Bool) {
            var rows = [Self.formula("ripgrep", onRequest: true), Self.formula("pcre2", onRequest: false)]
            if unknownRecord { rows.append(Self.formula("unknown", onRequest: nil)) }
            self.rows = rows
            dependencies("ripgrep", ["pcre2"])
            dependencies("pcre2", [])
        }

        static func formula(_ name: String, onRequest: Bool?) -> Package {
            Package(id: PackageRef(engine: .homebrew, kind: .formula, name: name), displayName: name,
                    installedVersion: "1", installedOnRequest: onRequest)
        }

        func dependencies(_ name: String, _ needs: [String]?) {
            let ref = PackageRef(engine: .homebrew, kind: .formula, name: name)
            catalog.scriptInfo(ref, .init(result: .success(PackageDetails(ref: ref, dependencies: needs))))
        }

        func failInfo(_ name: String) {
            catalog.scriptInfo(PackageRef(engine: .homebrew, kind: .formula, name: name),
                               .init(result: .failure(EngineError(engine: .homebrew, message: "no info"))))
        }

        func facts(walkingDependenciesAlways: Bool? = nil) async throws -> DependencyFacts {
            let gatherer = DependencyGatherer(engines: [brew], catalog: catalog)
            let picks = [rows[0]]
            if let walkingDependenciesAlways {
                return try await gatherer.facts(for: picks, engine: .homebrew, installed: rows,
                                                walkDependenciesWhenRequestedUnknown: walkingDependenciesAlways)
            }
            return try await gatherer.facts(for: picks, engine: .homebrew, installed: rows)
        }
    }

    @Test func knownRecordsWalkDependencies() async throws {
        let facts = try await Setup(unknownRecord: false).facts()
        #expect(facts.dependenciesComplete)
        #expect(facts.requested == ["ripgrep"])
        #expect(facts.dependencies["ripgrep"] == ["pcre2"])
    }

    @Test func unknownRecordSkipsTheWalkByDefault() async throws {
        let setup = Setup(unknownRecord: true)
        let facts = try await setup.facts()
        #expect(!facts.dependenciesComplete)
        #expect(facts.requested == nil)
        #expect(facts.dependencies.isEmpty)
        #expect(setup.catalog.infoCalls.isEmpty)
    }

    @Test func unknownRecordStillWalksWhenAsked() async throws {
        let facts = try await Setup(unknownRecord: true).facts(walkingDependenciesAlways: true)
        #expect(facts.dependenciesComplete)
        #expect(facts.requested == nil)
        #expect(facts.dependencies["ripgrep"] == ["pcre2"])
        #expect(facts.dependencies["pcre2"] == [])
    }

    @Test func failedInfoLeavesDependenciesIncomplete() async throws {
        let setup = Setup(unknownRecord: true)
        setup.failInfo("pcre2")
        let facts = try await setup.facts(walkingDependenciesAlways: true)
        #expect(!facts.dependenciesComplete)
        #expect(facts.requested == nil)
        #expect(facts.dependencies.isEmpty)
    }

    @Test func failedDependentsOfANeededPackageLeavesDependenciesIncomplete() async throws {
        let setup = Setup(unknownRecord: false)
        setup.brew.failDependents("pcre2")
        let facts = try await setup.facts()
        #expect(!facts.dependenciesComplete)
        #expect(facts.requested == nil)
        #expect(facts.dependencies.isEmpty)
    }
}
