import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// One captured Bun command from `Fixtures/bun` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`, stderr
/// from `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent("bun/" + file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

/// A captured file from `Fixtures/bun`, as text.
private func capturedText(_ file: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("bun/" + file), encoding: .utf8)
}

private let bun = URL(fileURLWithPath: "/opt/homebrew/bin/bun")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let listArguments = ["pm", "ls", "-g"]
private let binArguments = ["pm", "bin", "-g"]
private let outdatedArguments = ["outdated", "-g"]

private func searchURL(_ text: String) -> String { "https://registry.npmjs.org/-/v1/search?text=\(text)&size=50" }

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .bun, kind: .tool, name: name) }

/// A Bun answering `responses`, and `--version` as captured (1.4.5) unless `responses` answer it: a query asks Bun's
/// version first when no detect has.
private func engine(_ responses: [[String]: CommandResult], executable: URL? = bun,
                    registry: FakeRegistryFetch = FakeRegistryFetch()) -> (BunEngine, FakeRunner) {
    var answers = responses
    if answers[["--version"]] == nil { answers[["--version"]] = try? captured("version") }
    let runner = FakeRunner(answers)
    return (BunEngine(runner: runner, registry: registry, executable: executable, base: base), runner)
}

/// A Bun answering `responses` whose version a detect read (the captured 1.4.5), so its commands can be built.
private func detected(_ responses: [[String]: CommandResult] = [:],
                      registry: FakeRegistryFetch = FakeRegistryFetch()) async -> (BunEngine, FakeRunner) {
    let (engine, runner) = engine(responses, registry: registry)
    _ = await engine.detect()
    return (engine, runner)
}

/// Not a capture: an older Bun's `--version`, in the shape Bun 1.4.5 prints it (`version.txt`: the version, then a
/// newline). No Bun older than 1.4.5 was captured (T13 ran 1.4.5 only). Only used where nothing else is asked of that
/// Bun.
private func olderVersion(_ version: String) -> CommandResult {
    CommandResult(exitCode: 0, stdout: version + "\n", stderr: "")
}

/// `pm ls -g` with globals from everywhere (`t13-pm-ls-g-mixed`): a scoped package (`@antfu/ni@0.21.0`), a folder
/// install (`capture-pkg@../../../capture-pkg`), one from GitHub (`he@github:mathiasbynens/he#ab02411`) and two from
/// the registry.
private func mixedListing() throws -> CommandResult { try captured("t13-pm-ls-g-mixed") }

/// A Bun table row as `bun outdated` prints it. Values, not a capture.
private func row(_ name: String, _ current: String?, _ latest: String?) -> Package {
    Package(id: tool(name), displayName: name, installedVersion: current, latestVersion: latest)
}

private struct Unrelated: Error, Equatable {}

@Suite struct BunEngineTests {
    // MARK: detect

    /// The version, then the folders Bun reports: its bin folder (`pm bin -g`) and its global folder (the header of
    /// `pm ls -g`).
    @Test func detectsVersionAndFolders() async throws {
        let (found, runner) = engine([["--version"]: try captured("version"), binArguments: try captured("pm-bin-g"),
                                      listArguments: try captured("pm-ls-g")])
        #expect(found.installLocation == nil)
        #expect(found.binLocation == nil)
        #expect(await found.detect() == .present(path: bun, version: "1.4.5"))
        #expect(runner.calls == [["--version"], binArguments, listArguments])
        #expect(found.installLocation == URL(fileURLWithPath: "/Users/tester/.bun/install/global", isDirectory: true))
        #expect(found.binLocation == URL(fileURLWithPath: "/Users/tester/.bun/bin", isDirectory: true))
        // Before the first `add -g`, the header names the folder too.
        let (empty, _) = engine([["--version"]: try captured("version"), binArguments: try captured("pm-bin-g"),
                                 listArguments: try captured("pm-ls-g-empty")])
        _ = await empty.detect()
        #expect(empty.installLocation?.path == "/Users/tester/.bun/install/global")
    }

    /// Not a capture: folders Bun doesn't give (a failed command, a relative path, a header BrewxPort doesn't know)
    /// leave Bun present, without them.
    @Test func foldersBunDoesntGiveLeaveBunPresent() async throws {
        let refused = CommandResult(exitCode: 1, stdout: "", stderr: "error: EACCES")
        let answers: [(CommandResult, CommandResult)] = [
            (refused, refused),
            (CommandResult(exitCode: 0, stdout: ".bun/bin\n", stderr: ""),
             CommandResult(exitCode: 0, stdout: "global node_modules (2 installed)\n", stderr: "")),
            (CommandResult(exitCode: 0, stdout: "\n", stderr: ""),
             CommandResult(exitCode: 0, stdout: "error: something new\n", stderr: "")),
        ]
        for (bin, list) in answers {
            let (engine, _) = engine([["--version"]: try captured("version"), binArguments: bin, listArguments: list])
            #expect(await engine.detect() == .present(path: bun, version: "1.4.5"))
            #expect(engine.installLocation == nil)
            #expect(engine.binLocation == nil)
        }
        // An unusable Bun isn't asked for its folders.
        let (broken, runner) = engine([["--version"]: CommandResult(exitCode: 127, stdout: "", stderr: "")])
        #expect(isUnusable(await broken.detect(), at: bun))
        #expect(runner.calls == [["--version"]])
        #expect(broken.installLocation == nil)
        #expect(broken.binLocation == nil)
    }

