import Foundation
import BrewxPortCore
import Testing
@testable import BrewxPortUI

@MainActor
struct UpdatePreferencesTests {
    private func ref(_ name: String) -> PackageRef { PackageRef(engine: .homebrew, kind: .formula, name: name) }

    private func package(_ name: String, latest: String?) -> Package {
        Package(id: ref(name), displayName: name, installedVersion: "1.0", latestVersion: latest)
    }

    @Test func ignoreSurvivesReload() {
        let store = MemoryStore()
        UpdatePreferences(store: store).ignore([ref("wget"), ref("jq")])
        let reloaded = UpdatePreferences(store: store)
        #expect(reloaded.isIgnored(ref("wget")))
        #expect(reloaded.isIgnored(ref("jq")))
        #expect(!reloaded.isIgnored(ref("git")))
    }

    @Test func unignoreRemoves() {
        let store = MemoryStore()
        let prefs = UpdatePreferences(store: store)
        prefs.ignore([ref("wget"), ref("jq")])
        prefs.unignore([ref("wget")])
        #expect(!prefs.isIgnored(ref("wget")))
        #expect(UpdatePreferences(store: store).isIgnored(ref("jq")))
        #expect(!UpdatePreferences(store: store).isIgnored(ref("wget")))
    }

    @Test func skipHidesOnlyThatVersion() {
        let prefs = UpdatePreferences(store: MemoryStore())
        prefs.skip(ref("wget"), version: "2.0")
        #expect(prefs.isSkipped(package("wget", latest: "2.0")))
        #expect(!prefs.isSkipped(package("wget", latest: "2.1")))
        #expect(!prefs.isSkipped(package("jq", latest: "2.0")))
        #expect(!prefs.isSkipped(package("wget", latest: nil)))
    }

    @Test func skipSurvivesReload() {
        let store = MemoryStore()
        UpdatePreferences(store: store).skip(ref("wget"), version: "2.0")
        #expect(UpdatePreferences(store: store).isSkipped(package("wget", latest: "2.0")))
    }

    @Test func pruneClearsSkipWhenVersionMoves() {
        let store = MemoryStore()
        let prefs = UpdatePreferences(store: store)
        prefs.skip(ref("wget"), version: "2.0")
        prefs.skip(ref("jq"), version: "1.7")
        prefs.prune(outdated: [package("wget", latest: "2.1"), package("jq", latest: "1.7")])
        #expect(!prefs.isSkipped(package("wget", latest: "2.0")))
        #expect(prefs.isSkipped(package("jq", latest: "1.7")))
        let reloaded = UpdatePreferences(store: store)
        #expect(!reloaded.isSkipped(package("wget", latest: "2.0")))
        #expect(reloaded.isSkipped(package("jq", latest: "1.7")))
        let stored = String(decoding: store.data(forKey: "skippedVersions") ?? Data(), as: UTF8.self)
        #expect(!stored.contains("wget"))
    }

    @Test func pruneKeepsSkipForPackageNotListed() {
        let prefs = UpdatePreferences(store: MemoryStore())
        prefs.skip(ref("wget"), version: "2.0")
        prefs.prune(outdated: [])
        #expect(prefs.isSkipped(package("wget", latest: "2.0")))
    }

    @Test func oneBadEntryKeepsTheOthers() {
        // An engine this version doesn't know, and an entry missing its version, among good ones.
        let store = MemoryStore()
        store.set(Data("""
            [{"engine":"homebrew","kind":"formula","name":"wget"},{"engine":"fink","kind":"formula","name":"x"},
             {"engine":"homebrew","kind":"formula","name":"jq"},{"name":"broken"}]
            """.utf8), forKey: "ignoredPackages")
        store.set(Data("""
            [{"ref":{"engine":"homebrew","kind":"formula","name":"git"}},
             {"ref":{"engine":"homebrew","kind":"formula","name":"curl"},"version":"8.0"}]
            """.utf8), forKey: "skippedVersions")
        let prefs = UpdatePreferences(store: store)
        #expect(prefs.isIgnored(ref("wget")))
        #expect(prefs.isIgnored(ref("jq")))
        #expect(prefs.isSkipped(package("curl", latest: "8.0")))
        #expect(!prefs.isSkipped(package("git", latest: "2.0")))
    }

    @Test func corruptDataStartsEmpty() {
        let store = MemoryStore()
        store.set(Data("not json".utf8), forKey: "ignoredPackages")
        store.set(Data("{\"also\": bad".utf8), forKey: "skippedVersions")
        let prefs = UpdatePreferences(store: store)
        #expect(!prefs.isIgnored(ref("wget")))
        #expect(!prefs.isSkipped(package("wget", latest: "2.0")))
        prefs.ignore([ref("wget")])
        #expect(UpdatePreferences(store: store).isIgnored(ref("wget")))
    }

    @Test func providerWithoutPrompterReturnsNil() async {
        let provider = PromptPasswordProvider()
        #expect(await provider.password(reason: "test") == nil)
    }

    @Test func providerForwardsToPrompter() async {
        let provider = PromptPasswordProvider()
        let prompter = FakePrompter(password: "pw")
        provider.prompter = prompter
        let secret = await provider.password(reason: "Update all")
        #expect(secret != nil)
        #expect(prompter.reasons == ["Update all"])
    }
}
