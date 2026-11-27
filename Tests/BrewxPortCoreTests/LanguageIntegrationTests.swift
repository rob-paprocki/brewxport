import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// One captured command from `Fixtures/<engine>` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`, stderr
/// from `NAME-stderr.txt`, the exit code from `NAME.exit`.
private func captured(_ engine: String, _ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent(engine).appendingPathComponent(file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let quiet = ["--color", "never", "--no-progress"]

/// A folder of the test's own, removed (and made writable again first) when `body` returns.
private func withFolder(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-access-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let item as String in items {
                _ = chmod(root.appendingPathComponent(item).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
    try body(root)
}

@Suite struct LanguageIntegrationTests {
    // MARK: Access

    /// The access check is a real one: a folder this account can't write is refused, and a folder that isn't there
    /// yet counts as the nearest one above it that is.
    @Test func accessCheckUsesTheNearestFolderThatExists() throws {
        try withFolder { root in
            let mine = root.appendingPathComponent("mine")
            let locked = root.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            #expect(chmod(locked.path, 0o555) == 0)
            #expect(InstallAccess.isWritable(mine.path))
            #expect(InstallAccess.isWritable(mine.appendingPathComponent("not-yet/bin").path))
            #expect(!InstallAccess.isWritable(locked.path))
            #expect(!InstallAccess.isWritable(locked.appendingPathComponent("not-yet/bin").path))
        }
    }

    /// A location that's a link to something that isn't there can't be written through: it doesn't count as its
    /// writable parent folder, and the reason says it's the link.
    @Test func danglingLinkIsntWritable() throws {
        try withFolder { root in
            let link = root.appendingPathComponent(".cargo")
            try FileManager.default.createSymbolicLink(atPath: link.path,
                                                       withDestinationPath: root.appendingPathComponent("gone").path)
            #expect(!InstallAccess.isWritable(link.path))
            #expect(!InstallAccess.isWritable(link.appendingPathComponent("bin").path))
            #expect(InstallAccess.isWritable(root.appendingPathComponent("elsewhere/bin").path))
            let state = InstallAccessState(isWritable: InstallAccess.isWritable)
            state.checked(.cargo, folders: [link.appendingPathComponent("bin")], home: root.path)
            #expect(state.readOnlyReason == "Cargo installs tools into ~/.cargo/bin, but ~/.cargo is a link to a "
                    + "folder that isn't there, so BrewxPort leaves its tools as they are.")
        }
    }

    /// Any engine whose folder isn't writable refuses to change its tools, saying where, and changes nothing else.
    @Test func unwritableFolderRefusesChanges() async throws {
        let runner = FakeRunner([["--version"]: try captured("cargo", "version")])
        let cargo = CargoEngine(runner: runner, registry: FakeRegistryFetch(),
                                executable: URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/cargo"), base: base,
                                readRecord: { _ in nil }, isWritable: { !$0.hasPrefix("/Users/someone/.cargo") })
        #expect(cargo.readOnlyReason == nil)
        #expect(await cargo.detect() == .present(path: URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/cargo"),
                                                 version: "1.100.0"))
        let reason = "Cargo installs tools into ~/.cargo, which your account can't change, so BrewxPort leaves its "
            + "tools as they are."
        #expect(cargo.readOnlyReason == reason)
        #expect(!cargo.installRootWritable)
        let ripgrep = PackageRef(engine: .cargo, kind: .tool, name: "ripgrep")
        for op in [PackageOperation.install, .remove] {
            #expect(throws: EngineError(engine: .cargo, message: reason)) {
                try cargo.command(for: op, [ripgrep], options: InstallOptions())
            }
        }
    }

    // MARK: Runtimes

    /// R29: a venv's `pyvenv.cfg` `home` says whether it follows a patch update of its Homebrew Python: Homebrew's
    /// `opt/python@3.x` link (or inside it) and Homebrew's `bin` do; one Cellar copy, another Python or another
    /// formula's link don't. The files as captured (pipx's and uv's venvs, `t13-pyvenv-cfg-*.cfg`); the other homes are
    /// values.
    @Test func venvHomeSaysWhetherItFollowsPatchUpdates() throws {
        func file(_ path: String) throws -> String {
            try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
        }
        #expect(VenvConfig.home(try file("pipx/t13-pyvenv-cfg-black.cfg")) == "/opt/homebrew/opt/python@3.15/bin")
        #expect(VenvConfig.home(try file("uv/t13-pyvenv-cfg-tabulate.cfg"))
                == "/Users/tester/.local/share/uv/python/pypy-3.12.15-macos-aarch64-none/bin")
        #expect(VenvConfig.home(try file("uv/t13-on-system-python-pyvenv-cfg-ruff.cfg"))
                == "/Library/Developer/CommandLineTools/usr/bin")
        #expect(VenvConfig.home("version = 3.15.2\n") == nil)
        for home in ["/opt/homebrew/opt/python@3.15/bin", "/opt/homebrew/opt/python@3.15/bin/",
                     "/usr/local/opt/python@3.15/Frameworks/Python.framework/Versions/3.15/bin", "/opt/homebrew/bin"] {
            #expect(VenvConfig.followsPatchUpdates(home: home, formula: "python@3.15"), "\(home)")
        }
        // Homebrew's folders, and anywhere else (then the venv runs on no Homebrew Python at all).
        for home in ["/opt/homebrew/Cellar/python@3.15/3.15.2/bin", "/usr/local/opt/python@3.15/bin", "/usr/local/bin",
                     "/opt/homebrew/bin/", "/opt/homebrew/Frameworks/Python.framework/Versions/3.15/bin",
                     "/usr/local/Frameworks/Python.framework/Versions/3.15/bin"] {
            #expect(VenvConfig.isHomebrew(home: home), "\(home)")
        }
        // Homebrew's Frameworks link resolves through the formula's versioned folder: pinned, not following.
        #expect(!VenvConfig.followsPatchUpdates(home: "/opt/homebrew/Frameworks/Python.framework/Versions/3.15/bin",
                                                formula: "python@3.15"))
        #expect(!VenvConfig.isHomebrew(home: "/usr/local/lib/python3.15"))
        for name in ["black", "black.d", "cowsay3.9"] { #expect(VenvConfig.isPlainFolderName(name), "\(name)") }
        for name in ["", "../black", "a/b", ".hidden", "a..b"] { #expect(!VenvConfig.isPlainFolderName(name), "\(name)") }
        for home in ["/Users/someone/.local/share/uv/python/cpython-3.15.2-macos-aarch64-none/bin",
                     "/Users/someone/.pyenv/versions/3.15.2/bin", "/Library/Frameworks/Python.framework/Versions/3.15/bin",
                     "/usr/bin", "/opt/nanobrew/prefix/bin"] {
            #expect(!VenvConfig.isHomebrew(home: home), "\(home)")
        }
        for home in ["/opt/homebrew/Cellar/python@3.15/3.15.2/bin", "/opt/homebrew/opt/python@3.14/bin",
                     "/Users/someone/.local/share/uv/python/cpython-3.15.2-macos-aarch64-none/bin", "/usr/bin"] {
            #expect(!VenvConfig.followsPatchUpdates(home: home, formula: "python@3.15"), "\(home)")
        }
    }

    @Test func homebrewFormulaFromAPath() {
        let none: (String) -> String? = { _ in nil }
        #expect(HomebrewFormula.owning("/opt/homebrew/opt/python@3.15/bin/python3.15", realPath: none) == "python@3.15")
        #expect(HomebrewFormula.owning("/opt/homebrew/opt/ruby/bin/ruby", realPath: none) == "ruby")
        #expect(HomebrewFormula.owning("/usr/local/Cellar/node/25.2.1/bin/node", realPath: none) == "node")
        // Homebrew's bin folder holds links into the Cellar: the link decides.
        #expect(HomebrewFormula.owning("/opt/homebrew/bin/node",
                                       realPath: { _ in "/opt/homebrew/Cellar/node@22/22.20.0/bin/node" })
                == "node@22")
        // nodejs.org's installer, nvm and Apple's Ruby aren't Homebrew's.
        #expect(HomebrewFormula.owning("/usr/local/bin/node", realPath: { $0 }) == nil)
        #expect(HomebrewFormula.owning("/Users/someone/.nvm/versions/node/v24.1.0/bin/node", realPath: none) == nil)
        #expect(HomebrewFormula.owning("/usr/bin/ruby", realPath: none) == nil)
        #expect(HomebrewFormula.python(version: "3.15.2") == "python@3.15")
        #expect(HomebrewFormula.python(version: "3") == nil)
    }

    // MARK: Repair

    /// Repair tools, per engine: npm rebuilds its registry globals by name in one command (R39, the captured
    /// `npm rebuild -g cowsay semver`), pipx reinstalls every venv, uv reinstalls each tool it
    /// installed from an index, by its own requirement (one per command, as the captured `--reinstall ruff==0.6.0`),
    /// and RubyGems installs each tool again from its sources. Each runs as the user with the engine's environment.
    @Test func repairCommandsPerEngine() async throws {
        let npmRunner = FakeRunner([["ls", "-g", "--json", "--depth=0"]: try captured("npm", "t13-npm11-ls-g-restored")])
        let npm = NpmEngine(runner: npmRunner, executable: URL(fileURLWithPath: "/opt/homebrew/bin/npm"), base: base)
        _ = try await npm.listInstalled()
        let npmSteps = try npm.repairCommands(for: ["cowsay", "semver"])
        #expect(npmSteps.map(\.tool) == [nil])
        #expect(npmSteps.map(\.spec.arguments) == [["rebuild", "-g", "cowsay", "semver"]])
        #expect(npmSteps.allSatisfy { !$0.spec.needsRoot && $0.spec.environment?["npm_config_fund"] == "false" })

        let pipx = PipxEngine(runner: FakeRunner([:]), registry: FakeRegistryFetch(),
                              executable: URL(fileURLWithPath: "/opt/homebrew/bin/pipx"), base: base)
        #expect(try pipx.repairCommands(for: ["black"]).map(\.spec.arguments) == [["reinstall-all"]])

        // uv rebuilds each tool's install from its receipt (R28; `UvEngineTests.uvRepairKeepsExtrasAndWith`): ruff's,
        // pinned, as captured (`t13-receipt-ruff.toml`), on its own Python from its `pyvenv.cfg` (R41,
        // `t13-pyvenv-cfg-ruff.cfg`: Homebrew's 3.15.2), its `bin/python` link in place.
        let uvRunner = FakeRunner([["--version"]: try captured("uv", "version"),
                                   ["tool", "dir"] + quiet: try captured("uv", "tool-dir")])
        let ruff = "/Users/tester/.local/share/uv/tools/ruff/"
        let uvFixtures = fixtures.appendingPathComponent("uv")
        func file(_ name: String) throws -> Data { try Data(contentsOf: uvFixtures.appendingPathComponent(name)) }
        let ruffFiles = [ruff + "uv-receipt.toml": try file("t13-receipt-ruff.toml"),
                         ruff + "pyvenv.cfg": try file("t13-pyvenv-cfg-ruff.cfg")]
        let uv = UvEngine(runner: uvRunner, registry: FakeRegistryFetch(),
                          executable: URL(fileURLWithPath: "/opt/homebrew/bin/uv"), base: base,
                          readToolFile: { ruffFiles[$0] }, toolPathExists: { $0 == ruff + "bin/python" })
        _ = await uv.detect()
        // black has no receipt, so uv isn't asked to install whatever PyPI calls black.
        let uvSteps = try uv.repairCommands(for: ["ruff", "black"])
        #expect(uvSteps.map(\.tool) == ["ruff"])
        #expect(uvSteps.map(\.spec.arguments)
                == [["tool", "install", "--reinstall"] + quiet + ["--python", "3.15", "ruff==0.6.0"]])
        #expect(uv.repairRefusals(for: ["ruff", "black"]).keys.sorted() == ["black"])
        #expect(uv.maxTargetsPerCommand(for: .repair) == 1)

        let gem = GemEngine(runner: FakeRunner([:]), registry: FakeRegistryFetch(),
                            executable: URL(fileURLWithPath: "/opt/homebrew/bin/gem"), base: base)
        let gemSteps = try gem.repairCommands(for: ["thor", "lolcat"])
        #expect(gemSteps.map(\.tool) == ["lolcat", "thor"])
        #expect(gemSteps.map(\.spec.arguments) == [["install", "--remote", "--no-document", "lolcat"],
                                                   ["install", "--remote", "--no-document", "thor"]])
        // Nothing to repair one at a time is a refusal, not an empty run.
        #expect(throws: EngineError.self) { try gem.repairCommands(for: []) }
    }

    /// A tool's own package.json says which commands it has: one named after the package, or a map of names. Names
    /// that aren't plain file names are dropped.
    @Test func nodePackageExecutablesFromItsManifest() throws {
        try withFolder { root in
            // npm's own copy of cowsay's package.json fields (`ls -g --long --json`): its `bin` map.
            let long = try captured("npm", "ls-g-long")
            let object = try #require(try JSONSerialization.jsonObject(with: Data(long.stdout.utf8)) as? [String: Any])
            let dependencies = try #require(object["dependencies"] as? [String: Any])
            let cowsay = try #require(dependencies["cowsay"] as? [String: Any])
            let folder = root.appendingPathComponent("cowsay")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = try JSONSerialization.data(withJSONObject: ["name": "cowsay", "bin": cowsay["bin"] as Any])
            try manifest.write(to: folder.appendingPathComponent("package.json"))
            #expect(NodePackageExecutables.read(packageFolder: folder, name: "cowsay") == ["cowsay", "cowthink"])
            #expect(NodePackageExecutables.read(packageFolder: root.appendingPathComponent("absent"), name: "x")
                    == nil)
        }
    }

    /// The design: an engine page says when its list is for a version manager's current default version (nvm, fnm,
    /// asdf or mise for Node; rbenv, asdf or mise for Ruby), since each version keeps its own tools. Fake paths.
    @Test func versionManagerNoteFromTheExecutablesPath() {
        func node(_ manager: String) -> String {
            "The list is for \(manager)'s current default Node. Other Node versions keep their own tools."
        }
        func ruby(_ manager: String) -> String {
            "The list is for \(manager)'s current default Ruby. Other Ruby versions keep their own gems."
        }
        let cases: [(EngineID, String, String?)] = [
            (.npm, "/Users/someone/.nvm/versions/node/v22.11.0/bin/npm", node("nvm")),
            (.npm, "/Users/someone/.config/nvm/versions/node/v22.11.0/bin/npm", node("nvm")),
            (.npm, "/Users/someone/.local/share/fnm/node-versions/v22.11.0/installation/bin/npm", node("fnm")),
            (.npm, "/Users/someone/.local/state/fnm_multishells/123_456/bin/npm", node("fnm")),
            (.npm, "/Users/someone/.asdf/shims/npm", node("asdf")),
            (.npm, "/Users/someone/.local/share/mise/installs/node/22.11.0/bin/npm", node("mise")),
            (.npm, "/Users/someone/.local/share/mise/shims/npm", node("mise")),
            (.gem, "/Users/someone/.rbenv/shims/gem", ruby("rbenv")),
            (.gem, "/Users/someone/.rbenv/versions/3.4.1/bin/gem", ruby("rbenv")),
            (.gem, "/Users/someone/.asdf/shims/gem", ruby("asdf")),
            (.gem, "/Users/someone/.local/share/mise/installs/ruby/3.4.1/bin/gem", ruby("mise")),
            (.npm, "/opt/homebrew/bin/npm", nil),
            (.npm, "/Users/someone/.volta/bin/npm", nil),
            (.gem, "/opt/homebrew/opt/ruby/bin/gem", nil),
            (.gem, "/usr/bin/gem", nil),
            // Tools that don't belong to one runtime version: no note.
            (.pipx, "/Users/someone/.asdf/shims/pipx", nil),
            (.cargo, "/Users/someone/.asdf/shims/cargo", nil),
        ]
        for (engine, path, expected) in cases {
            #expect(VersionManagers.note(for: engine, executable: path) == expected, "\(engine) \(path)")
        }
    }
}
