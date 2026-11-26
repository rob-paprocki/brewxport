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

    @Test func unreadableStoreReadsAsEmpty() {
        let store = MemoryStore()
        store.set(Data("not json".utf8), forKey: "notifiedUpdates")
        #expect(NotifyLedger(store: store).newOnes(in: [wget2]).map(\.id) == [wget2.id])
    }
}
