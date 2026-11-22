import Testing
import Foundation
import BrewxPortCore
@testable import BrewxPortUI

/// Brewfile sources come from the Task 0 captures through the real `BrewfileReader`; bundle sources are
/// `BundleFile` values built in code (or, where labelled, derived from one).
enum PreviewFixtures {
    static func brewfile(_ name: String) throws -> BrewfileDocument {
        let url = UIFixtures.directory.appendingPathComponent("brewfile/\(name).Brewfile")
        return try BrewfileReader.read(try Data(contentsOf: url))
    }

    /// `brew tap` as captured, through `HomebrewEngine.listTaps`.
    static func capturedTaps() async throws -> [String] {
        let tapText = try String(contentsOf: UIFixtures.directory.appendingPathComponent("homebrew/tap.txt"),
                                 encoding: .utf8)
        let runner = UIFakeRunner([["tap"]: CommandResult(exitCode: 0, stdout: tapText, stderr: "")])
        return try await HomebrewEngine(runner: runner, executable: URL(fileURLWithPath: PlanFixtures.brewPath))
            .listTaps()
    }

    static let allPresent: [EngineID: EngineStatus] = Dictionary(uniqueKeysWithValues: EngineID.allCases.map {
        ($0, EngineStatus.present(path: URL(fileURLWithPath: "/x/\($0.rawValue)"), version: "1"))
    })

    static func status(_ changes: [EngineID: EngineStatus]) -> [EngineID: EngineStatus] {
        allPresent.merging(changes) { $1 }
    }

    static let arm = PackageCatalog.defaultOrder(for: .arm64)
    static let intel = PackageCatalog.defaultOrder(for: .x86_64)
    static let nothing = InstalledState(packages: [], taps: [])

    static func installed(_ engine: EngineID, _ kind: PackageKind, _ name: String, _ version: String?) -> Package {
        Package(id: PackageRef(engine: engine, kind: kind, name: name), displayName: name, installedVersion: version)
    }

    static func entry(_ engine: EngineID, _ kind: PackageKind, _ name: String, displayName: String? = nil,
                      pin: String? = nil, options: InstallOptions = InstallOptions()) -> BundleEntry {
        BundleEntry(engine: engine, kind: kind, name: name, displayName: displayName ?? name, versionPin: pin,
                    options: options)
    }

    static func bundle(_ entries: [BundleEntry]) -> ImportSource {
        .bundle(BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: entries))
    }
}

@Suite struct ImportPreviewTests {
    typealias F = PreviewFixtures

    private func row(_ preview: ImportPreview, _ name: String) -> ImportRow? {
        preview.groups.flatMap(\.rows).first { $0.id.name == name }
    }

    private func allIDs(_ preview: ImportPreview) -> Set<PackageRef> {
        Set(preview.groups.flatMap(\.rows).map(\.id))
    }

