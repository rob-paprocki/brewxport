import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pipx")

/// One captured pipx command from `Fixtures/pipx` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`, stderr
/// from `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

/// A captured PyPI answer (`GET https://pypi.org/pypi/<name>/json`), as its body.
private func pypiBody(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("\(name).json"), encoding: .utf8)
}

private let pipx = URL(fileURLWithPath: "/opt/homebrew/bin/pipx")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let cowsayURL = "https://pypi.org/pypi/cowsay/json"
private let blackURL = "https://pypi.org/pypi/black/json"
private let outdatedArguments = ["list", "--outdated", "--output", "json"]

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .pipx, kind: .tool, name: name) }

private func engine(_ responses: [[String]: CommandResult], executable: URL? = pipx,
                    registry: FakeRegistryFetch = FakeRegistryFetch()) -> (PipxEngine, FakeRunner) {
    let runner = FakeRunner(responses)
    return (PipxEngine(runner: runner, registry: registry, executable: executable, base: base), runner)
}

/// An older pipx's `--version` (`t13-old-1.15.0-version`), below the first pipx that checks for itself, so the engine
/// checks outdated tools against PyPI.
private func oldVersion() throws -> CommandResult { try captured("t13-old-1.15.0-version") }

/// The paths a reader was asked for.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var paths: [String] { lock.withLock { asked } }
    func add(_ path: String) { lock.withLock { asked.append(path) } }
}

@Suite struct PipxEngineTests {
    // MARK: detect

