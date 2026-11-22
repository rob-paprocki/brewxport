import Testing
import Foundation
@testable import BrewxPortCore

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/homebrew/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private struct InstalledShape: Decodable {
    struct Formula: Decodable { let name: String }
    struct Cask: Decodable { let token: String }
    let formulae: [Formula]
    let casks: [Cask]
}

private struct OutdatedShape: Decodable {
    struct Formula: Decodable {
        let name: String
        let installed_versions: [String]
        let current_version: String
    }
    let formulae: [Formula]
}

private let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
private func ok(_ out: String) -> CommandResult { CommandResult(exitCode: 0, stdout: out, stderr: "") }
private func ref(_ kind: PackageKind, _ name: String, engine: EngineID = .homebrew) -> PackageRef {
    PackageRef(engine: engine, kind: kind, name: name)
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@Suite struct HomebrewEngineTests {
    @Test func detectsVersion() async throws {
        let text = try fixture("version.txt")
        let engine = HomebrewEngine(runner: FakeRunner([["--version"]: ok(text)]), executable: brew)
        #expect(await engine.detect() == .present(path: brew, version: "7.0.13"))
    }

    @Test func detectsPkgInstallWithoutGit() async throws {
        let text = try fixture("version-no-git.txt")
        let engine = HomebrewEngine(runner: FakeRunner([["--version"]: ok(text)]), executable: brew)
        #expect(await engine.detect() == .present(path: brew, version: ">=4.3.0"))
    }

    @Test func engineInstalledAfterLaunchIsFoundOnTheNextDetect() async {
        let installed = LockedFlag()
        let engine = HomebrewEngine(runner: FakeRunner([["--version"]: ok("Homebrew 7.0.15\n")]),
                                    locate: { installed.value ? brew : nil })
        #expect(await engine.detect() == .missing)
        installed.set()
        #expect(await engine.detect() == .present(path: brew, version: "7.0.15"))
        #expect(engine.executableURL == brew)
    }

    @Test func detectMissingWithoutExecutable() async {
        let runner = FakeRunner([:])
        let engine = HomebrewEngine(runner: runner, executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
    }

    @Test func detectUnusableOnFailureOrGarbage() async {
        let fail = HomebrewEngine(runner: FakeRunner([["--version"]: CommandResult(exitCode: 1, stdout: "Homebrew 1.0.0", stderr: "")]), executable: brew)
        #expect(isUnusable(await fail.detect(), at: brew))
        let junk = HomebrewEngine(runner: FakeRunner([["--version"]: ok("hello\n")]), executable: brew)
        #expect(isUnusable(await junk.detect(), at: brew))
    }

    @Test func parsesFormulaSearch() async throws {
        let text = try fixture("search-formula.txt")
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let runner = FakeRunner([
            ["search", "--formula", "ripgrep"]: ok(text),
            ["search", "--cask", "ripgrep"]: CommandResult(exitCode: 1, stdout: "", stderr: ""),
        ])
        let result = try await HomebrewEngine(runner: runner, executable: brew).search("ripgrep")
        #expect(result.count == lines.count)
        #expect(result.map(\.id.name) == lines)
        #expect(result.allSatisfy { $0.id.kind == .formula && $0.id.engine == .homebrew && $0.displayName == $0.id.name })
    }

    @Test func parsesCaskSearch() async throws {
        let text = try fixture("search-cask.txt")
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let runner = FakeRunner([
            ["search", "--formula", "firefox"]: CommandResult(exitCode: 1, stdout: "", stderr: ""),
            ["search", "--cask", "firefox"]: ok(text),
        ])
        let result = try await HomebrewEngine(runner: runner, executable: brew).search("firefox")
        #expect(result.map(\.id.name) == lines)
        #expect(result.allSatisfy { $0.id.kind == .cask })
    }

    @Test func combinesFormulaeFirst() async throws {
        let runner = FakeRunner([
            ["search", "--formula", "x"]: ok("a\nb\n"),
            ["search", "--cask", "x"]: ok("c\n"),
        ])
        let result = try await HomebrewEngine(runner: runner, executable: brew).search("x")
        #expect(result.map(\.id) == [ref(.formula, "a"), ref(.formula, "b"), ref(.cask, "c")])
    }

    @Test func noMatchIsEmpty() async throws {
        let none = CommandResult(exitCode: 1, stdout: "", stderr: "")
        let runner = FakeRunner([["search", "--formula", "zzz"]: none, ["search", "--cask", "zzz"]: none])
        #expect(try await HomebrewEngine(runner: runner, executable: brew).search("zzz").isEmpty)
    }

    @Test func noMatchWithStderrOnlyIsEmpty() async throws {
        let none = CommandResult(exitCode: 1, stdout: "", stderr: "Error: No formulae or casks found for \"zzz\".")
        let runner = FakeRunner([["search", "--formula", "zzz"]: none, ["search", "--cask", "zzz"]: none])
        #expect(try await HomebrewEngine(runner: runner, executable: brew).search("zzz").isEmpty)
    }

    @Test func capturedNoMatchStderrIsEmpty() async throws {
        let none = CommandResult(exitCode: 1, stdout: "", stderr: try fixture("search-nomatch-stderr.txt"))
        let runner = FakeRunner([["search", "--formula", "zzzznotaformula"]: none, ["search", "--cask", "zzzznotaformula"]: none])
        #expect(try await HomebrewEngine(runner: runner, executable: brew).search("zzzznotaformula").isEmpty)
    }

    @Test func capturedBadRegexStderrThrows() async throws {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: try fixture("search-badregex-stderr.txt"))
        let runner = FakeRunner([["search", "--formula", "/[/"]: bad, ["search", "--cask", "/[/"]: bad])
        do {
            _ = try await HomebrewEngine(runner: runner, executable: brew).search("/[/")
            Issue.record("expected throw")
        } catch let e as EngineError {
            #expect(e.engine == .homebrew)
            #expect(e.message.contains("is not a valid regex"))
        }
    }

    @Test func exit1WithOtherStderrThrows() async {
        let bad = CommandResult(exitCode: 1, stdout: "", stderr: "Error: Permission denied @ rb_sysopen")
        let runner = FakeRunner([["search", "--formula", "q"]: bad, ["search", "--cask", "q"]: ok("")])
        await #expect(throws: EngineError.self) {
            _ = try await HomebrewEngine(runner: runner, executable: brew).search("q")
        }
    }

    @Test func commandRejectsDashName() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        #expect(throws: EngineError.self) {
            _ = try e.command(for: .remove, [ref(.formula, "--force")], options: InstallOptions())
        }
    }

    @Test func searchFailureThrows() async {
        let boom = CommandResult(exitCode: 2, stdout: "", stderr: "Error: boom")
        let runner = FakeRunner([["search", "--formula", "q"]: boom, ["search", "--cask", "q"]: ok("")])
        await #expect(throws: EngineError.self) {
            _ = try await HomebrewEngine(runner: runner, executable: brew).search("q")
        }
        let withOut = CommandResult(exitCode: 1, stdout: "partial", stderr: "")
        let runner2 = FakeRunner([["search", "--formula", "q"]: withOut, ["search", "--cask", "q"]: ok("")])
        await #expect(throws: EngineError.self) {
            _ = try await HomebrewEngine(runner: runner2, executable: brew).search("q")
        }
    }

    @Test func dashQueryUsesSeparator() async throws {
        let runner = FakeRunner([:])
        _ = try? await HomebrewEngine(runner: runner, executable: brew).search("-x")
        #expect(runner.calls.first == ["search", "--formula", "--", "-x"])
    }

    @Test func parsesInstalledVersions() async throws {
        let text = try fixture("info-installed.json")
        let shape = try JSONDecoder().decode(InstalledShape.self, from: Data(text.utf8))
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: ok(text)])
        let result = try await HomebrewEngine(runner: runner, executable: brew).listInstalled()
        #expect(result.count == shape.formulae.count + shape.casks.count)
        #expect(result.count > 0)
        #expect(result.allSatisfy { $0.installedVersion?.isEmpty == false })
        #expect(result.filter { $0.id.kind == .formula }.map(\.id.name) == shape.formulae.map(\.name))
        #expect(result.filter { $0.id.kind == .cask }.map(\.id.name) == shape.casks.map(\.token))
    }

    @Test func installedUsesLastFormulaVersionAndCaskString() async throws {
        let json = """
        {"formulae":[{"name":"f","installed":[{"version":"1"},{"version":"2"}],"extra":1}],
         "casks":[{"token":"c","installed":"9.9","version":"10"}]}
        """
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: ok(json)])
        let result = try await HomebrewEngine(runner: runner, executable: brew).listInstalled()
        #expect(result[0].installedVersion == "2")
        #expect(result[1].installedVersion == "9.9")
    }

    @Test func installedFailureIncludesStderr() async {
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: CommandResult(exitCode: 1, stdout: "", stderr: "  Error: kaput \n")])
        do {
            _ = try await HomebrewEngine(runner: runner, executable: brew).listInstalled()
            Issue.record("expected throw")
        } catch let e as EngineError {
            #expect(e.engine == .homebrew)
            #expect(e.message.contains("Error: kaput"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func installedBadJSONThrows() async {
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: ok("not json")])
        await #expect(throws: EngineError.self) {
            _ = try await HomebrewEngine(runner: runner, executable: brew).listInstalled()
        }
    }

    @Test func parsesOutdated() async throws {
        let text = try fixture("outdated.json")
        let shape = try JSONDecoder().decode(OutdatedShape.self, from: Data(text.utf8))
        let runner = FakeRunner([["outdated", "--json=v2"]: ok(text)])
        let result = try await HomebrewEngine(runner: runner, executable: brew).listOutdated()
        #expect(result.count == shape.formulae.count)
        #expect(result.count > 0)
        for (pkg, f) in zip(result, shape.formulae) {
            #expect(pkg.id == ref(.formula, f.name))
            #expect(pkg.installedVersion == f.installed_versions.last)
            #expect(pkg.latestVersion == f.current_version)
        }
    }

    @Test func parsesOutdatedCasks() async throws {
        let json = """
        {"formulae":[],"casks":[{"name":"foo","installed_versions":["1.0","1.1"],"current_version":"2.0"},
                                {"name":"bar","installed_versions":"3.0","current_version":"4.0"}]}
        """
        let runner = FakeRunner([["outdated", "--json=v2"]: ok(json)])
        let result = try await HomebrewEngine(runner: runner, executable: brew).listOutdated()
        #expect(result.map(\.id) == [ref(.cask, "foo"), ref(.cask, "bar")])
        #expect(result.map(\.installedVersion) == ["1.1", "3.0"])
        #expect(result.map(\.latestVersion) == ["2.0", "4.0"])
    }

    @Test func commandKeepsAtSignNames() throws {
        let spec = try HomebrewEngine(runner: FakeRunner([:]), executable: brew)
            .command(for: .install, [ref(.formula, "python@3.12")], options: InstallOptions())
        #expect(spec.arguments == ["install", "--formula", "python@3.12"])
        #expect(spec.executable == brew)
        #expect(spec.needsRoot == false)
    }

    @Test func formulaInstallPassesFormulaFlag() throws {
        // A formula entry named like a cask must never install the cask.
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        let spec = try e.command(for: .install, [ref(.formula, "firefox"), ref(.formula, "jq")],
                                 options: InstallOptions(extraArgs: ["--HEAD"]))
        #expect(spec.arguments == ["install", "--formula", "--HEAD", "firefox", "jq"])
        // Upgrades and removes are unchanged.
        #expect(try e.command(for: .upgrade, [ref(.formula, "jq")], options: InstallOptions()).arguments
                == ["upgrade", "jq"])
    }

    // MARK: taps

    @Test func tapInstallCommand() throws {
        let spec = try HomebrewEngine(runner: FakeRunner([:]), executable: brew)
            .command(for: .install, [ref(.tap, "felixkratz/formulae")], options: InstallOptions())
        #expect(spec.arguments == ["tap", "felixkratz/formulae"])
        #expect(spec.executable == brew)
        #expect(spec.needsRoot == false)
        #expect(HomebrewEngine(runner: FakeRunner([:]), executable: brew)
            .privilege(for: .install, ref(.tap, "felixkratz/formulae")) == .never)
    }

    @Test func twoTapRefsThrow() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        #expect(throws: EngineError.self) {
            _ = try e.command(for: .install, [ref(.tap, "a/b"), ref(.tap, "c/d")], options: InstallOptions())
        }
    }

    @Test func tapMixedWithFormulaThrows() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        for refs in [[ref(.tap, "a/b"), ref(.formula, "jq")], [ref(.formula, "jq"), ref(.tap, "a/b")],
                     [ref(.cask, "firefox"), ref(.tap, "a/b")]] {
            // The tap check runs first, so the error is the tap one, not "Formulae and casks …".
            #expect(throws: EngineError(engine: .homebrew, message: "Taps must be added in their own command"),
                    "\(refs)") {
                _ = try e.command(for: .install, refs, options: InstallOptions())
            }
        }
    }

    @Test func tapUpgradeThrows() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        for op in [PackageOperation.upgrade, .remove] {
            #expect(throws: EngineError.self, "\(op)") {
                _ = try e.command(for: op, [ref(.tap, "a/b")], options: InstallOptions())
            }
        }
    }

    @Test func tapWithOptionsOrBadNameThrows() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        for options in [InstallOptions(version: "1"), InstallOptions(variants: ["+x"]),
                        InstallOptions(extraArgs: ["--force"])] {
            #expect(throws: EngineError.self, "\(options)") {
                _ = try e.command(for: .install, [ref(.tap, "a/b")], options: options)
            }
        }
        for name in ["--force", "a", "a/b/c", "homebrew/core", "a/b.rb", ""] {
            #expect(throws: EngineError.self, "\(name)") {
                _ = try e.command(for: .install, [ref(.tap, name)], options: InstallOptions())
            }
        }
        let noExe = HomebrewEngine(runner: FakeRunner([:]), executable: nil)
        #expect(throws: EngineError.self) {
            _ = try noExe.command(for: .install, [ref(.tap, "a/b")], options: InstallOptions())
        }
    }

    @Test func caskInstallHasCaskFlag() throws {
        let spec = try HomebrewEngine(runner: FakeRunner([:]), executable: brew)
            .command(for: .install, [ref(.cask, "firefox")], options: InstallOptions(extraArgs: ["--no-quarantine"]))
        #expect(spec.arguments == ["install", "--cask", "--no-quarantine", "firefox"])
    }

    @Test func verbMap() throws {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        let r = [ref(.formula, "a"), ref(.formula, "b")]
        #expect(try e.command(for: .upgrade, r, options: InstallOptions()).arguments == ["upgrade", "a", "b"])
        #expect(try e.command(for: .remove, r, options: InstallOptions()).arguments == ["uninstall", "a", "b"])
    }

    @Test func nothingIsRootForBrew() throws {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(try e.command(for: op, [ref(.cask, "x")], options: InstallOptions()).needsRoot == false)
        }
        #expect(e.privilege(for: .install, ref(.cask, "x")) == .sometimes)
        #expect(e.privilege(for: .install, ref(.formula, "x")) == .never)
    }

    @Test func versionPinRejected() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        #expect(throws: EngineError.self) {
            _ = try e.command(for: .install, [ref(.formula, "a")], options: InstallOptions(version: "1.2"))
        }
        #expect(!e.capabilities.contains(.versionPinning))
    }

    @Test func variantsRejected() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(throws: EngineError.self) {
                _ = try e.command(for: op, [ref(.formula, "a")], options: InstallOptions(variants: ["+x11"]))
            }
        }
    }

    @Test func invalidRefsRejected() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        #expect(throws: EngineError.self) { _ = try e.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try e.command(for: .install, [ref(.formula, "a"), ref(.cask, "b")], options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try e.command(for: .install, [ref(.formula, "a", engine: .mas)], options: InstallOptions())
        }
        let noExe = HomebrewEngine(runner: FakeRunner([:]), executable: nil)
        #expect(throws: EngineError.self) { _ = try noExe.command(for: .install, [ref(.formula, "a")], options: InstallOptions()) }
    }

    @Test func capabilitiesAndId() {
        let e = HomebrewEngine(runner: FakeRunner([:]), executable: brew)
        #expect(e.id == .homebrew)
        #expect(e.capabilities == [.casks, .jsonOutput])
    }
}