    @Test func detectMissingWithoutExecutable() async {
        let (engine, runner) = engine([:], executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func detectUnusableWhenVersionFailsOrIsntOne() async throws {
        let broken = CommandResult(exitCode: 1, stdout: "", stderr: "dyld: Library not loaded")
        let (failing, _) = engine([["--version"]: broken])
        #expect(isUnusable(await failing.detect(), at: bun))
        let (garbled, _) = engine([["--version"]: CommandResult(exitCode: 0, stdout: "bun\n", stderr: "")])
        #expect(isUnusable(await garbled.detect(), at: bun))
    }

    /// Every Bun command runs with Bun's own folder first on PATH, only Bun's login-shell variables and NO_COLOR, from
    /// the home folder.
    @Test func commandsRunWithBunsEnvironmentFromHome() async throws {
        let own = URL(fileURLWithPath: "/Users/someone/.bun/bin/bun")
        let runner = FakeRunner([["--version"]: try captured("version"), binArguments: try captured("pm-bin-g"),
                                 listArguments: try captured("pm-ls-g")])
        let captured = ["BUN_INSTALL": "/Users/someone/.bun", "BUN_INSTALL_GLOBAL_DIR": "/Users/someone/globals",
                        "XDG_CACHE_HOME": "/Users/someone/.cache", "CARGO_HOME": "/Users/someone/.cargo",
                        "NVM_DIR": "/Users/someone/.nvm"]
        let engine = BunEngine(runner: runner, registry: FakeRegistryFetch(), executable: own, captured: captured,
                               base: base)
        _ = await engine.detect()
        _ = try await engine.listInstalled()
        // detect's three, then the list.
        #expect(runner.optionsCalls.count == 4)
        for options in runner.optionsCalls {
            let env = try #require(options.environment)
            #expect(env["PATH"]?.hasPrefix("/Users/someone/.bun/bin:/opt/homebrew/bin:") == true)
            #expect(env["BUN_INSTALL"] == "/Users/someone/.bun")
            #expect(env["BUN_INSTALL_GLOBAL_DIR"] == "/Users/someone/globals")
            #expect(env["XDG_CACHE_HOME"] == "/Users/someone/.cache")
            #expect(env["CARGO_HOME"] == nil)
            #expect(env["NVM_DIR"] == nil)
            #expect(env["NO_COLOR"] == "1")
            #expect(env["NONINTERACTIVE"] == "1")
            #expect(options.workingDirectory == "/Users/someone")
        }
    }

    // MARK: finding bun

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-bun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".bun/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("bun")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([["--version"]: try captured("version")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["BUN_INSTALL": root.path + "/.bun"])
        // The captured folders are the VM's: this test is about finding Bun, so they count as writable.
        let engine = BunEngine(runner: runner, registry: FakeRegistryFetch(), loginShell: { context }, arch: .arm64,
                               base: base, isWritable: { _ in true })
        #expect(engine.executableURL == nil)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/bun"), version: "1.4.5"))
        #expect(engine.executableURL?.path == realBin + "/bun")
        #expect(runner.optionsCalls.first?.environment?["BUN_INSTALL"] == root.path + "/.bun")
        let spec = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/bun")
    }

    @Test func liveEngineWithoutBunIsMissing() async {
        let runner = FakeRunner([:])
        let engine = BunEngine(runner: runner, registry: FakeRegistryFetch(),
                               loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"], environment: [:]) },
                               arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions()) }
    }