    @Test func groupedByEngineInOrderTapsFirst() {
        let source = F.bundle([
            F.entry(.mas, .app, "1519867270", displayName: "Refined GitHub"),
            F.entry(.homebrew, .formula, "felixkratz/formulae/borders"),
            F.entry(.macports, .port, "figlet"),
            F.entry(.homebrew, .cask, "rectangle"),
            F.entry(.homebrew, .tap, "felixkratz/formulae"),
            F.entry(.nanobrew, .formula, "tree"),
        ])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(preview.groups.map(\.engine) == [.nanobrew, .homebrew, .macports, .mas])
        #expect(preview.groups[1].rows.map(\.id.name) == ["felixkratz/formulae", "felixkratz/formulae/borders",
                                                          "rectangle"])
        let intel = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.intel)
        #expect(intel.groups.map(\.engine) == [.macports, .homebrew, .nanobrew, .mas])
    }

    @Test func alreadyInstalledNotChecked() throws {
        let installed = InstalledState(packages: [F.installed(.homebrew, .formula, "jq", "1.8.1")], taps: [])
        let preview = ImportPreview.make(.brewfile(try F.brewfile("dump-basic")), installed: installed,
                                         status: F.allPresent, order: F.arm)
        let jq = try #require(row(preview, "jq"))
        #expect(jq.state == .alreadyInstalled(version: "1.8.1"))
        #expect(!preview.initiallyChecked.contains(jq.id))
        #expect(row(preview, "rectangle")?.state == .willInstall)
        #expect(preview.initiallyChecked.contains(PackageRef(engine: .homebrew, kind: .cask, name: "rectangle")))
    }

    // Round A (2026-11-21): after Homebrew's figlet was installed, reopening a bundle that also lists MacPorts' figlet
    // ticked the MacPorts copy with no warning. A name another engine already has starts unchecked, with a note.
    @Test func nameInstalledByAnotherEngineStartsUnchecked() throws {
        let file = BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64,
                              entries: [F.entry(.homebrew, .formula, "figlet"), F.entry(.macports, .port, "figlet"),
                                        F.entry(.macports, .port, "nano")])
        let installed = InstalledState(packages: [F.installed(.homebrew, .formula, "figlet", "2.2.5")], taps: [])
        let preview = ImportPreview.make(.bundle(file), installed: installed, status: F.allPresent, order: F.arm)
        let port = try #require(preview.groups.flatMap(\.rows).first { $0.id.engine == .macports && $0.displayName == "figlet" })
        // Still installable if the user ticks it.
        #expect(port.state == .willInstall)
        #expect(!preview.initiallyChecked.contains(port.id))
        #expect(port.notes.contains("Already installed with Homebrew"))
        // A name nothing else has is untouched.
        #expect(preview.initiallyChecked.contains(PackageRef(engine: .macports, kind: .port, name: "nano")))
    }

    @Test func alreadyInstalledNeverRequested() throws {
        let installed = InstalledState(packages: [F.installed(.homebrew, .formula, "jq", "1.8.1")], taps: [])
        let preview = ImportPreview.make(.brewfile(try F.brewfile("dump-basic")), installed: installed,
                                         status: F.allPresent, order: F.arm)
        let requested = preview.requests(for: allIDs(preview)).map(\.package.id.name)
        #expect(!requested.contains("jq"))
        #expect(requested.contains("rectangle"))
        #expect(preview.requests(for: allIDs(preview)).allSatisfy { $0.operation == .install })
    }

    @Test func tapQualifiedFormulaMatchesBareInstalledName() throws {
        // Line 2: `brew "apple/apple/game-porting-toolkit"`; Homebrew lists it installed by its bare name.
        let installed = InstalledState(
            packages: [F.installed(.homebrew, .formula, "game-porting-toolkit", "1.1")], taps: [])
        let preview = ImportPreview.make(.brewfile(try F.brewfile("homebrew-bundle-types")), installed: installed,
                                         status: F.allPresent, order: F.arm)
        #expect(row(preview, "apple/apple/game-porting-toolkit")?.state == .alreadyInstalled(version: "1.1"))
    }

    @Test func installedTapShowsInstalled() async throws {
        let taps = try await F.capturedTaps()
        let installed = InstalledState(packages: [], taps: taps)
        let preview = ImportPreview.make(.brewfile(try F.brewfile("dump-basic")), installed: installed,
                                         status: F.allPresent, order: F.arm)
        let tap = try #require(row(preview, "felixkratz/formulae"))
        #expect(tap.state == .alreadyInstalled(version: nil))
        #expect(!preview.initiallyChecked.contains(tap.id))
        #expect(preview.requests(for: [tap.id]).isEmpty)

        let mixedCase = ImportPreview.make(F.bundle([F.entry(.homebrew, .tap, "FelixKratz/formulae")]),
                                           installed: installed, status: F.allPresent, order: F.arm)
        #expect(row(mixedCase, "FelixKratz/formulae")?.state == .alreadyInstalled(version: nil))
    }

    @Test func tapCheckedOnlyWithItsFormula() throws {
        let doc = try F.brewfile("homebrew-bundle-types")
        let tapRef = PackageRef(engine: .homebrew, kind: .tap, name: "apple/apple")
        let formulaRef = PackageRef(engine: .homebrew, kind: .formula, name: "apple/apple/game-porting-toolkit")

        let fresh = ImportPreview.make(.brewfile(doc), installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(row(fresh, "apple/apple/game-porting-toolkit")?.state == .willInstall)
        #expect(fresh.initiallyChecked.contains(formulaRef))
        #expect(fresh.initiallyChecked.contains(tapRef))

        let installed = InstalledState(
            packages: [F.installed(.homebrew, .formula, "game-porting-toolkit", "1.1")], taps: [])
        let later = ImportPreview.make(.brewfile(doc), installed: installed, status: F.allPresent, order: F.arm)
        #expect(row(later, "apple/apple")?.state == .willInstall)
        #expect(!later.initiallyChecked.contains(tapRef))
    }

    @Test func everyTapRowHasTheThirdPartyNote() throws {
        let preview = ImportPreview.make(.brewfile(try F.brewfile("homebrew-bundle-types")), installed: F.nothing,
                                         status: F.allPresent, order: F.arm)
        #expect(row(preview, "apple/apple")?.notes == ["Adds a third-party source of packages"])
    }

    @Test func qualifiedFormulaWithUnlistedTapShowsThirdPartyNote() throws {
        let doc = try F.brewfile("homebrew-bundle-types")
        let fresh = ImportPreview.make(.brewfile(doc), installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(row(fresh, "apple/apple/game-porting-toolkit")?.notes == ["Adds a third-party source of packages"])
        #expect(row(fresh, "firefox")?.notes == [])

        let tapped = ImportPreview.make(.brewfile(doc), installed: InstalledState(packages: [], taps: ["Apple/Apple"]),
                                        status: F.allPresent, order: F.arm)
        #expect(row(tapped, "apple/apple/game-porting-toolkit")?.notes == [])
        #expect(row(tapped, "apple/apple")?.state == .alreadyInstalled(version: nil))
        // A tap that's already added brings no new source, so it has no note.
        #expect(row(tapped, "apple/apple")?.notes == [])

        // Homebrew's own taps add nothing.
        let core = ImportPreview.make(F.bundle([F.entry(.homebrew, .formula, "homebrew/core/jq")]),
                                      installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(row(core, "homebrew/core/jq")?.notes == [])
    }

    @Test func masRowShowsAppID() throws {
        // Line 5: `mas "Refined GitHub", id: 1519867270`.
        let preview = ImportPreview.make(.brewfile(try F.brewfile("homebrew-bundle-types")), installed: F.nothing,
                                         status: F.allPresent, order: F.arm)
        let app = try #require(row(preview, "1519867270"))
        #expect(app.displayName == "Refined GitHub (1519867270)")
        let request = try #require(preview.requests(for: [app.id]).first)
        #expect(request.package.displayName == "Refined GitHub")
    }

    @Test func missingEngineSkipsItsEntries() throws {
        let source = F.bundle([
            F.entry(.macports, .port, "figlet"),
            F.entry(.macports, .port, "bzip2", options: InstallOptions(variants: ["+universal"])),
            F.entry(.homebrew, .formula, "jq"),
        ])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.status([.macports: .missing]),
                                         order: F.arm)
        let ports = try #require(preview.groups.first { $0.engine == .macports })
        #expect(ports.rows.allSatisfy { $0.state == .engineMissing })
        #expect(ports.rows.allSatisfy { !preview.initiallyChecked.contains($0.id) })
        let setup = try #require(preview.missingEngines.first)
        #expect(preview.missingEngines.count == 1)
        #expect(setup.engine == .macports)
        #expect(setup.skippedCount == 2)
        #expect(setup.reason == "MacPorts isn't installed")
        #expect(setup.link == URL(string: "https://www.macports.org/install.php"))
        let requests = preview.requests(for: allIDs(preview))
        #expect(requests.map(\.package.id.name) == ["jq"])
        #expect(preview.skippedCount == 2)
        #expect(preview.toInstallCount == 1)
    }

    @Test func unusableEngineCountsAsMissing() throws {
        let brew = URL(fileURLWithPath: PlanFixtures.brewPath)
        let status = F.status([.homebrew: .unusable(path: brew, reason: "`brew --version` exited 1")])
        let preview = ImportPreview.make(.brewfile(try F.brewfile("dump-basic")), installed: F.nothing,
                                         status: status, order: F.arm)
        let rows = preview.groups.flatMap(\.rows)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.state == .engineMissing })
        #expect(preview.initiallyChecked.isEmpty)
        #expect(preview.requests(for: allIDs(preview)).isEmpty)
        let setup = try #require(preview.missingEngines.first)
        #expect(setup.engine == .homebrew)
        #expect(setup.reason.contains("`brew --version` exited 1"))
        #expect(setup.skippedCount == rows.count)

        // An engine the status map doesn't name counts as missing too.
        let unknown = ImportPreview.make(.brewfile(try F.brewfile("dump-basic")), installed: F.nothing,
                                         status: [:], order: F.arm)
        #expect(unknown.missingEngines.map(\.engine) == [.homebrew])
    }

    @Test func duplicateNameChecksFirstEngineOnly() throws {
        let source = F.bundle([
            F.entry(.homebrew, .formula, "jq"),
            F.entry(.nanobrew, .formula, "jq"),
            F.entry(.homebrew, .cask, "rectangle"),
        ])
        let homebrewJQ = PackageRef(engine: .homebrew, kind: .formula, name: "jq")
        let nanobrewJQ = PackageRef(engine: .nanobrew, kind: .formula, name: "jq")

        let arm = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let rows = arm.groups.flatMap(\.rows)
        #expect(rows.first { $0.id == homebrewJQ }?.state == .duplicate(of: .nanobrew))
        #expect(rows.first { $0.id == nanobrewJQ }?.state == .duplicate(of: .homebrew))
        #expect(arm.initiallyChecked.contains(nanobrewJQ))
        #expect(!arm.initiallyChecked.contains(homebrewJQ))
        #expect(arm.requests(for: arm.initiallyChecked).filter { $0.package.id.name == "jq" }.map(\.package.id)
                == [nanobrewJQ])

        let intel = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.intel)
        #expect(intel.initiallyChecked.contains(homebrewJQ))
        #expect(!intel.initiallyChecked.contains(nanobrewJQ))
    }

    @Test func sameNameTwiceInOneEngineChecksOnlyTheFirst() throws {
        // `jq` and `foo/bar/jq` would both install a formula called jq: pick one.
        let source = F.bundle([
            F.entry(.homebrew, .formula, "jq"),
            F.entry(.homebrew, .formula, "foo/bar/jq"),
            F.entry(.homebrew, .formula, "wget"),
        ])
        let core = PackageRef(engine: .homebrew, kind: .formula, name: "jq")
        let tapped = PackageRef(engine: .homebrew, kind: .formula, name: "foo/bar/jq")
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let rows = preview.groups.flatMap(\.rows)
        #expect(rows.first { $0.id == core }?.state == .duplicate(of: .homebrew))
        #expect(rows.first { $0.id == tapped }?.state == .duplicate(of: .homebrew))
        #expect(rows.first { $0.id.name == "wget" }?.state == .willInstall)
        #expect(preview.initiallyChecked.contains(core))
        #expect(!preview.initiallyChecked.contains(tapped))
        #expect(preview.toInstallCount == 3)

        // The file's order decides: the qualified one first is the one checked.
        let reversed = ImportPreview.make(F.bundle([F.entry(.homebrew, .formula, "foo/bar/jq"),
                                                    F.entry(.homebrew, .formula, "jq")]),
                                          installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(reversed.initiallyChecked == [tapped])

        // With a nanobrew copy too, the earliest engine's first copy is checked and the others name nanobrew.
        let three = ImportPreview.make(F.bundle([F.entry(.homebrew, .formula, "jq"),
                                                 F.entry(.homebrew, .formula, "foo/bar/jq"),
                                                 F.entry(.nanobrew, .formula, "jq")]),
                                       installed: F.nothing, status: F.allPresent, order: F.intel)
        let threeRows = three.groups.flatMap(\.rows)
        #expect(threeRows.first { $0.id == core }?.state == .duplicate(of: .nanobrew))
        #expect(threeRows.first { $0.id == tapped }?.state == .duplicate(of: .nanobrew))
        #expect(three.initiallyChecked == [core])
    }

    @Test func brewfileLinesAreCarried() throws {
        let doc = try F.brewfile("dump-describe")
        let preview = ImportPreview.make(.brewfile(doc), installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(preview.brewfileLines == ImportPreview.BrewfileLines(total: doc.lineCount, ignored: doc.ignoredCount))
        #expect(doc.ignoredCount > 1)
        #expect(preview.ignoredLinesText == "\(doc.ignoredCount) blank or comment lines")
        // Every line is accounted for: entries, unhandled lines and blank or comment lines.
        #expect(doc.entries.count + doc.unhandled.count + doc.ignoredCount == doc.lineCount)

        let bundle = ImportPreview.make(F.bundle([F.entry(.homebrew, .formula, "jq")]), installed: F.nothing,
                                        status: F.allPresent, order: F.arm)
        #expect(bundle.brewfileLines == nil)
        #expect(bundle.ignoredLinesText == nil)
        #expect(ImportPreview(groups: [], missingEngines: [], unhandled: [], initiallyChecked: [],
                              brewfileLines: .init(total: 3, ignored: 1)).ignoredLinesText
                == "1 blank or comment line")
    }

    @Test func unhandledTitleNamesLinesOrEntries() throws {
        let one = PreviewUnhandled(location: "line 3", text: "x", reason: "y")
        let lines = ImportPreview(groups: [], missingEngines: [], unhandled: [one, one], initiallyChecked: [],
                                  brewfileLines: .init(total: 2, ignored: 0))
        #expect(lines.unhandledTitle == "2 lines BrewxPort doesn't handle")
        let line = ImportPreview(groups: [], missingEngines: [], unhandled: [one], initiallyChecked: [],
                                 brewfileLines: .init(total: 1, ignored: 0))
        #expect(line.unhandledTitle == "1 line BrewxPort doesn't handle")
        let entry = ImportPreview(groups: [], missingEngines: [], unhandled: [one], initiallyChecked: [])
        #expect(entry.unhandledTitle == "1 entry BrewxPort doesn't handle")
        let entries = ImportPreview(groups: [], missingEngines: [], unhandled: [one, one], initiallyChecked: [])
        #expect(entries.unhandledTitle == "2 entries BrewxPort doesn't handle")
    }

    @Test func pinShownNotApplied() throws {
        let source = F.bundle([F.entry(.homebrew, .formula, "jq", pin: "1.7.1")])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let jq = try #require(row(preview, "jq"))
        #expect(jq.pin == "1.7.1")
        #expect(jq.notes == ["Pinned to 1.7.1 in the file, but BrewxPort installs the latest version"])
        #expect(preview.initiallyChecked.contains(jq.id))
        let request = try #require(preview.requests(for: [jq.id]).first)
        #expect(request.options.version == nil)
        #expect(request.options == InstallOptions())
    }

    @Test func brewfileUnhandledLinesCarriedWithLineNumbers() throws {
        let doc = try F.brewfile("dump-basic")
        let preview = ImportPreview.make(.brewfile(doc), installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(preview.unhandled.map(\.location) == ["line 7", "line 8", "line 9", "line 10"])
        #expect(preview.unhandled.map(\.text) == doc.unhandled.map(\.text))
        #expect(preview.unhandled.map(\.reason) == doc.unhandled.map(\.reason))
        #expect(preview.unhandled[0].text == #"vscode "ms-python.debugpy""#)
        #expect(preview.skippedCount == 4)
        #expect(preview.toInstallCount == 6)
        #expect(preview.installedCount == 0)
    }

    @Test func bundleUnhandledEntriesCarried() throws {
        // DERIVED: a bundle encoded from values, with a hostile second entry spliced into its JSON.
        let file = BundleFile(createdBy: "BrewxPort 0.3.0", arch: .arm64, entries: [
            F.entry(.homebrew, .formula, "jq"), F.entry(.homebrew, .cask, "rectangle"),
        ])
        var object = try #require(try JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])
        var entries = try #require(object["entries"] as? [Any])
        entries.insert(["engine": "homebrew", "kind": "formula", "name": "--force", "displayName": "x\u{202E}y"],
                       at: 1)
        object["entries"] = entries
        let decoded = try BundleFile.decode(try JSONSerialization.data(withJSONObject: object))
        let preview = ImportPreview.make(.bundle(decoded), installed: F.nothing, status: F.allPresent, order: F.arm)
        let item = try #require(preview.unhandled.first)
        #expect(preview.unhandled.count == 1)
        #expect(item.location == "entry 2")
        #expect(item.text == decoded.unhandled[0].json)
        #expect(item.reason == decoded.unhandled[0].reason)
        #expect(!item.text.unicodeScalars.contains("\u{202E}"))
        #expect(preview.groups.flatMap(\.rows).map(\.id.name) == ["jq", "rectangle"])
    }

    // MARK: Task 6 review carries (Task 7)

    @Test func pinNoteOnlyOnInstallableRows() throws {
        let source = F.bundle([F.entry(.homebrew, .formula, "jq", pin: "1.7.1"),
                               F.entry(.macports, .port, "curl", pin: "8.0")])
        let installed = InstalledState(packages: [F.installed(.homebrew, .formula, "jq", "1.8.1")], taps: [])
        let preview = ImportPreview.make(source, installed: installed, status: F.status([.macports: .missing]),
                                         order: F.arm)
        #expect(row(preview, "jq")?.notes == [])
        #expect(row(preview, "jq")?.pin == "1.7.1")
        #expect(row(preview, "curl")?.notes == [])
        let fresh = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        #expect(row(fresh, "jq")?.notes == [ImportPreview.pinNote("1.7.1")])
    }

    @Test func sameRefTwiceGivesOneRow() throws {
        // A source built in code can repeat a ref; decoded files never do.
        let source = F.bundle([F.entry(.homebrew, .formula, "jq"), F.entry(.homebrew, .formula, "wget"),
                               F.entry(.homebrew, .formula, "jq")])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let ids = preview.groups.flatMap(\.rows).map(\.id)
        #expect(ids.map(\.name) == ["jq", "wget"])
        #expect(Set(ids).count == ids.count)
        #expect(preview.unhandled.map(\.reason) == ["listed twice"])
        #expect(preview.unhandled.map(\.text) == ["jq"])
    }

    @Test func standaloneTapStartsUncheckedWithAHint() throws {
        // A tap no checked package is named with starts unchecked, with a hint: its packages may be listed by bare
        // name, so the user decides.
        let source = F.bundle([F.entry(.homebrew, .tap, "felixkratz/formulae"), F.entry(.homebrew, .formula, "jq")])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let tap = try #require(row(preview, "felixkratz/formulae"))
        #expect(tap.state == .willInstall)
        #expect(!preview.initiallyChecked.contains(tap.id))
        #expect(tap.notes == [ImportPreview.tapNote, ImportPreview.standaloneTapHint])
        // A tap a checked formula needs starts checked, without the hint.
        let needed = ImportPreview.make(.brewfile(try F.brewfile("homebrew-bundle-types")), installed: F.nothing,
                                        status: F.allPresent, order: F.arm)
        #expect(row(needed, "apple/apple")?.notes == [ImportPreview.tapNote])
    }

    @Test func defaultSelectionPlansWithoutPickOne() throws {
        // ripgrep from nanobrew and MacPorts: only one copy starts checked, so the planner has nothing to refuse.
        let source = F.bundle([F.entry(.nanobrew, .formula, "ripgrep"), F.entry(.macports, .port, "ripgrep"),
                               F.entry(.homebrew, .formula, "jq")])
        for order in [F.arm, F.intel] {
            let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: order)
            let plan = ActionPlanner.make(preview.requests(for: preview.initiallyChecked),
                                          engines: PlanFixtures.engines, order: order)
            #expect(!plan.problems.contains { $0.contains("Pick one") })
            #expect(plan.problems.isEmpty)
            #expect(plan.steps.count == 2)
            // Checking both copies does give the planner's problem.
            let all = Set(preview.groups.flatMap(\.rows).map(\.id))
            let both = ActionPlanner.make(preview.requests(for: all), engines: PlanFixtures.engines, order: order)
            #expect(both.problems.contains { $0.contains("Pick one") })
        }
    }

    @Test func sameNameTwiceInOneEngineIsPickOneInThePlan() throws {
        // The default selection plans fine; ticking both `jq` and `foo/bar/jq` is refused, like two engines' copies.
        let source = F.bundle([F.entry(.homebrew, .formula, "jq"), F.entry(.homebrew, .formula, "foo/bar/jq"),
                               F.entry(.homebrew, .formula, "wget")])
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let plan = ActionPlanner.make(preview.requests(for: preview.initiallyChecked),
                                      engines: PlanFixtures.engines, order: F.arm)
        #expect(plan.problems.isEmpty)
        let all = Set(preview.groups.flatMap(\.rows).map(\.id))
        let both = ActionPlanner.make(preview.requests(for: all), engines: PlanFixtures.engines, order: F.arm)
        #expect(both.problems == ["jq is selected twice from Homebrew (jq and foo/bar/jq). Pick one."])
        let arguments = both.steps.flatMap(\.spec.arguments)
        #expect(arguments.contains("wget"))
        #expect(!arguments.contains("jq") && !arguments.contains("foo/bar/jq"))
    }

    @Test func formulaAndCaskSameNameBothStartTicked() throws {
        // `brew "x"` and `cask "x"`: different kinds, so they install side by side and aren't duplicates.
        let source = F.bundle([F.entry(.homebrew, .formula, "docker"), F.entry(.homebrew, .cask, "docker")])
        let formula = PackageRef(engine: .homebrew, kind: .formula, name: "docker")
        let cask = PackageRef(engine: .homebrew, kind: .cask, name: "docker")
        let preview = ImportPreview.make(source, installed: F.nothing, status: F.allPresent, order: F.arm)
        let rows = preview.groups.flatMap(\.rows)
        #expect(rows.first { $0.id == formula }?.state == .willInstall)
        #expect(rows.first { $0.id == cask }?.state == .willInstall)
        #expect(preview.initiallyChecked == [formula, cask])

        // A second formula with that name still clashes with the first, not with the cask.
        let three = ImportPreview.make(F.bundle([F.entry(.homebrew, .formula, "docker"),
                                                 F.entry(.homebrew, .cask, "docker"),
                                                 F.entry(.homebrew, .formula, "foo/bar/docker")]),
                                       installed: F.nothing, status: F.allPresent, order: F.arm)
        let threeRows = three.groups.flatMap(\.rows)
        #expect(threeRows.first { $0.id == cask }?.state == .willInstall)
        #expect(threeRows.first { $0.id == formula }?.state == .duplicate(of: .homebrew))
        #expect(three.initiallyChecked == [formula, cask])
    }

    @Test func nanobrewSetupLinksToItsInstaller() throws {
        let setup = try #require(EngineSetup.setup(for: .nanobrew, status: .missing))
        #expect(setup.link == URL(string: "https://nanobrew.trilok.ai"))
        #expect(setup.reason == "nanobrew isn't installed")
        #expect((2...3).contains(setup.steps.count))
        #expect(setup.skippedCount == 0)
        #expect(EngineSetup.setup(for: .nanobrew, status: .present(path: URL(fileURLWithPath: "/x"), version: "1"))
                == nil)
        let masBroken = try #require(EngineSetup.setup(for: .mas, status: .unusable(path: URL(fileURLWithPath: "/x"),
                                                                                     reason: "exit 1")))
        #expect(masBroken.steps == ["Reinstall mas from its GitHub page, or fix the problem shown above.",
                                    "Then select Mac App Store in the sidebar and click Check again."])
        let links = EngineID.allCases.compactMap { EngineSetup.setup(for: $0, status: .missing)?.link.absoluteString }
        #expect(links == ["https://brew.sh", "https://nanobrew.trilok.ai", "https://www.macports.org/install.php",
                          "https://github.com/mas-cli/mas"])
    }
}
