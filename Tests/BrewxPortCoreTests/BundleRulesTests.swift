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

private func check(
    _ engine: EngineID, _ kind: PackageKind, _ name: String, displayName: String? = nil,
    variants: [String] = [], extraArgs: [String] = []
) -> BundleVerdict {
    BundleRules.check(engine: engine, kind: kind, name: name, displayName: displayName, variants: variants, extraArgs: extraArgs)
}

private func isAccepted(_ v: BundleVerdict) -> Bool {
    if case .accepted = v { return true }
    return false
}

private func reason(_ v: BundleVerdict) -> String? {
    if case .rejected(let r) = v { return r }
    return nil
}

/// The (engine, kind) pairs that can carry a name, with a display name where mas needs one.
private let everyEngineKind: [(EngineID, PackageKind)] = [
    (.homebrew, .formula), (.homebrew, .cask), (.homebrew, .tap),
    (.nanobrew, .formula), (.nanobrew, .cask), (.macports, .port), (.mas, .app),
]

@Suite struct BundleRulesTests {
    @Test func acceptsEveryRealInstalledName() async throws {
        let brew = try await HomebrewEngine(
            runner: FakeRunner([["info", "--json=v2", "--installed"]: ok(try fixture("homebrew/info-installed.json"))]),
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        ).listInstalled()
        let nb = try await NanobrewEngine(
            runner: FakeRunner([["list", "--json"]: ok(try fixture("nanobrew/list.json"))]),
            executable: URL(fileURLWithPath: "/opt/nanobrew/prefix/bin/nb")
        ).listInstalled()
        let portText = try fixture("macports/installed.txt")
        let ports = try await MacPortsEngine(
            runner: FakeRunner([["-v", "-q", "installed", "active"]: ok(portText)]),
            executable: URL(fileURLWithPath: "/opt/local/bin/port")
        ).listInstalled()
        let apps = try await MasEngine(
            runner: FakeRunner([["list", "--json"]: ok(try fixture("mas/list.json"))]),
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/mas")
        ).listInstalled()
        #expect(!brew.isEmpty && !nb.isEmpty && ports.count == 18 && !apps.isEmpty)

        // DERIVED from the real installed.txt capture: each port's `requested_variants='…'` value, split into
        // `+name`/`-name` tokens. The MacPorts parser doesn't return variants yet (Task 3 adds that).
        var variantsByPort: [String: [String]] = [:]
        for line in portText.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let name = fields.first,
                  let field = fields.first(where: { $0.hasPrefix("requested_variants='") }) else { continue }
            let value = field.dropFirst("requested_variants='".count).dropLast()
            var tokens: [String] = []
            for ch in value {
                if ch == "+" || ch == "-" { tokens.append(String(ch)) } else if !tokens.isEmpty { tokens[tokens.count - 1].append(ch) }
            }
            variantsByPort[String(name)] = tokens
        }
        #expect(variantsByPort["bzip2"] == ["+universal"])
        #expect(variantsByPort["autoconf"] == [])

