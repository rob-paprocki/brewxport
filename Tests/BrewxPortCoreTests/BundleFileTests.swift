import Testing
import Foundation
@testable import BrewxPortCore

// The JSON in these tests is built in test code from `BundleFile` values or `JSONSerialization` dictionaries: it is
// the value under test, not a fixture. Task 11 adds a real exported file as a regression fixture.

private var ripgrep: [String: Any] { [
    "engine": "macports", "kind": "port", "name": "ripgrep", "displayName": "ripgrep",
    "installedVersion": "14.1.1_0", "options": ["variants": ["+universal"], "extraArgs": [] as [String]],
] }
private var jq: [String: Any] { [
    "engine": "homebrew", "kind": "formula", "name": "jq", "displayName": "jq",
    "options": ["variants": [] as [String], "extraArgs": [] as [String]],
] }

private func bundle(_ entries: [Any], schema: Any = 1, extra: [String: Any] = [:]) throws -> Data {
    var top: [String: Any] = ["schemaVersion": schema, "createdBy": "BrewxPort 0.2.0", "arch": "arm64", "entries": entries]
    top.merge(extra) { _, new in new }
    return try JSONSerialization.data(withJSONObject: top, options: [.sortedKeys])
}

private func with(_ base: [String: Any], _ changes: [String: Any]) -> [String: Any] {
    base.merging(changes) { _, new in new }
}

private func rulesReason(_ engine: EngineID, _ kind: PackageKind, _ name: String,
                         variants: [String] = [], extraArgs: [String] = []) -> String? {
    let v = BundleRules.check(engine: engine, kind: kind, name: name, displayName: name, variants: variants, extraArgs: extraArgs)
    if case .rejected(let r) = v { return r }
    return nil
}

@Suite struct BundleFileTests {
    @Test func roundTripKeepsEveryWrittenField() throws {
        let file = BundleFile(
            createdBy: "BrewxPort 0.2.0", arch: .x86_64,
            entries: [
                BundleEntry(engine: .macports, kind: .port, name: "ripgrep", displayName: "ripgrep",
                            installedVersion: "14.1.1_0", versionPin: "14.1.1", options: InstallOptions(variants: ["+universal"], extraArgs: ["-s"]),
                            id: "ripgrep"),
                BundleEntry(engine: .homebrew, kind: .tap, name: "felixkratz/formulae", displayName: "felixkratz/formulae"),
                BundleEntry(engine: .homebrew, kind: .formula, name: "felixkratz/formulae/borders",
                            displayName: "felixkratz/formulae/borders", installedVersion: "1.6.0"),
                BundleEntry(engine: .homebrew, kind: .cask, name: "firefox", displayName: "firefox"),
                BundleEntry(engine: .nanobrew, kind: .formula, name: "jq", displayName: "jq", versionPin: "1.7"),
                BundleEntry(engine: .mas, kind: .app, name: "1519867270", displayName: "Refined GitHub", id: "x-1"),
            ])
        let decoded = try BundleFile.decode(try file.encoded())
        #expect(decoded == file)
        #expect(decoded.unhandled.isEmpty)
        #expect(decoded.schemaVersion == BundleFile.currentSchema)
        #expect(decoded.entries[0].ref == PackageRef(engine: .macports, kind: .port, name: "ripgrep"))
    }

    @Test func nilOptionalsOmittedAndOptionsHaveOnlyTwoKeys() throws {
        let file = BundleFile(createdBy: "BrewxPort 0.2.0", arch: .arm64,
                              entries: [BundleEntry(engine: .homebrew, kind: .formula, name: "jq", displayName: "jq")])
        let top = try #require(try JSONSerialization.jsonObject(with: try file.encoded()) as? [String: Any])
        #expect(Set(top.keys) == ["arch", "createdBy", "entries", "schemaVersion"])
        let entry = try #require((top["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["displayName", "engine", "kind", "name", "options"])
        let options = try #require(entry["options"] as? [String: Any])
        #expect(Set(options.keys) == ["extraArgs", "variants"])
    }

