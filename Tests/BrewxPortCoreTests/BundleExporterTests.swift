import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(path)")
    return try String(contentsOf: url, encoding: .utf8)
}

private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }

private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")

/// Homebrew's installed list from `info-installed.json` text, through the real parser.
private func homebrew(_ json: String) async throws -> [Package] {
    try await HomebrewEngine(runner: FakeRunner([["info", "--json=v2", "--installed"]: ok(json)]), executable: brew)
        .listInstalled()
}

private func capturedTaps() async throws -> [String] {
    try await HomebrewEngine(runner: FakeRunner([["tap"]: ok(try fixture("homebrew/tap.txt"))]), executable: brew)
        .listTaps()
}

/// Every engine's captured installed list, through the real parsers.
private func allInstalled() async throws -> [Package] {
    let brewPkgs = try await homebrew(try fixture("homebrew/info-installed.json"))
    let nb = try await NanobrewEngine(
        runner: FakeRunner([["list", "--json"]: ok(try fixture("nanobrew/list.json"))]),
        executable: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
    ).listInstalled()
    let ports = try await MacPortsEngine(
        runner: FakeRunner([["-v", "-q", "installed", "active"]: ok(try fixture("macports/installed.txt"))]),
        executable: URL(fileURLWithPath: "/opt/local/bin/port")
    ).listInstalled()
    let apps = try await masInstalled()
    return brewPkgs + nb + ports + apps
}

private func masInstalled() async throws -> [Package] {
    try await MasEngine(
        runner: FakeRunner([["list", "--json"]: ok(try fixture("mas/list.json"))]),
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/mas")
    ).listInstalled()
}

private func export(_ installed: [Package], taps: [String]) -> (bundle: BundleFile, refused: [String]) {
    BundleExporter.make(installed: installed, taps: taps, appVersion: "0.3.0", arch: .arm64)
}

@Suite struct BundleExporterTests {
    @Test func exportIsSortedAndStable() async throws {
        let installed = try await allInstalled()
        let taps = try await capturedTaps()
        let first = export(installed, taps: taps)
        var shuffled = installed
        shuffled.shuffle()
        shuffled.reverse()
        let second = export(shuffled, taps: taps.reversed())
        #expect(try first.bundle.encoded() == second.bundle.encoded())
        #expect(first.bundle.createdBy == "BrewxPort 0.3.0")

        // Engine order, then kind (tap first), then name.
        let entries = first.bundle.entries
        let engines = entries.map { EngineID.allCases.firstIndex(of: $0.engine)! }
        #expect(engines == engines.sorted())
        #expect(entries.first?.kind == .tap)
        for engine in EngineID.allCases {
            let names = entries.filter { $0.engine == engine && $0.kind != .tap }
            for kind in Set(names.map(\.kind)) {
                let sameKind = names.filter { $0.kind == kind }.map(\.name)
                #expect(sameKind == sameKind.sorted())
            }
        }
        let homebrewKinds = entries.filter { $0.engine == .homebrew }.map(\.kind)
        #expect(homebrewKinds == homebrewKinds.sorted { BundleExporter.kindOrder.firstIndex(of: $0)! < BundleExporter.kindOrder.firstIndex(of: $1)! })
    }

