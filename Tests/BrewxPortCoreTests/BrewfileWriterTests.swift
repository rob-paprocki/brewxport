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

/// Every engine's captured installed list, through the real parsers (as in `BundleExporterTests`).
private func allInstalled() async throws -> [Package] {
    let brewPkgs = try await HomebrewEngine(
        runner: FakeRunner([["info", "--json=v2", "--installed"]: ok(try fixture("homebrew/info-installed.json"))]),
        executable: brew
    ).listInstalled()
    let nb = try await NanobrewEngine(
        runner: FakeRunner([["list", "--json"]: ok(try fixture("nanobrew/list.json"))]),
        executable: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
    ).listInstalled()
    let ports = try await MacPortsEngine(
        runner: FakeRunner([["-v", "-q", "installed", "active"]: ok(try fixture("macports/installed.txt"))]),
        executable: URL(fileURLWithPath: "/opt/local/bin/port")
    ).listInstalled()
    let apps = try await MasEngine(
        runner: FakeRunner([["list", "--json"]: ok(try fixture("mas/list.json"))]),
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/mas")
    ).listInstalled()
    return brewPkgs + nb + ports + apps
}

private func capturedTaps() async throws -> [String] {
    try await HomebrewEngine(runner: FakeRunner([["tap"]: ok(try fixture("homebrew/tap.txt"))]), executable: brew)
        .listTaps()
}

/// Task 3's export of the captured fixtures.
private func fixtureExport() async throws -> BundleFile {
    BundleExporter.make(installed: try await allInstalled(), taps: try await capturedTaps(), appVersion: "0.3.0",
                        arch: .arm64).bundle
}

/// 2026-11-19 12:00 UTC: the same calendar day in every time zone from UTC-11 to UTC+11.
private let noon = Date(timeIntervalSince1970: 1_795_089_600)

private func lines(_ text: String) -> [String] {
    var parts = text.components(separatedBy: "\n")
    if parts.last == "" { parts.removeLast() }
    return parts
}

@Suite struct BrewfileWriterTests {
    @Test func writtenBrewfileReadsBackWithNoUnhandled() async throws {
        let bundle = try await fixtureExport()
        let (text, _) = BrewfileWriter.write(bundle, date: noon)
        let doc = try BrewfileReader.read(Data(text.utf8))
        #expect(doc.unhandled.isEmpty)
        #expect(doc.ignoredCount == 1) // the header
        let expected = bundle.entries.filter { $0.engine == .homebrew || $0.engine == .mas }
        #expect(!expected.isEmpty)
        #expect(Set(doc.entries.map(\.ref)) == Set(expected.map(\.ref)))
        #expect(doc.entries.count == expected.count)
        for entry in expected where entry.engine == .mas {
            #expect(doc.entries.first { $0.ref == entry.ref }?.displayName == entry.displayName)
        }
    }

    @Test func thirdPartyFormulaAndCaskWrittenTrustedAndReadBack() async throws {
        var bundle = try await fixtureExport()
        bundle.entries = [
            BundleEntry(engine: .homebrew, kind: .formula, name: "felixkratz/formulae/borders", displayName: "borders"),
            BundleEntry(engine: .homebrew, kind: .cask, name: "user/repo/app", displayName: "app"),
            BundleEntry(engine: .homebrew, kind: .formula, name: "homebrew/core/jq", displayName: "jq"),
            BundleEntry(engine: .homebrew, kind: .formula, name: "jq", displayName: "jq"),
        ]
        let (text, _) = BrewfileWriter.write(bundle, date: noon)
        let written = lines(text)
        #expect(written.contains(#"brew "felixkratz/formulae/borders", trusted: true"#))
        #expect(written.contains(#"cask "user/repo/app", trusted: true"#))
        #expect(written.contains(#"brew "homebrew/core/jq""#))
        #expect(written.contains(#"brew "jq""#))
        let doc = try BrewfileReader.read(Data(text.utf8))
        #expect(doc.unhandled.isEmpty)
        #expect(doc.entries.map(\.ref.name).sorted() == ["felixkratz/formulae/borders", "homebrew/core/jq", "jq", "user/repo/app"])
    }

