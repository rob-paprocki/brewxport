import Foundation
import Testing
@testable import BrewxPortCore

/// One captured npm command from `Fixtures/npm` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`, stderr
/// from `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/npm")
    func read(_ file: String) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

private let npm = URL(fileURLWithPath: "/opt/homebrew/bin/npm")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let viewArguments = ["name", "version", "description", "homepage", "--json"]
private let listArguments = ["ls", "-g", "--json", "--depth=0"]

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .npm, kind: .tool, name: name) }

/// An npm answering `responses`, and `ls -g` as captured (`ls-g.json`) unless `responses` answer it: an outdated check
/// lists first (R14).
private func engine(_ responses: [[String]: CommandResult], executable: URL? = npm,
                    homebrewNode: Bool = true) -> (NpmEngine, FakeRunner) {
    var answers = responses
    if answers[listArguments] == nil { answers[listArguments] = try? captured("ls-g") }
    let runner = FakeRunner(answers)
    return (NpmEngine(runner: runner, executable: executable, base: base, homebrewNode: { _ in homebrewNode }), runner)
}

@Suite struct NpmEngineTests {
    // MARK: detect

    @Test func detectsVersionAndGlobalPrefix() async throws {
        let (engine, runner) = engine([["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g")])
        #expect(engine.installLocation == nil)
        #expect(await engine.detect() == .present(path: npm, version: "11.20.0"))
        #expect(engine.installLocation == URL(fileURLWithPath: "/opt/homebrew"))
        #expect(runner.calls == [["--version"], ["prefix", "-g"]])
        // The same npm's prefix isn't asked again on the next detect.
        #expect(await engine.detect() == .present(path: npm, version: "11.20.0"))
        #expect(engine.installLocation == URL(fileURLWithPath: "/opt/homebrew"))
        #expect(runner.calls == [["--version"], ["prefix", "-g"], ["--version"]])
    }