    @Test func fixedFoldersPutTheMachinesHomebrewFirst() {
        let arm = BunEngine.fixedFolders(arch: .arm64, home: "/Users/someone", captured: [:])
        #expect(arm == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                        "/Users/someone/.bun/bin", "/Users/someone/.asdf/shims",
                        "/Users/someone/.local/share/mise/shims", "/Users/someone/.proto/shims"])
        let intel = BunEngine.fixedFolders(arch: .x86_64, home: "/Users/someone", captured: [:])
        #expect(Array(intel.prefix(2)) == ["/usr/local/bin", "/opt/homebrew/bin"])
        // The official installer's folder follows BUN_INSTALL; BUN_INSTALL_BIN is where the globals' executables go,
        // not Bun itself.
        let moved = BunEngine.fixedFolders(arch: .arm64, home: "/Users/someone",
                                           captured: ["BUN_INSTALL": "/Users/someone/tools/bun",
                                                      "BUN_INSTALL_BIN": "/Users/someone/bin"])
        #expect(moved.contains("/Users/someone/tools/bun/bin"))
        #expect(moved.firstIndex(of: "/Users/someone/tools/bun/bin")! < moved.firstIndex(of: "/Users/someone/.bun/bin")!)
        #expect(!moved.contains("/Users/someone/bin"))
    }

    // MARK: installed

    @Test func parsesInstalled() async throws {
        let (engine, runner) = engine([listArguments: try captured("pm-ls-g")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["cowsay", "semver"])
        #expect(found.map(\.installedVersion) == ["1.5.0", "7.8.0"])
        #expect(found.map(\.displayName) == ["cowsay", "semver"])
        #expect(found.allSatisfy { $0.id.engine == .bun && $0.id.kind == .tool && $0.installedOnRequest == true })
        // No detect first: Bun's version is asked before anything else (R15).
        #expect(runner.calls == [["--version"], listArguments])
    }

    @Test func installedFollowsUpdates() async throws {
        let (engine, _) = engine([listArguments: try captured("pm-ls-g-after-update")])
        #expect(try await engine.listInstalled().map(\.installedVersion) == ["1.6.0", "7.8.0"])
    }

    @Test func nothingInstalledIsEmpty() async throws {
        let (engine, _) = engine([listArguments: try captured("pm-ls-g-empty")])
        #expect(try await engine.listInstalled().isEmpty)
    }

    /// Only a registry version is kept; any other source (which can carry a token) is dropped. Captured: a scoped
    /// package, a folder install and one from GitHub (`t13-pm-ls-g-mixed`). Not a capture: the listing below, with a
    /// git URL and a tarball URL each holding a token (no tarball or private git install was captured, T13), and a
    /// `link:` install, made up in `pm ls -g`'s shape to check those are dropped too.
    @Test func installedKeepsOnlyRegistryVersions() async throws {
        let (mixed, _) = engine([listArguments: try mixedListing()])
        let listed = try await mixed.listInstalled()
        #expect(listed.map(\.id.name) == ["@antfu/ni", "capture-pkg", "cowsay", "he", "semver"])
        #expect(listed.map(\.installedVersion) == ["0.21.0", nil, "1.5.0", nil, "7.8.0"])
        #expect(!String(describing: listed).contains("mathiasbynens") && !String(describing: listed).contains(".."))
        let listing = """
            /Users/someone/.bun/install/global node_modules (51 installed)
            ├── @types/node@20.1.0
            ├── private-tool@git+https://someone:s3cret@git.example.com/tool.git#0123abc
            ├── linked-tool@link:linked-tool
            ├── packed-tool@https://files.example.com/tool.tgz?token=s3cret
            └── typescript@5.9.3

            """
        let (engine, _) = engine([listArguments: CommandResult(exitCode: 0, stdout: listing, stderr: "")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["@types/node", "linked-tool", "packed-tool", "private-tool", "typescript"])
        #expect(found.map(\.installedVersion) == ["20.1.0", nil, nil, nil, "5.9.3"])
        #expect(!String(describing: found).contains("s3cret"))
        #expect(!String(describing: found).contains("example.com"))
    }

    /// Not a capture: output that isn't `pm ls -g`'s is a failure, and the message doesn't repeat it. Made up on
    /// purpose: no Bun printed these.
    @Test func installedRefusesOutputItDoesntKnow() async throws {
        let unknown = [
            "error: something new\n",
            "/Users/someone/.bun/install/global node_modules (1 installed)\n├── bad name!@1.0.0\n",
            "/Users/someone/.bun/install/global node_modules (1 installed)\nsurprise s3cret line\n",
            "/Users/someone/.bun/install/global node_modules (1 installed)\n├── @1.0.0\n",
        ]
        for text in unknown {
            let (engine, _) = engine([listArguments: CommandResult(exitCode: 0, stdout: text, stderr: "")])
            do {
                _ = try await engine.listInstalled()
                Issue.record("expected an error for \(text)")
            } catch let error as EngineError {
                #expect(error.engine == .bun)
                #expect(!error.message.contains("s3cret"))
                #expect(!error.message.contains("bad name"))
            }
        }
    }

    /// Not a capture: `pm ls -g` never failed in the captures (Task 0's or T13's), so its failure is made up.
    @Test func installedFailsOnAnotherExitCode() async {
        let broken = CommandResult(exitCode: 1, stdout: "", stderr: "error: EACCES opening the global folder")
        let (engine, _) = engine([listArguments: broken])
        do {
            _ = try await engine.listInstalled()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("EACCES"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: outdated (bun outdated -g)

    @Test func parsesOutdated() async throws {
        let (engine, runner) = engine([["--version"]: try captured("version"), listArguments: try captured("pm-ls-g"),
                                       outdatedArguments: try captured("outdated-g")])
        _ = await engine.detect()
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay", "semver"])
        #expect(found.map(\.installedVersion) == ["1.5.0", "7.8.0"])
        #expect(found.map(\.latestVersion) == ["1.6.0", "7.8.6"])
        #expect(found.allSatisfy { $0.id.engine == .bun && $0.id.kind == .tool })
        #expect(runner.calls.last == outdatedArguments)
        #expect(runner.calls.filter { $0 == outdatedArguments }.count == 1)
    }

    @Test func outdatedAfterAnUpdateHasTheRest() async throws {
        let (engine, _) = engine([listArguments: try captured("pm-ls-g-after-update"),
                                  outdatedArguments: try captured("outdated-g-after-update")])
        #expect(try await engine.listOutdated().map(\.id.name) == ["semver"])
    }

    /// Before the first `add -g` there's no global package.json: Bun exits 1, and nothing is outdated.
    @Test func outdatedWithoutGlobalPackageJSONIsEmpty() async throws {
        let answer = try captured("outdated-g-empty")
        #expect(answer.exitCode == 1)
        let (engine, _) = engine([listArguments: try captured("pm-ls-g-empty"), outdatedArguments: answer])
        #expect(try await engine.listOutdated().isEmpty)
    }

    /// With the registry unreachable, Bun exits 1 with only its header: a failure in Bun's words.
    @Test func outdatedWithoutAnyAnswerFails() async throws {
        let (engine, _) = engine([listArguments: try captured("pm-ls-g"),
                                  outdatedArguments: try captured("outdated-g-network-refused")])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .bun)
            #expect(error.message.contains("ConnectionRefused"))
        }
    }

    /// Some lookups failed, so Bun printed the rows it has and exited 1: `@antfu/ni`'s scope pointed at a registry
    /// that refused (`t13-outdated-g-scope-refused`). The rows count; the package it couldn't check is left out.
    @Test func outdatedPartialAnswerKeepsItsRows() async throws {
        let partial = try captured("t13-outdated-g-scope-refused")
        #expect(partial.exitCode == 1)
        let (engine, _) = engine([listArguments: try mixedListing(), outdatedArguments: partial])
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay", "semver"])
        #expect(found.map(\.latestVersion) == ["1.6.0", "7.8.6"])
        // R6: the package Bun couldn't look up is named, from its stderr line.
        let report = try await engine.checkOutdated()
        #expect(report.packages == found)
        #expect(report.unchecked == UncheckedPackages(reasons: [
            "@antfu/ni": "error: ConnectionRefused downloading package manifest @antfu/ni",
        ]))
        // Not a capture: a line BrewxPort doesn't know, made up, still says something couldn't be checked.
        #expect(BunEngine.unchecked("error: something new\n") == UncheckedPackages(unnamed: true))
    }

    /// A full answer has nothing unchecked.
    @Test func outdatedFullAnswerHasNothingUnchecked() async throws {
        let (full, _) = engine([listArguments: try captured("pm-ls-g"), outdatedArguments: try captured("outdated-g")])
        let report = try await full.checkOutdated()
        #expect(report.packages.map(\.id.name) == ["cowsay", "semver"])
        #expect(report.unchecked.isEmpty)
        #expect(report.held.isEmpty)
    }

    /// A version held back by `minimumReleaseAge` gets ` *` (the version shown is the one Bun would install), with a
    /// note under the table (`t13-outdated-g-min-release-age`). The version shown can be older than the installed one
    /// (semver's 7.7.3 against 7.8.0), which is never offered.
    @Test func outdatedHeldByReleaseAge() async throws {
        let table = try captured("t13-outdated-g-min-release-age")
        let rows = try BunEngine.outdatedRows(table.stdout)
        #expect(rows.map(\.id.name) == ["@antfu/ni", "cowsay", "semver"])
        #expect(rows.map(\.latestVersion) == ["27.0.1", "1.6.0", "7.7.3"])
        let (engine, _) = engine([listArguments: try mixedListing(), outdatedArguments: table])
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["@antfu/ni", "cowsay"])
        #expect(found.map(\.latestVersion) == ["27.0.1", "1.6.0"])
    }

    /// Not a capture: Bun's other table shapes, from its docs and its 1.4.5 source, which T13 didn't provoke (a global
    /// has no dev dependencies, and no aliased global was captured).
    /// - A dev dependency is named `name (dev)`.
    /// - An alias shows `alias@npm:name`, which isn't a name BrewxPort passes to Bun.
    /// - Columns are found by their headings, so an extra one (`Workspace`) doesn't move them.
    @Test func outdatedTableVariants() throws {
        let table = """
            bun outdated v1.4.5 (826ef2a6f)
            |---------------------------------------------------------|
            | Package              | Current | Update  | Latest  | Workspace |
            |----------------------|---------|---------|---------|-----------|
            | typescript (dev)     | 5.8.3   | 5.8.3   | 5.9.3   |           |
            |----------------------|---------|---------|---------|-----------|
            | cowsay               | 1.5.0   | 1.5.0   | 1.6.0 * |           |
            |----------------------|---------|---------|---------|-----------|
            | lodash3@npm:lodash   | 3.10.0  | 3.10.1  | 4.17.21 |           |
            |----------------------|---------|---------|---------|-----------|
            | @biomejs/biome       | 2.1.0   | 2.1.0   | 2.2.0   |           |
            |---------------------------------------------------------|

            Note: The * indicates that version isn't true latest due to minimum release age
            """
        let rows = try BunEngine.outdatedRows(table)
        #expect(rows.map(\.id.name) == ["@biomejs/biome", "cowsay", "typescript"])
        #expect(rows.map(\.installedVersion) == ["2.1.0", "1.5.0", "5.8.3"])
        #expect(rows.map(\.latestVersion) == ["2.2.0", "1.6.0", "5.9.3"])
    }

    /// Not a capture: a table without the headings BrewxPort reads isn't one it knows. Made up on purpose.
    @Test func outdatedTableWithoutHeadingsFails() {
        let table = """
            bun outdated v9.0.0
            | Name   | Installed | Newest |
            | cowsay | 1.5.0     | 1.6.0  |
            """
        #expect(throws: EngineError.self) { _ = try BunEngine.outdatedRows(table) }
    }

    /// Not a capture: Bun crashing (exit 132) wasn't captured, so it's made up.
    @Test func outdatedFailsOnAnotherExitCode() async throws {
        let crashed = CommandResult(exitCode: 132, stdout: "", stderr: "Illegal instruction")
        let (engine, _) = engine([listArguments: try captured("pm-ls-g"), outdatedArguments: crashed])
        await #expect(throws: EngineError.self) { _ = try await engine.listOutdated() }
    }

    /// Bun's error can name a private registry with a token; the message never shows it. Not a capture: the token is
    /// made up to check that (the captured failures name none).
    @Test func outdatedErrorNeverShowsURLCredentials() async throws {
        let refused = CommandResult(exitCode: 1, stdout: "bun outdated v1.4.5 (826ef2a6f)\n",
                                    stderr: "error: GET https://someone:s3cret@npm.example.com/cowsay?token=s3cret - 401\n")
        let (engine, _) = engine([listArguments: try captured("pm-ls-g"), outdatedArguments: refused])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("npm.example.com/cowsay"))
            #expect(!error.message.contains("s3cret"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// The filter on what Bun reports, by semver: only Latest counts (an upgrade is `update --latest`), and only when
    /// it's newer.
    @Test func updatesKeepOnlyNewerLatestVersions() {
        let rows = [
            row("ten", "1.9.0", "1.10.0"),            // numeric order, not text
            row("downgrade", "2.0.0", "1.9.9"),        // Bun shows an older latest dimmed; it's no update
            row("same", "1.0.0", "1.0.0"),
            row("beta-tag", "1.0.0", "2.0.0-beta.1"),  // a stable install isn't offered a pre-release
            row("rc", "2.0.0-rc.1", "2.0.0-rc.2"),     // a pre-release install is
            row("git", "github:someone/tool", "1.0.0"),
            row("missing", nil, "1.0.0"),
            row("nolatest", "1.0.0", nil),
        ]
        let updates = BunEngine.updates(rows)
        #expect(updates.map(\.id.name) == ["rc", "ten"])
        #expect(updates.map(\.latestVersion) == ["2.0.0-rc.2", "1.10.0"])
    }

    /// R13. A global whose source isn't the npm registry is listed, but never offered as an update: upgrading it by
    /// name would swap it for the registry's package of that name. Bun's own check leaves the GitHub and folder installs
    /// out (`t13-pm-ls-g-mixed`, `t13-outdated-g-mixed`); were it to report one, or a package the listing doesn't have,
    /// that row is dropped too (rows as values).
    @Test func bunNonRegistryGlobalNeverOffered() async throws {
        let (engine, _) = engine([["--version"]: try captured("version"), listArguments: try mixedListing(),
                                  outdatedArguments: try captured("t13-outdated-g-mixed")])
        _ = await engine.detect()
        let installed = try await engine.listInstalled()
        #expect(installed.map(\.id.name) == ["@antfu/ni", "capture-pkg", "cowsay", "he", "semver"])
        #expect(installed.first { $0.id.name == "he" }?.installedVersion == nil)
        #expect(try await engine.listOutdated().map(\.id.name) == ["@antfu/ni", "cowsay", "semver"])
        let globals = try BunEngine.globals(try mixedListing().stdout)
        let reported = [row("cowsay", "1.5.0", "1.6.0"), row("he", "1.2.0", "2.0.0"),
                        row("capture-pkg", "1.0.0", "2.0.0"), row("unlisted", "1.0.0", "2.0.0")]
        #expect(BunEngine.registryRows(reported, of: globals).map(\.id.name) == ["cowsay"])
    }

    // MARK: the oldest Bun BrewxPort drives (R15)

    /// Bun 1.4.5, the captured version, is driven: its folders, list and own outdated check, and the npm registry
    /// isn't asked for versions.
    @Test func bunAtFloorLists() async throws {
        let registry = FakeRegistryFetch()
        let (engine, runner) = engine([["--version"]: try captured("version"), binArguments: try captured("pm-bin-g"),
                                       listArguments: try captured("pm-ls-g"),
                                       outdatedArguments: try captured("outdated-g")],
                                      registry: registry)
        #expect(await engine.detect() == .present(path: bun, version: "1.4.5"))
        #expect(engine.installLocation?.path == "/Users/tester/.bun/install/global")
        #expect(try await engine.listInstalled().map(\.id.name) == ["cowsay", "semver"])
        let outdated = try await engine.listOutdated()
        #expect(outdated.map(\.latestVersion) == ["1.6.0", "7.8.6"])
        #expect(runner.calls.last == outdatedArguments)
        #expect(registry.requested.isEmpty)
        #expect(try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions()).arguments
                == ["update", "-g", "--latest", "cowsay"])
    }

    /// A Bun older than 1.4.5 is installed but unsupported (not "not working"), with a reason that says how to update
    /// it. Nothing else is run or fetched with it: no folders, list, check, search, details or commands, whether asked
    /// directly or through the catalog, which leaves it out quietly (no failure every check). Only `--version` is
    /// answered, in Bun's shape.
    @Test func bunBelowFloorIsUnsupportedWithReason() async throws {
        for version in ["1.2.20", "1.4.4"] {
            let reason = "Bun \(version) is too old for BrewxPort. Update Bun to 1.4.5 or later with brew upgrade bun "
                + "or bun upgrade."
            let registry = FakeRegistryFetch()
            let (engine, runner) = engine([["--version"]: olderVersion(version)], registry: registry)
            let status = await engine.detect()
            #expect(status == .unsupported(path: bun, version: version, reason: reason))
            #expect(PackageCatalog.message(for: .bun, status: status) == reason)
            #expect(engine.installLocation == nil)
            #expect(engine.binLocation == nil)

            func expectReason(_ work: () async throws -> Void) async {
                do {
                    try await work()
                    Issue.record("expected the unsupported reason")
                } catch let error as EngineError {
                    #expect(error.engine == .bun)
                    #expect(error.message == reason)
                } catch {
                    Issue.record("unexpected \(error)")
                }
            }
            await expectReason { _ = try await engine.listInstalled() }
            await expectReason { _ = try await engine.listOutdated() }
            await expectReason { _ = try await engine.search("cowsay") }
            await expectReason { _ = try await engine.info(tool("cowsay")) }
            for op in [PackageOperation.install, .upgrade, .remove] {
                await expectReason { _ = try engine.command(for: op, [tool("cowsay")], options: InstallOptions()) }
            }

            let catalog = PackageCatalog(engines: [engine])
            for await outcome in catalog.stream(.outdated) {
                Issue.record("expected no outcome, got \(outcome.engine)")
            }
            #expect(await catalog.outdated().errors.isEmpty)
            await expectReason { _ = try await catalog.info(tool("cowsay")) }
            #expect(runner.calls.allSatisfy { $0 == ["--version"] })
            #expect(registry.requested.isEmpty)
        }
        #expect(BunEngine.isSupported("1.4.5"))
        #expect(BunEngine.isSupported("1.10.0"))
        #expect(!BunEngine.isSupported("1.4.5-canary.1"))
    }

    /// The floor doesn't wait for a detect (R15): before any, a query asks Bun's version first and an old Bun is
    /// refused; one whose version can't be read is refused too; and a command, which can't ask, is refused until a
    /// detect or query has read the version.
    @Test func bunFloorHoldsBeforeAnyDetect() async throws {
        let reason = "Bun 1.2.20 is too old for BrewxPort. Update Bun to 1.4.5 or later with brew upgrade bun or "
            + "bun upgrade."
        let (old, oldRunner) = engine([["--version"]: olderVersion("1.2.20"), listArguments: try captured("pm-ls-g")])
        await #expect(throws: EngineError(engine: .bun, message: reason)) { _ = try await old.listInstalled() }
        #expect(oldRunner.calls == [["--version"]])
        #expect(throws: EngineError(engine: .bun, message: reason)) {
            _ = try old.command(for: .install, [tool("cowsay")], options: InstallOptions())
        }

        let unread = EngineError(engine: .bun, message: "BrewxPort couldn't read Bun's version, so it doesn't use it.")
        let (broken, _) = engine([["--version"]: CommandResult(exitCode: 1, stdout: "", stderr: "Killed: 9")])
        await #expect(throws: unread) { _ = try await broken.listOutdated() }

        let (fresh, freshRunner) = engine([listArguments: try captured("pm-ls-g")])
        let notChecked = EngineError(engine: .bun, message: "BrewxPort hasn't checked Bun's version yet, so it doesn't "
                                     + "run it.")
        #expect(throws: notChecked) {
            _ = try fresh.command(for: .install, [tool("cowsay")], options: InstallOptions())
        }
        #expect(freshRunner.calls.isEmpty)
        // A query reads the version (once) and the commands follow it.
        #expect(try await fresh.listInstalled().map(\.id.name) == ["cowsay", "semver"])
        _ = try await fresh.listInstalled()
        #expect(freshRunner.calls == [["--version"], listArguments, listArguments])
        #expect(try fresh.command(for: .install, [tool("cowsay")], options: InstallOptions()).arguments
                == ["add", "-g", "cowsay"])
    }

    // MARK: search

    @Test func parsesSearch() async throws {
        // The capture asked for 20 results; BrewxPort asks for 50.
        let registry = FakeRegistryFetch(bodies: [searchURL("cowsay"): try capturedText("registry-search-cowsay.json")])
        let (engine, runner) = engine([:], registry: registry)
        let found = try await engine.search("  cowsay ")
        #expect(found.count == 20)
        let first = try #require(found.first)
        #expect(first.id == tool("cowsay"))
        #expect(first.displayName == "cowsay")
        #expect(first.latestVersion == "1.6.0")
        #expect(first.summary == "cowsay is a configurable talking cow")
        #expect(found.allSatisfy { $0.installedVersion == nil && $0.id.engine == .bun && $0.id.kind == .tool })
        #expect(registry.requested.map(\.absoluteString) == [searchURL("cowsay")])
        // Bun has no search command: only its version is asked, the floor's check (R15), since nothing detected it.
        #expect(runner.calls == [["--version"]])
    }

    @Test func searchWithoutMatchesIsEmpty() async throws {
        let registry = FakeRegistryFetch(bodies: [searchURL("zzqxbrewxportnomatch"):
                                                    try capturedText("registry-search-nomatch.json")])
        let (engine, _) = engine([:], registry: registry)
        #expect(try await engine.search("zzqxbrewxportnomatch").isEmpty)
    }

    /// The query is the only text the user sends, percent-encoded so it can't add a parameter or end the URL.
    @Test func searchEncodesTheQuery() async throws {
        let encoded = searchURL("a%26b%3Dc%2Bd%23%C3%A9%20%2Fx")
        let registry = FakeRegistryFetch(bodies: [encoded: try capturedText("registry-search-nomatch.json")])
        let (engine, _) = engine([:], registry: registry)
        #expect(try await engine.search("a&b=c+d#é /x").isEmpty)
        #expect(registry.requested.map(\.absoluteString) == [encoded])
        #expect(BunEngine.searchURL("@scope/name-1.0_x~y")?.absoluteString == searchURL("%40scope%2Fname-1.0_x~y"))
    }

    @Test func emptySearchIsRefused() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        await #expect(throws: EngineError.self) { _ = try await engine.search("   ") }
        #expect(registry.requested.isEmpty)
    }

    /// Not a capture: a hit whose name Bun couldn't install by name is left out. The registry never answered such
    /// names in the captures, so the answer is made up in its shape.
    @Test func searchLeavesOutNamesBunCantInstall() async throws {
        let body = #"{"objects":[{"package":{"name":"good-tool","version":"1.0.0","description":"Fine"}},"#
            + #"{"package":{"name":"Bad Name!","version":"1.0.0"}},{"package":{"name":"-flag"}}],"total":3}"#
        let registry = FakeRegistryFetch(bodies: [searchURL("tool"): body])
        let (engine, _) = engine([:], registry: registry)
        #expect(try await engine.search("tool").map(\.id.name) == ["good-tool"])
    }

    @Test func searchRegistryFailuresAreEngineErrors() async throws {
        for failure: any Error in [RegistryFetchError.status(503), URLError(.notConnectedToInternet)] {
            let registry = FakeRegistryFetch([searchURL("cowsay"): .failure(failure)])
            let (engine, _) = engine([:], registry: registry)
            await #expect(throws: EngineError.self) { _ = try await engine.search("cowsay") }
        }
        let unreadable = FakeRegistryFetch(bodies: [searchURL("cowsay"): "<html>"])
        let (engine, _) = engine([:], registry: unreadable)
        await #expect(throws: EngineError.self) { _ = try await engine.search("cowsay") }
    }

    /// Anything that isn't the registry's refusal (a cancelled task, demo mode's uncaptured answer) is thrown as it is.
    @Test func searchPassesOtherErrorsThrough() async {
        let registry = FakeRegistryFetch([searchURL("cowsay"): .failure(Unrelated())])
        let (engine, _) = engine([:], registry: registry)
        await #expect(throws: Unrelated.self) { _ = try await engine.search("cowsay") }
    }

    // MARK: info

    @Test func parsesInfo() async throws {
        let (engine, runner) = engine([["info", "cowsay", "--json"]: try captured("info-cowsay-json")])
        let details = try await engine.info(tool("cowsay"))
        #expect(details.ref == tool("cowsay"))
        #expect(details.summary == "cowsay is a configurable talking cow")
        #expect(details.homepage == URL(string: "https://github.com/piuccio/cowsay"))
        #expect(details.latestVersion == "1.6.0")
        #expect(details.reportedName == "cowsay")
        #expect(runner.calls == [["--version"], ["info", "cowsay", "--json"]])
    }

    @Test func infoForAnUnknownPackageFails() async throws {
        let (engine, _) = engine([["info", "no-such-package-for-brewxport", "--json"]: try captured("info-unknown-json")])
        do {
            _ = try await engine.info(tool("no-such-package-for-brewxport"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .bun)
            #expect(error.message.contains("404"))
        }
    }

    @Test func infoOfflineFails() async throws {
        let (engine, _) = engine([["info", "cowsay", "--json"]: try captured("info-network-refused")])
        do {
            _ = try await engine.info(tool("cowsay"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("ConnectionRefused"))
        }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let (engine, runner) = engine([:])
        for name in ["bad name!", "github:someone/tool", "https://example.com/x.tgz", "-e", "tool.tgz"] {
            await #expect(throws: EngineError.self) { _ = try await engine.info(tool(name)) }
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .npm, kind: .tool, name: "cowsay"))
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: commands

    /// The shapes T13 ran with two names (`t13-add-g-two`, `t13-update-g-latest-two`, `t13-remove-g-two`), here with
    /// the captured scoped global (`t13-pm-ls-g-mixed`).
    @Test func commandShapes() async throws {
        let (engine, _) = engine([listArguments: try mixedListing()])
        _ = try await engine.listInstalled()
        let refs = [tool("cowsay"), tool("@antfu/ni")]
        let install = try engine.command(for: .install, refs, options: InstallOptions())
        #expect(install.executable == bun)
        #expect(install.arguments == ["add", "-g", "cowsay", "@antfu/ni"])
        #expect(install.needsRoot == false)
        // `--latest`: plain `update -g` stays inside the range `add -g` saved.
        let upgrade = try engine.command(for: .upgrade, refs, options: InstallOptions())
        #expect(upgrade.arguments == ["update", "-g", "--latest", "cowsay", "@antfu/ni"])
        let remove = try engine.command(for: .remove, refs, options: InstallOptions())
        #expect(remove.arguments == ["remove", "-g", "cowsay", "@antfu/ni"])
        // Bun's default stays: dependency install scripts are never trusted.
        for spec in [install, upgrade, remove] { #expect(!spec.arguments.contains("--trust")) }
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, tool("cowsay")) == .never)
        }
    }

    @Test func commandsCarryBunsEnvironmentAndHome() async throws {
        let (engine, _) = engine([listArguments: try captured("pm-ls-g")])
        _ = try await engine.listInstalled()
        let spec = try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["NO_COLOR"] == "1")
        #expect(env["HOME"] == "/Users/someone")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// R13: an upgrade of a global the last listing showed isn't from the npm registry is refused at plan time, in one
    /// line that doesn't show its source; so is one of a package no listing has shown. Removing it is fine. The
    /// GitHub and folder installs of `t13-pm-ls-g-mixed`.
    @Test func bunUpgradeRefusedForGitGlobal() async throws {
        let (engine, _) = engine([["--version"]: try captured("version"), listArguments: try mixedListing()])
        // Before any listing, BrewxPort doesn't know where a package came from.
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        }
        // detect lists them (for the global folder), which is enough.
        _ = await engine.detect()
        for name in ["he", "capture-pkg"] {
            do {
                _ = try engine.command(for: .upgrade, [tool(name)], options: InstallOptions())
                Issue.record("expected an error")
            } catch let error as EngineError {
                #expect(error.engine == .bun)
                #expect(error.message == "\(name) wasn't installed from the npm registry, so BrewxPort doesn't "
                        + "update it.")
                #expect(!error.message.contains("github") && !error.message.contains(".."))
            }
        }
        for refs in [[tool("cowsay"), tool("he")], [tool("not-installed")]] {
            #expect(throws: EngineError.self, "\(refs)") {
                _ = try engine.command(for: .upgrade, refs, options: InstallOptions())
            }
        }
        let upgrade = try engine.command(for: .upgrade, [tool("cowsay"), tool("semver")], options: InstallOptions())
        #expect(upgrade.arguments == ["update", "-g", "--latest", "cowsay", "semver"])
        let remove = try engine.command(for: .remove, [tool("he")], options: InstallOptions())
        #expect(remove.arguments == ["remove", "-g", "he"])
    }

    /// Nothing but a registry name reaches `bun add`.
    @Test func bunRefusesNonRegistrySpecs() throws {
        let (engine, _) = engine([:])
        let specs = ["https://example.com/tool.tgz", "github:someone/tool", "git+https://example.com/tool.git",
                     "../path", "./tool", "/tmp/tool", "~/tool", "-e", "--trust", "--global", "tool.tgz",
                     "someone/tool", "file:../tool", "link:tool", "tool@1.0.0", "tool@latest", "alias@npm:tool",
                     "bad name!", ""]
        for name in specs {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [tool("cowsay"), tool(name)], options: InstallOptions())
                }
            }
        }
    }

    @Test func commandRefusesWhatBunCantDoHere() throws {
        let (engine, _) = engine([:])
        let cowsay = [tool("cowsay")]
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(throws: EngineError.self) { _ = try engine.command(for: op, [], options: InstallOptions()) }
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(version: "1.5.0"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(extraArgs: ["--trust"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markDependency, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .npm, kind: .tool, name: "cowsay")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .bun, kind: .formula, name: "cowsay")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutBunThrows() {
        let (engine, _) = engine([:], executable: nil)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions()) }
    }

    /// A global's commands come from its own package.json in Bun's global folder.
    @Test func bunNamesAGlobalsCommands() async throws {
        let global = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-bun-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: global) }
        let folder = global.appendingPathComponent("node_modules/cowsay")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // npm's own copy of cowsay's package.json fields (`Fixtures/npm/ls-g-long.json`): its `bin` map.
        let long = try String(contentsOf: fixtures.appendingPathComponent("npm/ls-g-long.json"), encoding: .utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(long.utf8)) as? [String: Any])
        let cowsay = try #require((object["dependencies"] as? [String: Any])?["cowsay"] as? [String: Any])
        try JSONSerialization.data(withJSONObject: ["bin": cowsay["bin"] as Any])
            .write(to: folder.appendingPathComponent("package.json"))
        // Not a capture: the captured `pm ls -g` with its global folder moved to the test's, which has to exist.
        let listing = try captured("pm-ls-g").stdout
            .replacingOccurrences(of: "/Users/tester/.bun/install/global", with: global.path)
        let (engine, _) = await detected([listArguments: CommandResult(exitCode: 0, stdout: listing, stderr: "")])
        #expect(engine.executables(of: "cowsay") == ["cowsay", "cowthink"])
        #expect(engine.executables(of: "semver") == nil)
    }
}