    @Test func groupsInOrderAndSorted() async throws {
        let bundle = try await fixtureExport()
        var shuffled = bundle
        shuffled.entries.reverse()
        let (text, _) = BrewfileWriter.write(shuffled, date: noon)
        #expect(text == BrewfileWriter.write(bundle, date: noon).text)
        let body = lines(text).dropFirst()
        let words = body.map { String($0.prefix { $0 != " " }) }
        let order = ["tap", "brew", "cask", "mas"]
        #expect(words.map { order.firstIndex(of: $0)! } == words.map { order.firstIndex(of: $0)! }.sorted())
        for word in order {
            let group = body.filter { $0.hasPrefix(word + " ") }
            #expect(group == group.sorted(), "\(word)")
        }
    }

    @Test func nanobrewAndMacPortsListedAsLeftOut() async throws {
        let bundle = try await fixtureExport()
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        let nb = bundle.entries.filter { $0.engine == .nanobrew }
        let ports = bundle.entries.filter { $0.engine == .macports }
        #expect(!nb.isEmpty)
        #expect(!ports.isEmpty)
        #expect(leftOut.count == nb.count + ports.count)
        for entry in nb {
            #expect(leftOut.contains(LeftOut(ref: entry.ref, displayName: entry.displayName,
                                             reason: "nanobrew packages aren't in Brewfiles")))
        }
        for entry in ports {
            #expect(leftOut.contains(LeftOut(ref: entry.ref, displayName: entry.displayName,
                                             reason: "MacPorts packages aren't in Brewfiles")))
        }
        #expect(lines(text).count == 1 + bundle.entries.count - nb.count - ports.count)
    }

    @Test func pinsAndOptionsListedAsLeftOut() async throws {
        // DERIVED from the fixture export: a pin on a formula, options on a cask, both on a mas app.
        var bundle = try await fixtureExport()
        bundle.entries = bundle.entries.filter { $0.engine == .homebrew || $0.engine == .mas }
        let formula = try #require(bundle.entries.firstIndex { $0.kind == .formula })
        let cask = try #require(bundle.entries.firstIndex { $0.kind == .cask })
        let app = try #require(bundle.entries.firstIndex { $0.kind == .app })
        bundle.entries[formula].versionPin = "1.0"
        bundle.entries[cask].options = InstallOptions(extraArgs: ["--no-quarantine"])
        bundle.entries[app].versionPin = "2.0"
        bundle.entries[app].options = InstallOptions(extraArgs: ["--force"])
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)

        let f = bundle.entries[formula], c = bundle.entries[cask], a = bundle.entries[app]
        // In the bundle's entry order (the export puts formulae, then casks, then mas apps).
        #expect(leftOut == [
            LeftOut(ref: f.ref, displayName: f.displayName, reason: "Brewfiles can't pin a version"),
            LeftOut(ref: c.ref, displayName: c.displayName, reason: "Brewfiles from BrewxPort carry no install options"),
            LeftOut(ref: a.ref, displayName: a.displayName, reason: "Brewfiles can't pin a version"),
            LeftOut(ref: a.ref, displayName: a.displayName, reason: "Brewfiles from BrewxPort carry no install options"),
        ])
        // The packages themselves are still written, without the pin or options.
        let doc = try BrewfileReader.read(Data(text.utf8))
        #expect(doc.unhandled.isEmpty)
        #expect(Set(doc.entries.map(\.ref)) == Set(bundle.entries.map(\.ref)))
        for absent in ["quarantine", "--force", "\"1.0\"", "\"2.0\"", "args:", "version"] {
            #expect(!text.contains(absent), "\(absent)")
        }
    }

    @Test func quotesEscaped() async throws {
        // DERIVED from mas/list.json: the app name changed here to hold `"`, `\` and Ruby interpolation.
        let apps = try await MasEngine(
            runner: FakeRunner([["list", "--json"]: ok(try fixture("mas/list.json"))]),
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/mas")
        ).listInstalled()
        var app = try #require(apps.first)
        app.displayName = #"Ter"mi\us #{system("x")} #@a #$b"#
        let bundle = BundleExporter.make(installed: [app], taps: [], appVersion: "0.3.0", arch: .arm64).bundle
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        #expect(leftOut.isEmpty)
        #expect(lines(text).dropFirst() == [
            ##"mas "Ter\"mi\\us \#{system(\"x\")} \#@a \#$b", id: "## + app.id.name,
        ])
    }

    @Test func hashInNameRoundTrips() async throws {
        // DERIVED from mas/list.json: the app name changed here to "C# Notes". A `#` not followed by `{`, `@` or `$`
        // can't start Ruby interpolation, so it's written bare and the reader takes the line back.
        let apps = try await MasEngine(
            runner: FakeRunner([["list", "--json"]: ok(try fixture("mas/list.json"))]),
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/mas")
        ).listInstalled()
        var app = try #require(apps.first)
        app.displayName = "C# Notes"
        let bundle = BundleExporter.make(installed: [app], taps: [], appVersion: "0.3.0", arch: .arm64).bundle
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        #expect(leftOut.isEmpty)
        #expect(lines(text).dropFirst() == [#"mas "C# Notes", id: "# + app.id.name])
        let doc = try BrewfileReader.read(Data(text.utf8))
        #expect(doc.unhandled.isEmpty)
        #expect(doc.entries.map(\.displayName) == ["C# Notes"])
        #expect(doc.entries.map(\.ref) == [app.id])
    }

    @Test func controlCharactersEscaped() {
        // A writer input that skipped `BundleRules` (built in code, not decoded): nothing breaks the line.
        let entry = BundleEntry(engine: .mas, kind: .app, name: "1176074088", displayName: "Ter\nmius\u{7}")
        let bundle = BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: [entry])
        let (text, _) = BrewfileWriter.write(bundle, date: noon)
        #expect(lines(text).count == 2)
        #expect(!text.unicodeScalars.contains { $0 != "\n" && $0.properties.generalCategory == .control })
    }

    @Test func invalidEntriesLeftOutWithReason() {
        // Built in code, not decoded: the writer still runs `BundleRules` and names what it refuses.
        let bad = [
            BundleEntry(engine: .homebrew, kind: .formula, name: "--force", displayName: "--force"),
            BundleEntry(engine: .homebrew, kind: .tap, name: "homebrew/core", displayName: "homebrew/core"),
            BundleEntry(engine: .mas, kind: .app, name: "0123", displayName: "Old"),
        ]
        let bundle = BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: bad)
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        #expect(lines(text).count == 1)
        #expect(leftOut.map(\.ref) == bad.map(\.ref))
        #expect(leftOut.allSatisfy { !$0.reason.isEmpty })
    }

    @Test func languageToolsLeftOut() {
        let tool = BundleEntry(engine: .npm, kind: .tool, name: "typescript", displayName: "typescript")
        let jq = BundleEntry(engine: .homebrew, kind: .formula, name: "jq", displayName: "jq")
        let bundle = BundleFile(createdBy: "BrewxPort 0.8.0", arch: .arm64, entries: [tool, jq])
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        #expect(lines(text).dropFirst() == ["brew \"jq\""])
        #expect(leftOut == [LeftOut(ref: tool.ref, displayName: "typescript",
                                    reason: "language tools aren't included in Brewfiles")])
    }

    @Test func headerHasNoUserOrHost() async throws {
        var bundle = try await fixtureExport()
        bundle.createdBy = "BrewxPort 0.3.0\nsystem(\"echo injected\")"
        let (text, _) = BrewfileWriter.write(bundle, date: noon)
        let all = lines(text)
        #expect(all[0].hasPrefix("# "))
        #expect(all[0].contains("BrewxPort"))
        #expect(all[0].contains("2026-11-19"))
        #expect(!all[1].hasPrefix("#"))
        #expect(!text.contains("injected"))
        for secret in [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, NSHomeDirectory()]
        where !secret.isEmpty {
            #expect(!text.contains(secret))
        }
        let local = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? ""
        if !local.isEmpty { #expect(!text.contains(local)) }
    }

    @Test func emptyBundleIsHeaderOnly() {
        let bundle = BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: [])
        let (text, leftOut) = BrewfileWriter.write(bundle, date: noon)
        #expect(lines(text).count == 1)
        #expect(text.hasSuffix("\n"))
        #expect(leftOut.isEmpty)
    }
}
