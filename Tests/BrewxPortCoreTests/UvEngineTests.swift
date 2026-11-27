import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// One captured uv command from `Fixtures/uv` (see its SOURCES.md): stdout from `NAME.txt`, stderr from
/// `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent("uv/" + file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).txt") ?? "", stderr: read("\(name)-stderr.txt") ?? "")
}

/// PyPI's captured answer for cowsay (`Fixtures/pipx/pypi-cowsay.json`), decoded.
private func cowsayProject() throws -> PyPI.Project {
    let body = try Data(contentsOf: fixtures.appendingPathComponent("pipx/pypi-cowsay.json"))
    return try JSONDecoder().decode(PyPI.Project.self, from: body)
}

private let uv = URL(fileURLWithPath: "/opt/homebrew/bin/uv")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let quiet = ["--color", "never", "--no-progress"]
private let versionArguments = ["--version"]
private let toolDirArguments = ["tool", "dir"] + quiet
private let binDirArguments = ["tool", "dir", "--bin"] + quiet
private let listArguments = ["tool", "list", "--show-version-specifiers"] + quiet
private let outdatedArguments = ["tool", "list", "--show-version-specifiers", "--outdated"] + quiet
private let pythonListArguments = ["tool", "list", "--show-version-specifiers", "--show-with", "--show-extras",
                                   "--show-python", "--show-paths"] + quiet
private let cowsayURL = "https://pypi.org/pypi/cowsay/json"
private let isortURL = "https://pypi.org/pypi/isort/json"

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .uv, kind: .tool, name: name) }

private func engine(_ responses: [[String]: CommandResult], executable: URL? = uv,
                    registry: FakeRegistryFetch = FakeRegistryFetch()) -> (UvEngine, FakeRunner) {
    let runner = FakeRunner(responses)
    return (UvEngine(runner: runner, registry: registry, executable: executable, base: base), runner)
}

/// An older uv's `--version`, as captured (`t13-old-<version>-version`: 0.4.5, 0.4.6, 0.9.1, 0.9.2, 0.10.9, 0.10.10).
private func olderVersion(_ version: String) throws -> CommandResult { try captured("t13-old-\(version)-version") }

/// A captured file from `Fixtures/uv` as it is (a receipt, a `pyvenv.cfg`).
private func capturedFile(_ file: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("uv/" + file), encoding: .utf8)
}

/// A tool as `tool list` would have printed it. Values, not a capture.
private func listed(_ name: String, _ version: String, required: String? = nil, python: String? = "3.15.2",
                    latest: String? = nil) -> UvEngine.Tool {
    let specifier = required.flatMap { PyPI.Specifier($0) }
    return UvEngine.Tool(name: name, version: version, requirement: specifier,
                         fromIndex: required == nil || specifier != nil, python: python, latest: latest)
}

@Suite struct UvEngineTests {
    // MARK: detect