    @Test func tapsBecomeTapEntries() async throws {
        let (bundle, refused) = export([], taps: try await capturedTaps())
        #expect(refused.isEmpty)
        #expect(bundle.entries == [BundleEntry(engine: .homebrew, kind: .tap, name: "felixkratz/formulae",
                                               displayName: "felixkratz/formulae")])
    }

    @Test func macportsVariantsKept() async throws {
        let (bundle, refused) = export(try await allInstalled(), taps: [])
        #expect(refused.isEmpty)
        let ports = Dictionary(uniqueKeysWithValues: bundle.entries.filter { $0.engine == .macports }.map { ($0.name, $0) })
        #expect(ports["bzip2"]?.options.variants == ["+universal"])
        #expect(ports["bzip2"]?.installedVersion == "1.0.8_1")
        #expect(ports["autoconf"]?.options.variants == [])
        #expect(bundle.entries.filter { $0.engine != .macports }.allSatisfy { $0.options.variants.isEmpty })
        #expect(bundle.entries.allSatisfy { $0.options.extraArgs.isEmpty && $0.options.version == nil })
    }

    @Test func masEntryKeepsIdAndDisplayName() async throws {
        let apps = try await masInstalled()
        let app = try #require(apps.first)
        let (bundle, _) = export(apps, taps: [])
        let entry = try #require(bundle.entries.first)
        #expect(entry.engine == .mas && entry.kind == .app)
        #expect(entry.name == app.id.name)            // the numeric app id
        #expect(BundleRules.isValidMasID(entry.name))
        #expect(entry.displayName == app.displayName)
        #expect(entry.id == nil)
    }

    @Test func versionPinIsNullOnExport() async throws {
        let (bundle, _) = export(try await allInstalled(), taps: try await capturedTaps())
        #expect(!bundle.entries.isEmpty)
        #expect(bundle.entries.allSatisfy { $0.versionPin == nil && $0.id == nil })
        let text = String(decoding: try bundle.encoded(), as: UTF8.self)
        #expect(!text.contains("\"versionPin\""))
        #expect(!text.contains("\"version\""))
    }

    @Test func exportDecodesWithNoUnhandled() async throws {
        let installed = try await allInstalled()
        let taps = try await capturedTaps()
        let (bundle, refused) = export(installed, taps: taps)
        #expect(refused.isEmpty)
        #expect(bundle.entries.count == installed.count + taps.count)
        let decoded = try BundleFile.decode(try bundle.encoded())
        #expect(decoded.unhandled.isEmpty)
        #expect(decoded.entries.map(\.ref) == bundle.entries.map(\.ref))
        #expect(decoded == bundle)
        let expectedRefs = Set(installed.map(\.id)).union(taps.map { PackageRef(engine: .homebrew, kind: .tap, name: $0) })
        #expect(Set(decoded.entries.map(\.ref)) == expectedRefs)
    }

    @Test func tapFormulaExportedQualified() async throws {
        // DERIVED from the real info-installed.json capture: its first formula is given the shape `brew info`
        // reports for a third-party tap formula (name `borders`, tap `felixkratz/formulae`, full_name qualified).
        let data = Data(try fixture("homebrew/info-installed.json").utf8)
        var doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var formulae = try #require(doc["formulae"] as? [[String: Any]])
        formulae[0]["name"] = "borders"
        formulae[0]["tap"] = "felixkratz/formulae"
        formulae[0]["full_name"] = "felixkratz/formulae/borders"
        doc["formulae"] = formulae
        let json = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)

        let installed = try await homebrew(json)
        let borders = try #require(installed.first { $0.id.name == "borders" })
        #expect(borders.id == PackageRef(engine: .homebrew, kind: .formula, name: "borders"))
        #expect(borders.fullName == "felixkratz/formulae/borders")
        #expect(installed.filter { $0.id.name != "borders" }.allSatisfy { $0.fullName == nil })

        let (bundle, refused) = export(installed, taps: try await capturedTaps())
        #expect(refused.isEmpty)
        let names = bundle.entries.filter { $0.kind == .formula }.map(\.name)
        #expect(names.contains("felixkratz/formulae/borders"))
        #expect(!names.contains("borders"))
        #expect(names.filter { $0.contains("/") } == ["felixkratz/formulae/borders"])
        #expect(try BundleFile.decode(try bundle.encoded()).unhandled.isEmpty)
    }

    @Test func refusedPackageNamedNotWritten() async throws {
        // DERIVED from the real captures: one nanobrew package renamed to `-x` in test code.
        var installed = try await allInstalled()
        let index = try #require(installed.firstIndex { $0.id.engine == .nanobrew })
        let original = installed[index].id
        installed[index].id = PackageRef(engine: .nanobrew, kind: original.kind, name: "-x")
        let (bundle, refused) = export(installed, taps: [])
        #expect(refused.count == 1)
        #expect(refused.first?.contains("“-x”") == true)
        #expect(refused.first?.hasPrefix("nanobrew") == true)
        #expect(!bundle.entries.contains { $0.name == "-x" })
        #expect(bundle.entries.count == installed.count - 1)
    }

    @Test func duplicateRefWrittenOnceAndReported() async throws {
        let apps = try await masInstalled()
        let (bundle, refused) = export(apps + apps, taps: [])
        #expect(refused.count == apps.count)
        // mas is named by its app name, not its id.
        #expect(refused == apps.map { "Mac App Store “\($0.displayName)”: listed twice" }.sorted())
        #expect(bundle.entries.count == apps.count)
        #expect(try BundleFile.decode(try bundle.encoded()).unhandled.isEmpty)
    }

    @Test func thirdPartyCaskExportedQualified() async throws {
        // DERIVED from the real info-installed.json capture: its first cask is given the shape `brew info` reports
        // for a third-party tap cask (token `widget`, tap `felixkratz/formulae`, full_token qualified).
        let data = Data(try fixture("homebrew/info-installed.json").utf8)
        var doc = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var casks = try #require(doc["casks"] as? [[String: Any]])
        casks[0]["token"] = "widget"
        casks[0]["tap"] = "felixkratz/formulae"
        casks[0]["full_token"] = "felixkratz/formulae/widget"
        doc["casks"] = casks
        let json = String(decoding: try JSONSerialization.data(withJSONObject: doc), as: UTF8.self)

        let installed = try await homebrew(json)
        let widget = try #require(installed.first { $0.id.name == "widget" })
        #expect(widget.id == PackageRef(engine: .homebrew, kind: .cask, name: "widget"))
        #expect(widget.fullName == "felixkratz/formulae/widget")

        let (bundle, refused) = export(installed, taps: try await capturedTaps())
        #expect(refused.isEmpty)
        let names = bundle.entries.filter { $0.kind == .cask }.map(\.name)
        #expect(names.contains("felixkratz/formulae/widget"))
        #expect(!names.contains("widget"))
        #expect(names.filter { $0.contains("/") } == ["felixkratz/formulae/widget"])
        #expect(try BundleFile.decode(try bundle.encoded()).unhandled.isEmpty)
    }

    @Test func summaryNamesFailedEngine() async throws {
        let (bundle, refused) = export(try await masInstalled(), taps: [])
        let macports = EngineError(engine: .macports, message: "MacPorts didn't answer within 60 seconds")
        let summary = ExportSummary.make(bundle, errors: [macports], tapsError: nil, refused: refused)
        #expect(summary.counts == [.mas: bundle.entries.count])
        #expect(summary.failedEngines == [.macports: "MacPorts didn't answer within 60 seconds"])
        #expect(summary.refused == [])

        // A failed tap listing is a Homebrew failure, kept alongside Homebrew's own error.
        let tapFail = EngineError(engine: .homebrew, message: "brew tap failed (exit 1)")
        let onlyTaps = ExportSummary.make(bundle, errors: [], tapsError: tapFail, refused: ["x"])
        #expect(onlyTaps.failedEngines == [.homebrew: "brew tap failed (exit 1)"])
        #expect(onlyTaps.refused == ["x"])
        let both = ExportSummary.make(bundle, errors: [EngineError(engine: .homebrew, message: "a")], tapsError: tapFail,
                                      refused: [])
        #expect(both.failedEngines == [.homebrew: "a; brew tap failed (exit 1)"])
    }

    @Test func summaryCountsTapsUnderHomebrew() async throws {
        let (bundle, _) = export(try await allInstalled(), taps: try await capturedTaps())
        let summary = ExportSummary.make(bundle, errors: [], tapsError: nil, refused: [])
        let homebrewEntries = bundle.entries.filter { $0.engine == .homebrew }.count
        #expect(summary.counts[.homebrew] == homebrewEntries)
        #expect(summary.counts.values.reduce(0, +) == bundle.entries.count)
        #expect(summary.failedEngines.isEmpty)
    }
}