    @Test func detectMissingWithoutExecutable() async {
        let (engine, runner) = engine([:], executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
    }

    /// Not a capture: `npm prefix -g` never failed in the captures (Task 0's, nor T13's missing node, old Node and
    /// unwritable prefix, where it answered or `--version` failed first), so its failure here is made up.
    @Test func failedPrefixKeepsNpmPresent() async throws {
        let refused = CommandResult(exitCode: 1, stdout: "", stderr: "npm error")
        let (engine, runner) = engine([["--version"]: try captured("version"), ["prefix", "-g"]: refused])
        #expect(await engine.detect() == .present(path: npm, version: "11.20.0"))
        #expect(engine.installLocation == nil)
        // A prefix npm didn't give is asked again next time.
        runner.respond(["prefix", "-g"], try captured("prefix-g"))
        _ = await engine.detect()
        #expect(engine.installLocation == URL(fileURLWithPath: "/opt/homebrew"))
        #expect(runner.calls.filter { $0 == ["prefix", "-g"] }.count == 2)
    }

    /// npm without a `node` on PATH (`t13-no-node-version`: exit 127, `env: node: No such file or directory`).
    @Test func detectUnusableWhenVersionFails() async throws {
        let broken = try captured("t13-no-node-version")
        #expect(broken.exitCode == 127)
        let (engine, runner) = engine([["--version"]: broken])
        #expect(isUnusable(await engine.detect(), at: npm))
        #expect(engine.installLocation == nil)
        #expect(runner.calls == [["--version"]])
    }

    /// Every npm command runs with npm's own folder first on PATH, only npm's login-shell variables, BrewxPort's npm
    /// settings and NO_COLOR, from the home folder.
    @Test func commandsRunWithNpmsEnvironmentFromHome() async throws {
        let nvm = URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm")
        let runner = FakeRunner([["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g")])
        let captured = ["NVM_DIR": "/Users/someone/.nvm", "CARGO_HOME": "/Users/someone/.cargo"]
        let engine = NpmEngine(runner: runner, executable: nvm, captured: captured, base: base, homebrewNode: { _ in false })
        _ = await engine.detect()
        #expect(runner.optionsCalls.count == 2)
        for options in runner.optionsCalls {
            let env = try #require(options.environment)
            #expect(env["PATH"]?.hasPrefix("/Users/someone/.nvm/versions/node/v22.11.0/bin:/opt/homebrew/bin:") == true)
            #expect(env["NVM_DIR"] == "/Users/someone/.nvm")
            #expect(env["CARGO_HOME"] == nil)
            #expect(env["npm_config_update_notifier"] == "false")
            #expect(env["npm_config_fund"] == "false")
            #expect(env["npm_config_audit"] == "false")
            #expect(env["NO_COLOR"] == "1")
            #expect(env["NONINTERACTIVE"] == "1")
            #expect(options.workingDirectory == "/Users/someone")
        }
    }

    // MARK: finding npm

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-npm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("nvm/versions/node/v22.11.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("npm")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["NVM_DIR": root.path + "/nvm"])
        let asked = Counter()
        // This test is about finding npm, so its folders count as writable.
        let engine = NpmEngine(runner: runner, loginShell: { asked.add(); return context }, arch: .arm64, base: base,
                               isWritable: { _ in true })
        // Nothing is looked for until a detect asks the login shell.
        #expect(engine.executableURL == nil)
        #expect(asked.value == 0)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/npm"), version: "11.20.0"))
        #expect(engine.executableURL?.path == realBin + "/npm")
        #expect(asked.value == 1)
        #expect(runner.executableCalls.allSatisfy { $0.path == realBin + "/npm" })
        let env = try #require(runner.optionsCalls.first?.environment)
        #expect(env["PATH"]?.hasPrefix(realBin + ":") == true)
        #expect(env["NVM_DIR"] == root.path + "/nvm")
        // A later operation uses the copy detect found, without asking the shell again.
        let spec = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/npm")
        #expect(asked.value == 1)
    }

    @Test func liveEngineWithoutNpmIsMissing() async {
        let runner = FakeRunner([:])
        let engine = NpmEngine(runner: runner, loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"],
                                                                               environment: [:]) },
                               arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions()) }
    }

    @Test func fixedFoldersPutTheMachinesHomebrewFirst() {
        let arm = NpmEngine.fixedFolders(arch: .arm64, home: "/Users/someone", captured: [:])
        #expect(Array(arm.prefix(3)) == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
        let intel = NpmEngine.fixedFolders(arch: .x86_64, home: "/Users/someone", captured: [:])
        #expect(Array(intel.prefix(3)) == ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin"])
        // Then the version managers' default copies, from the home folder.
        #expect(arm.contains("/Users/someone/.local/share/fnm/aliases/default/bin"))
        #expect(arm.contains("/Users/someone/.asdf/shims"))
        #expect(arm.contains("/Users/someone/.local/share/mise/shims"))
    }

    @Test func nvmDefaultFollowsItsAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-nvm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["v20.18.0", "v22.1.0", "v22.11.0", "v24.0.1"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("versions/node/\(version)/bin"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("alias"), withIntermediateDirectories: true)
        func alias(_ text: String) throws -> String? {
            try Data(text.utf8).write(to: root.appendingPathComponent("alias/default"))
            return NpmEngine.nvmDefaultBin(nvmDir: root.path)
        }
        let versions = root.path + "/versions/node/"
        #expect(try alias("22\n") == versions + "v22.11.0/bin")
        #expect(try alias("v20.18.0") == versions + "v20.18.0/bin")
        #expect(try alias("22.1") == versions + "v22.1.0/bin")
        #expect(try alias("node") == versions + "v24.0.1/bin")
        #expect(try alias("lts/*") == nil)
        #expect(try alias("18") == nil)
        // nvm's folder comes from the login shell's NVM_DIR, else ~/.nvm.
        _ = try alias("v20.18.0")
        let folders = NpmEngine.fixedFolders(arch: .arm64, home: "/Users/someone", captured: ["NVM_DIR": root.path])
        #expect(folders.contains(versions + "v20.18.0/bin"))
    }

    // MARK: Homebrew's node

    @Test func homebrewNodeIsToldApartByItsNode() {
        let cellar = ["/usr/local/bin/node": "/usr/local/Cellar/node/26.13.1/bin/node"]
        // Apple silicon Homebrew: its prefix says so.
        #expect(NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/opt/homebrew/bin/npm"), realPath: { _ in nil }))
        // Intel Homebrew and the nodejs.org installer both put npm in /usr/local/bin; only Homebrew's node is a link
        // into its Cellar.
        #expect(NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/usr/local/bin/npm"), realPath: { cellar[$0] }))
        #expect(!NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/usr/local/bin/npm"), realPath: { $0 }))
        // A keg-only node@22 resolves into the Cellar too.
        let keg = ["/usr/local/opt/node@22/bin/node": "/usr/local/Cellar/node@22/22.11.0/bin/node"]
        #expect(NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/usr/local/opt/node@22/bin/npm"),
                                         realPath: { keg[$0] }))
        #expect(!NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm"),
                                          realPath: { $0 }))
        #expect(!NpmEngine.isHomebrewNode(npm: URL(fileURLWithPath: "/opt/local/bin/npm"), realPath: { $0 }))
    }

    // MARK: installed

    @Test func parsesInstalled() async throws {
        let (engine, runner) = engine([["ls", "-g", "--json", "--depth=0"]: try captured("ls-g")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["cowsay", "npm", "semver"])
        #expect(found.map(\.installedVersion) == ["1.5.0", "11.20.0", "7.8.0"])
        #expect(found.allSatisfy { $0.id.engine == .npm && $0.id.kind == .tool && $0.installedOnRequest == true })
        #expect(found.map(\.displayName) == ["cowsay", "npm", "semver"])
        #expect(runner.calls == [["ls", "-g", "--json", "--depth=0"]])
    }

    @Test func installedListsNpmItselfEvenUnderHomebrewNode() async throws {
        let (engine, _) = engine([["ls", "-g", "--json", "--depth=0"]: try captured("ls-g-empty")])
        #expect(try await engine.listInstalled().map(\.id.name) == ["npm"])
    }

    /// `npm ls -g` without a `node` on PATH (`t13-no-node-ls-g`, exit 127).
    @Test func installedFailsOnAnotherExitCode() async throws {
        let broken = try captured("t13-no-node-ls-g")
        let (engine, _) = engine([["ls", "-g", "--json", "--depth=0"]: broken])
        await #expect(throws: EngineError.self) { _ = try await engine.listInstalled() }
    }

    // MARK: outdated

    @Test func outdatedExitOneIsAnAnswer() async throws {
        let answer = try captured("outdated-g")
        #expect(answer.exitCode == 1)
        let (engine, _) = engine([["outdated", "-g", "--json"]: answer])
        let found = try await engine.listOutdated()
        // Under Homebrew's node, npm itself isn't offered: Homebrew updates it with node.
        #expect(found.map(\.id.name) == ["cowsay", "semver"])
        #expect(found.map(\.installedVersion) == ["1.5.0", "7.8.0"])
        #expect(found.map(\.latestVersion) == ["1.6.0", "7.8.6"])
        #expect(found.allSatisfy { $0.id.engine == .npm && $0.id.kind == .tool })
    }

    @Test func outdatedOffersNpmWhenHomebrewDoesntOwnIt() async throws {
        let (engine, _) = engine([["outdated", "-g", "--json"]: try captured("outdated-g")], homebrewNode: false)
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay", "npm", "semver"])
        #expect(found.first { $0.id.name == "npm" }?.latestVersion == "12.2.3")
    }

    @Test func outdatedErrorIsAFailureInNpmsOwnWords() async throws {
        let refused = try captured("outdated-g-network-refused")
        let (engine, _) = engine([["outdated", "-g", "--json"]: refused])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .npm)
            #expect(error.message.contains("ECONNREFUSED"))
            // The stack trace and the log path from stderr aren't shown.
            #expect(!error.message.contains("_logs"))
            #expect(!error.message.contains("ClientRequest"))
        }
    }

    /// An npm too new for its Node only warns (`t13-npm11-old-node-*`: npm 11.20.0 under Node 18.20.8, "does not
    /// support Node.js" on stderr) and answers as usual. Its outdated answer gives npm itself an older `latest`
    /// (10.9.11), which is never offered.
    @Test func npmTooNewForItsNodeStillAnswers() async throws {
        let outdated = try captured("t13-npm11-old-node-outdated-g")
        #expect(outdated.exitCode == 1)
        #expect(outdated.stderr.contains("does not support Node.js"))
        let (engine, _) = engine([listArguments: try captured("t13-npm11-old-node-ls-g"),
                                  ["outdated", "-g", "--json"]: outdated], homebrewNode: false)
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay", "semver"])
        #expect(found.map(\.latestVersion) == ["1.6.0", "7.8.6"])
    }

    // MARK: globals not from the registry (R14, `nonregistry-*` captures)

    /// `he` (a dangling GitHub install) has no version: it's listed with its version unknown, and the list doesn't
    /// fail. The folder and `npm link` installs are listed too.
    @Test func npmListsAnEntryWithoutAVersion() async throws {
        let (engine, _) = engine([listArguments: try captured("nonregistry-ls-g")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["capture-link", "capture-pkg", "cowsay", "he", "is-number", "ms", "n", "npm",
                                         "semver"])
        #expect(found.first { $0.id.name == "he" }?.installedVersion == nil)
        #expect(found.first { $0.id.name == "capture-pkg" }?.installedVersion == "1.0.0")
    }

    /// npm's own outdated decides for git, GitHub and tarball installs (R14: is-number from GitHub, ms from a
    /// tarball); an entry without `current` (`he`) isn't offered; the folder and link installs, which npm leaves out,
    /// aren't either. Under Homebrew's node, npm itself isn't offered.
    @Test func npmOutdatedFromTheNonRegistryCaptures() async throws {
        let (engine, runner) = engine([listArguments: try captured("nonregistry-ls-g"),
                                       ["outdated", "-g", "--json"]: try captured("nonregistry-outdated-g")])
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay", "is-number", "ms", "semver"])
        #expect(found.map(\.latestVersion) == ["1.6.0", "7.0.0", "2.1.3", "7.8.6"])
        #expect(runner.calls == [listArguments, ["outdated", "-g", "--json"]])
    }

    /// R14: an upgrade of a folder or `npm link` install is refused at plan time (by name it would become the
    /// registry's package of that name), and so is one the last listing didn't show; git, GitHub and tarball installs
    /// upgrade like any other.
    @Test func npmFolderAndLinkInstallsAreNeverUpgraded() async throws {
        let (engine, _) = engine([listArguments: try captured("nonregistry-ls-g")])
        let unlisted = EngineError(engine: .npm, message: "BrewxPort can't find capture-pkg among npm's global "
                                   + "packages, so it doesn't update it.")
        #expect(throws: unlisted) {
            _ = try engine.command(for: .upgrade, [tool("capture-pkg")], options: InstallOptions())
        }
        _ = try await engine.listInstalled()
        for name in ["capture-pkg", "capture-link"] {
            #expect(throws: EngineError(engine: .npm, message: "\(name) was installed from a folder on this Mac, so "
                                        + "BrewxPort doesn't update it.")) {
                _ = try engine.command(for: .upgrade, [tool("cowsay"), tool(name)], options: InstallOptions())
            }
            // Removing one is still fine.
            #expect(try engine.command(for: .remove, [tool(name)], options: InstallOptions()).arguments
                    == ["uninstall", "-g", name])
        }
        #expect(try engine.command(for: .upgrade, [tool("is-number"), tool("ms")], options: InstallOptions())
            .arguments == ["install", "-g", "is-number@latest", "ms@latest"])
        let missing = EngineError(engine: .npm, message: "BrewxPort can't find left-pad among npm's global packages, "
                                  + "so it doesn't update it.")
        #expect(throws: missing) {
            _ = try engine.command(for: .upgrade, [tool("left-pad")], options: InstallOptions())
        }
    }

    /// `npm ls -g` failing as captured without a `node` on PATH (`t13-no-node-ls-g`, exit 127): at `--depth=0` a
    /// missing dependency doesn't fail it (`t13-npm11-ls-g-broken-dep`, exit 0), so that's the real failure the
    /// listing has. `npm outdated -g --json` beside it is the captured answer.
    static func failedList() throws -> CommandResult { try captured("t13-no-node-ls-g") }

    /// R26: npm's update check doesn't depend on `npm ls -g`. When the listing fails, npm's own outdated answer still
    /// counts (it already leaves folder and linked installs out), and the check says why it can't tell them apart.
    /// Since upgrades are refused until a listing works (fix round 1), the updates are held back from every update,
    /// with why, rather than offered and then refused: an automatic run never reports them as failed.
    @Test func npmOutdatedSurvivesFailedList() async throws {
        let (engine, runner) = engine([listArguments: try Self.failedList(),
                                       ["outdated", "-g", "--json"]: try captured("outdated-g")])
        let report = try await engine.checkOutdated()
        #expect(report.packages.isEmpty)
        let wait = UpdateHold(reason: "Updates wait until npm's list of globals can be read.", blocksAutomatic: true,
                              blocksManual: true)
        #expect(report.held.map(\.package.id.name) == ["cowsay", "semver"])
        #expect(report.held.map(\.package.latestVersion) == ["1.6.0", "7.8.6"])
        #expect(report.held.allSatisfy { $0.hold == wait })
        #expect(report.unchecked == UncheckedPackages(note: "Couldn't read npm's list of globals; folder and linked "
                                                      + "installs can't be told apart until it works"))
        #expect(report.unchecked.names.isEmpty && !report.unchecked.unnamed)
        #expect(try await engine.listOutdated().isEmpty)
        #expect(runner.calls.filter { $0 == ["outdated", "-g", "--json"] }.count == 2)
        // A listing that works again clears the note and offers the updates.
        runner.respond(listArguments, try captured("ls-g"))
        let listed = try await engine.checkOutdated()
        #expect(listed.unchecked.isEmpty)
        #expect(listed.held.isEmpty)
        #expect(listed.packages.map(\.id.name) == ["cowsay", "semver"])
    }

    /// R26: upgrades stay fail-closed. When the last `npm ls -g` didn't succeed, an upgrade is refused at plan time,
    /// even of a package an earlier listing showed as a registry install.
    @Test func npmUpgradeRefusedWhenListFailed() async throws {
        let refused = { (name: String) in
            EngineError(engine: .npm, message: "BrewxPort couldn't read npm's list of global packages, so it doesn't "
                        + "update \(name).")
        }
        let (fresh, _) = engine([listArguments: try Self.failedList(),
                                 ["outdated", "-g", "--json"]: try captured("outdated-g")])
        _ = try await fresh.checkOutdated()
        #expect(throws: refused("cowsay")) {
            _ = try fresh.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        }

        let (engine, runner) = engine([listArguments: try captured("ls-g"),
                                       ["outdated", "-g", "--json"]: try captured("outdated-g")])
        _ = try await engine.checkOutdated()
        #expect(try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions()).arguments
                == ["install", "-g", "cowsay@latest"])
        runner.respond(listArguments, try Self.failedList())
        _ = try await engine.checkOutdated()
        #expect(throws: refused("cowsay")) {
            _ = try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        }
        await #expect(throws: EngineError.self) { _ = try await engine.listInstalled() }
        #expect(throws: refused("semver")) {
            _ = try engine.command(for: .upgrade, [tool("semver")], options: InstallOptions())
        }
        // Installs and removals don't depend on the listing.
        #expect(try engine.command(for: .install, [tool("left-pad")], options: InstallOptions()).arguments
                == ["install", "-g", "left-pad"])
        #expect(try engine.command(for: .remove, [tool("cowsay")], options: InstallOptions()).arguments
                == ["uninstall", "-g", "cowsay"])
    }

    /// npm failing before it reads its arguments, without a `node` on PATH: `env` exits 127 whatever npm was asked
    /// (`t13-no-node-ls-g`, the same words as `t13-no-node-version`).
    @Test func outdatedFailsOnAnotherExitCode() async throws {
        let broken = try captured("t13-no-node-ls-g")
        let (engine, _) = engine([["outdated", "-g", "--json"]: broken])
        await #expect(throws: EngineError.self) { _ = try await engine.listOutdated() }
    }

    /// The filter on what `npm outdated` reports, by semver: only `latest` counts, and only when it's newer.
    @Test func updatesKeepOnlyNewerLatestVersions() {
        func row(_ name: String, _ current: String?, _ latest: String?) -> Package {
            Package(id: tool(name), displayName: name, installedVersion: current, latestVersion: latest)
        }
        let rows = [
            row("ten", "1.9.0", "1.10.0"),            // numeric order, not text
            row("downgrade", "2.0.0", "1.9.9"),        // the registry's latest is older than what's installed
            row("same", "1.0.0", "1.0.0"),
            row("beta-tag", "1.0.0", "2.0.0-beta.1"),  // a stable install isn't offered a pre-release
            row("rc", "2.0.0-rc.1", "2.0.0-rc.2"),     // a pre-release install is
            row("linked", "linked", "1.0.0"),          // not a version: not compared
            row("missing", nil, "1.0.0"),
            row("nolatest", "1.0.0", nil),
            row("npm", "11.20.0", "12.2.3"),
            row("corepack", "0.34.0", "0.35.0"),
        ]
        let underHomebrew = NpmEngine.updates(rows, homebrewNode: true)
        #expect(underHomebrew.map(\.id.name) == ["ten", "rc"])
        #expect(underHomebrew.map(\.latestVersion) == ["1.10.0", "2.0.0-rc.2"])
        let elsewhere = NpmEngine.updates(rows, homebrewNode: false)
        #expect(elsewhere.map(\.id.name) == ["ten", "rc", "npm", "corepack"])
    }

    // MARK: search

    @Test func parsesSearch() async throws {
        let (engine, runner) = engine([["search", "--json", "--searchlimit=50", "--", "cowsay"]: try captured("search-cowsay")])
        let found = try await engine.search("  cowsay ")
        #expect(found.count == 50)
        let first = try #require(found.first)
        #expect(first.id == tool("cowsay"))
        #expect(first.displayName == "cowsay")
        #expect(first.latestVersion == "1.6.0")
        #expect(first.summary == "cowsay is a configurable talking cow")
        #expect(found.contains { $0.id.name == "@afcms/cowsay-ng" })
        #expect(found.allSatisfy { $0.installedVersion == nil && $0.id.kind == .tool })
        #expect(runner.calls == [["search", "--json", "--searchlimit=50", "--", "cowsay"]])
    }

    @Test func searchWithoutMatchesIsEmpty() async throws {
        let (engine, _) = engine([["search", "--json", "--searchlimit=50", "--", "zzqxbrewxportnomatch"]:
                                    try captured("search-nomatch")])
        #expect(try await engine.search("zzqxbrewxportnomatch").isEmpty)
    }

    @Test func searchAlwaysEndsOptionsBeforeTheQuery() async throws {
        let (engine, runner) = engine([["search", "--json", "--searchlimit=50", "--", "-x"]: try captured("search-nomatch")])
        #expect(try await engine.search("-x").isEmpty)
        #expect(runner.calls == [["search", "--json", "--searchlimit=50", "--", "-x"]])
    }

    @Test func emptySearchIsRefused() async {
        let (engine, runner) = engine([:])
        await #expect(throws: EngineError.self) { _ = try await engine.search("   ") }
        #expect(runner.calls.isEmpty)
    }

    @Test func searchRegistryErrorFails() async throws {
        let (engine, _) = engine([["search", "--json", "--searchlimit=50", "--", "cowsay"]:
                                    try captured("search-network-refused")])
        await #expect(throws: EngineError.self) { _ = try await engine.search("cowsay") }
    }

    // MARK: info

    @Test func parsesInfo() async throws {
        let (engine, runner) = engine([["view", "cowsay@latest"] + viewArguments: try captured("view-cowsay")])
        let details = try await engine.info(tool("cowsay"))
        #expect(details.ref == tool("cowsay"))
        #expect(details.summary == "cowsay is a configurable talking cow")
        #expect(details.homepage == URL(string: "https://github.com/piuccio/cowsay"))
        #expect(details.latestVersion == "1.6.0")
        #expect(details.reportedName == "cowsay")
        #expect(runner.calls == [["view", "cowsay@latest"] + viewArguments])
    }

    /// npm 12 answers `view` with an array (`t13-npm12-view-cowsay`).
    @Test func infoAcceptsTheArrayNpm12Prints() async throws {
        let answer = try captured("t13-npm12-view-cowsay")
        #expect(answer.stdout.hasPrefix("["))
        let (engine, _) = engine([["view", "cowsay@latest"] + viewArguments: answer])
        #expect(try await engine.info(tool("cowsay")).latestVersion == "1.6.0")
    }

    @Test func infoForAnUnknownPackageFails() async throws {
        let (engine, _) = engine([["view", "no-such-package-for-brewxport@latest"] + viewArguments:
                                    try captured("view-unknown")])
        do {
            _ = try await engine.info(tool("no-such-package-for-brewxport"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("E404"))
            #expect(!error.message.contains("tarball"))
        }
    }

    @Test func infoErrorCodesComeFromTheJSON() async throws {
        // npm refused the name in the capture; any `view` answer with an error object fails the same way.
        let (engine, _) = engine([["view", "cowsay@latest"] + viewArguments: try captured("view-invalid-name")])
        do {
            _ = try await engine.info(tool("cowsay"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("EINVALIDPACKAGENAME"))
        }
    }

    /// npm's error summary can name a private registry with a token; the message never shows it. Not a capture.
    @Test func errorSummaryNeverShowsURLCredentials() async throws {
        let summary = "Unable to authenticate, GET https://someone:s3cret@npm.example.com/cowsay?token=s3cret"
        let answer = CommandResult(exitCode: 1, stdout: #"{"error": {"code": "E401", "summary": "\#(summary)"}}"#,
                                   stderr: "")
        let (engine, _) = engine([["view", "cowsay@latest"] + viewArguments: answer])
        do {
            _ = try await engine.info(tool("cowsay"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("GET https://npm.example.com/cowsay"))
            #expect(!error.message.contains("s3cret"))
            #expect(!error.message.contains("someone"))
        }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let (engine, runner) = engine([:])
        for name in ["bad name!", "github:someone/tool", "https://example.com/x.tgz", "-e"] {
            await #expect(throws: EngineError.self) { _ = try await engine.info(tool(name)) }
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .homebrew, kind: .formula, name: "cowsay"))
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: commands

    @Test func commandShapes() async throws {
        let (engine, _) = engine([:])
        _ = try await engine.listInstalled()
        let refs = [tool("cowsay"), tool("@scope/name")]
        let install = try engine.command(for: .install, refs, options: InstallOptions())
        #expect(install.executable == npm)
        #expect(install.arguments == ["install", "-g", "cowsay", "@scope/name"])
        #expect(install.needsRoot == false)
        // Never `npm update -g`, which downgrades a package newer than `latest`.
        let upgrade = try engine.command(for: .upgrade, [tool("cowsay"), tool("semver")], options: InstallOptions())
        #expect(upgrade.arguments == ["install", "-g", "cowsay@latest", "semver@latest"])
        let remove = try engine.command(for: .remove, refs, options: InstallOptions())
        #expect(remove.arguments == ["uninstall", "-g", "cowsay", "@scope/name"])
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, tool("cowsay")) == .never)
        }
    }

    @Test func commandsCarryNpmsEnvironmentAndHome() async throws {
        let (engine, _) = engine([:])
        _ = try await engine.listInstalled()
        let spec = try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["npm_config_update_notifier"] == "false")
        #expect(env["npm_config_fund"] == "false")
        #expect(env["npm_config_audit"] == "false")
        #expect(env["NO_COLOR"] == "1")
        #expect(env["HOME"] == "/Users/someone")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// Review Focus 3: nothing but a registry name reaches `npm install`.
    @Test func npmRefusesNonRegistrySpecs() throws {
        let (engine, _) = engine([:])
        let specs = ["https://example.com/tool.tgz", "github:someone/tool", "git+https://example.com/tool.git",
                     "../path", "./tool", "/tmp/tool", "~/tool", "-e", "--global", "tool.tgz", "someone/tool",
                     "file:../tool", "tool@1.0.0", "bad name!", ""]
        for name in specs {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [tool("cowsay"), tool(name)], options: InstallOptions())
                }
            }
        }
    }

    @Test func commandRefusesWhatNpmCantDoHere() throws {
        let (engine, _) = engine([:])
        let cowsay = [tool("cowsay")]
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(version: "1.5.0"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(extraArgs: ["--allow-scripts=x"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markDependency, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .bun, kind: .tool, name: "cowsay")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .npm, kind: .formula, name: "cowsay")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutNpmThrows() {
        let (engine, _) = engine([:], executable: nil)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions()) }
    }

    // MARK: where npm writes, and what it runs on

    /// npm's global folder can't be written (Node from nodejs.org or MacPorts): installs, updates and removals are
    /// refused, with the official fix, and every detect reads the prefix again, so Check again sees the fix.
    @Test func npmPrefixNotWritableRefusesChanges() async throws {
        let runner = FakeRunner([["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g")])
        let engine = NpmEngine(runner: runner, executable: npm, base: base,
                               isWritable: { !$0.hasPrefix("/opt/homebrew/") })
        #expect(await engine.detect() == .present(path: npm, version: "11.20.0"))
        #expect(engine.binLocation == URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        let reason = "npm installs tools into /opt/homebrew, which your account can't change. Give npm a folder of "
            + "your own with npm config set prefix ~/.npm-global, then add ~/.npm-global/bin to your PATH."
        #expect(engine.readOnlyReason == reason)
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(throws: EngineError(engine: .npm, message: reason)) {
                try engine.command(for: op, [tool("cowsay")], options: InstallOptions())
            }
        }
        _ = await engine.detect()
        #expect(runner.calls == [["--version"], ["prefix", "-g"], ["--version"], ["prefix", "-g"]])

        // A writable prefix: nothing refused, and the prefix is kept for the next detect.
        let mine = NpmEngine(runner: FakeRunner([["--version"]: try captured("version"),
                                                 ["prefix", "-g"]: try captured("prefix-g")]),
                             executable: npm, base: base, isWritable: { _ in true })
        _ = await mine.detect()
        #expect(mine.readOnlyReason == nil)
        #expect(mine.installRootWritable)
    }

    /// Homebrew's `node` owns the npm when the node beside it resolves into Homebrew's Cellar (npm's own file resolves
    /// into lib/node_modules); a Node major update then needs `npm rebuild -g`.
    @Test func npmRunsOnHomebrewNode() async throws {
        let cellar = "/opt/homebrew/Cellar/node/25.2.1/bin/node"
        #expect(NpmEngine.homebrewNodeFormula(npm: npm, realPath: { $0.hasSuffix("/node") ? cellar : nil }) == "node")
        #expect(NpmEngine.homebrewNodeFormula(npm: URL(fileURLWithPath: "/usr/local/bin/npm"), realPath: { $0 })
                == nil)

        let responses = [["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g")]
        let homebrew = NpmEngine(runner: FakeRunner(responses), executable: npm, base: base,
                                 nodeFormula: { _ in "node" })
        _ = await homebrew.detect()
        #expect(try await homebrew.runtimeUses() == [RuntimeUse(formula: "node")])
        let other = NpmEngine(runner: FakeRunner(responses), executable: npm, base: base, nodeFormula: { _ in nil })
        _ = await other.detect()
        #expect(try await other.runtimeUses().isEmpty)
    }

    /// A global's commands come from its own package.json under the prefix.
    @Test func npmNamesAGlobalsCommands() async throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-npm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let folder = prefix.appendingPathComponent("lib/node_modules/cowsay")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // npm's own copy of cowsay's package.json fields (`ls -g --long --json`): its `bin` map.
        let long = try captured("ls-g-long")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(long.stdout.utf8)) as? [String: Any])
        let cowsay = try #require((object["dependencies"] as? [String: Any])?["cowsay"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: ["bin": cowsay["bin"] as Any])
            .write(to: folder.appendingPathComponent("package.json"))
        // Not a capture: `npm prefix -g` naming the test's folder.
        let runner = FakeRunner([["--version"]: try captured("version"),
                                 ["prefix", "-g"]: CommandResult(exitCode: 0, stdout: prefix.path + "\n", stderr: "")])
        let engine = NpmEngine(runner: runner, executable: npm, base: base)
        _ = await engine.detect()
        #expect(engine.executables(of: "cowsay") == ["cowsay", "cowthink"])
        #expect(engine.executables(of: "semver") == nil)
        #expect(engine.executables(of: "../cowsay") == nil)
    }

    // MARK: Repair (R39)

    /// R39: `npm rebuild -g` alone fails on Homebrew's Node (`t13-npm11-rebuild-g`: EEXIST on Homebrew's own link to
    /// npm), and naming the globals works (`t13-npm11-rebuild-g-named`: `npm rebuild -g cowsay semver`, exit 0). So
    /// Repair names the registry globals the last listing showed, in one command, never npm or corepack.
    @Test func npmRepairNamesTheRegistryGlobals() async throws {
        let plain = try captured("t13-npm11-rebuild-g")
        #expect(plain.exitCode == 1 && plain.stderr.contains("EEXIST"))
        #expect(try captured("t13-npm11-rebuild-g-named").exitCode == 0)
        let (engine, _) = engine([listArguments: try captured("t13-npm11-ls-g-restored")])
        _ = try await engine.listInstalled()
        let steps = try engine.repairCommands(for: ["cowsay"])
        #expect(steps.map(\.tool) == [nil])
        #expect(steps.map(\.spec.arguments) == [["rebuild", "-g", "cowsay", "semver"]])
        #expect(steps.allSatisfy { !$0.spec.needsRoot && $0.spec.environment?["npm_config_fund"] == "false" })
        #expect(engine.repairRefusals(for: ["cowsay", "semver"]).isEmpty)
    }

    /// Folder and `npm link` installs (R14) and a dangling GitHub install npm lists without a version aren't rebuilt by
    /// name; git, GitHub and tarball installs are (`nonregistry-ls-g`). With nothing to name, or no listing to name them
    /// from (none yet, or the last one failed), Repair says why instead of running anything.
    @Test func npmRepairLeavesOutWhatItCantName() async throws {
        let (mixed, _) = engine([listArguments: try captured("nonregistry-ls-g")])
        _ = try await mixed.listInstalled()
        #expect(try mixed.repairCommands(for: []).map(\.spec.arguments)
                == [["rebuild", "-g", "cowsay", "is-number", "ms", "n", "semver"]])

        let (unlisted, _) = engine([:])
        #expect(throws: EngineError(engine: .npm, message: "BrewxPort couldn't read npm's list of global packages, so "
                                    + "it doesn't rebuild them.")) { _ = try unlisted.repairCommands(for: ["cowsay"]) }
        let (failed, runner) = engine([listArguments: try captured("ls-g")])
        _ = try await failed.listInstalled()
        runner.respond(listArguments, try Self.failedList())
        _ = try? await failed.listInstalled()
        #expect(throws: EngineError.self) { _ = try failed.repairCommands(for: ["cowsay"]) }

        let (onlyNpm, _) = engine([listArguments: try captured("t13-npm12-ls-g-only-npm")])
        _ = try await onlyNpm.listInstalled()
        #expect(throws: EngineError(engine: .npm, message: "npm has no global packages BrewxPort can rebuild.")) {
            _ = try onlyNpm.repairCommands(for: [])
        }
    }

    // MARK: Final review

    /// npm and corepack came with Node: they stay listed and their updates keep the usual rules, but removing one is
    /// refused at plan time, since `npm uninstall -g npm` deletes Node's own npm. A batch with one is refused too
    /// (the uninstall sheet blocks them before that, `UninstallPlanner`).
    @Test func npmAndCorepackAreNeverRemoved() async throws {
        let (engine, _) = engine([:], homebrewNode: false)
        #expect(try await engine.listInstalled().map(\.id.name).contains("npm"))
        for name in ["npm", "corepack"] {
            let refusal = EngineError(engine: .npm, message: "\(name) came with Node; removing it would break Node's "
                                      + "own \(name).")
            #expect(throws: refusal) {
                _ = try engine.command(for: .remove, [tool(name)], options: InstallOptions())
            }
            #expect(throws: refusal) {
                _ = try engine.command(for: .remove, [tool("cowsay"), tool(name)], options: InstallOptions())
            }
            #expect(NpmEngine.cameWithNodeReason(name) == "it came with Node; removing it would break Node's own "
                    + "\(name).")
        }
        #expect(try engine.command(for: .remove, [tool("cowsay")], options: InstallOptions()).arguments
                == ["uninstall", "-g", "cowsay"])
        // Updating npm is as before: offered unless Homebrew's node updates it, and upgradable once listed.
        #expect(try engine.command(for: .upgrade, [tool("npm")], options: InstallOptions()).arguments
                == ["install", "-g", "npm@latest"])
        let npmRow = Package(id: tool("npm"), displayName: "npm", installedVersion: "11.2.0", latestVersion: "11.3.0")
        #expect(NpmEngine.updates([npmRow], homebrewNode: false).map(\.id.name) == ["npm"])
        #expect(NpmEngine.updates([npmRow], homebrewNode: true).isEmpty)
    }

    /// The design: Volta-managed Node is read-only, since Volta tracks the tools itself (`npm i -g` goes into Volta's
    /// store and `npm ls -g` doesn't show them). An npm in `~/.volta` (here a fake path), or one that resolves to
    /// Volta's shim (a VOLTA_HOME elsewhere), lists its globals, but offers no updates and installs, updates and
    /// removes nothing, with Volta's own commands as the fix.
    @Test func voltaManagedNpmIsReadOnly() async throws {
        let reason = "Volta manages these tools. Use volta install and volta uninstall."
        #expect(NpmEngine.voltaReason == reason)
        let volta = URL(fileURLWithPath: "/Users/someone/.volta/bin/npm")
        let runner = FakeRunner([["--version"]: try captured("version"), ["prefix", "-g"]: try captured("prefix-g"),
                                 listArguments: try captured("ls-g"),
                                 ["outdated", "-g", "--json"]: try captured("outdated-g")])
        let engine = NpmEngine(runner: runner, executable: volta, base: base, homebrewNode: { _ in false },
                               nodeFormula: { _ in nil }, isWritable: { _ in false })
        _ = await engine.detect()
        #expect(engine.readOnlyReason == reason)
        #expect(try await engine.listInstalled().map(\.id.name).contains("cowsay"))
        let report = try await engine.checkOutdated()
        #expect(report.packages.isEmpty)
        #expect(report.held.isEmpty)
        #expect(!runner.calls.contains(["outdated", "-g", "--json"]))
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(throws: EngineError(engine: .npm, message: reason), "\(op)") {
                _ = try engine.command(for: op, [tool("cowsay")], options: InstallOptions())
            }
        }
        #expect(throws: EngineError(engine: .npm, message: reason)) { _ = try engine.repairCommands(for: []) }

        // Volta's shim is found by where it resolves, wherever VOLTA_HOME is; any other npm isn't Volta's.
        let home = "/Users/someone"
        #expect(NpmEngine.isVolta(npm: volta, home: home, realPath: { _ in nil }))
        #expect(NpmEngine.isVolta(npm: URL(fileURLWithPath: "/opt/volta/bin/npm"), home: home,
                                  realPath: { _ in "/opt/homebrew/Cellar/volta/2.0.2/bin/volta-shim" }))
        #expect(!NpmEngine.isVolta(npm: npm, home: home, realPath: { _ in "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js" }))
        #expect(!NpmEngine.isVolta(npm: URL(fileURLWithPath: "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm"),
                                   home: home, realPath: { _ in nil }))
    }

    /// R29's careful reading: an npm whose last detect didn't find it working (or that hasn't been detected) couldn't
    /// say which Node it runs on, so it says nothing rather than "none": the caller then holds a Node update for it.
    @Test func npmThatCouldntSayWhatItRunsOnThrows() async throws {
        let undetected = NpmEngine(runner: FakeRunner([:]), executable: npm, base: base, nodeFormula: { _ in "node" })
        await #expect(throws: EngineError.self) { _ = try await undetected.runtimeUses() }
        let broken = NpmEngine(runner: FakeRunner([["--version"]: try captured("t13-no-node-version")]),
                               executable: npm, base: base, nodeFormula: { _ in "node" })
        _ = await broken.detect()
        await #expect(throws: EngineError.self) { _ = try await broken.runtimeUses() }
    }
}

/// Counts calls from a `@Sendable` closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