    @Test func detectsVersionToolDirAndBinDir() async throws {
        let (engine, runner) = engine([versionArguments: try captured("version"),
                                       toolDirArguments: try captured("tool-dir"),
                                       binDirArguments: try captured("tool-dir-bin")])
        #expect(engine.installLocation == nil)
        #expect(engine.binLocation == nil)
        #expect(await engine.detect() == .present(path: uv, version: "0.13.10"))
        #expect(engine.installLocation
                == URL(fileURLWithPath: "/Users/tester/.local/share/uv/tools", isDirectory: true))
        #expect(engine.binLocation == URL(fileURLWithPath: "/Users/tester/.local/bin", isDirectory: true))
        #expect(runner.calls == [versionArguments, toolDirArguments, binDirArguments])
    }

    @Test func detectMissingWithoutExecutable() async {
        let (engine, runner) = engine([:], executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
    }

    /// Not a capture: `uv tool dir` never failed in the captures (Task 0's, nor T13's older uv versions), so its
    /// failure, and the bin folder beside it, are made up. uv stays present, without its folders.
    @Test func failedFoldersKeepUvPresent() async throws {
        let refused = CommandResult(exitCode: 2, stdout: "", stderr: "error: unrecognized subcommand 'dir'")
        let (engine, _) = engine([versionArguments: try captured("version"), toolDirArguments: refused,
                                  binDirArguments: CommandResult(exitCode: 0, stdout: "bin\n", stderr: "")])
        #expect(await engine.detect() == .present(path: uv, version: "0.13.10"))
        #expect(engine.installLocation == nil)
        #expect(engine.binLocation == nil)
    }

    /// Not a capture: `uv --version` never failed in the captures (every older uv answered), so its failure is made up.
    @Test func detectUnusableWhenVersionFails() async {
        let broken = CommandResult(exitCode: 1, stdout: "", stderr: "dyld: Library not loaded")
        let (engine, runner) = engine([versionArguments: broken])
        #expect(isUnusable(await engine.detect(), at: uv))
        #expect(engine.installLocation == nil)
        #expect(runner.calls == [versionArguments])
    }

    /// `uv --version` names uv, then its version. The other lines aren't captures.
    @Test func readsUvsVersion() throws {
        #expect(UvEngine.version(try captured("version").stdout) == "0.13.10")
        #expect(UvEngine.version("uv 0.4.30\n") == "0.4.30")
        #expect(UvEngine.version("uv 0.13.10 (4c3f1c2 2026-11-24)") == "0.13.10")
        for text in ["", "0.13.10", "uvx 0.13.10", "uv", "uv unknown (Homebrew)"] {
            #expect(UvEngine.version(text) == nil, "\(text)")
        }
    }

    /// Every uv command runs with uv's own folder first on PATH, only uv's login-shell variables and NO_COLOR, from
    /// the home folder.
    @Test func commandsRunWithUvsEnvironmentFromHome() async throws {
        let local = URL(fileURLWithPath: "/Users/someone/.local/bin/uv")
        let runner = FakeRunner([versionArguments: try captured("version"),
                                 toolDirArguments: try captured("tool-dir"),
                                 binDirArguments: try captured("tool-dir-bin")])
        let captured = ["UV_TOOL_DIR": "/Users/someone/tools", "PIPX_HOME": "/Users/someone/.pipx",
                        "XDG_DATA_HOME": "/Users/someone/.data"]
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(), executable: local, captured: captured,
                              base: base)
        _ = await engine.detect()
        #expect(runner.optionsCalls.count == 3)
        for options in runner.optionsCalls {
            let env = try #require(options.environment)
            #expect(env["PATH"]?.hasPrefix("/Users/someone/.local/bin:/opt/homebrew/bin:") == true)
            #expect(env["UV_TOOL_DIR"] == "/Users/someone/tools")
            #expect(env["XDG_DATA_HOME"] == "/Users/someone/.data")
            #expect(env["PIPX_HOME"] == nil)
            #expect(env["NO_COLOR"] == "1")
            #expect(options.workingDirectory == "/Users/someone")
        }
    }

    // MARK: finding uv

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-uv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("mise/installs/uv/0.13.10/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("uv")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([versionArguments: try captured("version")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["UV_TOOL_BIN_DIR": root.path + "/bin"])
        // The captured folders are the VM's: this test is about finding uv, so they count as writable.
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(), loginShell: { context }, arch: .arm64,
                              base: base, isWritable: { _ in true })
        // Nothing is looked for until a detect asks the login shell.
        #expect(engine.executableURL == nil)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/uv"), version: "0.13.10"))
        #expect(runner.executableCalls.allSatisfy { $0.path == realBin + "/uv" })
        let env = try #require(runner.optionsCalls.first?.environment)
        #expect(env["PATH"]?.hasPrefix(realBin + ":") == true)
        #expect(env["UV_TOOL_BIN_DIR"] == root.path + "/bin")
        let spec = try engine.command(for: .install, [tool("ruff")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/uv")
    }

    @Test func liveEngineWithoutUvIsMissing() async {
        let runner = FakeRunner([:])
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(),
                              loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"], environment: [:]) },
                              arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool("ruff")], options: InstallOptions())
        }
    }

    /// Homebrew (this Mac's prefix first), MacPorts, nanobrew, then the standalone installer's folders (XDG_BIN_HOME,
    /// `~/.local/bin`) and the older installers' and `cargo install`'s (CARGO_HOME's bin, `~/.cargo/bin`).
    @Test func fixedFoldersPutTheMachinesHomebrewFirst() {
        let home = "/Users/someone"
        #expect(UvEngine.fixedFolders(arch: .arm64, home: home, captured: [:])
                == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                    home + "/.local/bin", home + "/.cargo/bin"])
        let captured = ["XDG_BIN_HOME": "/Users/someone/xdg/bin", "CARGO_HOME": "/Users/someone/rust/cargo"]
        #expect(UvEngine.fixedFolders(arch: .x86_64, home: home, captured: captured)
                == ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/opt/nanobrew/prefix/bin",
                    "/Users/someone/xdg/bin", home + "/.local/bin", "/Users/someone/rust/cargo/bin",
                    home + "/.cargo/bin"])
    }

    // MARK: installed

    @Test func parsesInstalled() async throws {
        let (engine, runner) = engine([listArguments: try captured("tool-list-specifiers")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["isort", "ruff"])
        #expect(found.map(\.displayName) == ["isort", "ruff"])
        #expect(found.map(\.installedVersion) == ["5.13.2", "0.6.0"])
        #expect(found.allSatisfy { $0.id.engine == .uv && $0.id.kind == .tool && $0.installedOnRequest == true })
        #expect(runner.calls == [listArguments])
    }

    @Test func installedWithNothingIsEmpty() async throws {
        let empty = try captured("tool-list-empty")
        #expect(empty.stdout.isEmpty)
        #expect(empty.stderr.contains("No tools installed"))
        let (engine, _) = engine([listArguments: empty])
        #expect(try await engine.listInstalled().isEmpty)
        // uv's "No tools installed" isn't a note.
        #expect(engine.note == nil)
    }

    /// A broken tool uv leaves out of its list doesn't vanish without a word: what uv said on stderr is the engine's
    /// note until a listing says nothing. The captured warnings: a tool whose Python link was deleted
    /// (`t13-broken-link-list`), tools whose Python was removed (`t13-broken-python-list`), and tools on a Homebrew
    /// Python that was autoremoved (`t13-homebrew-python-removed-list-specifiers`).
    @Test func brokenToolWarningIsKeptAsANote() async throws {
        let broken = try captured("t13-broken-python-list")
        let runner = FakeRunner([listArguments: broken])
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(), executable: uv, base: base)
        #expect(try await engine.listInstalled().map(\.id.name) == ["isort", "ruff"])
        let note = try #require(engine.note)
        #expect(note.hasPrefix("uv said while listing its tools: warning: Tool `black` environment not found"))
        #expect(note.contains("Tool `pyfiglet` environment not found"))
        let link = try captured("t13-broken-link-list")
        #expect(UvEngine.listNote(link.stderr)?.contains("missing Python executable") == true)
        #expect(try UvEngine.tools(link.stdout).map(\.name) == ["black", "isort", "pyfiglet", "ruff", "sampleproject"])
        let removed = try captured("t13-homebrew-python-removed-list-specifiers")
        #expect(UvEngine.listNote(removed.stderr)?.contains("Tool `isort` environment not found") == true)
        // Not a capture: a warning naming an index with a token, made up to check it's never shown.
        let token = UvEngine.listNote("warning: index https://user:token@pypi.example.com/simple?key=secret failed\n")
        #expect(token?.contains("token") == false && token?.contains("secret") == false)
        #expect(UvEngine.listNote("No tools installed\n") == nil)
        #expect(UvEngine.listNote("") == nil)
        let prefix = "uv said while listing its tools: "
        #expect(UvEngine.listNote(String(repeating: "x", count: 1000))?.count == prefix.count + 300)
        runner.respond(listArguments, try captured("tool-list"))
        _ = try await engine.listInstalled()
        #expect(engine.note == nil)
    }

    /// A failed list, in uv's words: uv 0.4.5 refusing `--show-version-specifiers` (`t13-old-0.4.5-list-specifiers`).
    @Test func installedFailsInUvsWords() async throws {
        let (engine, _) = engine([listArguments: try captured("t13-old-0.4.5-list-specifiers")])
        do {
            _ = try await engine.listInstalled()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .uv)
            #expect(error.message.hasPrefix("uv tool list failed (exit 2): error: unexpected argument "
                                            + "'--show-version-specifiers' found"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    /// Every captured list, whatever flags it was asked with: the tool lines, never their executables' lines, paths
    /// or the Python's name.
    @Test func parserReadsEveryCapturedList() throws {
        func tools(_ name: String) throws -> [UvEngine.Tool] { try UvEngine.tools(try captured(name).stdout) }
        let pin = { (version: String) in PyPI.Specifier("==" + version) }

        for name in ["tool-list", "tool-list-paths"] {
            #expect(try tools(name) == [listed("isort", "5.13.2", python: nil), listed("ruff", "0.6.0", python: nil)],
                    "\(name)")
        }
        #expect(try tools("tool-list-specifiers") == [
            listed("isort", "5.13.2", required: "==5.13.2", python: nil),
            listed("ruff", "0.6.0", required: "==0.6.0", python: nil),
        ])
        #expect(try tools("tool-list-all-flags") == [listed("isort", "5.13.2", required: "==5.13.2"),
                                                     listed("ruff", "0.6.0", required: "==0.6.0")])
        #expect(try tools("tool-list-outdated") == [listed("isort", "5.13.2", python: nil, latest: "9.0.2"),
                                                    listed("ruff", "0.6.0", python: nil, latest: "0.17.6")])
        #expect(try tools("tool-list-specifiers-outdated") == [
            listed("isort", "5.13.2", required: "==5.13.2", python: nil, latest: "9.0.2"),
            listed("ruff", "0.6.0", required: "==0.6.0", python: nil, latest: "0.17.6"),
        ])
        for name in ["tool-list-final", "tool-list-specifiers-after-unpin"] {
            #expect(try tools(name) == [listed("isort", "5.13.2", python: nil, latest: "9.0.2"),
                                        listed("ruff", "0.6.0", required: "==0.6.0", python: nil, latest: "0.17.6")],
                    "\(name)")
        }
        #expect(try tools("tool-list-after-upgrade-all")
                == [listed("ruff", "0.6.0", required: "==0.6.0", python: nil, latest: "0.17.6")])
        #expect(try tools("tool-list-empty").isEmpty)
        #expect(try tools("tool-list-specifiers").allSatisfy { $0.isPinned })
        #expect(try tools("tool-list-specifiers")[0].requirement == pin("5.13.2"))
    }

    /// Every bracket uv prints (`t13-list-all-flags-many`): a range, extras, `with:`, CPython and PyPy, a wheel URL and
    /// a git repository (two spaces after `required:`), and paths. uv 0.4.6 prints `[required: ]` for a tool
    /// installed without one (`t13-old-0.4.6-list-specifiers`), which allows every version, so it's from an index.
    @Test func parserReadsEveryBracket() throws {
        let tools = try UvEngine.tools(try captured("t13-list-all-flags-many").stdout)
        #expect(tools.map(\.name) == ["black", "isort", "pyfiglet", "ruff", "sampleproject", "tabulate"])
        #expect(tools[0].requirement == PyPI.Specifier(">=24, <24.3.0"))
        #expect(tools[0].fromIndex && !tools[0].isPinned)
        #expect(tools[0].python == "3.12.16")
        #expect(tools[1].requirement == PyPI.Specifier(">=5, <7"))
        #expect(tools[1].python == "3.15.2")
        #expect(!tools[2].fromIndex && tools[2].requirement == nil)
        #expect(tools[3].isPinned)
        #expect(!tools[4].fromIndex && tools[4].requirement == nil)
        #expect(tools[5].python == "3.12.15")
        #expect(tools[5].fromIndex && tools[5].requirement == nil)
        let outdated = try UvEngine.tools(try captured("t13-list-outdated-many").stdout)
        #expect(outdated.map(\.latest) == ["26.10.1", "9.0.2", "1.0.4", "0.17.6"])
        let old = try UvEngine.tools(try captured("t13-old-0.4.6-list-specifiers").stdout)
        #expect(old.map(\.name) == ["black", "isort", "pyfiglet", "ruff", "sampleproject", "tabulate"])
        #expect(old[5].fromIndex && !old[5].isPinned)
        // Not a capture (R46): a requirement holding brackets of its own (a wheel on an IPv6 host), made up, since no
        // captured install had one: the requirement's brackets don't end it, and it isn't from an index.
        let nested = try UvEngine.tools("fromwheel v1.0 [required: http://[::1]/fromwheel-1.0-py3-none-any.whl] "
                                        + "[latest: 2.0]\n- fromwheel\n")
        #expect(nested.map(\.name) == ["fromwheel"])
        #expect(!nested[0].fromIndex && nested[0].requirement == nil)
        #expect(nested[0].latest == "2.0")
    }

    /// Not captures: stdout BrewxPort doesn't know is a failure, not an empty or partial list. Made up on purpose: no
    /// uv printed these.
    @Test func parserRefusesLinesItDoesntKnow() {
        for text in ["isort 5.13.2\n- isort", "warning: something changed", "isort v5.13.2 [latest: 9.0.2",
                     "isort v5.13.2 extra words", "bad/name v1.0"] {
            #expect(throws: EngineError.self, "\(text)") { _ = try UvEngine.tools(text) }
        }
    }

    /// A tool installed from a URL, a path or git shows that source as its requirement, which can hold a token. The
    /// list keeps only that it isn't from an index: the captured git and wheel installs (`t13-list-specifiers-many`,
    /// `t13-list-outdated-many`), and, not a capture, the same shape with a token made up to check it's dropped.
    @Test func listNeverKeepsAnInstallSource() throws {
        for name in ["t13-list-specifiers-many", "t13-list-outdated-many"] {
            let listed = try UvEngine.tools(try captured(name).stdout)
            let sources = listed.filter { ["pyfiglet", "sampleproject"].contains($0.name) }
            #expect(!sources.isEmpty && sources.allSatisfy { !$0.fromIndex && $0.requirement == nil }, "\(name)")
            #expect(!String(reflecting: listed).contains("git+") && !String(reflecting: listed).contains("https:"))
            #expect(!UvEngine.updates(listed).contains { $0.id.name == "pyfiglet" })
        }
        let text = "mytool v1.0.0 [required: git+https://__token__:s3cret@git.example.com/me/mytool.git] "
            + "[latest: 2.0]\n- mytool\n"
        let tools = try UvEngine.tools(text)
        #expect(tools.map(\.name) == ["mytool"])
        #expect(tools.allSatisfy { !$0.fromIndex && $0.requirement == nil })
        let dumped = String(reflecting: tools)
        #expect(!dumped.contains("s3cret"))
        #expect(!dumped.contains("git+"))
        #expect(UvEngine.updates(tools).isEmpty)
    }

    // MARK: outdated (uv's own check)

    /// R41: a tool installed with a range (`isort>=5,<7` at 5.13.2) gets `[latest: 9.0.2]`, outside it, from uv's own
    /// check (`t13-list-outdated-many`), but `uv tool upgrade` still moves it inside the range (to 6.1.0,
    /// `t13-upgrade-isort-in-range`). So such a tool is looked up on PyPI for its newest version inside the range, on
    /// its own Python (its `pyvenv.cfg`); black's range is the other. Their PyPI answers weren't captured, so here
    /// both lookups fail, and they're named as not checked (R6), never a failed check. A pinned tool (ruff) and one
    /// not from an index (pyfiglet) aren't looked up.
    @Test func rangedToolsAreOfferedTheNewestInTheirRange() async throws {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([outdatedArguments: try captured("t13-list-outdated-many")], registry: registry)
        let report = try await engine.checkOutdated()
        #expect(report.packages.isEmpty)
        #expect(report.unchecked.names == ["black", "isort"])
        #expect(Set(registry.requested.map(\.absoluteString)) == ["https://pypi.org/pypi/black/json", isortURL])
        #expect(UvEngine.outOfRange(try UvEngine.tools(try captured("t13-list-outdated-after-in-range-upgrade").stdout))
            .map(\.name) == ["black", "isort"])
        let upgraded = try captured("t13-upgrade-isort-in-range")
        #expect(upgraded.stderr.hasPrefix("Updated isort v5.13.2 -> v6.1.0"))
        let expectedUpgrade: [String] = ["tool", "upgrade"] + quiet + ["isort"]
        #expect(try engine.command(for: .upgrade, [tool("isort")], options: InstallOptions()).arguments
                == expectedUpgrade)

        // Values and the real cowsay answer: the newest release inside the range (6.1 is outside `<6.1`), on the
        // tool's Python, never one outside it.
        let cowsay = try cowsayProject()
        let ranged = [listed("cowsay", "5.0", required: ">=5,<6.1", python: "3.12.16", latest: "6.1")]
        #expect(UvEngine.outOfRange(ranged).map(\.name) == ["cowsay"])
        let found = UvEngine.inRangeUpdates(ranged, projects: ["cowsay": .success(cowsay)])
        #expect(found.packages.map(\.latestVersion) == ["6.0"])
        #expect(found.unchecked.isEmpty)
        #expect(UvEngine.inRangeUpdates([listed("cowsay", "6.0", required: ">=5,<6.1", latest: "6.1")],
                                        projects: ["cowsay": .success(cowsay)]).packages.isEmpty)
        #expect(UvEngine.outOfRange([listed("pinned", "1.0", required: "==1.0", latest: "2.0"),
                                     listed("inside", "1.0", required: "<3", latest: "2.0"),
                                     listed("plain", "1.0", latest: "2.0")]).isEmpty)
    }

    /// With the tool folder known, the in-range lookup checks releases against the tool's own Python, from its
    /// `pyvenv.cfg` (`t13-pyvenv-cfg-isort.cfg`: 3.15.2).
    @Test func rangedToolsUseTheirOwnPython() async throws {
        let isortConfig = Data(try capturedFile("t13-pyvenv-cfg-isort.cfg").utf8)
        let runner = FakeRunner([versionArguments: try captured("version"), toolDirArguments: try captured("tool-dir"),
                                 binDirArguments: try captured("tool-dir-bin"),
                                 outdatedArguments: try captured("t13-list-outdated-many")])
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(), executable: uv, base: base,
                              readToolFile: { path in
                                  path == "/Users/tester/.local/share/uv/tools/isort/pyvenv.cfg" ? isortConfig : nil
                              })
        _ = await engine.detect()
        let tools = try UvEngine.tools(try captured("t13-list-outdated-many").stdout)
        #expect(engine.withVenvPython(UvEngine.outOfRange(tools)).map(\.python) == [nil, "3.15.2"])
    }

    /// uv reports ruff's newest version although ruff is pinned to 0.6.0, which `uv tool upgrade` never moves: only
    /// isort is an update.
    @Test func parsesOutdated() async throws {
        let (engine, runner) = engine([outdatedArguments: try captured("tool-list-final")])
        let found = try await engine.listOutdated()
        #expect(found.map(\.id.name) == ["isort"])
        #expect(found.map(\.installedVersion) == ["5.13.2"])
        #expect(found.map(\.latestVersion) == ["9.0.2"])
        #expect(found.allSatisfy { $0.id.engine == .uv && $0.id.kind == .tool })
        #expect(runner.calls == [outdatedArguments])
    }

    @Test func pinnedToolsAreNeverOffered() async throws {
        for name in ["tool-list-specifiers-outdated", "tool-list-after-upgrade-all"] {
            let (engine, _) = engine([outdatedArguments: try captured(name)])
            #expect(try await engine.listOutdated().isEmpty, "\(name)")
        }
    }

    /// Captured without `--show-version-specifiers`, which only adds `[required: …]` to tool lines: with no tools
    /// uv prints nothing on stdout either way.
    @Test func outdatedWithNothingIsEmpty() async throws {
        let (engine, _) = engine([outdatedArguments: try captured("tool-list-outdated-empty")])
        #expect(try await engine.listOutdated().isEmpty)
    }

    /// One failed lookup stops uv's whole check (exit 2, nothing on stdout); the message is uv's. Captured without
    /// `--show-version-specifiers`, which doesn't change a failure.
    @Test func outdatedFailsInUvsWords() async throws {
        for name in ["tool-list-outdated-network-refused", "tool-list-outdated-network-refused-no-cache"] {
            let refused = try captured(name)
            #expect(refused.exitCode == 2)
            let (engine, _) = engine([outdatedArguments: refused])
            do {
                _ = try await engine.listOutdated()
                Issue.record("expected an error")
            } catch let error as EngineError {
                #expect(error.engine == .uv)
                #expect(error.message.hasPrefix("uv tool list --outdated failed (exit 2): error: Request failed"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }

    /// uv 0.10.10 and later answer for themselves, after a detect too.
    @Test func newUvChecksForItself() async throws {
        let registry = FakeRegistryFetch()
        let (current, runner) = engine([versionArguments: try captured("version"),
                                        outdatedArguments: try captured("tool-list-final")], registry: registry)
        _ = await current.detect()
        #expect(try await current.listOutdated().map(\.id.name) == ["isort"])
        #expect(runner.calls.last == outdatedArguments)
        #expect(registry.requested.isEmpty)
        // The first uv with the flag.
        let (exact, exactRunner) = engine([versionArguments: try olderVersion("0.10.10"),
                                           outdatedArguments: try captured("tool-list-final")], registry: registry)
        _ = await exact.detect()
        #expect(try await exact.listOutdated().count == 1)
        #expect(exactRunner.calls.last == outdatedArguments)
    }

    /// What uv reports is an update only when `uv tool upgrade` would move to it: from an index, within the
    /// requirement the tool was installed with (never for an exact pin), newer by PEP 440, and no pre-release for a
    /// stable install. Values, not a capture.
    @Test func updatesKeepOnlyWhatUpgradeWouldMove() {
        let tools = [
            listed("plain", "1.0", latest: "2.0"),
            listed("ranged", "24.1.0", required: "<25", latest: "24.2.0"),
            listed("outside", "24.1.0", required: "<24.3.0", latest: "26.10.1"),
            listed("pinned", "0.6.0", required: "==0.6.0", latest: "0.17.6"),
            listed("fromgit", "1.0", required: "git+https://example.com/fromgit.git", latest: "2.0"),
            listed("older", "2.0", latest: "1.0"),
            listed("pre", "1.0", latest: "2.0rc1"),
            listed("current", "1.0"),
        ]
        let rows = UvEngine.updates(tools)
        #expect(rows.map(\.id.name) == ["plain", "ranged"])
        #expect(rows.map(\.latestVersion) == ["2.0", "24.2.0"])
    }

    /// On uv's own check, a pre-release install is offered a newer pre-release, and a stable install never is. Values,
    /// not a capture.
    @Test func preReleasesOnlyForAPreReleaseInstall() async throws {
        let rows = UvEngine.updates([listed("beta", "2.0b1", latest: "2.0rc1"),
                                     listed("stable", "1.0", latest: "2.0rc1"),
                                     listed("final", "2.0b1", latest: "2.0")])
        #expect(rows.map(\.id.name) == ["beta", "final"])
        #expect(rows.map(\.latestVersion) == ["2.0rc1", "2.0"])
        // The same through the engine, on uv's own `--outdated` answer. Not a capture: no tool on a pre-release was
        // captured (Task 0 or T13), so this is the real capture with isort's line edited to one, offered 9.0.2's
        // release candidate.
        let final = try captured("tool-list-final")
        for (installed, offered) in [("9.0.0b1", "9.0.2rc1"), ("5.13.2", nil)] {
            let edited = final.stdout.replacingOccurrences(of: "isort v5.13.2 [latest: 9.0.2]",
                                                           with: "isort v\(installed) [latest: 9.0.2rc1]")
            #expect(edited != final.stdout)
            let (engine, _) = engine([outdatedArguments: CommandResult(exitCode: 0, stdout: edited, stderr: "")])
            #expect(try await engine.listOutdated().first { $0.id.name == "isort" }?.latestVersion == offered,
                    "\(installed)")
        }
    }

    // MARK: outdated (PyPI, for a uv before 0.10.10)

    /// uv 0.9.2 to 0.10.9 name each tool's Python, so PyPI's answer is checked against it (uv 0.9.2's own list,
    /// `t13-old-0.9.2-list-all-flags`): ruff is pinned and pyfiglet and sampleproject aren't from an index, so they
    /// aren't looked up; black's, isort's and tabulate's answers aren't captured, so none of the tools to check could
    /// be.
    @Test func olderUvChecksPyPI() async throws {
        let registry = FakeRegistryFetch()
        let (engine, runner) = engine([versionArguments: try olderVersion("0.9.2"),
                                       pythonListArguments: try captured("t13-old-0.9.2-list-all-flags")],
                                      registry: registry)
        #expect(await engine.detect() == .present(path: uv, version: "0.9.2"))
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .uv)
            #expect(error.message.hasPrefix("BrewxPort couldn't check PyPI for newer versions: "))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(Set(registry.requested.map(\.absoluteString))
                == ["https://pypi.org/pypi/black/json", isortURL, "https://pypi.org/pypi/tabulate/json"])
        #expect(runner.calls.contains(pythonListArguments))
        #expect(!runner.calls.contains(outdatedArguments))
    }

    /// A uv before 0.9.2 can't name the Python: the plain list, and every tool here is pinned, so nothing is asked.
    @Test func olderUvWithoutShowPythonChecksWhatIsntPinned() async throws {
        let registry = FakeRegistryFetch()
        let (engine, runner) = engine([versionArguments: try olderVersion("0.4.6"),
                                       listArguments: try captured("tool-list-specifiers")], registry: registry)
        _ = await engine.detect()
        #expect(try await engine.listOutdated().isEmpty)
        #expect(runner.calls.last == listArguments)
        #expect(registry.requested.isEmpty)
    }

    /// PyPI's answer gives each tool its newest release that isn't yanked, fits its Python and meets its requirement;
    /// pinned tools and tools not from an index aren't looked up, and one failed lookup leaves only that tool out.
    /// Values and the real cowsay answer.
    @Test func pypiUpdatesUseEachToolsRequirementAndPython() throws {
        let cowsay = try cowsayProject()
        func update(_ tool: UvEngine.Tool) throws -> String? {
            try UvEngine.pypiUpdates([tool], projects: ["cowsay": .success(cowsay)]).packages.first?.latestVersion
        }
        #expect(try update(listed("cowsay", "5.0")) == "6.1")
        #expect(try update(listed("cowsay", "5.0", python: nil)) == "6.1")
        // 6.1 needs Python 3.8.
        #expect(try update(listed("cowsay", "5.0", python: "3.7.17")) == "6.0")
        #expect(try update(listed("cowsay", "5.0", required: "<6.1")) == "6.0")
        #expect(try update(listed("cowsay", "6.1")) == nil)

        let tools = [listed("cowsay", "5.0"), listed("held", "5.0", required: "==5.0"),
                     listed("fromgit", "1.0", required: "git+https://example.com/fromgit.git"),
                     listed("black", "24.2.0")]
        #expect(UvEngine.pypiNames(tools) == ["black", "cowsay"])
        let report = try UvEngine.pypiUpdates(tools, projects: ["cowsay": .success(cowsay),
                                                                "black": .failure(RegistryFetchError.status(503))])
        #expect(report.packages.map(\.id.name) == ["cowsay"])
        // R6: the tool whose lookup failed is named.
        #expect(report.unchecked.names == ["black"])
        #expect(throws: EngineError.self) {
            _ = try UvEngine.pypiUpdates(tools, projects: ["cowsay": .failure(RegistryFetchError.status(503)),
                                                           "black": .failure(RegistryFetchError.status(404))])
        }
        #expect(try UvEngine.pypiUpdates([], projects: [:]) == OutdatedReport(packages: []))
    }

    // MARK: search and info (exact names on PyPI)

    @Test func searchLooksUpTheExactName() async throws {
        let body = try String(contentsOf: fixtures.appendingPathComponent("pipx/pypi-cowsay.json"), encoding: .utf8)
        let registry = FakeRegistryFetch(bodies: [cowsayURL: body])
        let (engine, runner) = engine([:], registry: registry)
        let found = try await engine.search("  CowSay ")
        #expect(found.map(\.id) == [tool("cowsay")])
        #expect(found.first?.latestVersion == "6.1")
        #expect(found.first?.summary == "The famous cowsay for GNU/Linux is now available for python")
        #expect(registry.requested.map(\.absoluteString) == [cowsayURL])
        #expect(runner.calls.isEmpty)
        #expect(try await engine.search("no-such-package-for-brewxport").isEmpty)
    }

    /// PyPI has no search: anything that isn't a project name is no match, and nothing is asked.
    @Test func searchForTextThatIsntANameAsksNothing() async throws {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        for query in ["python formatter", "https://example.com/x.whl", "-e", "../ruff", "ruff==0.6.0", "a/b"] {
            #expect(try await engine.search(query).isEmpty, "\(query)")
        }
        await #expect(throws: EngineError.self) { _ = try await engine.search("   ") }
        #expect(registry.requested.isEmpty)
    }

    @Test func parsesInfo() async throws {
        let body = try String(contentsOf: fixtures.appendingPathComponent("pipx/pypi-cowsay.json"), encoding: .utf8)
        let registry = FakeRegistryFetch(bodies: [cowsayURL: body])
        let (engine, _) = engine([:], registry: registry)
        let details = try await engine.info(tool("cowsay"))
        #expect(details.ref == tool("cowsay"))
        #expect(details.summary == "The famous cowsay for GNU/Linux is now available for python")
        #expect(details.homepage == URL(string: "https://github.com/VaasuDevanS/cowsay-python"))
        #expect(details.latestVersion == "6.1")
        do {
            _ = try await engine.info(tool("no-such-package-for-brewxport"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .uv)
            #expect(error.message.contains("PyPI"))
        }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        for name in ["bad name!", "git+https://example.com/x", "https://example.com/x.whl", "-e", "../x", "x.whl"] {
            await #expect(throws: EngineError.self) { _ = try await engine.info(tool(name)) }
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .pipx, kind: .tool, name: "cowsay"))
        }
        #expect(registry.requested.isEmpty)
    }

    // MARK: commands

    /// The shapes the captures ran (SOURCES.md): options before the names, never as root.
    @Test func commandShapes() throws {
        let (engine, _) = engine([:])
        let install = try engine.command(for: .install, [tool("isort")], options: InstallOptions())
        #expect(install.executable == uv)
        #expect(install.arguments == ["tool", "install", "--color", "never", "--no-progress", "isort"])
        #expect(!install.needsRoot)
        let upgrade = try engine.command(for: .upgrade, [tool("isort"), tool("ruff")], options: InstallOptions())
        #expect(upgrade.arguments == ["tool", "upgrade", "--color", "never", "--no-progress", "isort", "ruff"])
        let remove = try engine.command(for: .remove, [tool("isort"), tool("ruff")], options: InstallOptions())
        #expect(remove.arguments == ["tool", "uninstall", "--color", "never", "--no-progress", "isort", "ruff"])
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, tool("isort")) == .never)
        }
    }

    /// `uv tool install` takes one package.
    @Test func uvInstallsOneToolAtATime() {
        let (engine, _) = engine([:])
        do {
            _ = try engine.command(for: .install, [tool("isort"), tool("ruff")], options: InstallOptions())
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message == "uv installs one tool at a time")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func commandsCarryUvsEnvironmentAndHome() throws {
        let (engine, _) = engine([:])
        let spec = try engine.command(for: .upgrade, [tool("isort")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["NO_COLOR"] == "1")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// Only plain PyPI names reach uv: never a URL, a path, an archive, a version spec or an option, and no command
    /// carries `--force`, `--with` or an index.
    @Test func uvRefusesNonRegistrySpecs() throws {
        let (engine, _) = engine([:])
        for name in ["git+https://example.com/x.git", "https://example.com/x.whl", "./ruff", "/tmp/ruff", "~/ruff",
                     "ruff-0.6.0-py3-none-any.whl", "ruff.tar.gz", "ruff==0.6.0", "ruff@latest", "-e", "--force",
                     "ruff[all]", "a b"] {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [tool(name)], options: InstallOptions())
                }
            }
        }
        for op in [PackageOperation.install, .upgrade, .remove] {
            let arguments = try engine.command(for: op, [tool("ruff")], options: InstallOptions()).arguments
            #expect(!arguments.contains { $0.hasPrefix("--force") || $0.hasPrefix("--with") || $0.contains("index") })
        }
    }

    @Test func commandRefusesWhatUvCantDoHere() throws {
        let (engine, _) = engine([:])
        let ruff = [tool("ruff")]
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ruff, options: InstallOptions(version: "0.6.0"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ruff, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ruff, options: InstallOptions(extraArgs: ["--index-url=x"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, ruff, options: InstallOptions()) }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markDependency, ruff, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .pipx, kind: .tool, name: "ruff")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .uv, kind: .formula, name: "ruff")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutUvThrows() {
        let (engine, _) = engine([:], executable: nil)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool("ruff")], options: InstallOptions())
        }
    }

    /// Not a capture: uv naming an index with a token when its check fails, made up to check the message never shows
    /// it (the captured failures name no index with a token).
    @Test func outdatedErrorsNeverShowURLCredentials() async {
        let stderr = "error: Request failed after 3 retries\n"
            + "  cause: Failed to fetch: https://__token__:s3cret@pypi.example.com/simple/isort/?token=s3cret"
        let (engine, _) = engine([outdatedArguments: CommandResult(exitCode: 2, stdout: "", stderr: stderr)])
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.contains("Failed to fetch: https://pypi.example.com/simple/isort/"))
            #expect(!error.message.contains("s3cret"))
            #expect(!error.message.contains("__token__"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: Repair (R28)

    /// The captured receipts (`t13-receipt-<name>.toml`): black with a range, extras, two `--with` packages and
    /// `python = "3.12"`; ruff pinned; sampleproject from git; pyfiglet from a wheel URL; tabulate on PyPy.
    private static func receipt(_ name: String) throws -> String { try capturedFile("t13-receipt-\(name).toml") }

    private static let receiptFolder = "/Users/tester/.local/share/uv/tools/"

    /// A detected uv (its tool folder as captured) whose receipts are `receipts` and whose venvs' `pyvenv.cfg` are
    /// `venvs`, by tool name; the tools in `missingLinks` have no `bin/python` left in their folder.
    private func receiptEngine(_ receipts: [String: String], venvs: [String: String] = [:],
                               missingLinks: Set<String> = []) async throws -> UvEngine {
        let runner = FakeRunner([versionArguments: try captured("version"), toolDirArguments: try captured("tool-dir")])
        @Sendable func tool(_ path: String, _ file: String) -> String? {
            guard path.hasPrefix(Self.receiptFolder), path.hasSuffix("/" + file) else { return nil }
            return String(path.dropFirst(Self.receiptFolder.count).dropLast(file.count + 1))
        }
        let engine = UvEngine(runner: runner, registry: FakeRegistryFetch(), executable: uv, base: base,
                              readToolFile: { path in
                                  if let name = tool(path, "uv-receipt.toml") {
                                      return receipts[name].map { Data($0.utf8) }
                                  }
                                  return tool(path, "pyvenv.cfg").flatMap { venvs[$0] }.map { Data($0.utf8) }
                              },
                              toolPathExists: { path in
                                  tool(path, "bin/python").map { !missingLinks.contains($0) } ?? false
                              })
        _ = await engine.detect()
        return engine
    }

    /// R41: Repair keeps each tool on its own Python. The receipt's request when uv recorded one (black's `3.12`,
    /// tabulate's `pypy`); else the venv's own minor version, from its `pyvenv.cfg`: ruff on the Command Line Tools'
    /// Python 3.9.6 (`t13-on-system-python-*`) repairs with `--python 3.9`, where the repair without it moved ruff to
    /// uv's own CPython 3.12 (`t13-repair-ruff-moves-to-managed-python`), and isort on Homebrew's 3.15.2 with
    /// `--python 3.15`. `--force` only when the venv's Python link itself is gone: tabulate's deleted link fails
    /// without it (`t13-repair-tabulate`, exit 2) and works with it (`t13-repair-tabulate-force`, these very
    /// arguments).
    @Test func uvRepairKeepsEachToolsPython() async throws {
        let reinstall: [String] = ["tool", "install", "--reinstall"] + quiet
        let engine = try await receiptEngine(
            ["black": try Self.receipt("black"), "isort": try Self.receipt("isort"),
             "ruff": try capturedFile("t13-on-system-python-receipt-ruff.toml"),
             "tabulate": try Self.receipt("tabulate")],
            venvs: ["black": try capturedFile("t13-pyvenv-cfg-black.cfg"),
                    "isort": try capturedFile("t13-pyvenv-cfg-isort.cfg"),
                    "ruff": try capturedFile("t13-on-system-python-pyvenv-cfg-ruff.cfg"),
                    "tabulate": try capturedFile("t13-pyvenv-cfg-tabulate.cfg")],
            missingLinks: ["tabulate"])
        // Built in typed parts: as one literal inside #expect it was too slow for the CI compiler to type-check.
        let blackArgs: [String] = reinstall
            + ["--python", "3.12", "--with", "click>=8", "--with", "colorama", "black[d]>=24,<24.3.0"]
        let isortArgs: [String] = reinstall + ["--python", "3.15", "isort>=5,<7"]
        let ruffArgs: [String] = reinstall + ["--python", "3.9", "ruff==0.6.0"]
        let forced: [String] = ["tool", "install", "--reinstall", "--force"] + quiet
        let tabulateArgs: [String] = forced + ["--python", "pypy", "tabulate"]
        let expectedRepairs: [[String]] = [blackArgs, isortArgs, ruffArgs, tabulateArgs]
        let repairs: [[String]] = try engine.repairCommands(for: ["tabulate", "ruff", "isort", "black"])
            .map(\.spec.arguments)
        #expect(repairs == expectedRepairs)
        #expect(try captured("t13-repair-ruff-moves-to-managed-python").stderr
            .contains("Ignoring existing environment for `ruff`: the Python interpreter does not match"))
        #expect(try captured("t13-repair-tabulate").exitCode == 2)
        #expect(try captured("t13-repair-tabulate-uv-suggestion").exitCode == 2)
        #expect(try captured("t13-repair-tabulate-force").exitCode == 0)

        // A link whose Python was removed (Homebrew autoremoved python@3.15) is still there: no `--force`, and the
        // repair worked without it (`t13-homebrew-python-removed-repair-ruff`).
        let homebrewRuff = try capturedFile("t13-on-homebrew-python-pyvenv-cfg-ruff.cfg")
        let removed = try await receiptEngine(["ruff": try Self.receipt("ruff")], venvs: ["ruff": homebrewRuff])
        #expect(try removed.repairCommands(for: ["ruff"]).map(\.spec.arguments)
                == [reinstall + ["--python", "3.15", "ruff==0.6.0"]])
        #expect(try captured("t13-homebrew-python-removed-repair-ruff").exitCode == 0)

        // `version_info` as uv writes it, or `version` as Python's `venv` module does; only `major.minor` is passed.
        #expect(VenvConfig.minorVersion(try capturedFile("t13-pyvenv-cfg-tabulate.cfg")) == "3.12")
        #expect(VenvConfig.minorVersion("home = /x\nversion = 3.13.1\n") == "3.13")
        for text in ["home = /x\n", "version_info = 3\n", "version_info = 3.x.1\n", "version_info = -3.12\n"] {
            #expect(VenvConfig.minorVersion(text) == nil, "\(text)")
        }
    }

    /// Repair installs each tool again with everything uv recorded for it: the Python asked for, every `--with`
    /// package with its requirement, the tool's extras and its own requirement, each written in BrewxPort's own form,
    /// one tool per command. black's is the captured repair that worked (`t13-repair-black`), and a pinned tool keeps
    /// its pin, as the captured `--reinstall ruff==0.6.0`.
    @Test func uvRepairKeepsExtrasAndWith() async throws {
        let engine = try await receiptEngine(["black": try Self.receipt("black"), "ruff": try Self.receipt("ruff")])
        let steps = try engine.repairCommands(for: ["ruff", "black"])
        #expect(steps.map(\.tool) == ["black", "ruff"])
        // Built in typed parts: as one literal inside #expect it was too slow for the CI compiler to type-check.
        let reinstall: [String] = ["tool", "install", "--reinstall"] + quiet
        let blackArgs: [String] = reinstall
            + ["--python", "3.12", "--with", "click>=8", "--with", "colorama", "black[d]>=24,<24.3.0"]
        let ruffArgs: [String] = reinstall + ["ruff==0.6.0"]
        let expectedSteps: [[String]] = [blackArgs, ruffArgs]
        let arguments: [[String]] = steps.map(\.spec.arguments)
        #expect(arguments == expectedSteps)
        #expect(engine.repairRefusals(for: ["ruff", "black"]).isEmpty)
        #expect(steps.allSatisfy { !$0.spec.needsRoot && $0.spec.environment?["NO_COLOR"] == "1" })
    }

    /// A tool uv installed from git, a URL or a folder (or with a `--with` package from one) gets no automatic Repair:
    /// installing it by name would swap in the index's package of that name. Nor does one whose receipt asks for
    /// what BrewxPort doesn't pass back, asks for a Python by its path, is missing or can't be read. Each says why in
    /// one line, and the others are still repaired. The git and URL receipts are captured (`t13-receipt-sampleproject`,
    /// `t13-receipt-pyfiglet`). Not captures: the folder, `--with` URL, marker, index, constraints, Python-by-path and
    /// garbled receipts, which T13 didn't make (it captured git, URL, PyPy, range, extras and `--with` installs); each
    /// is written in uv's receipt shape to check one refusal.
    @Test func uvRepairRefusedForNonRegistryRequirement() async throws {
        let receipts = [
            "sampleproject": try Self.receipt("sampleproject"),
            "pyfiglet": try Self.receipt("pyfiglet"),
            "local": "[tool]\nrequirements = [{ name = \"local\", directory = \"/Users/someone/local\", "
                + "editable = true }]\n",
            "withurl": "[tool]\nrequirements = [\n    { name = \"withurl\" },\n    { name = \"helper\", "
                + "url = \"https://example.com/helper.whl\" },\n]\n",
            "marked": "[tool]\nrequirements = [{ name = \"marked\", marker = \"python_full_version >= '3.12'\" }]\n",
            "indexed": "[tool]\nrequirements = [{ name = \"indexed\" }]\n\n[tool.options]\n"
                + "index-url = \"https://pypi.example.com/simple\"\n",
            "constrained": "[tool]\nrequirements = [{ name = \"constrained\" }]\n"
                + "constraints = [{ name = \"click\", specifier = \"<9\" }]\n",
            "pathpython": "[tool]\nrequirements = [{ name = \"pathpython\" }]\npython = \"/opt/homebrew/bin/python3.15\"\n",
            "garbled": "[tool]\nrequirements = [{ name = \"garbled\", specifier = 3 }]\n",
            "ruff": try Self.receipt("ruff"),
        ]
        let engine = try await receiptEngine(receipts)
        let names = Array(receipts.keys) + ["missing"]
        #expect(try engine.repairCommands(for: names).map(\.tool) == ["ruff"])
        let refusals = engine.repairRefusals(for: names)
        let fromSource = "was installed from a URL, a path or git, so BrewxPort doesn't repair it by name."
        #expect(refusals["sampleproject"] == "sampleproject " + fromSource)
        #expect(refusals["pyfiglet"] == "pyfiglet " + fromSource)
        #expect(refusals["local"] == "local " + fromSource)
        #expect(refusals["withurl"] == "withurl " + fromSource)
        let settings = "was installed with uv settings BrewxPort doesn't pass back (a marker, an index, constraints "
            + "or overrides), so it doesn't repair it."
        #expect(refusals["marked"] == "marked " + settings)
        #expect(refusals["indexed"] == "indexed " + settings)
        #expect(refusals["constrained"] == "constrained " + settings)
        #expect(refusals["pathpython"]
                == "pathpython was installed for a Python given by its path, so BrewxPort doesn't repair it.")
        #expect(refusals["garbled"] == "BrewxPort couldn't read uv's record of garbled, so it doesn't repair it.")
        #expect(refusals["missing"] == "uv has no record of missing, so BrewxPort doesn't repair it.")
        #expect(refusals["ruff"] == nil)
        // Nothing to repair and nothing refused is an error, not an empty run.
        #expect(throws: EngineError.self) { try engine.repairCommands(for: []) }
    }

    /// Only a `[tool.options]` value that sets something counts: an empty string, list or table, or `false`, is uv's
    /// default and doesn't stop a repair. Not captures: no captured receipt has `[tool.options]` (T13), so these are
    /// written in uv's shape.
    @Test func receiptDefaultOptionsArentSettings() async throws {
        let defaults = "[tool]\nrequirements = [{ name = \"ruff\", specifier = \"==0.6.0\" }]\n\n[tool.options]\n"
            + "index = []\nexclude-newer = \"\"\nno-build-isolation = false\nsources = {}\n"
        #expect(UvReceipt(defaults)?.hasOptions == false)
        let engine = try await receiptEngine(["ruff": defaults])
        #expect(try engine.repairCommands(for: ["ruff"]).map(\.spec.arguments)
                == [["tool", "install", "--reinstall"] + quiet + ["ruff==0.6.0"]])
        for setting in ["no-build-isolation = true", "exclude-newer = \"2026-01-01T00:00:00Z\"",
                        "index = [{ url = \"https://pypi.example.com/simple\" }]",
                        "sources = { x = { y = \"z\" } }"] {
            #expect(UvReceipt("[tool]\nrequirements = []\n[tool.options]\n" + setting + "\n")?.hasOptions == true,
                    "\(setting)")
        }
    }

    /// The receipt reader takes only the TOML uv writes for it: comments, quoted keys, literal strings and escapes
    /// read; numbers, repeated keys, unclosed arrays and multi-line strings don't, so such a receipt isn't half-read.
    /// Every captured receipt reads in full. Not captures: the other texts, made up on purpose.
    @Test func receiptReadsOnlyWhatItKnows() throws {
        for name in ["black", "black-after-repair", "isort", "pyfiglet", "ruff", "sampleproject", "tabulate"] {
            #expect(UvReceipt(try Self.receipt(name)) != nil, "\(name)")
        }
        #expect(UvReceipt(try capturedFile("t13-broken-python-receipt-black.toml")) != nil)
        #expect(UvReceipt(try Self.receipt("tabulate"))?.python == "pypy")
        #expect(UvReceipt(try Self.receipt("black"))?.requirements.first?.specifier == ">=24,<24.3.0")
        let fine = """
            # written by uv
            [tool]
            requirements = [
                { "name" = 'black', extras = ["d", "jupyter"] }, # the tool
            ]
            python = "cpython@3.12"
            entrypoints = []
            """
        let receipt = UvReceipt(fine)
        #expect(receipt?.requirements.map(\.name) == ["black"])
        #expect(receipt?.requirements.first?.extras == ["d", "jupyter"])
        #expect(receipt?.python == "cpython@3.12")
        #expect(receipt?.hasOptions == false)
        #expect(UvReceipt("[tool]\nrequirements = [{ name = \"a\\u0062c\" }]\n")?.requirements.first?.name == "abc")
        for broken in ["[tool]\nrequirements = [{ name = \"a\" }]\nrequirements = []\n",
                       "[tool]\nrequirements = [\n{ name = \"a\" },\n",
                       "[tool]\npython = 3.12\n",
                       "[tool]\npython = \"\"\"3.12\"\"\"\n",
                       "[tool]\nrequirements = [{ name = \"a\" }] trailing\n",
                       "requirements = []\n"] {
            #expect(UvReceipt(broken) == nil, "\(broken)")
        }
    }

    // MARK: what uv's tools run on

    /// uv names each tool's Python (`--show-python`, 0.9.2 and later) by version only, so a tool on CPython 3.15 counts
    /// as running on Homebrew's python@3.15: the careful reading, since uv can use Homebrew's Python.
    @Test func uvToolsRunOnTheirPython() async throws {
        let (current, runner) = engine([versionArguments: try captured("version"),
                                        pythonListArguments: try captured("tool-list-all-flags")])
        _ = await current.detect()
        #expect(try await current.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["isort", "ruff"])])
        #expect(runner.calls.last == pythonListArguments)
        // R29: ruff's pyvenv.cfg (in `uv tool dir`, `t13-pyvenv-cfg-ruff.cfg`) names Homebrew's `opt/python@3.15`
        // link, so it follows a patch update; isort's can't be read.
        let ruffConfig = Data(try capturedFile("t13-pyvenv-cfg-ruff.cfg").utf8)
        let (withHomes, _) = (UvEngine(runner: FakeRunner([versionArguments: try captured("version"),
                                                           toolDirArguments: try captured("tool-dir"),
                                                           pythonListArguments: try captured("tool-list-all-flags")]),
                                       registry: FakeRegistryFetch(), executable: uv, base: base,
                                       readToolFile: { path in
                                           path == "/Users/tester/.local/share/uv/tools/ruff/pyvenv.cfg"
                                               ? ruffConfig : nil
                                       }), 0)
        _ = await withHomes.detect()
        #expect(try await withHomes.runtimeUses() == [RuntimeUse(formula: "python@3.15", tools: ["isort", "ruff"],
                                                                 patchSafeTools: ["ruff"])])
        // An older uv can't name them, so it can't say.
        let (older, _) = engine([versionArguments: try olderVersion("0.9.1")])
        _ = await older.detect()
        await #expect(throws: EngineError.self) { _ = try await older.runtimeUses() }
    }
}
