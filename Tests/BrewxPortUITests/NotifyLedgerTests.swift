import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

@MainActor @Suite struct NotifyLedgerTests {
    static func row(_ engine: EngineID, _ kind: PackageKind, _ name: String, latest: String) -> PackageRow {
        PackageRow(package: Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name,
                                    installedVersion: "1", latestVersion: latest), arch: .arm64)
    }

    let wget2 = row(.homebrew, .formula, "wget", latest: "2")
    let wget3 = row(.homebrew, .formula, "wget", latest: "3")
    let jq2 = row(.homebrew, .formula, "jq", latest: "2")
    let curl8 = row(.macports, .port, "curl", latest: "8.1_0")

    @Test func newOnesAreTheVersionsNotRecorded() {
        let ledger = NotifyLedger(store: MemoryStore())
        #expect(ledger.newOnes(in: [wget2, jq2]).map(\.id) == [wget2.id, jq2.id])
        ledger.record([wget2])
        #expect(ledger.newOnes(in: [wget2, jq2]).map(\.id) == [jq2.id])
        // Keyed by version: the same package at a newer version is new.
        #expect(ledger.newOnes(in: [wget3]).map(\.id) == [wget3.id])
    }

    @Test func storedAsJSONListOfEngineKindNameAndVersion() throws {
        let store = MemoryStore()
        NotifyLedger(store: store).record([wget2, curl8])
        let data = try #require(store.data(forKey: "notifiedUpdates"))
        let entries = try JSONDecoder().decode([String].self, from: data)
        #expect(Set(entries) == ["homebrew/formula/wget@2", "macports/port/curl@8.1_0"])
    }

    /// The runtime notice keeps its own entries: a version told as available is still new to it, and the reverse.
    /// Pruning treats both the same way (kept while the version is offered, or while its engine didn't answer).
    @Test func runtimeNoticesHaveTheirOwnEntries() throws {
        let store = MemoryStore()
        let ledger = NotifyLedger(store: store)
        ledger.record([wget2])
        #expect(ledger.newOnes(in: [wget2], namespace: .runtime).map(\.id) == [wget2.id])
        ledger.record([jq2], namespace: .runtime)
        #expect(ledger.newOnes(in: [jq2]).map(\.id) == [jq2.id])
        #expect(ledger.newOnes(in: [jq2], namespace: .runtime).isEmpty)
        let entries = try JSONDecoder().decode([String].self, from: try #require(store.data(forKey: "notifiedUpdates")))
        #expect(Set(entries) == ["homebrew/formula/wget@2", "runtime:homebrew/formula/jq@2"])
        ledger.prune(outdated: [jq2])
        #expect(ledger.newOnes(in: [jq2], namespace: .runtime).isEmpty)
        #expect(ledger.newOnes(in: [wget2]).map(\.id) == [wget2.id])
        ledger.prune(outdated: [], unanswered: [.homebrew])
        #expect(ledger.newOnes(in: [jq2], namespace: .runtime).isEmpty)
        ledger.prune(outdated: [])
        #expect(ledger.newOnes(in: [jq2], namespace: .runtime).map(\.id) == [jq2.id])
    }

    @Test func survivesANewLedgerOnTheSameStore() {
        let store = MemoryStore()
        NotifyLedger(store: store).record([wget2])
        let again = NotifyLedger(store: store)
        #expect(again.newOnes(in: [wget2]).isEmpty)
        #expect(again.newOnes(in: [wget3]).map(\.id) == [wget3.id])
    }

    @Test func pruneForgetsVersionsNoLongerOutdated() {
        let store = MemoryStore()
        let ledger = NotifyLedger(store: store)
        ledger.record([wget2, jq2, curl8])
        // wget moved on to 3, jq was updated: both entries go; curl stays.
        ledger.prune(outdated: [wget3, curl8])
        #expect(NotifyLedger(store: store).newOnes(in: [wget2, jq2, curl8]).map(\.id) == [wget2.id, jq2.id])
    }

    @Test func pruneKeepsEnginesThatDidNotAnswer() {
        let ledger = NotifyLedger(store: MemoryStore())
        ledger.record([wget2, curl8])
        // Homebrew failed this time, so its rows are missing; that's not "updated".
        ledger.prune(outdated: [], unanswered: [.homebrew])
        #expect(ledger.newOnes(in: [wget2, curl8]).map(\.id) == [curl8.id])
    }

    /// Final review (R6): a tool a partial check couldn't look up is missing from Updates though its engine answered;
    /// that's not "updated" either, so its told version stays, and comes back without a second notice. Names with
    /// slashes and at-signs (npm's `@scope/name`, Mint's `owner/repo`) are matched whole. A check that couldn't name
    /// what it missed (Bun's unnamed failure) or only says why (npm's note, R26) keeps all of its engine's entries.
    @Test func pruneKeepsToolsAPartialCheckCouldntLookUp() {
        let black = Self.row(.pipx, .tool, "black", latest: "25.1")
        let ruff = Self.row(.pipx, .tool, "ruff", latest: "0.9")
        let scoped = Self.row(.npm, .tool, "@biomejs/biome", latest: "2.1.0")
        let swiftlint = Self.row(.mint, .tool, "realm/SwiftLint", latest: "0.59.1")
        let ts = Self.row(.bun, .tool, "typescript", latest: "5.9.0")
        let cowsay = Self.row(.npm, .tool, "cowsay", latest: "1.6.0")
        let ledger = NotifyLedger(store: MemoryStore())
        ledger.record([black, ruff, scoped, swiftlint, ts])
        ledger.prune(outdated: [], unchecked: [
            .pipx: UncheckedPackages(reasons: ["black": "PyPI didn't answer"]),
            .npm: UncheckedPackages(reasons: ["@biomejs/biome": "registry didn't answer"]),
            .mint: UncheckedPackages(reasons: ["realm/SwiftLint": "GitHub didn't answer"]),
            .bun: UncheckedPackages(unnamed: true),
        ])
        // ruff answered and is gone from Updates: updated, so forgotten. The rest stay told.
        #expect(ledger.newOnes(in: [black, ruff, scoped, swiftlint, ts]).map(\.id) == [ruff.id])
        // A name that only starts like an unchecked one isn't kept by it.
        let blackd = Self.row(.pipx, .tool, "black-d", latest: "1.0")
        ledger.record([blackd])
        ledger.prune(outdated: [], unchecked: [.pipx: UncheckedPackages(reasons: ["black": "PyPI didn't answer"])])
        #expect(ledger.newOnes(in: [blackd]).map(\.id) == [blackd.id])
        // npm's note (its list of globals couldn't be read): every npm entry stays. (The prune above, with npm
        // answering in full, forgot the scoped one.)
        #expect(ledger.newOnes(in: [scoped]).map(\.id) == [scoped.id])
        ledger.record([cowsay, scoped])
        ledger.prune(outdated: [], unchecked: [.npm: UncheckedPackages(note: "Couldn't read npm's list of globals")])
        #expect(ledger.newOnes(in: [cowsay, scoped]).isEmpty)
    }

    @Test func unreadableStoreReadsAsEmpty() {
        let store = MemoryStore()
        store.set(Data("not json".utf8), forKey: "notifiedUpdates")
        #expect(NotifyLedger(store: store).newOnes(in: [wget2]).map(\.id) == [wget2.id])
    }
}