        for pkg in brew + nb + apps {
            let v = check(pkg.id.engine, pkg.id.kind, pkg.id.name, displayName: pkg.displayName)
            #expect(isAccepted(v), "\(pkg.id): \(reason(v) ?? "")")
        }
        for pkg in ports {
            let variants = try #require(variantsByPort[pkg.id.name])
            let v = check(.macports, .port, pkg.id.name, variants: variants)
            #expect(v == .accepted(ref: pkg.id, displayName: pkg.id.name, options: InstallOptions(variants: variants)))
        }
        // The real tap list.
        for tap in try fixture("homebrew/tap.txt").split(separator: "\n") {
            #expect(isAccepted(check(.homebrew, .tap, String(tap))))
        }
    }

    @Test func rejectsDashLeadingNames() {
        for name in ["-x", "--no-quarantine", "--force"] {
            for (engine, kind) in everyEngineKind {
                #expect(!isAccepted(check(engine, kind, name, displayName: "App")), "\(engine) \(kind) \(name)")
            }
        }
    }

    @Test func rejectsPathLikeNames() {
        for name in ["../x", "./x", "/usr/bin/x", "a/../b", "a//b", "~/x", "a/b/c/d", "a/b/", "/", "..", "."] {
            for (engine, kind) in everyEngineKind {
                #expect(!isAccepted(check(engine, kind, name, displayName: "App")), "\(engine) \(kind) \(name)")
            }
        }
        // Three segments are a tap-qualified formula or cask on Homebrew only.
        #expect(isAccepted(check(.homebrew, .formula, "felixkratz/formulae/borders")))
        #expect(isAccepted(check(.homebrew, .cask, "homebrew/cask-fonts/font-x")))
        #expect(!isAccepted(check(.homebrew, .formula, "a/b")))
        #expect(!isAccepted(check(.nanobrew, .formula, "felixkratz/formulae/borders")))
    }

    @Test func rejectsWhitespaceControlAndOverlongNames() {
        let hostile = ["jq ", " jq", "j q", "jq\n", "jq\t", "j\u{0}q", "j\u{1B}q", "jq\u{202E}", "j\u{200B}q",
                       "j\u{00A0}q", "ｊｑ", "jq;rm", "jq|x", "jq$x", "jq`x`", "jq*", "jq:x", "jq'", "jq\"", ""]
        for name in hostile {
            for (engine, kind) in everyEngineKind {
                #expect(!isAccepted(check(engine, kind, name, displayName: "App")), "\(engine) \(kind) \(name.debugDescription)")
            }
        }
        let max = String(repeating: "a", count: 200)
        #expect(isAccepted(check(.homebrew, .formula, max)))
        #expect(!isAccepted(check(.homebrew, .formula, max + "a")))
        #expect(!isAccepted(check(.macports, .port, max + "a")))
        // Combining marks don't sneak past the length limit by hiding in one Character.
        #expect(!BundleRules.isValidFormulaName("a" + String(repeating: "\u{301}", count: 300), engine: .homebrew))
    }

    @Test func rejectsMacPortsPseudoPortNames() {
        for name in ["installed", "outdated", "all", "NOT", "and", "or", "leaves", "name:x", "x*"] {
            #expect(!isAccepted(check(.macports, .port, name)), "\(name)")
        }
    }

    @Test func rejectsExtraArgsOutsideMacPorts() {
        for (engine, kind) in [(EngineID.homebrew, PackageKind.formula), (.homebrew, .cask), (.homebrew, .tap),
                               (.nanobrew, .formula), (.mas, .app)] {
            let name = engine == .mas ? "1519867270" : (kind == .tap ? "felixkratz/formulae" : "jq")
            let v = check(engine, kind, name, displayName: "App", extraArgs: ["--no-quarantine"])
            #expect(!isAccepted(v))
            #expect(reason(v)?.contains("--no-quarantine") == true, "\(reason(v) ?? "")")
        }
    }

    @Test func reasonsNeverEchoControlCharacters() throws {
        let v = check(.homebrew, .formula, "jq", extraArgs: ["--x\u{1B}[2J\u{202E}" + String(repeating: "y", count: 500)])
        let r = try #require(reason(v))
        #expect(!r.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{202E}" })
        #expect(r.count < 300)
        let n = try #require(reason(check(.homebrew, .formula, "j\u{7}q")))
        #expect(!n.unicodeScalars.contains("\u{7}"))
    }

    @Test func macPortsExtraArgsFromFilesOnlySourceOrBinary() throws {
        for good in [["-s"], ["-b"], ["-s", "-b"]] {
            #expect(check(.macports, .port, "jq", extraArgs: good)
                == .accepted(ref: PackageRef(engine: .macports, kind: .port, name: "jq"), displayName: "jq",
                             options: InstallOptions(extraArgs: good)))
        }
        // Allowed when typed in the app (RootArguments.macPortsExtraArgs), but never taken from a file.
        for bad in ["-n", "-R", "-u", "-c"] {
            let r = try #require(reason(check(.macports, .port, "jq", extraArgs: ["-s", bad])), "\(bad)")
            #expect(r.contains(bad), "\(r)")
            #expect(!r.contains("-s,") && !r.hasSuffix("-s"), "\(r)")
        }
    }

    @Test func rejectsLocalFileNamesForHomebrewAndNanobrew() throws {
        for name in ["x.rb", "x.json", "X.RB", "x.Json", "felixkratz/formulae/borders.rb", "a/b.json"] {
            for (engine, kind) in [(EngineID.homebrew, PackageKind.formula), (.homebrew, .cask), (.homebrew, .tap),
                                   (.nanobrew, .formula), (.nanobrew, .cask)] {
                let r = try #require(reason(check(engine, kind, name)), "\(engine) \(kind) \(name)")
                #expect(r.contains(name), "\(r)")
            }
        }
        #expect(!BundleRules.isValidFormulaName("jq.rb", engine: .homebrew))
        #expect(!BundleRules.isValidFormulaName("jq.JSON", engine: .nanobrew))
        #expect(!BundleRules.isValidTapName("a/b.rb"))
        // Only the ending counts, and MacPorts ports are not Homebrew files.
        #expect(isAccepted(check(.homebrew, .formula, "rb")))
        #expect(isAccepted(check(.homebrew, .formula, "x.rbx")))
        #expect(isAccepted(check(.homebrew, .formula, "json-c")))
        #expect(isAccepted(check(.macports, .port, "x.rb")))
    }

    @Test func macPortsExtraArgsAllowList() {
        #expect(check(.macports, .port, "jq", extraArgs: ["-s"])
            == .accepted(ref: PackageRef(engine: .macports, kind: .port, name: "jq"), displayName: "jq",
                         options: InstallOptions(extraArgs: ["-s"])))
        for bad in ["-f", "--no-quarantine", "-s ", "-sf", "", "-y"] {
            let v = check(.macports, .port, "jq", extraArgs: ["-s", bad])
            #expect(!isAccepted(v), "\(bad.debugDescription)")
        }
    }

    @Test func macPortsVariantsChecked() {
        #expect(isAccepted(check(.macports, .port, "bzip2", variants: ["+universal"])))
        #expect(isAccepted(check(.macports, .port, "bzip2", variants: ["-x11", "+universal"])))
        for bad in ["+a;rm", "+x", "universal", "+", "+univ ersal", "+uni\u{0}versal", "--force"] {
            #expect(!isAccepted(check(.macports, .port, "bzip2", variants: [bad])), "\(bad.debugDescription)")
        }
    }

    @Test func rejectsVariantsOutsideMacPorts() {
        for (engine, kind) in [(EngineID.homebrew, PackageKind.formula), (.homebrew, .cask), (.homebrew, .tap),
                               (.nanobrew, .formula), (.nanobrew, .cask), (.mas, .app)] {
            let name = engine == .mas ? "1519867270" : (kind == .tap ? "felixkratz/formulae" : "jq")
            #expect(!isAccepted(check(engine, kind, name, displayName: "App", variants: ["+universal"])), "\(engine) \(kind)")
        }
    }

    @Test func masIDDigitsOnly() {
        #expect(check(.mas, .app, "1519867270", displayName: "Hidden Bar")
            == .accepted(ref: PackageRef(engine: .mas, kind: .app, name: "1519867270"), displayName: "Hidden Bar",
                         options: InstallOptions()))
        #expect(BundleRules.isValidMasID("1"))
        #expect(BundleRules.isValidMasID(String(repeating: "9", count: 15)))
        for bad in ["12a", "-1", "", String(repeating: "1", count: 16), "+1", " 1", "1.0", "١٢٣", "１２３", "0x1F"] {
            #expect(!BundleRules.isValidMasID(bad), "\(bad)")
            #expect(!isAccepted(check(.mas, .app, bad, displayName: "App")), "\(bad)")
        }
    }

    @Test func masDisplayNameRequiredAndCleaned() {
        #expect(!isAccepted(check(.mas, .app, "1519867270", displayName: nil)))
        #expect(!isAccepted(check(.mas, .app, "1519867270", displayName: "")))
        #expect(!isAccepted(check(.mas, .app, "1519867270", displayName: " \u{7}\u{202E} ")))
        #expect(check(.mas, .app, "1519867270", displayName: "Hid\u{0}den\u{202E} Bar\n")
            == .accepted(ref: PackageRef(engine: .mas, kind: .app, name: "1519867270"), displayName: "Hidden Bar",
                         options: InstallOptions()))
        #expect(isAccepted(check(.mas, .app, "1", displayName: String(repeating: "é", count: 200))))
        #expect(!isAccepted(check(.mas, .app, "1", displayName: String(repeating: "x", count: 201))))
    }

    @Test func tapNames() {
        for good in ["felixkratz/formulae", "FelixKratz/formulae", "a-b/c_d.e"] {
            #expect(BundleRules.isValidTapName(good), "\(good)")
            #expect(check(.homebrew, .tap, good)
                == .accepted(ref: PackageRef(engine: .homebrew, kind: .tap, name: good), displayName: good,
                             options: InstallOptions()))
        }
        for bad in ["../x", "a/b/c", "-a/b", "homebrew/core", "Homebrew/Cask", "HOMEBREW/CORE", "a", "a/", "/b",
                    "a/b@1", "a/b+c", "a /b", "a/.b"] {
            #expect(!BundleRules.isValidTapName(bad), "\(bad)")
            #expect(!isAccepted(check(.homebrew, .tap, bad)), "\(bad)")
        }
    }

    @Test func kindMustFitEngine() {
        #expect(!isAccepted(check(.macports, .tap, "felixkratz/formulae")))
        #expect(!isAccepted(check(.homebrew, .port, "jq")))
        #expect(!isAccepted(check(.homebrew, .app, "1519867270", displayName: "App")))
        #expect(!isAccepted(check(.nanobrew, .tap, "felixkratz/formulae")))
        #expect(!isAccepted(check(.nanobrew, .port, "jq")))
        #expect(!isAccepted(check(.macports, .formula, "jq")))
        #expect(!isAccepted(check(.mas, .formula, "1519867270", displayName: "App")))
        #expect(isAccepted(check(.nanobrew, .cask, "firefox")))
    }

    @Test func languageToolsNeverAccepted() {
        // Bundles don't carry language tools (Plan 9 design), so an import never turns one into a request.
        for engine in [EngineID.npm, .pipx, .uv, .cargo, .bun, .gem, .mint] {
            #expect(reason(check(engine, .tool, "ripgrep")) == "language tools aren't included in bundles")
            #expect(!isAccepted(check(engine, .formula, "ripgrep")))
        }
        #expect(!isAccepted(check(.homebrew, .tool, "ripgrep")))
        #expect(reason(check(.homebrew, .tool, "ripgrep")) == "Homebrew has no tools")
    }

    @Test func firstFailureIsTheReason() {
        // Wrong kind wins over a bad name, a bad name over bad options.
        let wrongKind = reason(check(.macports, .tap, "--force", extraArgs: ["--no-quarantine"]))
        #expect(wrongKind?.contains("--no-quarantine") == false)
        let badName = reason(check(.homebrew, .formula, "../x", extraArgs: ["--no-quarantine"]))
        #expect(badName?.contains("--no-quarantine") == false)
    }

    @Test func displayNameDerivedFromName() {
        #expect(check(.homebrew, .formula, "jq", displayName: "ripgrep")
            == .accepted(ref: PackageRef(engine: .homebrew, kind: .formula, name: "jq"), displayName: "jq",
                         options: InstallOptions()))
        #expect(check(.macports, .port, "jq", displayName: "ripgrep")
            == .accepted(ref: PackageRef(engine: .macports, kind: .port, name: "jq"), displayName: "jq",
                         options: InstallOptions()))
        #expect(check(.nanobrew, .formula, "jq", displayName: "--force\u{1B}")
            == .accepted(ref: PackageRef(engine: .nanobrew, kind: .formula, name: "jq"), displayName: "jq",
                         options: InstallOptions()))
    }

    @Test func versionNeverSet() {
        let verdicts = [
            check(.homebrew, .formula, "jq"), check(.homebrew, .cask, "firefox"), check(.homebrew, .tap, "a/b"),
            check(.nanobrew, .formula, "jq"), check(.macports, .port, "bzip2", variants: ["+universal"], extraArgs: ["-s"]),
            check(.mas, .app, "1519867270", displayName: "App"),
        ]
        for v in verdicts {
            guard case .accepted(_, _, let options) = v else { Issue.record("not accepted: \(v)"); continue }
            #expect(options.version == nil)
        }
    }

    @Test func matchKeyStripsTapPrefixAndCase() {
        let qualified = PackageRef(engine: .homebrew, kind: .formula, name: "felixkratz/formulae/Borders")
        let bare = PackageRef(engine: .homebrew, kind: .formula, name: "borders")
        #expect(BundleRules.matchKey(qualified) == BundleRules.matchKey(bare))
        #expect(BundleRules.matchKey(bare) == "homebrew/formula/borders")
        #expect(BundleRules.matchKey(PackageRef(engine: .homebrew, kind: .cask, name: "borders")) != BundleRules.matchKey(bare))
        #expect(BundleRules.matchKey(PackageRef(engine: .nanobrew, kind: .formula, name: "borders")) != BundleRules.matchKey(bare))
    }

    @Test func matchKeyKeepsWholeTapName() {
        let tap = PackageRef(engine: .homebrew, kind: .tap, name: "FelixKratz/Formulae")
        #expect(BundleRules.matchKey(tap) == "homebrew/tap/felixkratz/formulae")
        #expect(BundleRules.matchKey(tap) == BundleRules.matchKey(PackageRef(engine: .homebrew, kind: .tap, name: "felixkratz/formulae")))
        #expect(BundleRules.matchKey(tap) != BundleRules.matchKey(PackageRef(engine: .homebrew, kind: .tap, name: "other/formulae")))
    }

    @Test func duplicateKeyUsesMasDisplayName() {
        let app = Package(id: PackageRef(engine: .mas, kind: .app, name: "1176074088"), displayName: "Termius")
        #expect(BundleRules.duplicateKey(app) == "termius")
        let cask = Package(id: PackageRef(engine: .homebrew, kind: .cask, name: "termius"), displayName: "Termius")
        #expect(BundleRules.duplicateKey(app) == BundleRules.duplicateKey(cask))
        let qualified = Package(id: PackageRef(engine: .homebrew, kind: .formula, name: "felixkratz/formulae/Borders"), displayName: "x")
        let nb = Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: "borders"), displayName: "y")
        #expect(BundleRules.duplicateKey(qualified) == "borders")
        #expect(BundleRules.duplicateKey(qualified) == BundleRules.duplicateKey(nb))
        let rg1 = Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: "ripgrep"), displayName: "ripgrep")
        let rg2 = Package(id: PackageRef(engine: .macports, kind: .port, name: "ripgrep"), displayName: "ripgrep")
        #expect(BundleRules.duplicateKey(rg1) == BundleRules.duplicateKey(rg2))
    }

    @Test func duplicateKeyKeepsWholeTapName() {
        let a = Package(id: PackageRef(engine: .homebrew, kind: .tap, name: "alice/Tap"), displayName: "alice/Tap")
        let b = Package(id: PackageRef(engine: .homebrew, kind: .tap, name: "bob/tap"), displayName: "bob/tap")
        let f = Package(id: PackageRef(engine: .nanobrew, kind: .formula, name: "tap"), displayName: "tap")
        #expect(BundleRules.duplicateKey(a) != BundleRules.duplicateKey(b))
        #expect(BundleRules.duplicateKey(a) != BundleRules.duplicateKey(f))
        #expect(BundleRules.duplicateKey(a) == BundleRules.duplicateKey(
            Package(id: PackageRef(engine: .homebrew, kind: .tap, name: "ALICE/tap"), displayName: "")))
    }
}