private let intelBrew = URL(fileURLWithPath: "/usr/local/bin/brew")
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func next() -> Int { lock.withLock { n += 1; return n } }
}

private let archTool = URL(fileURLWithPath: "/usr/bin/arch")

@Suite struct HomebrewArchTests {
    private func versionOK() -> CommandResult { ok("Homebrew 4.4.0\n") }

    @Test func usrLocalBrewOnArmRunsUnderArch() async throws {
        let wrapped = ["-x86_64", "/usr/local/bin/brew"]
        let runner = FakeRunner([
            wrapped + ["--version"]: versionOK(),
            wrapped + ["search", "--formula", "tree"]: ok("tree\n"),
            wrapped + ["search", "--cask", "tree"]: ok(""),
            wrapped + ["info", "--json=v2", "--installed"]: ok(#"{"formulae":[],"casks":[]}"#),
            wrapped + ["outdated", "--json=v2"]: ok(#"{"formulae":[],"casks":[]}"#),
        ])
        let engine = HomebrewEngine(runner: runner, executable: intelBrew, arch: .arm64)
        #expect(await engine.detect() == .present(path: intelBrew, version: "4.4.0"))
        #expect(try await engine.search("tree").map(\.id.name) == ["tree"])
        _ = try await engine.listInstalled()
        _ = try await engine.listOutdated()
        #expect(runner.calls.count == 5)
        #expect(runner.executableCalls.allSatisfy { $0 == archTool })
        #expect(runner.calls.allSatisfy { Array($0.prefix(2)) == wrapped })
        let spec = try engine.command(for: .install, [ref(.formula, "tree")], options: InstallOptions())
        #expect(spec.arch == .x86_64)
        let launch = spec.launchCommand(host: .arm64)
        #expect(launch.executable == archTool)
        #expect(launch.arguments == ["-x86_64", "/usr/local/bin/brew", "install", "--formula", "tree"])
    }

    @Test func anOperationKeepsOnePathEvenIfTheLocatorsAnswerChanges() async throws {
        let wrapped = ["-x86_64", "/usr/local/bin/brew"]
        let runner = FakeRunner([
            wrapped + ["info", "--json=v2", "--installed"]: ok(#"{"formulae":[],"casks":[]}"#),
            ["--version"]: versionOK(),
        ])
        // The first answer (at launch) is the Intel brew; every later lookup would say the native one.
        let lookups = LockedCounter()
        let engine = HomebrewEngine(runner: runner, locate: { lookups.next() == 1 ? intelBrew : brew }, arch: .arm64)
        _ = try await engine.listInstalled()
        #expect(runner.executableCalls == [archTool])
        #expect(Array(runner.calls[0].prefix(2)) == wrapped)
        #expect(lookups.count == 1)
        // Only detect() looks again.
        #expect(await engine.detect() == .present(path: brew, version: "4.4.0"))
        #expect(runner.executableCalls == [archTool, brew])
        #expect(engine.runArch == .arm64)
    }

    @Test func optHomebrewRunsNative() async throws {
        let runner = FakeRunner([["--version"]: versionOK()])
        let engine = HomebrewEngine(runner: runner, executable: brew, arch: .arm64)
        _ = await engine.detect()
        #expect(runner.executableCalls == [brew])
        let spec = try engine.command(for: .install, [ref(.formula, "tree")], options: InstallOptions())
        #expect(spec.arch == nil)
        let launch = spec.launchCommand(host: .arm64)
        #expect(launch.executable == brew)
        #expect(launch.arguments == ["install", "--formula", "tree"])
    }

    @Test func intelMacRunsNative() async throws {
        let runner = FakeRunner([["--version"]: versionOK()])
        let engine = HomebrewEngine(runner: runner, executable: intelBrew, arch: .x86_64)
        #expect(await engine.detect() == .present(path: intelBrew, version: "4.4.0"))
        #expect(runner.executableCalls == [intelBrew])
        let spec = try engine.command(for: .upgrade, [ref(.formula, "tree")], options: InstallOptions())
        let launch = spec.launchCommand(host: .x86_64)
        #expect(launch.executable == intelBrew)
        #expect(launch.arguments == ["upgrade", "tree"])
    }

    @Test func usrLocalBrewOnArmRunsAsX86() {
        let intel = HomebrewEngine(runner: FakeRunner([:]), executable: URL(fileURLWithPath: "/usr/local/bin/brew"),
                                   arch: .arm64)
        #expect(intel.runArch == .x86_64)
        #expect(intel.executableURL?.path == "/usr/local/bin/brew")
        let native = HomebrewEngine(runner: FakeRunner([:]), executable: brew, arch: .arm64)
        #expect(native.runArch == .arm64)
        // Through the protocol, so the override is what callers see.
        let erased: any Engine = intel
        #expect(erased.runArch == .x86_64)
    }
}

// MARK: info

private let ripgrepFormula = ref(.formula, "ripgrep")

@Suite struct HomebrewInfoTests {
    private func engine(_ argv: [String], _ fixtureName: String) throws -> (HomebrewEngine, FakeRunner) {
        let runner = FakeRunner([argv: ok(try fixture(fixtureName))])
        return (HomebrewEngine(runner: runner, executable: brew, arch: .arm64), runner)
    }

    @Test func infoFormulaFromCapture() async throws {
        let (e, _) = try engine(["info", "--json=v2", "--formula", "ripgrep"], "info-ripgrep.json")
        let d = try await e.info(ripgrepFormula)
        #expect(d.ref == ripgrepFormula)
        #expect(d.summary == "Search tool like grep and The Silver Searcher")
        #expect(d.homepage == URL(string: "https://github.com/BurntSushi/ripgrep"))
        #expect(d.latestVersion == "15.2.0")
        #expect(d.installedVersion == nil)
        #expect(d.dependencies == ["pcre2"])
        #expect(d.variants.isEmpty)
        #expect(d.installerNeedsRoot == nil)
    }

    @Test func infoCaskWithPkgNeedsRoot() async throws {
        let (e, _) = try engine(["info", "--json=v2", "--cask", "blackhole-2ch"], "info-cask-blackhole-2ch.json")
        let d = try await e.info(ref(.cask, "blackhole-2ch"))
        #expect(d.summary == "Virtual Audio Driver")
        #expect(d.homepage == URL(string: "https://existential.audio/blackhole/"))
        #expect(d.latestVersion == "0.7.1")
        #expect(d.installerNeedsRoot == true)
        // `depends_on` names no formula: the cask needs none.
        #expect(d.dependencies == [])
    }

    @Test func infoCaskReadsFormulaDependencies() async throws {
        // Real capture: the droid cask's `depends_on.formula` is ["ripgrep"].
        let (e, _) = try engine(["info", "--json=v2", "--cask", "droid"], "info-cask-droid.json")
        let d = try await e.info(ref(.cask, "droid"))
        #expect(d.dependencies == ["ripgrep"])
        #expect(d.reportedName == "droid")
    }

    @Test func infoCaskAppOnlyDoesntNeedRoot() async throws {
        let (e, _) = try engine(["info", "--json=v2", "--cask", "firefox"], "info-cask-firefox.json")
        let d = try await e.info(ref(.cask, "firefox"))
        #expect(d.summary == "Web browser")
        #expect(d.homepage == URL(string: "https://www.mozilla.org/firefox/"))
        #expect(d.latestVersion == "160.0")
        #expect(d.installerNeedsRoot == false)
    }

    @Test func infoArgvUsesKindFlag() async throws {
        let (e, runner) = try engine(["info", "--json=v2", "--formula", "ripgrep"], "info-ripgrep.json")
        _ = try await e.info(ripgrepFormula)
        #expect(runner.calls == [["info", "--json=v2", "--formula", "ripgrep"]])
        let (c, cRunner) = try engine(["info", "--json=v2", "--cask", "firefox"], "info-cask-firefox.json")
        _ = try await c.info(ref(.cask, "firefox"))
        #expect(cRunner.calls == [["info", "--json=v2", "--cask", "firefox"]])
    }

    @Test func infoInstalledFixtureStillParses() async throws {
        let (e, _) = try engine(["info", "--json=v2", "--formula", "abseil"], "info-installed.json")
        let d = try await e.info(ref(.formula, "abseil"))
        #expect(d.summary == "C++ Common Libraries")
        #expect(d.homepage == URL(string: "https://abseil.io"))
        #expect(d.installedVersion == "20260817.0")
    }

    @Test func infoRejectsBadNamesWithoutRunning() async {
        let runner = FakeRunner([:])
        let e = HomebrewEngine(runner: runner, executable: brew, arch: .arm64)
        await #expect(throws: EngineError.self) { try await e.info(ref(.formula, "--evil")) }
        await #expect(throws: EngineError.self) { try await e.info(ref(.port, "ripgrep")) }
        await #expect(throws: EngineError.self) { try await e.info(ref(.formula, "ripgrep", engine: .mas)) }
        #expect(runner.calls.isEmpty)
    }

    @Test func infoFailsOnBadOutput() async {
        let argv = ["info", "--json=v2", "--formula", "ripgrep"]
        for result in [ok("not json"), ok(#"{"formulae":[],"casks":[]}"#),
                       CommandResult(exitCode: 1, stdout: "", stderr: "Error: No available formula")] {
            let e = HomebrewEngine(runner: FakeRunner([argv: result]), executable: brew, arch: .arm64)
            await #expect(throws: EngineError.self) { try await e.info(ripgrepFormula) }
        }
    }

    @Test func infoIntelBrewRunsUnderRosetta() async throws {
        let intel = URL(fileURLWithPath: "/usr/local/bin/brew")
        let argv = ["-x86_64", "/usr/local/bin/brew", "info", "--json=v2", "--formula", "ripgrep"]
        let runner = FakeRunner([argv: ok(try fixture("info-ripgrep.json"))])
        let e = HomebrewEngine(runner: runner, executable: intel, arch: .arm64)
        _ = try await e.info(ripgrepFormula)
        #expect(runner.calls == [argv])
        #expect(runner.executableCalls == [URL(fileURLWithPath: "/usr/bin/arch")])
    }
}

// MARK: taps (Plan 4 Task 3)

extension HomebrewEngineTests {
    @Test func listTapsParsesCapture() async throws {
        let runner = FakeRunner([["tap"]: ok(try fixture("tap.txt"))])
        let taps = try await HomebrewEngine(runner: runner, executable: brew).listTaps()
        #expect(taps == ["felixkratz/formulae"])
        #expect(runner.calls == [["tap"]])
        #expect(runner.optionsCalls.first?.timeout == BrewxPortTimeouts.engineQuery)
    }

    @Test func listTapsRejectsGarbage() async throws {
        // DERIVED from the real tap.txt capture: one path-like line added.
        let text = try fixture("tap.txt") + "../x\n"
        let engine = HomebrewEngine(runner: FakeRunner([["tap"]: ok(text)]), executable: brew)
        await #expect(throws: EngineError.self) { try await engine.listTaps() }
    }

    @Test func listTapsSkipsBuiltInTaps() async throws {
        // DERIVED from the real tap.txt capture: Homebrew's own taps added around it, as older brew lists them.
        let text = "homebrew/core\n" + (try fixture("tap.txt")) + "homebrew/cask\n"
        let engine = HomebrewEngine(runner: FakeRunner([["tap"]: ok(text)]), executable: brew)
        #expect(try await engine.listTaps() == ["felixkratz/formulae"])
    }

    @Test func listTapsFailsOnNonZeroExitAndWithoutBrew() async throws {
        let failing = HomebrewEngine(runner: FakeRunner([["tap"]: CommandResult(exitCode: 1, stdout: "", stderr: "x")]),
                                     executable: brew)
        await #expect(throws: EngineError.self) { try await failing.listTaps() }
        let missing = HomebrewEngine(runner: FakeRunner([:]), executable: nil)
        await #expect(throws: EngineError.self) { try await missing.listTaps() }
    }

    @Test func installedCoreAndCaskPackagesHaveNoFullName() async throws {
        let runner = FakeRunner([["info", "--json=v2", "--installed"]: ok(try fixture("info-installed.json"))])
        let result = try await HomebrewEngine(runner: runner, executable: brew).listInstalled()
        #expect(!result.isEmpty)
        #expect(result.allSatisfy { $0.fullName == nil })
    }
}