    @Test func detectsVersionAndPipxFolders() async throws {
        let (engine, runner) = engine([["--version"]: try captured("version"),
                                       ["environment", "--value", "PIPX_HOME"]: try captured("environment-pipx-home"),
                                       ["environment", "--value", "PIPX_BIN_DIR"]:
                                        try captured("environment-pipx-bin-dir")])
        #expect(engine.installLocation == nil)
        #expect(engine.binLocation == nil)
        #expect(await engine.detect() == .present(path: pipx, version: "1.19.1"))
        #expect(engine.installLocation == URL(fileURLWithPath: "/Users/tester/Library/Application Support/pipx",
                                              isDirectory: true))
        #expect(engine.binLocation == URL(fileURLWithPath: "/Users/tester/.local/bin", isDirectory: true))
        #expect(runner.calls == [["--version"], ["environment", "--value", "PIPX_HOME"],
                                 ["environment", "--value", "PIPX_BIN_DIR"]])
        #expect(engine.readOnlyReason == nil)
    }

    @Test func detectMissingWithoutExecutable() async {
        let (engine, runner) = engine([:], executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
    }

    /// Not a capture: `pipx environment` never failed in the captures (Task 0's or T13's, old pipx versions included),
    /// so its failure here is made up.
    @Test func failedHomeKeepsPipxPresent() async throws {
        let refused = CommandResult(exitCode: 1, stdout: "", stderr: "pipx: error")
        let (engine, _) = engine([["--version"]: try captured("version"),
                                  ["environment", "--value", "PIPX_HOME"]: refused])
        #expect(await engine.detect() == .present(path: pipx, version: "1.19.1"))
        #expect(engine.installLocation == nil)
    }

    /// Not a capture: `pipx --version` never failed in the captures (T13's old pipx versions each answered, 1.5.0 with
    /// a warning on stderr), so a pipx whose Python is gone is made up here.
    @Test func detectUnusableWhenVersionFails() async {
        let broken = CommandResult(exitCode: 1, stdout: "", stderr: "bad interpreter: /opt/homebrew/opt/python@3.12")
        let (engine, runner) = engine([["--version"]: broken])
        #expect(isUnusable(await engine.detect(), at: pipx))
        #expect(engine.installLocation == nil)
        #expect(runner.calls == [["--version"]])
    }

    /// Every pipx command runs with pipx's own folder first on PATH, only pipx's login-shell variables and NO_COLOR,
    /// from the home folder.
    @Test func commandsRunWithPipxsEnvironmentFromHome() async throws {
        let local = URL(fileURLWithPath: "/Users/someone/.local/bin/pipx")
        let runner = FakeRunner([["--version"]: try captured("version"),
                                 ["environment", "--value", "PIPX_HOME"]: try captured("environment-pipx-home")])
        let captured = ["PIPX_HOME": "/Users/someone/.pipx", "UV_TOOL_DIR": "/Users/someone/tools",
                        "XDG_DATA_HOME": "/Users/someone/.data"]
        let engine = PipxEngine(runner: runner, registry: FakeRegistryFetch(), executable: local, captured: captured,
                                base: base)
        _ = await engine.detect()
        #expect(runner.optionsCalls.count == 3)
        for options in runner.optionsCalls {
            let env = try #require(options.environment)
            #expect(env["PATH"]?.hasPrefix("/Users/someone/.local/bin:/opt/homebrew/bin:") == true)
            #expect(env["PIPX_HOME"] == "/Users/someone/.pipx")
            #expect(env["XDG_DATA_HOME"] == "/Users/someone/.data")
            #expect(env["UV_TOOL_DIR"] == nil)
            #expect(env["NO_COLOR"] == "1")
            #expect(env["NONINTERACTIVE"] == "1")
            #expect(options.workingDirectory == "/Users/someone")
        }
    }

    // MARK: finding pipx

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-pipx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("mise/installs/pipx/1.19.1/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("pipx")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([["--version"]: try captured("version"),
                                 ["environment", "--value", "PIPX_HOME"]: try captured("environment-pipx-home")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["PIPX_BIN_DIR": root.path + "/bin"])
        // The captured PIPX_HOME is the VM's: this test is about finding pipx, so its folders count as writable.
        let engine = PipxEngine(runner: runner, registry: FakeRegistryFetch(), loginShell: { context }, arch: .arm64,
                                base: base, isWritable: { _ in true })
        // Nothing is looked for until a detect asks the login shell.
        #expect(engine.executableURL == nil)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/pipx"), version: "1.19.1"))
        #expect(runner.executableCalls.allSatisfy { $0.path == realBin + "/pipx" })
        let env = try #require(runner.optionsCalls.first?.environment)
        #expect(env["PATH"]?.hasPrefix(realBin + ":") == true)
        #expect(env["PIPX_BIN_DIR"] == root.path + "/bin")
        let spec = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/pipx")
    }

    @Test func liveEngineWithoutPipxIsMissing() async {
        let runner = FakeRunner([:])
        let engine = PipxEngine(runner: runner, registry: FakeRegistryFetch(),
                                loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"], environment: [:]) },
                                arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions())
        }
    }

    /// Homebrew (this Mac's prefix first), MacPorts, nanobrew, then pipx's own bin folder and `pip install --user`'s
    /// folders, newest Python first.
    @Test func fixedFoldersPutTheMachinesHomebrewFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in ["3.9", "3.12", "3.10", "notaversion"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Python/\(folder)/bin"),
                                                    withIntermediateDirectories: true)
        }
        let arm = PipxEngine.fixedFolders(arch: .arm64, home: home.path, captured: [:])
        #expect(arm == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                        home.path + "/.local/bin", home.path + "/Library/Python/3.12/bin",
                        home.path + "/Library/Python/3.10/bin", home.path + "/Library/Python/3.9/bin"])
        let intel = PipxEngine.fixedFolders(arch: .x86_64, home: home.path,
                                            captured: ["PIPX_BIN_DIR": "/Users/someone/bin"])
        #expect(Array(intel.prefix(6)) == ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin",
                                           "/opt/nanobrew/prefix/bin", "/Users/someone/bin", home.path + "/.local/bin"])
    }

    // MARK: installed

    @Test func parsesInstalled() async throws {
        let (engine, runner) = engine([["list", "--json"]: try captured("list-json")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["black", "cowsay"])
        #expect(found.map(\.displayName) == ["black", "cowsay"])
        #expect(found.map(\.installedVersion) == ["24.2.0", "5.0"])
        #expect(found.allSatisfy { $0.id.engine == .pipx && $0.id.kind == .tool && $0.installedOnRequest == true })
        #expect(runner.calls == [["list", "--json"]])
    }

    @Test func installedWithNothingIsEmpty() async throws {
        let empty = try captured("list-json-empty")
        #expect(empty.stderr.contains("nothing has been installed"))
        let (engine, _) = engine([["list", "--json"]: empty])
        #expect(try await engine.listInstalled().isEmpty)
    }

    /// R40: with one venv's Python gone, `pipx list --json` exits 1 with only an empty line on stderr, but stdout
    /// still holds every healthy venv (`t13-list-json-broken-venv`: cowsay's `bin/python` was deleted). Those are
    /// listed, and the broken ones are counted from `pipx list --short`'s stderr, which names each
    /// (`t13-list-short-broken-venv`), as a note on pipx's page: Repair tools (`pipx reinstall-all`) fixes them
    /// (`t13-reinstall-all`). A listing that works again clears the note.
    @Test func brokenVenvLeavesTheOthersListedWithANote() async throws {
        let broken = try captured("t13-list-json-broken-venv")
        #expect(broken.exitCode == 1 && broken.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let (engine, runner) = engine([["list", "--json"]: broken,
                                       ["list", "--short"]: try captured("t13-list-short-broken-venv")])
        #expect(engine.note == nil)
        #expect(try await engine.listInstalled().map(\.id.name) == ["black", "pygments", "pyjokes-private"])
        #expect(engine.note == "1 pipx tool is broken. Repair tools fixes it.")
        #expect(runner.calls == [["list", "--json"], ["list", "--short"]])
        #expect(try await engine.runtimeUses() == [RuntimeUse(formula: "python@3.15",
                                                              tools: ["black", "pygments", "pyjokes-private"])])
        runner.respond(["list", "--json"], try captured("t13-list-json-after-reinstall-all"))
        #expect(try await engine.listInstalled().map(\.id.name).contains("cowsay"))
        #expect(engine.note == nil)
        #expect(PipxEngine.brokenNote(stderr: "   package a has invalid interpreter /x\n   package b has missing "
                                      + "internal pipx metadata.\n") == "2 pipx tools are broken. Repair tools fixes "
                                      + "them.")
        // Fix round 1: when pipx doesn't say which venv is broken, the note doesn't claim to know.
        #expect(PipxEngine.brokenNote(stderr: "")
                == "pipx reported a problem. Tools that answered are listed; Repair tools may fix it.")
        #expect(PipxEngine.brokenNote(stderr: try captured("t13-list-json-broken-venv").stderr)
                == "pipx reported a problem. Tools that answered are listed; Repair tools may fix it.")
    }

    /// Only stdout pipx can't use fails the listing, in pipx's words: pipx 1.5.0 can't read the venvs a newer pipx
    /// made (`t13-old-1.5.0-real-list-json`: exit 1, nothing on stdout, `Unknown metadata version` on stderr).
    @Test func installedFailsWhenStdoutIsntUsable() async throws {
        let (engine, runner) = engine([["list", "--json"]: try captured("t13-old-1.5.0-real-list-json")])
        do {
            _ = try await engine.listInstalled()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .pipx)
            #expect(error.message.hasPrefix("pipx list failed (exit 1): "))
            #expect(error.message.contains("Unknown metadata version"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(runner.calls == [["list", "--json"]])
        #expect(engine.note == nil)
    }

    /// `package_or_url` and `pip_args` can hold an index URL with a token, so nothing read from `pipx list --json`
    /// keeps them: the install spec only says whether it named a package on an index.
    @Test func listNeverKeepsTheInstallSpec() throws {
        let answer = try JSONDecoder().decode(PipxEngine.ListAnswer.self,
                                              from: Data(try captured("list-json").stdout.utf8))
        let venvs = PipxEngine.venvs(answer)
        #expect(venvs.map(\.name) == ["black", "cowsay"])
        #expect(venvs.map(\.project) == ["black", "cowsay"])
        #expect(venvs.map(\.python) == ["3.15.2", "3.15.2"])
        #expect(venvs.allSatisfy { $0.fromIndex && !$0.pinned })
        for dumped in [String(reflecting: answer), String(reflecting: venvs)] {
            #expect(!dumped.contains("=="))
            #expect(!dumped.contains("pip_args"))
        }
    }

    // MARK: outdated (pipx's own check)

    @Test func parsesOutdated() async throws {
        let (engine, runner) = engine([outdatedArguments: try captured("list-outdated-json")])
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["black", "cowsay"])
        #expect(found.map(\.installedVersion) == ["24.2.0", "5.0"])
        #expect(found.map(\.latestVersion) == ["26.10.1", "6.1"])
        #expect(found.allSatisfy { $0.id.engine == .pipx && $0.id.kind == .tool })
        #expect(runner.calls == [outdatedArguments])
    }

    @Test func outdatedWithNothingIsEmpty() async throws {
        for name in ["list-outdated-empty", "list-outdated-json-after-upgrade-all"] {
            let (engine, _) = engine([outdatedArguments: try captured(name)])
            #expect(try await engine.listOutdated().isEmpty, "\(name)")
        }
    }

    /// pipx 1.15.1 and later answer for themselves, after a detect too. 1.15.0 is the last that refuses `--outdated
    /// --output json` (argparse, exit 2); 1.15.1 answers it (`t13-old-1.15.0-*`, `t13-old-1.15.1-*`, and 1.15.2).
    @Test func newPipxChecksForItself() async throws {
        let registry = FakeRegistryFetch()
        let (current, runner) = engine([["--version"]: try captured("version"),
                                        outdatedArguments: try captured("list-outdated-json")], registry: registry)
        _ = await current.detect()
        #expect(try await current.listOutdated().count == 2)
        #expect(runner.calls.last == outdatedArguments)
        #expect(registry.requested.isEmpty)

        for (version, offered) in [("1.15.1", ["cowsay"]), ("1.15.2", ["black", "cowsay"])] {
            let (first, firstRunner) = engine([["--version"]: try captured("t13-old-\(version)-version"),
                                               outdatedArguments: try captured("t13-old-\(version)-iso-list-outdated-json")],
                                              registry: registry)
            _ = await first.detect()
            #expect(try await first.listOutdated().map(\.id.name) == offered, "\(version)")
            #expect(firstRunner.calls.last == outdatedArguments, "\(version)")
        }
        #expect(registry.requested.isEmpty)
        #expect(try captured("t13-old-1.15.0-iso-list-outdated-json").exitCode == 2)
    }

    @Test func outdatedWhenEveryCheckFailedIsAFailure() async throws {
        let refused = try captured("list-outdated-json-network-refused")
        #expect(refused.exitCode == 1)
        let (engine, _) = engine([outdatedArguments: refused])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .pipx)
            #expect(error.message.contains("environment_outdated_check_failed"))
            #expect(error.message.contains("Request failed"))
            #expect(!error.message.contains("\n"))
            #expect(error.message.count < 400)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// pipx's own answer when some tools couldn't be checked: the others still count, and nothing is a failure unless
    /// every tool failed. Values, not a capture (no partial check was captured).
    @Test func outdatedKeepsWhatPipxCouldCheck() throws {
        typealias Answer = PipxEngine.OutdatedAnswer
        let cowsay = Answer.Entry(environment: "cowsay", version: "5.0", latestVersion: "6.1", injected: false,
                                  pinned: false)
        let blackFailed = Answer.Failure(code: "environment_outdated_check_failed", environment: "black",
                                         message: "Package backend exited with code 2.")
        let partial = Answer(status: "partial", data: .init(packages: [cowsay], packagesChecked: 2),
                             errors: [blackFailed])
        let report = try PipxEngine.outdated(partial)
        #expect(report.packages.map(\.id.name) == ["cowsay"])
        // R6: the tool pipx couldn't check is named, with pipx's words.
        #expect(report.unchecked == UncheckedPackages(reasons: ["black": "Package backend exited with code 2."]))
        #expect(report.uncheckedCount == 1)
        // Partial, and the tool that could be checked is current: nothing to update, not a failure.
        let current = Answer(status: "partial", data: .init(packages: [], packagesChecked: 2), errors: [blackFailed])
        #expect(try PipxEngine.outdated(current).packages.isEmpty)
        #expect(try PipxEngine.outdated(current).unchecked.names == ["black"])
        // An error about no one venv beside an answer: something unnamed couldn't be checked.
        let unnamed = Answer(status: "partial", data: .init(packages: [cowsay], packagesChecked: 2),
                             errors: [Answer.Failure(code: "pipx_error", environment: nil, message: "failed")])
        #expect(try PipxEngine.outdated(unnamed).unchecked == UncheckedPackages(unnamed: true))
        // A full answer has nothing unchecked.
        let full = Answer(status: "success", data: .init(packages: [cowsay], packagesChecked: 2), errors: [])
        #expect(try PipxEngine.outdated(full).unchecked.isEmpty)
        // Every tool failed.
        let none = Answer(status: "partial", data: .init(packages: [], packagesChecked: 1), errors: [blackFailed])
        #expect(throws: EngineError.self) { _ = try PipxEngine.outdated(none) }
        // A failure that isn't about one tool.
        let whole = Answer(status: "error", data: nil,
                           errors: [Answer.Failure(code: "pipx_error", environment: nil, message: "failed")])
        #expect(throws: EngineError.self) { _ = try PipxEngine.outdated(whole) }
    }

    /// An older pipx refusing `--outdated` with argparse's usage error and exit code 2 (`t13-old-1.15.0-iso-list-
    /// outdated-json`).
    @Test func outdatedWithoutJSONShowsPipxsMessage() async throws {
        let refused = try captured("t13-old-1.15.0-iso-list-outdated-json")
        #expect(refused.exitCode == 2)
        let (engine, _) = engine([outdatedArguments: refused])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("unrecognized arguments"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// The filter on what pipx reports, by PEP 440: pinned tools and injected packages are never offered (`pipx
    /// upgrade` moves neither), and only a newer version counts.
    @Test func updatesSkipPinnedInjectedAndOlder() {
        typealias Entry = PipxEngine.OutdatedAnswer.Entry
        func entry(_ name: String, _ current: String?, _ latest: String?, injected: Bool? = false,
                   pinned: Bool? = false) -> Entry {
            Entry(environment: name, version: current, latestVersion: latest, injected: injected, pinned: pinned)
        }
        let rows = PipxEngine.updates([
            entry("ten", "26.5.1", "26.10.1"),          // PEP 440 order, not text
            entry("downgrade", "2.0", "1.9"),
            entry("same", "1.0", "1.0.0"),
            entry("rc-offered", "1.0", "2.0rc1"),       // a stable install isn't offered a pre-release
            entry("rc", "2.0rc1", "2.0rc2"),            // a pre-release install is
            entry("pinned", "1.0", "2.0", pinned: true),
            entry("plugin", "1.0", "2.0", injected: true),
            entry("missing", nil, "1.0"),
            entry("post", "1.0", "1.0.post1"),
        ])
        #expect(rows.map(\.id.name) == ["post", "rc", "ten"])
        #expect(rows.map(\.latestVersion) == ["1.0.post1", "2.0rc2", "26.10.1"])
    }

    // MARK: outdated (PyPI, for pipx before 1.15.1)

    @Test func olderPipxChecksPyPI() async throws {
        let registry = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let (engine, runner) = engine([["--version"]: try oldVersion(),
                                       ["list", "--json"]: try captured("list-json")], registry: registry)
        #expect(await engine.detect() == .present(path: pipx, version: "1.15.0"))
        // black's answer isn't captured (it's 900 KB): that one tool couldn't be checked, cowsay still is.
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["cowsay"])
        #expect(found.map(\.installedVersion) == ["5.0"])
        #expect(found.map(\.latestVersion) == ["6.1"])
        #expect(!runner.calls.contains(outdatedArguments))
        #expect(Set(registry.requested.map(\.absoluteString)) == [blackURL, cowsayURL])
    }

    /// R6: one tool's failed lookup (black's PyPI answer isn't captured) leaves the other's update on the list and is
    /// named, with why, rather than failing the check or vanishing.
    @Test func oneFailedLookupDoesNotHideOtherUpdates() async throws {
        let registry = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let (engine, _) = engine([["--version"]: try oldVersion(), ["list", "--json"]: try captured("list-json")],
                                 registry: registry)
        _ = await engine.detect()
        let report = try await engine.checkOutdated()
        #expect(report.packages.map(\.id.name) == ["cowsay"])
        #expect(report.unchecked.names == ["black"])
        #expect(report.unchecked.reasons["black"]?.isEmpty == false)
        #expect(report.held.isEmpty)
        #expect(try await engine.listOutdated() == report.packages)
    }

    @Test func olderPipxFailsWhenNoLookupWorks() async throws {
        let registry = FakeRegistryFetch([cowsayURL: .failure(RegistryFetchError.tooLarge(8 * 1024 * 1024)),
                                          blackURL: .failure(URLError(.notConnectedToInternet))])
        let (engine, _) = engine([["--version"]: try oldVersion(), ["list", "--json"]: try captured("list-json")],
                                 registry: registry)
        _ = await engine.detect()
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .pipx)
            #expect(error.message.contains("PyPI"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func olderPipxWithNothingInstalledAsksNothing() async throws {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([["--version"]: try oldVersion(), ["list", "--json"]: try captured("list-json-empty")],
                                 registry: registry)
        _ = await engine.detect()
        #expect(try await engine.listOutdated().isEmpty)
        #expect(registry.requested.isEmpty)
    }

    /// Pinned tools, and tools installed from a URL, a path or git, aren't looked up; each project is looked up once,
    /// by its PEP 503 name. Values, not a capture.
    @Test func pypiUpdatesSkipWhatPipxWouldntUpgrade() throws {
        typealias Venv = PipxEngine.Venv
        let cowsay = try JSONDecoder().decode(PyPI.Project.self, from: Data(try pypiBody("pypi-cowsay").utf8))
        let venvs = [
            Venv(name: "cowsay", project: "cowsay", version: "5.0", python: "3.15.2", pinned: false, fromIndex: true),
            Venv(name: "cowsay3.9", project: "CowSay", version: "4.0", python: "3.9.6", pinned: false, fromIndex: true),
            Venv(name: "held", project: "cowsay", version: "5.0", python: "3.15.2", pinned: true, fromIndex: true),
            Venv(name: "fromgit", project: "cowsay", version: "5.0", python: "3.15.2", pinned: false, fromIndex: false),
            Venv(name: "black", project: "black", version: "24.2.0", python: "3.15.2", pinned: false, fromIndex: true),
        ]
        #expect(PipxEngine.pypiNames(venvs) == ["black", "cowsay"])
        let report = try PipxEngine.pypiUpdates(venvs, projects: ["cowsay": .success(cowsay),
                                                                  "black": .failure(RegistryFetchError.status(404))])
        let rows = report.packages
        #expect(rows.map(\.id.name) == ["cowsay", "cowsay3.9"])
        #expect(rows.map(\.latestVersion) == ["6.1", "6.1"])
        #expect(report.unchecked.names == ["black"])
        #expect(throws: EngineError.self) {
            _ = try PipxEngine.pypiUpdates(venvs, projects: ["cowsay": .failure(RegistryFetchError.status(503)),
                                                             "black": .failure(RegistryFetchError.status(404))])
        }
    }

    /// Final review: PyPI's fallback offers only what `pipx upgrade` installs. pipx upgrades without `--pre`, and
    /// BrewxPort doesn't read the pip arguments a venv was made with, so it never offers a pre-release: a pre-release
    /// install (black 25.0b1) gets a newer stable release, and nothing for a newer pre-release alone. uv's fallback
    /// is unchanged (uv honours a pre-release requirement). Values, not a capture.
    @Test func pypiFallbackOffersOnlyWhatPipxUpgradeInstalls() throws {
        typealias Venv = PipxEngine.Venv
        func project(_ releases: [String]) throws -> PyPI.Project {
            let files = Dictionary(uniqueKeysWithValues: releases.map { ($0, [["yanked": false]]) })
            let json: [String: Any] = ["info": ["name": "black", "version": releases.last ?? ""], "releases": files]
            return try JSONDecoder().decode(PyPI.Project.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let beta = [Venv(name: "black", project: "black", version: "25.0b1", python: "3.15.2", pinned: false,
                         fromIndex: true)]
        let newerBeta = try project(["24.10.0", "25.0b1", "25.0b2"])
        #expect(try PipxEngine.pypiUpdates(beta, projects: ["black": .success(newerBeta)]).packages.isEmpty)
        let final = try project(["24.10.0", "25.0b1", "25.0b2", "25.0"])
        #expect(try PipxEngine.pypiUpdates(beta, projects: ["black": .success(final)]).packages.map(\.latestVersion)
                == ["25.0"])
        // A stable install, as before.
        let stable = [Venv(name: "black", project: "black", version: "24.2.0", python: "3.15.2", pinned: false,
                           fromIndex: true)]
        #expect(try PipxEngine.pypiUpdates(stable, projects: ["black": .success(newerBeta)]).packages
            .map(\.latestVersion) == ["24.10.0"])
        // uv's reading is unchanged: a pre-release install is offered a newer pre-release.
        #expect(newerBeta.newerVersion(than: "25.0b1", python: "3.15.2") == "25.0b2")
        #expect(newerBeta.newerVersion(than: "25.0b1", python: "3.15.2", stableOnly: true) == nil)
    }

    /// pipx doesn't check git, URL and path installs against the index; the PyPI check doesn't either.
    @Test func indexSpecs() {
        for spec in ["black==24.2.0", "black", "Black[d]>=24", "black ; python_version >= '3.8'", "zope.interface<6"] {
            #expect(PipxEngine.isIndexSpec(spec, project: spec.hasPrefix("zope") ? "zope-interface" : "black"),
                    "\(spec)")
        }
        for spec in ["git+https://github.com/psf/black", "./black", "/tmp/black-24.2.0-py3-none-any.whl",
                     "black @ https://example.com/black.tar.gz", "https://example.com/black.whl", "~/src/black",
                     "black-24.2.0-py3-none-any.whl", "blacken", "file:///tmp/black", ""] {
            #expect(!PipxEngine.isIndexSpec(spec, project: "black"), "\(spec)")
        }
    }

    // MARK: search (exact names on PyPI)

    @Test func searchLooksUpTheExactName() async throws {
        let registry = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let (engine, runner) = engine([:], registry: registry)
        let found = try await engine.search("  CowSay ")
        #expect(found.count == 1)
        let row = try #require(found.first)
        #expect(row.id == tool("cowsay"))
        #expect(row.displayName == "cowsay")
        #expect(row.latestVersion == "6.1")
        #expect(row.summary == "The famous cowsay for GNU/Linux is now available for python")
        #expect(row.installedVersion == nil)
        #expect(registry.requested.map(\.absoluteString) == [cowsayURL])
        #expect(runner.calls.isEmpty)
    }

    @Test func searchForAnUnknownNameIsEmpty() async throws {
        let unknown = "https://pypi.org/pypi/no-such-package-for-brewxport/json"
        #expect(try String(contentsOf: fixtures.appendingPathComponent("pypi-unknown.http"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "404")
        let registry = FakeRegistryFetch([unknown: .failure(RegistryFetchError.status(404))])
        let (engine, _) = engine([:], registry: registry)
        #expect(try await engine.search("no_such.package-for-brewxport").isEmpty)
        #expect(registry.requested.map(\.absoluteString) == [unknown])
    }

    /// PyPI has no search: anything that isn't a project name is no match, and nothing is asked.
    @Test func searchForTextThatIsntANameAsksNothing() async throws {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        for query in ["python formatter", "https://example.com/x.whl", "-e", "../black", "black==24.2.0", "a/b"] {
            #expect(try await engine.search(query).isEmpty, "\(query)")
        }
        #expect(registry.requested.isEmpty)
    }

    @Test func emptySearchIsRefused() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        await #expect(throws: EngineError.self) { _ = try await engine.search("   ") }
        #expect(registry.requested.isEmpty)
    }

    @Test func searchFailsWhenPyPICantAnswer() async throws {
        let failures: [any Error] = [URLError(.timedOut), RegistryFetchError.tooLarge(8 * 1024 * 1024),
                                     RegistryFetchError.status(503)]
        for failure in failures {
            let (engine, _) = engine([:], registry: FakeRegistryFetch([cowsayURL: .failure(failure)]))
            await #expect(throws: EngineError.self, "\(failure)") { _ = try await engine.search("cowsay") }
        }
        let (engine, _) = engine([:], registry: FakeRegistryFetch(bodies: [cowsayURL: "<html>"]))
        await #expect(throws: EngineError.self) { _ = try await engine.search("cowsay") }
    }

    // MARK: info

    @Test func parsesInfo() async throws {
        let registry = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let (engine, _) = engine([:], registry: registry)
        let details = try await engine.info(tool("cowsay"))
        #expect(details.ref == tool("cowsay"))
        #expect(details.summary == "The famous cowsay for GNU/Linux is now available for python")
        #expect(details.homepage == URL(string: "https://github.com/VaasuDevanS/cowsay-python"))
        #expect(details.latestVersion == "6.1")
        #expect(details.reportedName == "cowsay")
        #expect(registry.requested.map(\.absoluteString) == [cowsayURL])
    }

    /// A tool installed with a suffix is the same PyPI project; details look that project up: the venv
    /// `pyjokes-private` (`pipx install --suffix=-private … pyjokes`, `t13-list-json-six`) is pyjokes. Its PyPI answer
    /// wasn't captured, so the lookup is a 404.
    @Test func infoLooksUpTheVenvsProject() async throws {
        let registry = FakeRegistryFetch()
        let (six, _) = engine([["list", "--json"]: try captured("t13-list-json-six")], registry: registry)
        #expect(try await six.listInstalled().map(\.id.name) == ["black", "cowsay", "pygments", "pyjokes-private"])
        await #expect(throws: EngineError.self) { _ = try await six.info(tool("pyjokes-private")) }
        #expect(registry.requested.map(\.absoluteString) == ["https://pypi.org/pypi/pyjokes/json"])

        // Not a capture: the captured `list-json` with cowsay's venv renamed as a suffix would name it, so the found
        // details can be checked against the one captured PyPI answer (cowsay's; pyjokes' wasn't captured).
        let listing = try captured("list-json")
        let renamed = listing.stdout.replacingOccurrences(of: "\"cowsay\": {", with: "\"cowsay3.15\": {")
        #expect(renamed != listing.stdout)
        let cowsay = FakeRegistryFetch(bodies: [cowsayURL: try pypiBody("pypi-cowsay")])
        let (suffixed, _) = engine([["list", "--json"]: CommandResult(exitCode: 0, stdout: renamed, stderr: "")],
                                   registry: cowsay)
        #expect(try await suffixed.listInstalled().map(\.id.name) == ["black", "cowsay3.15"])
        let details = try await suffixed.info(tool("cowsay3.15"))
        #expect(details.ref == tool("cowsay3.15"))
        #expect(details.reportedName == "cowsay")
        #expect(cowsay.requested.map(\.absoluteString) == [cowsayURL])
    }

    @Test func infoForAnUnknownProjectFails() async throws {
        let (engine, _) = engine([:])
        do {
            _ = try await engine.info(tool("no-such-package-for-brewxport"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .pipx)
            #expect(error.message.contains("PyPI"))
        }
    }

    /// Errors that aren't PyPI's (a cancelled check, demo mode's uncaptured answers) pass through as they are.
    @Test func infoPassesOtherErrorsThrough() async {
        let (engine, _) = engine([:], registry: FakeRegistryFetch([cowsayURL: .failure(CancellationError())]))
        await #expect(throws: CancellationError.self) { _ = try await engine.info(tool("cowsay")) }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        for name in ["bad name!", "git+https://example.com/x", "https://example.com/x.whl", "-e", "../x", "x.whl"] {
            await #expect(throws: EngineError.self) { _ = try await engine.info(tool(name)) }
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .uv, kind: .tool, name: "cowsay"))
        }
        #expect(registry.requested.isEmpty)
    }

    // MARK: commands

    @Test func commandShapes() throws {
        let (engine, _) = engine([:])
        let refs = [tool("black"), tool("zope.interface")]
        let install = try engine.command(for: .install, refs, options: InstallOptions())
        #expect(install.executable == pipx)
        #expect(install.arguments == ["install", "black", "zope.interface"])
        #expect(install.needsRoot == false)
        let upgrade = try engine.command(for: .upgrade, [tool("zope.interface")], options: InstallOptions())
        #expect(upgrade.arguments == ["upgrade", "zope.interface"])
        let remove = try engine.command(for: .remove, [tool("cowsay")], options: InstallOptions())
        #expect(remove.arguments == ["uninstall", "cowsay"])
        // `pipx uninstall` takes one tool, and so does `pipx upgrade` before 1.6.0: the planner splits them.
        #expect(throws: EngineError(engine: .pipx, message: "pipx removes one tool at a time")) {
            _ = try engine.command(for: .remove, refs, options: InstallOptions())
        }
        #expect(throws: EngineError(engine: .pipx, message: "pipx updates one tool at a time")) {
            _ = try engine.command(for: .upgrade, refs, options: InstallOptions())
        }
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, tool("cowsay")) == .never)
        }
    }

    @Test func commandsCarryPipxsEnvironmentAndHome() throws {
        let (engine, _) = engine([:])
        let spec = try engine.command(for: .upgrade, [tool("cowsay")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["NO_COLOR"] == "1")
        #expect(env["HOME"] == "/Users/someone")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// Review Focus 3: nothing but a project name reaches `pipx install`.
    @Test func pipxRefusesNonRegistrySpecs() throws {
        let (engine, _) = engine([:])
        let specs = ["https://example.com/black.whl", "git+https://github.com/psf/black", "../path", "./black",
                     "/tmp/black", "~/black", "-e", "--force", "--index-url=https://example.com", "black==24.2.0",
                     "black[d]", "black @ https://example.com/black.tar.gz", "black-24.2.0-py3-none-any.whl",
                     "black-24.2.0.tar.gz", "black.zip", "someone/black", "bad name!", ""]
        for name in specs {
            for op in [PackageOperation.install, .upgrade] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [tool("cowsay"), tool(name)], options: InstallOptions())
                }
            }
            #expect(throws: EngineError.self, "remove \(name)") {
                _ = try engine.command(for: .remove, [tool(name)], options: InstallOptions())
            }
        }
    }

    @Test func commandRefusesWhatPipxCantDoHere() throws {
        let (engine, _) = engine([:])
        let cowsay = [tool("cowsay")]
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(version: "5.0"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, cowsay, options: InstallOptions(extraArgs: ["--pip-args=-i x"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markDependency, cowsay, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .uv, kind: .tool, name: "cowsay")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .pipx, kind: .formula, name: "cowsay")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutPipxThrows() {
        let (engine, _) = engine([:], executable: nil)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool("cowsay")], options: InstallOptions())
        }
    }

    // MARK: credentials in messages

    /// An index URL with a user name or token never reaches a message, even when pipx or pip prints one
    /// (`CredentialScrubber`, whose own tests cover the forms).
    @Test func messagesNeverShowURLCredentials() async {
        // Not captures: a failed list whose stderr names an index with a token, once whole and once where the 300
        // characters shown would end inside the token (so the URL is cleaned before it's cut).
        let url = "https://__token__:s3cretvalue@pypi.example.com/simple/"
        for stderr in ["error: no index at \(url)", String(repeating: "x", count: 270) + " " + url] {
            let (engine, _) = engine([["list", "--json"]: CommandResult(exitCode: 1, stdout: "", stderr: stderr)])
            do {
                _ = try await engine.listInstalled()
                Issue.record("expected an error")
            } catch let error as EngineError {
                #expect(error.message.contains("https://pypi.example.com/simple/") || stderr.count > 300)
                #expect(!error.message.contains("s3cret"))
                #expect(!error.message.contains("__token__"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    /// pipx's outdated answer can carry pip's words about an index with a token; the message never does. Values, not
    /// a capture.
    @Test func outdatedErrorsNeverShowURLCredentials() {
        typealias Answer = PipxEngine.OutdatedAnswer
        let failed = Answer.Failure(code: "environment_outdated_check_failed", environment: nil,
                                    message: "Could not fetch URL "
                                        + "https://__token__:s3cret@pypi.example.com/simple/black/"
                                        + " or https://pypi.example.com/simple/?token=s3cret")
        do {
            _ = try PipxEngine.outdated(Answer(status: "error", data: nil, errors: [failed]))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("https://pypi.example.com/simple/black/"))
            #expect(!error.message.contains("s3cret"))
            #expect(!error.message.contains("__token__"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: what pipx's tools run on

    /// R29: each venv's `pyvenv.cfg` (in PIPX_HOME's `venvs`) says whether it follows a patch update. The captured
    /// venvs (`t13-pyvenv-cfg-black.cfg`, `-cowsay.cfg`) were both made through Homebrew's `opt` link, so both do; a
    /// venv whose file can't be read doesn't count. No venv pinned to a Cellar copy was captured: that `home` is
    /// covered by `VenvConfig.followsPatchUpdates`' own values below.
    @Test func pipxReadsEachVenvsHome() async throws {
        let venvs = "/Users/tester/Library/Application Support/pipx/venvs/"
        let files = ["black": "t13-pyvenv-cfg-black.cfg", "cowsay": "t13-pyvenv-cfg-cowsay.cfg"]
        func engine(_ readable: Set<String>) throws -> PipxEngine {
            let runner = FakeRunner([["--version"]: try captured("version"),
                                     ["environment", "--value", "PIPX_HOME"]: try captured("environment-pipx-home"),
                                     ["list", "--json"]: try captured("list-json")])
            return PipxEngine(runner: runner, registry: FakeRegistryFetch(), executable: pipx, base: base,
                              readToolFile: { path in
                                  let name = String(path.dropFirst(venvs.count).dropLast("/pyvenv.cfg".count))
                                  guard path.hasPrefix(venvs), readable.contains(name), let file = files[name] else {
                                      return nil
                                  }
                                  return try Data(contentsOf: fixtures.appendingPathComponent(file))
                              })
        }
        let both = try engine(["black", "cowsay"])
        _ = await both.detect()
        #expect(try await both.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["black", "cowsay"],
                                                            patchSafeTools: ["black", "cowsay"])])
        let one = try engine(["black"])
        _ = await one.detect()
        #expect(try await one.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["black", "cowsay"],
                                                           patchSafeTools: ["black"])])
        #expect(!VenvConfig.followsPatchUpdates(home: "/opt/homebrew/Cellar/python@3.15/3.15.2/bin",
                                                formula: "python@3.15"))
    }

    /// A venv name pipx printed that isn't one plain folder name is never put in a path: its `pyvenv.cfg` isn't read, so
    /// it counts as unknown (held). Not a capture: the captured list with black's venv renamed to a name pipx never
    /// prints, made up on purpose to check the guard.
    @Test func pipxNeverReadsAVenvFolderOutsideItsVenvs() async throws {
        let listed = try captured("list-json").stdout.replacingOccurrences(of: "\"black\": {", with: "\"../black\": {")
        let asked = Asked()
        let runner = FakeRunner([["--version"]: try captured("version"),
                                 ["environment", "--value", "PIPX_HOME"]: try captured("environment-pipx-home"),
                                 ["list", "--json"]: CommandResult(exitCode: 0, stdout: listed, stderr: "")])
        let engine = PipxEngine(runner: runner, registry: FakeRegistryFetch(), executable: pipx, base: base,
                                readToolFile: { path in
                                    asked.add(path)
                                    return Data("home = /opt/homebrew/opt/python@3.15/bin\n".utf8)
                                })
        _ = await engine.detect()
        let uses = try await engine.runtimeUses()
        #expect(uses.first?.tools == ["../black", "cowsay"])
        #expect(uses.first?.patchSafeTools == ["cowsay"])
        #expect(asked.paths.allSatisfy { !$0.contains("..") })
        #expect(asked.paths.count == 1)
    }

    /// A venv's interpreter path names today's Python, which for an unversioned link (`/opt/homebrew/bin/python3`) may
    /// not be the one the venv was made with: the version's Python counts too, so both are held (the careful way).
    @Test func pipxCountsBothThePathsAndTheVersionsPython() {
        let link = "/opt/homebrew/bin/python3"
        let today = "/opt/homebrew/Cellar/python@3.14/3.14.1/bin/python3.14"
        #expect(PipxEngine.homebrewPythons(interpreter: link, version: "3.15.2", realPath: { $0 == link ? today : nil })
                == ["python@3.14", "python@3.15"])
        #expect(PipxEngine.homebrewPythons(interpreter: "/opt/homebrew/opt/python@3.15/bin/python3.15",
                                           version: "3.15.2", realPath: { _ in nil }) == ["python@3.15"])
        // Not Homebrew's by its path: its version still counts.
        #expect(PipxEngine.homebrewPythons(interpreter: "/Users/someone/.pyenv/versions/3.13.1/bin/python3.13",
                                           version: "3.13.1", realPath: { _ in nil }) == ["python@3.13"])
        #expect(PipxEngine.homebrewPythons(interpreter: nil, version: nil).isEmpty)
    }

    /// Each venv names the Python it was made with (`source_interpreter`): Homebrew's python@3.15 for both captured
    /// tools, so a change to that formula breaks them until they're reinstalled.
    @Test func pipxToolsRunOnHomebrewPython() async throws {
        let (listing, runner) = engine([["list", "--json"]: try captured("list-json")])
        #expect(try await listing.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["black", "cowsay"])])
        #expect(runner.calls == [["list", "--json"]])
        // Before a detect there's no PIPX_HOME, so no venv's pyvenv.cfg is read: none counts as safe.
        #expect(try await listing.runtimeUses().first?.patchSafeTools == [])
        // A pipx that can't list (here pipx 1.5.0 with a newer pipx's venvs) can't say: the caller assumes the worst.
        let (broken, _) = engine([["list", "--json"]: try captured("t13-old-1.5.0-real-list-json")])
        await #expect(throws: EngineError.self) { _ = try await broken.runtimeUses() }
    }
}
