import Testing
@testable import BrewxPortCore

private func package(_ engine: EngineID, _ kind: PackageKind, _ name: String, _ onRequest: Bool?) -> Package {
    Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedOnRequest: onRequest)
}

/// `BundleExporter.requestedOnly`: an export of only what the user installed.
@Suite struct RequestedOnlyTests {
    @Test func dropsDependenciesKeepsRequestedAndUnknown() {
        let jq = package(.homebrew, .formula, "jq", true)
        let oniguruma = package(.homebrew, .formula, "oniguruma", false)
        let tree = package(.nanobrew, .formula, "tree", nil)
        let made = BundleExporter.requestedOnly([jq, oniguruma, tree])
        #expect(made.kept == [jq, tree])
        #expect(made.dependencies == 1)
        // nanobrew doesn't say, so its package stays and the engine is named.
        #expect(made.unknown == [.nanobrew])
    }

    @Test func nothingToDropWhenEverythingWasAskedFor() {
        let app = package(.mas, .app, "497799835", true)
        let made = BundleExporter.requestedOnly([app])
        #expect(made.kept == [app])
        #expect(made.dependencies == 0)
        #expect(made.unknown.isEmpty)
    }
}