    @Test func newerSchemaRefused() throws {
        #expect(throws: BundleFileError.newerSchema(2)) { try BundleFile.decode(try bundle([jq], schema: 2)) }
    }

    @Test func schemaZeroRefused() throws {
        #expect(throws: BundleFileError.unsupportedSchema(0)) { try BundleFile.decode(try bundle([jq], schema: 0)) }
        #expect(throws: BundleFileError.unsupportedSchema(-1)) { try BundleFile.decode(try bundle([jq], schema: -1)) }
    }

    @Test func schemaOfTheWrongTypeIsNotABundle() throws {
        for schema: Any in [true, "1", 1.5] {
            #expect(throws: BundleFileError.notABundle, "\(schema)") { try BundleFile.decode(try bundle([jq], schema: schema)) }
        }
    }

    @Test func notJSONRefused() {
        for text in ["", "not json", "{\"schemaVersion\": 1,", "brew \"jq\"\n"] {
            #expect(throws: BundleFileError.notJSON, "\(text)") { try BundleFile.decode(Data(text.utf8)) }
        }
        #expect(throws: BundleFileError.notJSON) { try BundleFile.decode(Data([0xFF, 0xFE, 0x00])) }
    }

    @Test func jsonWithoutEntriesIsNotABundle() throws {
        let noEntries = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "createdBy": "BrewxPort 0.2.0", "arch": "arm64"])
        #expect(throws: BundleFileError.notABundle) { try BundleFile.decode(noEntries) }
        #expect(throws: BundleFileError.notABundle) { try BundleFile.decode(try bundle([], extra: ["entries": "jq"])) }
        for text in ["[]", "\"hello\"", "1", "{}", "null"] {
            #expect(throws: BundleFileError.notABundle, "\(text)") { try BundleFile.decode(Data(text.utf8)) }
        }
        // createdBy and arch are part of the format too.
        let noArch = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "createdBy": "BrewxPort 0.2.0", "entries": [Any]()])
        #expect(throws: BundleFileError.notABundle) { try BundleFile.decode(noArch) }
        #expect(throws: BundleFileError.notABundle) { try BundleFile.decode(try bundle([jq], extra: ["arch": "riscv"])) }
        #expect(throws: BundleFileError.notABundle) { try BundleFile.decode(try bundle([jq], extra: ["createdBy": 3])) }
    }

    @Test func emptyEntriesDecode() throws {
        let file = try BundleFile.decode(try bundle([]))
        #expect(file.entries.isEmpty && file.unhandled.isEmpty)
        #expect(file.createdBy == "BrewxPort 0.2.0" && file.arch == .arm64)
    }

    @Test func unknownEngineEntryKeptAsUnhandled() throws {
        let winget = with(jq, ["engine": "winget", "name": "Git.Git"])
        let file = try BundleFile.decode(try bundle([jq, winget, ripgrep]))
        #expect(file.entries.map(\.name) == ["jq", "ripgrep"])
        #expect(file.unhandled.count == 1)
        let u = try #require(file.unhandled.first)
        #expect(u.index == 1)
        #expect(u.reason.contains("winget"), "\(u.reason)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(u.json.utf8)) as? [String: Any])
        #expect(json["engine"] as? String == "winget" && json["name"] as? String == "Git.Git")
    }

    @Test func malformedEntriesKeptAsUnhandled() throws {
        var noName = jq; noName["name"] = nil
        var noEngine = jq; noEngine["engine"] = nil
        let entries: [Any] = [
            "jq", 3, NSNull(), [jq],
            noName, noEngine,
            with(jq, ["kind": "rpm"]),
            with(jq, ["name": 7]),
            with(jq, ["options": ["variants": "+universal"]]),
            with(jq, ["installedVersion": ["x"]]),
            with(jq, ["engine": "win\u{1B}[2J\u{202E}get"]),
            ripgrep,
        ]
        let file = try BundleFile.decode(try bundle(entries))
        #expect(file.entries.map(\.name) == ["ripgrep"])
        #expect(file.unhandled.map(\.index) == Array(0...10))
        for u in file.unhandled {
            #expect(!u.reason.isEmpty)
            #expect(!u.reason.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{202E}" }, "\(u.reason)")
        }
        #expect(file.unhandled[4].reason.contains("name"), "\(file.unhandled[4].reason)")
        #expect(file.unhandled[6].reason.contains("rpm"), "\(file.unhandled[6].reason)")
    }

    @Test func hostileEntriesKeptAsUnhandled() throws {
        let noQuarantine = with(jq, ["options": ["variants": [] as [String], "extraArgs": ["--no-quarantine"]]])
        let dash = with(jq, ["name": "-x", "displayName": "-x"])
        let path = with(jq, ["name": "../x", "displayName": "../x"])
        let semicolon = with(ripgrep, ["options": ["variants": ["+a;rm"], "extraArgs": [] as [String]]])
        let localFile = with(jq, ["name": "x.rb"])
        let rootFlag = with(ripgrep, ["options": ["variants": [] as [String], "extraArgs": ["-n"]]])
        let file = try BundleFile.decode(try bundle([jq, noQuarantine, dash, path, semicolon, localFile, rootFlag, ripgrep]))
        #expect(file.entries.map(\.name) == ["jq", "ripgrep"])
        let expected: [(Int, String?)] = [
            (1, rulesReason(.homebrew, .formula, "jq", extraArgs: ["--no-quarantine"])),
            (2, rulesReason(.homebrew, .formula, "-x")),
            (3, rulesReason(.homebrew, .formula, "../x")),
            (4, rulesReason(.macports, .port, "ripgrep", variants: ["+a;rm"])),
            (5, rulesReason(.homebrew, .formula, "x.rb")),
            (6, rulesReason(.macports, .port, "ripgrep", extraArgs: ["-n"])),
        ]
        #expect(file.unhandled.map(\.index) == expected.map(\.0))
        for (u, (_, reason)) in zip(file.unhandled, expected) {
            let r = try #require(reason)
            #expect(u.reason == r)
        }
        // Nothing smuggled reaches an accepted entry.
        for entry in file.entries {
            #expect(entry.options.extraArgs.isEmpty)
            #expect(entry.options.version == nil)
        }
    }

    @Test func optionsVersionKeyNeverRead() throws {
        let pinned = with(jq, [
            "versionPin": "1.6",
            "options": ["version": "1.0", "variants": [] as [String], "extraArgs": [] as [String]],
        ])
        let onlyVersion = with(ripgrep, ["options": ["version": "--force"]])
        let file = try BundleFile.decode(try bundle([pinned, onlyVersion]))
        #expect(file.unhandled.isEmpty)
        #expect(file.entries.count == 2)
        #expect(file.entries[0].options.version == nil)
        #expect(file.entries[0].versionPin == "1.6")
        #expect(file.entries[1].options == InstallOptions())
        #expect(file.entries[1].versionPin == nil)
        // And it's never written back.
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(!text.contains("\"version\""))
    }

    @Test func versionInStructNeverWritten() throws {
        let file = BundleFile(createdBy: "BrewxPort 0.2.0", arch: .arm64, entries: [
            BundleEntry(engine: .homebrew, kind: .formula, name: "jq", displayName: "jq", options: InstallOptions(version: "1.0")),
        ])
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(!text.contains("\"version\""))
        #expect(try BundleFile.decode(try file.encoded()).entries[0].options.version == nil)
    }

    @Test func duplicateEntryKeptAsUnhandled() throws {
        let again = with(jq, ["installedVersion": "1.7.1"])
        let file = try BundleFile.decode(try bundle([jq, ripgrep, again]))
        #expect(file.entries.map(\.name) == ["jq", "ripgrep"])
        #expect(file.entries[0].installedVersion == nil)
        #expect(file.unhandled.count == 1)
        #expect(file.unhandled.first?.index == 2)
        #expect(file.unhandled.first?.reason == "listed twice; entry 1 is used")
        // A rejected entry doesn't claim a ref: a later good copy still decodes.
        let bad = with(jq, ["options": ["variants": [] as [String], "extraArgs": ["--force"]]])
        let afterBad = try BundleFile.decode(try bundle([bad, jq]))
        #expect(afterBad.entries.map(\.name) == ["jq"])
        #expect(afterBad.unhandled.map(\.index) == [0])
        // The same name in another engine or kind is not a duplicate here (the preview handles that).
        let cask = with(jq, ["kind": "cask"])
        let nb = with(jq, ["engine": "nanobrew"])
        #expect(try BundleFile.decode(try bundle([jq, cask, nb])).unhandled.isEmpty)
    }

    @Test func unknownKeysIgnored() throws {
        let entry = with(jq, ["homepage": "https://example.com", "options": [
            "variants": [] as [String], "extraArgs": [] as [String], "future": ["x": 1],
        ]])
        let file = try BundleFile.decode(try bundle([entry], extra: ["comment": "hi", "machine": ["x": 1]]))
        #expect(file.unhandled.isEmpty)
        #expect(file.entries == [BundleEntry(engine: .homebrew, kind: .formula, name: "jq", displayName: "jq")])
    }

    @Test func displayNameComesFromTheRules() throws {
        let renamed = with(jq, ["displayName": "--force\u{202E}"])
        var noDisplayName = ripgrep; noDisplayName["displayName"] = nil
        let mas: [String: Any] = ["engine": "mas", "kind": "app", "name": "1519867270", "displayName": "  Refined\u{200B} GitHub "]
        var masNoName = mas; masNoName["displayName"] = nil
        let file = try BundleFile.decode(try bundle([renamed, noDisplayName, mas, masNoName]))
        #expect(file.entries.map(\.displayName) == ["jq", "ripgrep", "Refined GitHub"])
        #expect(file.unhandled.map(\.index) == [3])
        #expect(file.unhandled.first?.reason == "has no app name")
    }

    @Test func encodedIsSortedWithUnescapedSlashes() throws {
        let file = BundleFile(createdBy: "BrewxPort 0.2.0", arch: .arm64, entries: [
            BundleEntry(engine: .homebrew, kind: .tap, name: "felixkratz/formulae", displayName: "felixkratz/formulae"),
            BundleEntry(engine: .homebrew, kind: .formula, name: "felixkratz/formulae/borders", displayName: "felixkratz/formulae/borders"),
        ])
        let text = String(decoding: try file.encoded(), as: UTF8.self)
        #expect(text.contains("\"name\" : \"felixkratz/formulae\""), "\(text)")
        #expect(!text.contains("\\/"))
        let keys = ["\"arch\"", "\"createdBy\"", "\"entries\"", "\"schemaVersion\""]
        let positions = try keys.map { try #require(text.range(of: $0)?.lowerBound) }
        #expect(positions == positions.sorted())
        #expect(text.contains("\n  "), "pretty-printed")
        #expect(!text.contains("unhandled"))
    }

    @Test func unhandledNeverWritten() throws {
        let winget = with(jq, ["engine": "winget"])
        let file = try BundleFile.decode(try bundle([jq, winget]))
        #expect(file.unhandled.count == 1)
        let again = try BundleFile.decode(try file.encoded())
        #expect(again.unhandled.isEmpty)
        #expect(again.entries == file.entries)
    }

    @Test func createdByUsesAppVersion() throws {
        #expect(BundleFile.appVersion(nil) == "0.0.0")
        #expect(BundleFile.appVersion([:]) == "0.0.0")
        #expect(BundleFile.appVersion(["CFBundleShortVersionString": 3]) == "0.0.0")
        #expect(BundleFile.appVersion(["CFBundleShortVersionString": "0.2.0"]) == "0.2.0")
        let pattern = try Regex(#"^BrewxPort \d+\.\d+\.\d+$"#)
        for info: [String: Any]? in [nil, [:], ["CFBundleShortVersionString": "0.2.0"]] {
            let createdBy = BundleFile.createdBy(info)
            #expect(createdBy.wholeMatch(of: pattern) != nil, "\(createdBy)")
        }
        #expect(BundleFile.createdBy(["CFBundleShortVersionString": "0.2.0"]) == "BrewxPort 0.2.0")
    }

    @Test func oversizedFileRefused() throws {
        // Checked before parsing: not even JSON is looked at.
        #expect(throws: BundleFileError.tooLarge) { try BundleFile.decode(Data(count: BundleFile.maxFileBytes + 1)) }
        // A real bundle padded past the limit with one huge field.
        let blob = with(jq, ["homepage": String(repeating: "x", count: BundleFile.maxFileBytes)])
        let data = try bundle([blob])
        #expect(data.count > BundleFile.maxFileBytes)
        #expect(throws: BundleFileError.tooLarge) { try BundleFile.decode(data) }
    }

    @Test func tooManyEntriesRefused() throws {
        let over = try bundle(Array(repeating: jq, count: BundleFile.maxEntries + 1))
        #expect(over.count <= BundleFile.maxFileBytes)
        #expect(throws: BundleFileError.tooLarge) { try BundleFile.decode(over) }
        // At the cap the file decodes (one entry, the rest listed twice).
        let at = try BundleFile.decode(try bundle(Array(repeating: jq, count: BundleFile.maxEntries)))
        #expect(at.entries.count == 1)
        #expect(at.unhandled.count == BundleFile.maxEntries - 1)
    }

    @Test func unhandledJSONEscapedAndCapped() throws {
        let hostile = with(jq, ["engine": "winget", "name": "a\u{202E}b\u{200B}c", "note": String(repeating: "y", count: 5_000)])
        let file = try BundleFile.decode(try bundle([hostile]))
        let u = try #require(file.unhandled.first)
        #expect(!u.json.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{200B}" })
        #expect(u.json.contains("\\u{202E}") && u.json.contains("\\u{200B}"), "\(u.json.prefix(200))")
        #expect(u.json.hasSuffix("…"))
        #expect(u.json.unicodeScalars.count <= BundleFile.maxJSONPreview + 20)
        // A small entry is whole.
        let small = try BundleFile.decode(try bundle([with(jq, ["engine": "winget"])]))
        #expect(small.unhandled.first?.json.hasSuffix("…") == false)
    }

    @Test func infoFieldsSanitizedOnDecode() throws {
        let entry = with(jq, [
            "installedVersion": "1.7\u{202E}1", "versionPin": String(repeating: "9", count: 300), "id": "a\u{200B}\u{1B}b",
        ])
        let decoded = try #require(try BundleFile.decode(try bundle([entry])).entries.first)
        #expect(decoded.installedVersion == "1.7\\u{202E}1")
        #expect(decoded.versionPin == String(repeating: "9", count: BundleFile.maxInfoLength) + "…")
        #expect(decoded.id == "a\\u{200B}\\u{1B}b")
        // Clean values are untouched.
        let clean = try #require(try BundleFile.decode(try bundle([with(jq, ["installedVersion": "1.7.1_2", "id": "jq"])])).entries.first)
        #expect(clean.installedVersion == "1.7.1_2" && clean.id == "jq")
    }

    @Test func duplicateCheckIsCaseSensitive() throws {
        // Exact refs only; the preview matches installed packages case-insensitively with BundleRules.matchKey.
        let upper = with(jq, ["name": "JQ"])
        let file = try BundleFile.decode(try bundle([jq, upper]))
        #expect(file.entries.map(\.name) == ["jq", "JQ"])
        #expect(file.unhandled.isEmpty)
    }
}
