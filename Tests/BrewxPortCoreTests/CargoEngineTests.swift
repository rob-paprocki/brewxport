import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// One captured command from `Fixtures/cargo` (see its SOURCES.md): stdout from `NAME.txt`, stderr from
/// `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent("cargo/" + file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).txt") ?? "", stderr: read("\(name)-stderr.txt") ?? "")
}

/// A captured file from `Fixtures/cargo` as it is: cargo's record, an index file, an API answer.
private func fixture(_ file: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent("cargo/" + file))
}

private func text(_ file: String) throws -> String { String(decoding: try fixture(file), as: UTF8.self) }

/// The source the captures' records name for crates.io.
private let cratesIOSource = "registry+https://github.com/rust-lang/crates.io-index"

/// Not a capture: the captured record (`crates2.json`) with ripgrep's source changed to `source`, a git URL with a
/// token, made up to check it's never kept (the captured git installs, `t13-git-*-crates2.json`, have none).
private func record(source: String) throws -> Data {
    Data(try text("crates2.json").replacingOccurrences(of: cratesIOSource, with: source).utf8)
}

/// Not a capture: the captured record (`crates2.json`) with some of ripgrep's recorded fields changed, in cargo's own
/// field names and shape (`"features":[]` to `"features":["pcre2"]`, …). Each text to change must be there. T13
/// recorded `--features` and `--no-default-features` only for a path install (`t13-path-features-crates2.json`,
/// `-no-default-`), which BrewxPort never upgrades, and no profile or target change at all, so an upgrade with
/// recorded options needs a crates.io install edited this way (`optionsFromTheCapturedRecords` reads the real ones).
private func record(changing changes: KeyValuePairs<String, String>) throws -> Data {
    var text = try text("crates2.json")
    for (old, new) in changes {
        try #require(text.contains(old), "\(old)")
        text = text.replacingOccurrences(of: old, with: new)
    }
    return Data(text.utf8)
}

/// Not a capture: `base` (the captured record unless given) with more installs, each a copy of the captured ripgrep
/// entry (a plain install) under another key (`name version (source)`) with its own executables, in cargo's shape.
/// Used where T13 has no record: a crate installed twice (cargo keeps two installs apart only when their executables
/// differ), and a second crates.io crate beside one with edited options.
private func record(adding installs: KeyValuePairs<String, [String]>, to base: Data? = nil) throws -> Data {
    let captured = try #require(try JSONSerialization.jsonObject(with: fixture("crates2.json")) as? [String: Any])
    let ripgrep = try #require((captured["installs"] as? [String: Any])?.values.first as? [String: Any])
    var object = try #require(try JSONSerialization.jsonObject(with: base ?? fixture("crates2.json")) as? [String: Any])
    var entries = try #require(object["installs"] as? [String: Any])
    for (key, bins) in installs {
        var entry = ripgrep
        entry["bins"] = bins
        entries[key] = entry
    }
    object["installs"] = entries
    return try JSONSerialization.data(withJSONObject: object)
}

/// Cargo's record files, which a test can change between calls (a crate removed from Terminal).
private final class RecordFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]

    init(_ files: [String: Data]) { self.files = files }

    func set(_ path: String, _ data: Data?) { lock.withLock { files[path] = data } }
    func read(_ path: String) -> Data? { lock.withLock { files[path] } }
}

/// bat 0.24.0 from crates.io, added to the captured record beside ripgrep.
private let batKey = "bat 0.24.0 (registry+https://github.com/rust-lang/crates.io-index)"

/// A git source with a token in its URL, which BrewxPort must never keep or show.
private let gitSource = "git+https://someone:s3cret@git.example.com/ripgrep?branch=master#"
    + "0123456789abcdef0123456789abcdef01234567"

private let cargo = URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/cargo")
private let rustc = URL(fileURLWithPath: "/opt/homebrew/opt/rustup/bin/rustc")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let recordPath = "/Users/someone/.cargo/.crates2.json"
private let legacyRecordPath = "/Users/someone/.cargo/.crates.toml"
private let versionArguments = ["--version"]
private let listArguments = ["install", "--list"]
private let searchArguments = ["search", "--limit", "20", "--color", "never"]
private let ripgrepIndex = "https://index.crates.io/ri/pg/ripgrep"
private let ripgrepAPI = "https://crates.io/api/v1/crates/ripgrep"

private func crate(_ name: String) -> PackageRef { PackageRef(engine: .cargo, kind: .tool, name: name) }

/// A Cargo engine at Homebrew rustup's cargo. `files` are cargo's record files by path (a path without one has no
/// file); `rustc` is the answer of the `rustc --version` beside cargo.
private func engine(_ responses: [[String]: CommandResult] = [:], rustc rustcAnswer: CommandResult? = nil,
                    files: [String: Data] = [:], registry: FakeRegistryFetch = FakeRegistryFetch(),
                    executable: URL? = cargo, captured: [String: String] = [:]) -> (CargoEngine, FakeRunner) {
    let runner = FakeRunner(responses, byExecutable: rustcAnswer.map { ["rustc": [versionArguments: $0]] } ?? [:])
    let engine = CargoEngine(runner: runner, registry: registry, executable: executable, captured: captured,
                             base: base, readRecord: { files[$0] }, apiPacing: noPacing)
    return (engine, runner)
}

/// The captured index file for ripgrep (60 versions, 14.0.0 to 14.1.1 need Rust 1.72, 15.x 1.85, 16.0.0 1.96).
private func ripgrepVersions() throws -> [CargoEngine.IndexVersion] {
    try #require(CargoEngine.indexVersions(try fixture("index-ripgrep.txt")))
}

/// An installed crate. Values, not a capture.
private func installed(_ name: String, _ version: String, _ source: CargoEngine.Source = .cratesIO,
                       bins: [String] = [], copies: Int = 1) -> CargoEngine.Crate {
    CargoEngine.Crate(name: name, version: version, source: source, bins: bins, copies: copies)
}

private func version(_ vers: String, yanked: Bool = false, rust: String? = nil) -> CargoEngine.IndexVersion {
    CargoEngine.IndexVersion(vers: vers, yanked: yanked, rustVersion: rust)
}

/// Not a capture: one line of crates.io's index for `name` at `vers`, with the fields BrewxPort reads in the index's
/// own shape (`index-ripgrep.txt` has the rest). Only ripgrep's index file was captured.
private func indexLine(_ name: String, _ vers: String) -> String {
    #"{"name":"\#(name)","vers":"\#(vers)","deps":[],"cksum":"","features":{},"yanked":false}"# + "\n"
}

/// Not a capture: crates.io's index with one version per crate (`indexLine`), so an outdated check offers it.
private func offering(_ versions: KeyValuePairs<String, String>) throws -> FakeRegistryFetch {
    var bodies: [String: String] = [:]
    for (name, vers) in versions {
        bodies[try #require(CargoEngine.indexURL(name)).absoluteString] = indexLine(name, vers)
    }
    return FakeRegistryFetch(bodies: bodies)
}

/// crates.io's index answering `body` for every crate, at once until `hold()`, then only once `release()`d.
private final class HeldIndex: RegistryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ body: String) { self.body = Data(body.utf8) }

    var waiting: Int { lock.withLock { waiters.count } }
    func hold() { lock.withLock { held = true } }

    func release() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            held = false
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }

    func get(_ url: URL) async throws -> Data {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if !held { return true }
                waiters.append(waiter)
                return false
            }
            if now { waiter.resume() }
        }
        return body
    }
}

/// What a test saw, in order: crates.io API requests and the engine's waits between them.
private final class APILog: @unchecked Sendable {
    private let lock = NSLock()
    private var logged: [String] = []
    var entries: [String] { lock.withLock { logged } }
    func add(_ entry: String) { lock.withLock { logged.append(entry) } }
}

/// `inner`'s answers, logging each crates.io API request (`/api/v1/…`) as it's asked for.
private struct LoggingRegistry: RegistryFetching {
    let inner: FakeRegistryFetch
    let log: APILog

    init(_ inner: FakeRegistryFetch, log: APILog) {
        self.inner = inner
        self.log = log
    }

    func get(_ url: URL) async throws -> Data {
        if url.host == "crates.io" { log.add(url.absoluteString) }
        return try await inner.get(url)
    }
}

/// No waits between crates.io API lookups, and all the time a test needs: tests that don't check the pacing never pause.
private let noPacing = CargoEngine.APIPacing(spacing: .zero, budget: .seconds(3600))

/// A clock for the pacing that only moves when told: `sleep` moves it at once, and a lookup can move it (`advance`).
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed: Duration = .zero
    private var slept: [Duration] = []

    var now: ContinuousClock.Instant { lock.withLock { start.advanced(by: elapsed) } }
    var sleeps: [Duration] { lock.withLock { slept } }
    var time: Duration { lock.withLock { elapsed } }

    func advance(_ by: Duration) { lock.withLock { elapsed += by } }
    func sleep(_ by: Duration) {
        lock.withLock {
            slept.append(by)
            elapsed += by
        }
    }

    func pacing(spacing: Duration = .seconds(1), budget: Duration = .seconds(20)) -> CargoEngine.APIPacing {
        CargoEngine.APIPacing(spacing: spacing, budget: budget, now: { self.now }, sleep: { self.sleep($0) })
    }
}

/// `inner`'s answers, each crates.io API answer taking `apiTime` on `clock` (a slow crates.io).
private struct SlowAPI: RegistryFetching {
    let inner: FakeRegistryFetch
    let clock: VirtualClock
    let apiTime: Duration

    func get(_ url: URL) async throws -> Data {
        if url.host == "crates.io" { clock.advance(apiTime) }
        return try await inner.get(url)
    }
}

/// A crates.io API that never answers until it's cancelled; the index answers from `inner`. `asked` hears of each
/// API request as it starts.
private struct HungAPI: RegistryFetching {
    let inner: FakeRegistryFetch
    var asked: AsyncStream<Void>.Continuation?

    func get(_ url: URL) async throws -> Data {
        if url.host == "crates.io" {
            asked?.yield()
            try await Task.sleep(for: .seconds(600))
        }
        return try await inner.get(url)
    }
}

/// `inner`'s answers, each index answer taking `indexTime` and each crates.io API answer `apiTime` on `clock` (a slow
/// index and a slow API), logging the API requests.
private struct SlowRegistry: RegistryFetching {
    let inner: FakeRegistryFetch
    let clock: VirtualClock
    let indexTime: Duration
    let apiTime: Duration
    let log: APILog

    func get(_ url: URL) async throws -> Data {
        if url.host == "crates.io" {
            log.add(url.absoluteString)
            clock.advance(apiTime)
        } else {
            clock.advance(indexTime)
        }
        return try await inner.get(url)
    }
}

/// R36: what an upgrade is refused with when the last outdated check didn't offer the crate a version.
private func noOffer(_ name: String) -> String {
    "BrewxPort hasn't found a newer version of \(name) on crates.io, so it doesn't update it."
}

private func expectEngineError(_ message: String, _ work: () async throws -> Void) async {
    do {
        try await work()
        Issue.record("expected an error")
    } catch let error as EngineError {
        #expect(error.engine == .cargo)
        #expect(error.message.contains(message), "\(error.message)")
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Suite struct CargoEngineTests {
    // MARK: detect

    @Test func detectsCargosVersionAndInstallRoot() async throws {
        let (engine, runner) = engine([versionArguments: try captured("version")])
        #expect(engine.installLocation == nil)
        #expect(await engine.detect() == .present(path: cargo, version: "1.100.0"))
        #expect(engine.installLocation == URL(fileURLWithPath: "/Users/someone/.cargo", isDirectory: true))
        #expect(engine.binLocation == URL(fileURLWithPath: "/Users/someone/.cargo/bin", isDirectory: true))
        #expect(runner.calls == [versionArguments])
        #expect(runner.executableCalls == [cargo])
    }

    @Test func detectMissingWithoutExecutable() async {
        let (engine, runner) = engine(executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
    }

    /// rustup's cargo without a toolchain: with RUSTUP_AUTO_INSTALL=0 it says so instead of downloading one.
    @Test func detectUnusableWithoutAToolchain() async throws {
        let (engine, _) = engine([versionArguments: try captured("version-no-toolchain")])
        let status = await engine.detect()
        #expect(isUnusable(status, at: cargo))
        if case .unusable(_, let reason) = status { #expect(reason.contains("is not installed")) }
        #expect(engine.installLocation == nil)
    }

    /// `cargo --version` and `rustc --version` name the tool, then its version. The other lines aren't captures.
    @Test func readsCargoAndRustcVersions() throws {
        #expect(CargoEngine.version(try captured("version").stdout, of: "cargo") == "1.100.0")
        #expect(CargoEngine.version(try captured("version-after-setup").stdout, of: "cargo") == "1.100.0")
        #expect(CargoEngine.version(try captured("rustc-version").stdout, of: "rustc") == "1.100.0")
        #expect(CargoEngine.version("cargo 1.96.0-nightly (3acc79c0c 2026-08-01)\n", of: "cargo") == "1.96.0-nightly")
        for text in ["", "1.100.0", "rustc 1.100.0", "cargo", "cargo unknown"] {
            #expect(CargoEngine.version(text, of: "cargo") == nil, "\(text)")
        }
        // A nightly or beta counts as its release for a crate's Rust requirement.
        #expect(CargoEngine.release("1.96.0-nightly") == "1.96.0")
        #expect(CargoEngine.release("1.100.0") == "1.100.0")
    }

    /// The install root is CARGO_INSTALL_ROOT, then CARGO_HOME (from the login shell), then `~/.cargo`.
    @Test func installRootFollowsCargosVariables() async throws {
        let answers = [versionArguments: try captured("version")]
        let (plain, _) = engine(answers)
        _ = await plain.detect()
        #expect(plain.installLocation?.path == "/Users/someone/.cargo")
        let (home, _) = engine(answers, captured: ["CARGO_HOME": "/Users/someone/rust/cargo"])
        _ = await home.detect()
        #expect(home.installLocation?.path == "/Users/someone/rust/cargo")
        #expect(home.binLocation?.path == "/Users/someone/rust/cargo/bin")
        let (root, _) = engine(answers, captured: ["CARGO_HOME": "/Users/someone/rust/cargo",
                                                    "CARGO_INSTALL_ROOT": "/Users/someone/tools"])
        _ = await root.detect()
        #expect(root.installLocation?.path == "/Users/someone/tools")
    }

    /// Every cargo command runs with cargo's folder first on PATH, only Cargo's login-shell variables,
    /// RUSTUP_AUTO_INSTALL=0 (so a rustup proxy never downloads a toolchain) and NO_COLOR, from the home folder.
    @Test func commandsRunWithCargosEnvironmentFromHome() async throws {
        let variables = ["CARGO_HOME": "/Users/someone/rust/cargo", "RUSTUP_HOME": "/Users/someone/rust/rustup",
                         "PIPX_HOME": "/Users/someone/.pipx"]
        let (engine, runner) = engine([versionArguments: try captured("version")], captured: variables)
        _ = await engine.detect()
        let options = try #require(runner.optionsCalls.first)
        let env = try #require(options.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:") == true)
        #expect(env["CARGO_HOME"] == "/Users/someone/rust/cargo")
        #expect(env["RUSTUP_HOME"] == "/Users/someone/rust/rustup")
        #expect(env["PIPX_HOME"] == nil)
        #expect(env["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(env["NO_COLOR"] == "1")
        #expect(options.workingDirectory == "/Users/someone")
    }

    // MARK: finding cargo

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-cargo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("cargo-home/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("cargo")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([versionArguments: try captured("version")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["CARGO_HOME": root.path + "/cargo-home"])
        let engine = CargoEngine(runner: runner, registry: FakeRegistryFetch(), loginShell: { context }, arch: .arm64,
                                 base: base, readRecord: { _ in nil })
        // Nothing is looked for until a detect asks the login shell.
        #expect(engine.executableURL == nil)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/cargo"), version: "1.100.0"))
        #expect(runner.executableCalls.allSatisfy { $0.path == realBin + "/cargo" })
        let env = try #require(runner.optionsCalls.first?.environment)
        #expect(env["PATH"]?.hasPrefix(realBin + ":") == true)
        #expect(env["CARGO_HOME"] == root.path + "/cargo-home")
        #expect(engine.installLocation?.path == root.path + "/cargo-home")
        let spec = try engine.command(for: .install, [crate("ripgrep")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/cargo")
    }

    @Test func liveEngineWithoutCargoIsMissing() async {
        let runner = FakeRunner([:])
        let engine = CargoEngine(runner: runner, registry: FakeRegistryFetch(),
                                 loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"], environment: [:]) },
                                 arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] },
                                 readRecord: { _ in nil })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [crate("ripgrep")], options: InstallOptions())
        }
        await expectEngineError("isn't installed") { _ = try await engine.listInstalled() }
    }

    /// Homebrew's `rust` (this Mac's prefix first), Homebrew's keg-only `rustup`, MacPorts, nanobrew, then rustup's
    /// own folder (CARGO_HOME's bin, `~/.cargo/bin`) and the version managers' shims.
    @Test func fixedFoldersPutTheMachinesHomebrewFirst() {
        let home = "/Users/someone"
        let rest = ["/opt/local/bin", "/opt/nanobrew/prefix/bin"]
        let user = [home + "/.cargo/bin", home + "/.asdf/shims", home + "/.local/share/mise/shims",
                    home + "/.nix-profile/bin"]
        #expect(CargoEngine.fixedFolders(arch: .arm64, home: home, captured: [:])
                == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/rustup/bin", "/usr/local/opt/rustup/bin"]
                + rest + user)
        #expect(CargoEngine.fixedFolders(arch: .x86_64, home: home, captured: ["CARGO_HOME": "/Users/someone/rust"])
                == ["/usr/local/bin", "/opt/homebrew/bin", "/usr/local/opt/rustup/bin", "/opt/homebrew/opt/rustup/bin"]
                + rest + ["/Users/someone/rust/bin"] + user)
    }

    // MARK: installed

    /// Read from cargo's record, without running cargo.
    @Test func parsesInstalledFromCargosRecord() async throws {
        let (engine, runner) = engine(files: [recordPath: try fixture("crates2.json")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id) == [crate("ripgrep")])
        #expect(found.map(\.displayName) == ["ripgrep"])
        #expect(found.map(\.installedVersion) == ["14.1.0"])
        #expect(found.allSatisfy { $0.installedOnRequest == true })
        #expect(runner.calls.isEmpty)
    }

    /// The record after `cargo install ripgrep` replaced 14.1.0, and after `cargo uninstall ripgrep`.
    @Test func recordFollowsUpgradeAndUninstall() throws {
        #expect(try CargoEngine.crates(record: try fixture("crates2-after-upgrade.json"))
                == [installed("ripgrep", "16.0.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(record: try fixture("crates2.json"))
                == [installed("ripgrep", "14.1.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(record: try fixture("crates2-after-uninstall.json")).isEmpty)
    }

    /// The record names each crate's commands (ripgrep's `rg`), which Installed's "which copy runs" looks for.
    @Test func cargoNamesACratesCommands() async throws {
        let (engine, _) = engine(files: [recordPath: try fixture("crates2.json")])
        #expect(engine.executables(of: "ripgrep") == nil)
        _ = try await engine.listInstalled()
        #expect(engine.executables(of: "ripgrep") == ["rg"])
        #expect(engine.executables(of: "bat") == nil)
    }

    /// The install root's record, where CARGO_INSTALL_ROOT or CARGO_HOME put it.
    @Test func installedReadsTheRecordInTheInstallRoot() async throws {
        let (engine, _) = engine(files: ["/Users/someone/tools/.crates2.json": try fixture("crates2.json")],
                                 captured: ["CARGO_INSTALL_ROOT": "/Users/someone/tools"])
        #expect(try await engine.listInstalled().map(\.id.name) == ["ripgrep"])
    }

    /// No record at all (cargo never installed anything) means nothing is installed: cargo isn't asked, because
    /// `install --list` would wait for a running build and create the files.
    @Test func noRecordMeansNothingInstalledWithoutAskingCargo() async throws {
        let (engine, runner) = engine()
        #expect(try await engine.listInstalled().isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// `install --list` with no `~/.cargo` created both files empty (SOURCES.md): an empty record is no crates.
    @Test func emptyRecordMeansNothingInstalled() async throws {
        let (engine, runner) = engine(files: [recordPath: Data(), legacyRecordPath: Data()])
        #expect(try await engine.listInstalled().isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// Only the older record (`.crates.toml`, from a cargo before 1.41): cargo lists its crates.
    @Test func olderRecordAsksCargo() async throws {
        let (engine, runner) = engine([listArguments: try captured("install-list")],
                                      files: [legacyRecordPath: try fixture("crates.toml")])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["ripgrep"])
        #expect(found.map(\.installedVersion) == ["14.1.0"])
        #expect(runner.calls == [listArguments])
    }

    /// A record that won't decode (here the `.crates.toml` capture where JSON belongs), or won't open: cargo lists.
    @Test func unreadableRecordAsksCargo() async throws {
        let (engine, runner) = engine([listArguments: try captured("install-list-after-upgrade")],
                                      files: [recordPath: try fixture("crates.toml")])
        #expect(try await engine.listInstalled().map(\.installedVersion) == ["16.0.0"])
        #expect(runner.calls == [listArguments])

        struct Refused: Error {}
        let refusing = FakeRunner([listArguments: try captured("install-list")])
        let locked = CargoEngine(runner: refusing, registry: FakeRegistryFetch(), executable: cargo, base: base,
                                 readRecord: { _ in throw Refused() })
        #expect(try await locked.listInstalled().map(\.id.name) == ["ripgrep"])
        #expect(refusing.calls == [listArguments])
    }

    /// cargo failing to list (here without a toolchain) is a failure in cargo's words.
    @Test func installListFailsInCargosWords() async throws {
        let (engine, _) = engine([listArguments: try captured("version-no-toolchain")],
                                 files: [legacyRecordPath: try fixture("crates.toml")])
        await expectEngineError("cargo install --list failed (exit 1): error: toolchain") {
            _ = try await engine.listInstalled()
        }
    }

    /// `cargo install --list`: `name vVERSION:`, then its executables indented; a crate not from crates.io has its
    /// source in brackets: a folder (`t13-path-install-list`), a local git repository with a short commit
    /// (`t13-git-file-install-list`) or GitHub's URL (`t13-git-ripgrep-install-list`). Not captures: the two lines it
    /// refuses, made up.
    @Test func parsesInstallList() throws {
        #expect(try CargoEngine.crates(list: try captured("t13-path-install-list").stdout)
                == [installed("capture-crate", "0.1.0", .notRegistry, bins: ["cap-one", "cap-two"]),
                    installed("ripgrep", "14.1.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(list: try captured("t13-git-file-install-list").stdout)
                == [installed("capture-crate", "0.1.0", .notRegistry, bins: ["cap-one", "cap-two"]),
                    installed("ripgrep", "14.1.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(list: try captured("t13-git-ripgrep-install-list").stdout)
                == [installed("ripgrep", "14.1.1", .notRegistry, bins: ["rg"])])
        #expect(try CargoEngine.crates(list: try captured("install-list").stdout)
                == [installed("ripgrep", "14.1.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(list: try captured("install-list-after-upgrade").stdout)
                == [installed("ripgrep", "16.0.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(list: try captured("install-list-final").stdout)
                == [installed("ripgrep", "14.1.0", bins: ["rg"])])
        #expect(try CargoEngine.crates(list: "").isEmpty)
        #expect(throws: EngineError.self) { _ = try CargoEngine.crates(list: "Installed crates\n") }
        #expect(throws: EngineError.self) { _ = try CargoEngine.crates(list: "    rg\n") }
    }

    /// A record key is `name version (source)`; only the kind of source is kept. Captured: crates.io's git-index key,
    /// a path install's, a local git one's and GitHub's (`t13-path-crates2.json`, `t13-git-file-crates2.json`,
    /// `t13-git-ripgrep-crates2.json`). Not captures: crates.io's `sparse+` key and another registry's keys (no
    /// alternate registry was captured, T13), and a git key with a token, made up to check it's dropped.
    @Test func recordKeysKeepOnlyTheKindOfSource() throws {
        for (file, name, source) in [("t13-path-crates2.json", "capture-crate", CargoEngine.Source.notRegistry),
                                     ("t13-git-file-crates2.json", "capture-crate", .notRegistry),
                                     ("t13-git-ripgrep-crates2.json", "ripgrep", .notRegistry),
                                     ("t13-start-crates2.json", "ripgrep", .cratesIO)] {
            let crates = try CargoEngine.crates(record: try fixture(file))
            #expect(crates.first { $0.name == name }?.source == source, "\(file)")
        }
        let cases: [(String, CargoEngine.Source)] = [
            ("ripgrep 14.1.0 (\(cratesIOSource))", .cratesIO),
            ("ripgrep 14.1.0 (sparse+https://index.crates.io/)", .cratesIO),
            ("ripgrep 14.1.0 (\(gitSource))", .notRegistry),
            ("ripgrep 14.1.0 (registry+https://git.example.com/index)", .otherRegistry),
            ("ripgrep 14.1.0 (sparse+https://cargo.example.com/index/)", .otherRegistry),
        ]
        for (key, source) in cases {
            #expect(CargoEngine.crate(key: key, bins: ["rg"]) == installed("ripgrep", "14.1.0", source, bins: ["rg"]),
                    "\(key)")
        }
        for key in ["ripgrep", "ripgrep 14.1.0", "ripgrep 14.1.0 registry", " 14.1.0 (x)"] {
            #expect(CargoEngine.crate(key: key, bins: []) == nil, "\(key)")
        }
    }

    /// A git install's URL can carry a token: nothing BrewxPort keeps, prints or shows holds it. The captured GitHub
    /// install (`t13-git-ripgrep-crates2.json`) keeps nothing of its URL either.
    @Test func recordNeverKeepsAnInstallSource() async throws {
        let github = try CargoEngine.crates(record: try fixture("t13-git-ripgrep-crates2.json"))
        #expect(github == [installed("ripgrep", "14.1.1", .notRegistry, bins: ["rg"])])
        #expect(!String(reflecting: github).contains("BurntSushi") && !String(reflecting: github).contains("4649aa"))
        let (engine, _) = engine(files: [recordPath: try record(source: gitSource)])
        let found = try await engine.listInstalled()
        #expect(found.map(\.id.name) == ["ripgrep"])
        let crates = try CargoEngine.crates(record: try record(source: gitSource))
        var dumped = ""
        dump(crates, to: &dumped)
        for text in [dumped, String(describing: crates), String(describing: found)] {
            #expect(!text.contains("s3cret") && !text.contains("example.com"), "\(text)")
        }
    }

    /// A record that names a crate twice (two versions with different executables) is one row: the highest version,
    /// every executable, and never an update. Values, not a capture.
    @Test func aCrateInstalledTwiceIsOneRow() throws {
        let merged = CargoEngine.merged([installed("foo", "1.0.0", bins: ["foo"]), installed("bar", "2.0.0"),
                                         installed("foo", "1.2.0", bins: ["foo-cli"])])
        #expect(merged == [installed("bar", "2.0.0"), installed("foo", "1.2.0", bins: ["foo", "foo-cli"], copies: 2)])
        #expect(merged.map(\.isChecked) == [true, false])
        let mixed = CargoEngine.merged([installed("foo", "1.0.0"), installed("foo", "0.9.0", .notRegistry)])
        #expect(mixed.map(\.source) == [.notRegistry])
    }

    // MARK: outdated

    /// ripgrep 14.1.0 from crates.io, with crates.io's index answer and rustc 1.100.0 beside cargo.
    @Test func parsesOutdatedFromTheIndex() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (engine, runner) = engine(rustc: try captured("rustc-version"),
                                      files: [recordPath: try fixture("crates2.json")], registry: registry)
        let found = try await engine.listOutdated()
        #expect(found == [Package(id: crate("ripgrep"), displayName: "ripgrep", installedVersion: "14.1.0",
                                  latestVersion: "16.0.0")])
        // Then the offered crate's executables at the installed version (R42; not captured, so a 404 here).
        #expect(registry.requested.map(\.absoluteString)
                == [ripgrepIndex, "https://crates.io/api/v1/crates/ripgrep/14.1.0"])
        #expect(runner.calls == [versionArguments])
        #expect(runner.executableCalls == [rustc])
        #expect(engine.needsNewerRust.isEmpty)
        let env = try #require(runner.optionsCalls.first?.environment)
        #expect(env["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(runner.optionsCalls.first?.workingDirectory == "/Users/someone")
    }

    /// Nothing newer than 16.0.0 after the upgrade.
    @Test func upToDateCrateIsntOffered() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (engine, _) = engine(rustc: try captured("rustc-version"),
                                 files: [recordPath: try fixture("crates2-after-upgrade.json")], registry: registry)
        #expect(try await engine.listOutdated().isEmpty)
    }

    /// ripgrep 16.0.0 needs Rust 1.96. Beside an older rustc (1.90.0, `t13-msrv-rustc-version`) it isn't offered: cargo
    /// refuses to build it (`t13-msrv-install-ripgrep-16`, exit 101). The engine records what it needs, and the check
    /// holds it back, shown with "Needs Rust 1.96", from every update.
    @Test func cargoNeedsNewerRustShownAndNotAutomatic() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (engine, _) = engine(rustc: try captured("t13-msrv-rustc-version"),
                                 files: [recordPath: try fixture("crates2.json")],
                                 registry: registry)
        #expect(try await engine.listOutdated().isEmpty)
        #expect(engine.needsNewerRust == ["ripgrep": "1.96"])
        let report = try await engine.checkOutdated()
        #expect(report.packages.isEmpty)
        #expect(report.unchecked.isEmpty)
        #expect(report.held == [HeldUpdate(
            package: Package(id: crate("ripgrep"), displayName: "ripgrep", installedVersion: "14.1.0",
                             latestVersion: "16.0.0"),
            hold: UpdateHold(reason: "Needs Rust 1.96", blocksAutomatic: true, blocksManual: true))])

        let crates = [installed("ripgrep", "14.1.0")]
        let index: [String: Result<[CargoEngine.IndexVersion], any Error>] = [
            "ripgrep": .success(try ripgrepVersions())]
        #expect(try CargoEngine.updates(crates, index: index, rust: "1.96.0").updates.map(\.latestVersion)
                == ["16.0.0"])
        #expect(try CargoEngine.updates(crates, index: index, rust: "1.84.1").needsNewerRust == ["ripgrep": "1.96"])
        // A Rust that isn't known holds nothing back.
        #expect(try CargoEngine.updates(crates, index: index, rust: nil).updates.map(\.latestVersion) == ["16.0.0"])
    }

    /// The rustc beside cargo not answering (here rustup's no-toolchain refusal, which a rustc proxy shares with
    /// cargo) holds nothing back.
    @Test func rustcThatDoesntAnswerHoldsNothingBack() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (engine, _) = engine(rustc: try captured("version-no-toolchain"),
                                 files: [recordPath: try fixture("crates2.json")], registry: registry)
        #expect(try await engine.listOutdated().map(\.latestVersion) == ["16.0.0"])
    }

    /// Yanked versions never count; pre-releases only for a pre-release install. Values, not a capture.
    @Test func yankedAndPreReleaseVersionsAreSkipped() throws {
        let versions = try ripgrepVersions() + [version("17.0.0", yanked: true), version("18.0.0-rc.1")]
        let index: [String: Result<[CargoEngine.IndexVersion], any Error>] = ["ripgrep": .success(versions)]
        let stable = try CargoEngine.updates([installed("ripgrep", "14.1.0")], index: index, rust: "1.100.0")
        #expect(stable.updates.map(\.latestVersion) == ["16.0.0"])
        let preview = try CargoEngine.updates([installed("ripgrep", "18.0.0-beta.2")], index: index, rust: "1.100.0")
        #expect(preview.updates.map(\.latestVersion) == ["18.0.0-rc.1"])
        // The index's newest is older than what's installed: not a downgrade.
        #expect(try CargoEngine.updates([installed("ripgrep", "99.0.0")], index: index, rust: nil).updates.isEmpty)
    }

    /// R36: an upgrade passes the version the outdated check offered, from crates.io's index (`--version =<it>`), so
    /// cargo installs what Updates showed. Plain `cargo install` takes the newest stable version instead, which for a
    /// pre-release install can be older: 18.0.0-beta.2, offered 18.0.0-rc.1, would get 16.0.0. Without an offer (no
    /// check yet, or one that found nothing newer) an upgrade is refused, never run plain.
    @Test func upgradePassesTheOfferedVersion() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let files = RecordFiles([recordPath: try fixture("crates2.json")])
        let stable = CargoEngine(runner: FakeRunner([:], byExecutable: ["rustc": [versionArguments:
                                                                                     try captured("rustc-version")]]),
                                 registry: registry, executable: cargo, base: base, readRecord: { files.read($0) })
        Self.expectRefused(stable, ["ripgrep"], noOffer("ripgrep"))
        #expect(try await stable.listOutdated().map(\.latestVersion) == ["16.0.0"])
        #expect(try Self.upgrade(stable) == ["install", "--version", "=16.0.0", "ripgrep"])
        // Up to date after the upgrade (the record as captured after it): the next check offers nothing, so the
        // offer is gone and nothing is upgraded.
        files.set(recordPath, try fixture("crates2-after-upgrade.json"))
        #expect(try await stable.listOutdated().isEmpty)
        Self.expectRefused(stable, ["ripgrep"], noOffer("ripgrep"))

        // A pre-release install, with a newer pre-release on the index (values added to the captured index).
        let beta = try record(changing: ["ripgrep 14.1.0 (": "ripgrep 18.0.0-beta.2 ("])
        let withRC = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")
                                                + indexLine("ripgrep", "18.0.0-rc.1")])
        let (preview, _) = engine(rustc: try captured("rustc-version"), files: [recordPath: beta], registry: withRC)
        #expect(try await preview.listOutdated().map(\.latestVersion) == ["18.0.0-rc.1"])
        #expect(try Self.upgrade(preview) == ["install", "--version", "=18.0.0-rc.1", "ripgrep"])
    }

    /// Updates keeps showing the last check's rows while the next check runs (a Refresh, a run's reload), and a row's
    /// Update can be clicked then: the offers change only when a check ends, so that upgrade still passes the version
    /// the row showed.
    @Test func offersChangeOnlyWhenACheckEnds() async throws {
        let index = HeldIndex(try text("index-ripgrep.txt"))
        let record = try fixture("crates2.json")
        let engine = CargoEngine(runner: FakeRunner([:], byExecutable: ["rustc": [versionArguments:
                                                                                     try captured("rustc-version")]]),
                                 registry: index, executable: cargo, base: base,
                                 readRecord: { $0 == recordPath ? record : nil })
        #expect(try await engine.listOutdated().map(\.latestVersion) == ["16.0.0"])
        index.hold()
        let next = Task { try await engine.listOutdated() }
        for _ in 0..<500 where index.waiting == 0 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(index.waiting == 1)
        #expect(try Self.upgrade(engine) == ["install", "--version", "=16.0.0", "ripgrep"])
        index.release()
        #expect(try await next.value.map(\.latestVersion) == ["16.0.0"])
    }

    /// Git and path installs, crates from another registry and a crate installed twice are listed but never checked:
    /// nothing is asked for them (ripgrep from GitHub, `t13-git-ripgrep-crates2.json`; a path install beside crates.io's
    /// ripgrep, `t13-path-crates2.json`).
    @Test func onlyCratesFromCratesIOAreChecked() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (fromGit, runner) = engine(rustc: try captured("rustc-version"),
                                       files: [recordPath: try fixture("t13-git-ripgrep-crates2.json")],
                                       registry: registry)
        #expect(try await fromGit.listInstalled().map(\.id.name) == ["ripgrep"])
        #expect(try await fromGit.listOutdated().isEmpty)
        #expect(registry.requested.isEmpty)
        #expect(runner.calls.isEmpty)
        let (path, _) = engine(rustc: try captured("rustc-version"),
                               files: [recordPath: try fixture("t13-path-crates2.json")], registry: registry)
        #expect(try await path.listInstalled().map(\.id.name) == ["capture-crate", "ripgrep"])
        #expect(try await path.listOutdated().map(\.id.name) == ["ripgrep"])
        #expect(registry.requested.map(\.absoluteString)
                == [ripgrepIndex, "https://crates.io/api/v1/crates/ripgrep/14.1.0"])
        let crates = [installed("a", "1.0.0", .notRegistry), installed("b", "1.0.0", .otherRegistry),
                      installed("c", "1.0.0", copies: 2), installed("d", "1.0.0")]
        #expect(CargoEngine.indexNames(crates) == ["d"])
    }

    /// One lookup that fails leaves only that crate out; when every one fails, the check fails in crates.io's words.
    /// Values, not a capture.
    @Test func failedLookupsLeaveOnlyThoseCratesOut() throws {
        let failed = EngineError(engine: .cargo, message: "crates.io has no crate named gone")
        let crates = [installed("gone", "1.0.0"), installed("ripgrep", "14.1.0")]
        let partial: [String: Result<[CargoEngine.IndexVersion], any Error>] = [
            "gone": .failure(failed), "ripgrep": .success(try ripgrepVersions())]
        let check = try CargoEngine.updates(crates, index: partial, rust: nil)
        #expect(check.updates.map(\.id.name) == ["ripgrep"])
        // R6: the crate that couldn't be looked up is named, with why.
        #expect(check.unchecked == UncheckedPackages(reasons: ["gone": "crates.io has no crate named gone"]))
        let none: [String: Result<[CargoEngine.IndexVersion], any Error>] = [
            "gone": .failure(failed), "ripgrep": .failure(RegistryFetchError.status(503))]
        #expect(throws: EngineError(engine: .cargo, message: "BrewxPort couldn't check crates.io for newer versions: "
                                    + "crates.io has no crate named gone")) {
            _ = try CargoEngine.updates(crates, index: none, rust: nil)
        }
    }

    /// The index answering 404 (its captured body is the storage service's XML), or refusing: the check fails.
    @Test func outdatedFailsWhenTheIndexDoesntAnswer() async throws {
        let (missing, _) = engine(rustc: try captured("rustc-version"),
                                  files: [recordPath: try fixture("crates2.json")])
        await expectEngineError("crates.io has no crate named ripgrep") { _ = try await missing.listOutdated() }
        let registry = FakeRegistryFetch([ripgrepIndex: .failure(RegistryFetchError.status(503))])
        let (refused, _) = engine(rustc: try captured("rustc-version"),
                                  files: [recordPath: try fixture("crates2.json")], registry: registry)
        await expectEngineError("HTTP status 503") { _ = try await refused.listOutdated() }
        let offline = FakeRegistryFetch([ripgrepIndex: .failure(URLError(.notConnectedToInternet))])
        let (away, _) = engine(rustc: try captured("rustc-version"),
                               files: [recordPath: try fixture("crates2.json")], registry: offline)
        await expectEngineError("Couldn't reach crates.io") { _ = try await away.listOutdated() }
        // The 404's XML body isn't an index file.
        #expect(CargoEngine.indexVersions(try fixture("index-unknown.txt")) == nil)
    }

    /// Nothing installed: nothing is asked, not even rustc.
    @Test func outdatedWithNothingInstalledAsksNothing() async throws {
        let registry = FakeRegistryFetch()
        let (engine, runner) = engine(files: [recordPath: try fixture("crates2-after-uninstall.json")],
                                      registry: registry)
        #expect(try await engine.listOutdated().isEmpty)
        #expect(registry.requested.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// cargo's index layout: `1/a`, `2/ab`, `3/a/abc`, then the first two and next two characters, lowercased. The
    /// two captured URLs, then the short-name rules.
    @Test func indexURLsFollowCargosLayout() {
        #expect(CargoEngine.indexURL("ripgrep")?.absoluteString == ripgrepIndex)
        #expect(CargoEngine.indexURL("no-such-crate-for-brewxport")?.absoluteString
                == "https://index.crates.io/no/-s/no-such-crate-for-brewxport")
        #expect(CargoEngine.indexURL("a")?.absoluteString == "https://index.crates.io/1/a")
        #expect(CargoEngine.indexURL("ab")?.absoluteString == "https://index.crates.io/2/ab")
        #expect(CargoEngine.indexURL("abc")?.absoluteString == "https://index.crates.io/3/a/abc")
        #expect(CargoEngine.indexURL("Serde_JSON")?.absoluteString == "https://index.crates.io/se/rd/serde_json")
        for name in ["", "-x", "../x", "a/b", "a b", "1abc"] { #expect(CargoEngine.indexURL(name) == nil, "\(name)") }
    }

    /// The captured index file: 60 versions, none yanked, with their Rust requirements.
    @Test func readsTheIndexFile() throws {
        let versions = try ripgrepVersions()
        #expect(versions.count == 60)
        #expect(versions.first?.vers == "0.1.0")
        #expect(versions.last == version("16.0.0", rust: "1.96"))
        #expect(versions.first { $0.vers == "14.1.0" }?.rustVersion == "1.72")
        #expect(versions.allSatisfy { $0.yanked == false })
    }

    // MARK: search

    @Test func parsesSearch() async throws {
        let (engine, runner) = engine([searchArguments + ["ripgrep"]: try captured("search-ripgrep")])
        let found = try await engine.search("ripgrep")
        #expect(found.count == 20)
        #expect(found.first?.id == crate("ripgrep"))
        #expect(found.first?.latestVersion == "16.0.0")
        #expect(found.first?.summary?.hasPrefix("ripgrep is a line-oriented search tool") == true)
        #expect(found.map(\.id.name).prefix(3) == ["ripgrep", "gist-search", "maxgrep"])
        #expect(found.last?.id.name == "elgrep")
        #expect(found.first { $0.id.name == "ripgrep_all" }?.latestVersion == "0.10.10")
        #expect(found.allSatisfy { $0.id.engine == .cargo && $0.id.kind == .tool })
        #expect(runner.calls == [searchArguments + ["ripgrep"]])
    }

    /// R43: a Discover row shows the version `cargo search` printed, and its install installs exactly that version
    /// (`--version =<it>`, as R36 does for an upgrade): ripgrep's row says 16.0.0 (`search-ripgrep`), so its install is
    /// `cargo install --version =16.0.0 ripgrep`, the shape `t13-install-ripgrep-16-exact` ran. A crate no search
    /// showed installs plain. Not a capture: a search line whose version isn't semver (cargo's output never had one),
    /// which shows no version and installs plain.
    @Test func discoverInstallsTheShownVersion() async throws {
        let (searched, _) = engine([searchArguments + ["ripgrep"]: try captured("search-ripgrep")])
        func install(_ engine: CargoEngine, _ name: String) throws -> [String] {
            try engine.command(for: .install, [crate(name)], options: InstallOptions()).arguments
        }
        #expect(try install(searched, "ripgrep") == ["install", "ripgrep"])
        let found = try await searched.search("ripgrep")
        #expect(found.first?.latestVersion == "16.0.0")
        #expect(try install(searched, "ripgrep") == ["install", "--version", "=16.0.0", "ripgrep"])
        #expect(try install(searched, "ripgrep_all") == ["install", "--version", "=0.10.10", "ripgrep_all"])
        #expect(try captured("t13-install-ripgrep-16-exact").exitCode == 0)
        #expect(try install(searched, "tokei") == ["install", "tokei"])

        // R42's guard holds here too: `--version =X` would install the shown version over a newer or equal one
        // (`t13-install-tokei-prerelease-down`), so the record is read first: ripgrep 16.0.0 installed
        // (`t13-ripgrep-16-crates2.json`) refuses 16.0.0; 14.1.0 (`t13-start-crates2.json`) installs it.
        for (file, refused) in [("t13-ripgrep-16-crates2.json", true), ("t13-start-crates2.json", false)] {
            let (installed, _) = engine([searchArguments + ["ripgrep"]: try captured("search-ripgrep")],
                                        files: [recordPath: try fixture(file)])
            _ = try await installed.search("ripgrep")
            if refused {
                #expect(throws: EngineError(engine: .cargo, message: "ripgrep is already at 16.0.0, so BrewxPort "
                                            + "doesn't install 16.0.0 over it.")) { _ = try install(installed, "ripgrep") }
            } else {
                #expect(try install(installed, "ripgrep") == ["install", "--version", "=16.0.0", "ripgrep"])
            }
        }

        let odd = "oddcrate = \"latest\"        # a version cargo never prints\n"
        let (unversioned, _) = engine([searchArguments + ["oddcrate"]: CommandResult(exitCode: 0, stdout: odd, stderr: "")])
        let rows = try await unversioned.search("oddcrate")
        #expect(rows.map(\.id.name) == ["oddcrate"])
        #expect(rows.first?.latestVersion == nil)
        #expect(try install(unversioned, "oddcrate") == ["install", "oddcrate"])
    }

    @Test func searchWithoutMatchesIsEmpty() async throws {
        let (engine, _) = engine([searchArguments + ["zzqxbrewxportnomatch"]: try captured("search-nomatch")])
        #expect(try await engine.search("zzqxbrewxportnomatch").isEmpty)
    }

    @Test func searchFailsInCargosWords() async throws {
        let (engine, _) = engine([searchArguments + ["ripgrep"]: try captured("search-network-refused")])
        await expectEngineError("cargo search failed (exit 101): error: failed to retrieve search results") {
            _ = try await engine.search("ripgrep")
        }
    }

    /// A query cargo would read as an option (`--index …`, `--registry …`) finds nothing, without asking cargo; an
    /// empty one is refused.
    @Test func searchNeverPassesAnOption() async throws {
        let (engine, runner) = engine()
        for query in ["-x", "--index=https://git.example.com/index", "--registry", " -v"] {
            #expect(try await engine.search(query).isEmpty, "\(query)")
        }
        #expect(runner.calls.isEmpty)
        await expectEngineError("Search query is empty") { _ = try await engine.search("  ") }
    }

    /// Not a capture: cargo naming a registry with a token when its search fails. The message never shows it.
    @Test func searchErrorsNeverShowURLCredentials() async {
        let stderr = "error: failed to retrieve search results from the registry at "
            + "https://someone:s3cret@cargo.example.com/api?token=s3cret\n"
        let (engine, _) = engine([searchArguments + ["ripgrep"]: CommandResult(exitCode: 101, stdout: "",
                                                                               stderr: stderr)])
        await expectEngineError("registry at https://cargo.example.com/api") { _ = try await engine.search("ripgrep") }
        do {
            _ = try await engine.search("ripgrep")
        } catch let error as EngineError {
            #expect(!error.message.contains("s3cret"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: info

    /// crates.io's API answer: the description on one line, the repository as the home page (it has no homepage),
    /// the newest stable version and its executables.
    @Test func parsesInfoFromCratesIO() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepAPI: try text("api-crate-ripgrep.json")])
        let (engine, runner) = engine(registry: registry)
        let details = try await engine.info(crate("ripgrep"))
        #expect(details.ref == crate("ripgrep"))
        #expect(details.summary == "ripgrep is a line-oriented search tool that recursively searches the current "
                + "directory for a regex pattern while respecting gitignore rules. ripgrep has first class support on "
                + "Windows, macOS and Linux.")
        #expect(details.homepage == URL(string: "https://github.com/BurntSushi/ripgrep"))
        #expect(details.latestVersion == "16.0.0")
        #expect(details.executables == ["rg"])
        #expect(details.reportedName == "ripgrep")
        #expect(registry.requested.map(\.absoluteString) == [ripgrepAPI])
        #expect(runner.calls.isEmpty)
    }

    /// Final review: a crate's own home page and repository are links only when they're web pages; otherwise its page
    /// on crates.io. Not a capture: the captured answer with both fields changed.
    @Test func infoLinksOnlyWebPages() async throws {
        let answer = try text("api-crate-ripgrep.json")
        try #require(answer.contains(#""homepage":null"#)
                     && answer.contains(#""repository":"https://github.com/BurntSushi/ripgrep""#))
        let edited = answer.replacingOccurrences(of: #""homepage":null"#,
                                                 with: #""homepage":"smb://attacker.example/share""#)
            .replacingOccurrences(of: #""repository":"https://github.com/BurntSushi/ripgrep""#,
                                  with: #""repository":"ssh://attacker.example/ripgrep""#)
        let (engine, _) = engine(registry: FakeRegistryFetch(bodies: [ripgrepAPI: edited]))
        #expect(try await engine.info(crate("ripgrep")).homepage == URL(string: "https://crates.io/crates/ripgrep"))
    }

    /// An installed crate shows the executables its install put in place.
    @Test func infoShowsTheInstalledExecutables() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepAPI: try text("api-crate-ripgrep.json")])
        let (engine, _) = engine(files: [recordPath: try fixture("crates2.json")], registry: registry)
        _ = try await engine.listInstalled()
        let details = try await engine.info(crate("ripgrep"))
        #expect(details.executables == ["rg"])
        #expect(details.latestVersion == "16.0.0")
    }

    /// A git or path install isn't the crate crates.io has under its name: its details are its own, without asking
    /// (ripgrep from GitHub, `t13-git-ripgrep-crates2.json`).
    @Test func infoForACrateNotFromCratesIOAsksNothing() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepAPI: try text("api-crate-ripgrep.json")])
        let (engine, _) = engine(files: [recordPath: try fixture("t13-git-ripgrep-crates2.json")], registry: registry)
        _ = try await engine.listInstalled()
        let details = try await engine.info(crate("ripgrep"))
        #expect(details == PackageDetails(ref: crate("ripgrep"), installedVersion: "14.1.1", executables: ["rg"]))
        #expect(registry.requested.isEmpty)
    }

    @Test func infoForAnUnknownCrateFails() async {
        let (engine, _) = engine()
        await expectEngineError("crates.io has no crate named no-such-crate-for-brewxport") {
            _ = try await engine.info(crate("no-such-crate-for-brewxport"))
        }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine(registry: registry)
        for name in ["../ripgrep", "ripgrep@14.1.0", "-x", "a b"] {
            await #expect(throws: EngineError.self, "\(name)") { _ = try await engine.info(crate(name)) }
        }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .npm, kind: .tool, name: "ripgrep"))
        }
        #expect(registry.requested.isEmpty)
    }

    // MARK: commands

    /// The shapes the captures ran (SOURCES.md): `install` and `uninstall` with crate names, an upgrade being an
    /// install (cargo replaces the older one) of the version the check offered (R36), never as root, never `--locked`
    /// or `--force`. A Discover install has no version from crates.io's index, so it's plain: cargo's newest stable.
    /// tokei at 13.0.0-alpha.8 (`t13-tokei-prerelease-crates2.json`) offered alpha.9 upgrades exactly as the captured
    /// `cargo install tokei --version =13.0.0-alpha.9` (`t13-install-tokei-prerelease-next`); its index line isn't a
    /// capture (`offering`).
    @Test func commandShapes() async throws {
        let (engine, _) = engine(files: [recordPath: try fixture("t13-tokei-prerelease-crates2.json")],
                                 registry: try offering(["tokei": "13.0.0-alpha.9"]))
        _ = try await engine.checkOutdated()
        let install = try engine.command(for: .install, [crate("ripgrep")], options: InstallOptions())
        #expect(install.executable == cargo)
        #expect(install.arguments == ["install", "ripgrep"])
        #expect(!install.needsRoot)
        let upgrade = try engine.command(for: .upgrade, [crate("tokei")], options: InstallOptions())
        #expect(upgrade.arguments == ["install", "--version", "=13.0.0-alpha.9", "tokei"])
        let remove = try engine.command(for: .remove, [crate("ripgrep"), crate("tokei")], options: InstallOptions())
        #expect(remove.arguments == ["uninstall", "ripgrep", "tokei"])
        // One crate per build: the planner splits installs and upgrades (`maxTargetsPerCommand`).
        #expect(throws: EngineError(engine: .cargo, message: "Cargo installs one tool at a time")) {
            _ = try engine.command(for: .install, [crate("ripgrep"), crate("tokei")], options: InstallOptions())
        }
        #expect(throws: EngineError(engine: .cargo, message: "Cargo updates one tool at a time")) {
            _ = try engine.command(for: .upgrade, [crate("ripgrep"), crate("tokei")], options: InstallOptions())
        }
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, crate("ripgrep")) == .never)
        }
    }

    @Test func commandsCarryCargosEnvironmentAndHome() async throws {
        let (engine, _) = engine(files: ["/Users/someone/rust/cargo/.crates2.json": try fixture("crates2.json")],
                                 registry: try offering(["ripgrep": "16.0.0"]),
                                 captured: ["CARGO_HOME": "/Users/someone/rust/cargo"])
        _ = try await engine.checkOutdated()
        let spec = try engine.command(for: .upgrade, [crate("ripgrep")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/opt/rustup/bin:") == true)
        #expect(env["CARGO_HOME"] == "/Users/someone/rust/cargo")
        #expect(env["RUSTUP_AUTO_INSTALL"] == "0")
        #expect(env["NO_COLOR"] == "1")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// Only plain crates.io names reach cargo: never a URL, a path, a version spec or an option, and no command
    /// carries `--git`, `--path`, `--index` or `--registry`. The one version any command passes is an upgrade's
    /// `--version =<offered>`, from crates.io's index (R36), never from text.
    @Test func cargoRefusesNonRegistrySpecs() async throws {
        let (engine, _) = engine(files: [recordPath: try fixture("crates2.json")],
                                 registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await engine.checkOutdated()
        for name in ["git+https://git.example.com/x.git", "https://git.example.com/x", "./ripgrep", "/tmp/ripgrep",
                     "~/ripgrep", "ripgrep@14.1.0", "ripgrep==14.1.0", "-x", "--git", "--path", "--index",
                     "--registry", "a b", "1password", "rip.grep"] {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [crate(name)], options: InstallOptions())
                }
            }
        }
        for op in [PackageOperation.install, .upgrade, .remove] {
            var arguments = try engine.command(for: op, [crate("ripgrep")], options: InstallOptions()).arguments
            if op == .upgrade {
                #expect(arguments == ["install", "--version", "=16.0.0", "ripgrep"])
                arguments.removeAll { $0 == "--version" || $0 == "=16.0.0" }
            }
            #expect(!arguments.contains { $0.hasPrefix("-") || $0.contains("@") }, "\(arguments)")
        }
    }

    /// `cargo install foo` would swap a git or path install of foo for crates.io's crate of that name: crates.io's
    /// ripgrep replaced the GitHub one without a word (`t13-install-registry-over-git`). ripgrep from GitHub
    /// (`t13-git-ripgrep-crates2.json`) and a path install (`t13-path-crates2.json`) are refused.
    @Test func upgradeRefusesACrateNotFromCratesIO() async throws {
        let (path, _) = engine(files: [recordPath: try fixture("t13-path-crates2.json")])
        _ = try await path.listInstalled()
        Self.expectRefused(path, ["capture-crate"],
                           "capture-crate wasn't installed from crates.io, so BrewxPort doesn't update it.")
        let (engine, _) = engine(files: [recordPath: try fixture("t13-git-ripgrep-crates2.json")])
        _ = try await engine.listInstalled()
        do {
            _ = try engine.command(for: .upgrade, [crate("ripgrep")], options: InstallOptions())
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message == "ripgrep wasn't installed from crates.io, so BrewxPort doesn't update it.")
        }
        // Removing it is still cargo's own `uninstall`.
        #expect(try engine.command(for: .remove, [crate("ripgrep")], options: InstallOptions()).arguments
                == ["uninstall", "ripgrep"])
    }

    /// An upgrade reads cargo's record when its command is built, so a crate cargo hasn't installed (never listed,
    /// or removed from Terminal since the last listing) is refused, never upgraded plain.
    @Test func upgradeRefusesACrateCargoHasntInstalled() async throws {
        let notFound = { (name: String) in
            "BrewxPort can't find \(name) among Cargo's installed crates, so it doesn't update it."
        }
        // Read when the command is built, without a listing first: ripgrep is found (and then refused for want of an
        // offered version, R36), bat isn't.
        let (fresh, runner) = engine(files: [recordPath: try fixture("crates2.json")])
        Self.expectRefused(fresh, ["ripgrep"], noOffer("ripgrep"))
        #expect(runner.calls.isEmpty)
        Self.expectRefused(fresh, ["bat"], notFound("bat"))
        // No record at all.
        let (empty, _) = engine()
        Self.expectRefused(empty, ["ripgrep"], notFound("ripgrep"))

        // Listed, then removed with `cargo uninstall ripgrep` (the record as captured after it).
        let files = RecordFiles([recordPath: try fixture("crates2.json")])
        let listed = CargoEngine(runner: FakeRunner([:]), registry: FakeRegistryFetch(), executable: cargo, base: base,
                                 readRecord: { files.read($0) })
        #expect(try await listed.listInstalled().map(\.id.name) == ["ripgrep"])
        files.set(recordPath, try fixture("crates2-after-uninstall.json"))
        Self.expectRefused(listed, ["ripgrep"], notFound("ripgrep"))
    }

    /// A crate installed twice (cargo kept two versions apart) isn't upgraded: one `cargo install` can't stand for
    /// both copies.
    @Test func upgradeRefusesACrateInstalledTwice() async throws {
        let twice = try record(adding: ["ripgrep 13.0.0 (registry+https://github.com/rust-lang/crates.io-index)":
                                            ["rg13"]])
        let (engine, _) = engine(files: [recordPath: twice])
        #expect(try await engine.listInstalled().map(\.installedVersion) == ["14.1.0"])
        Self.expectRefused(engine, ["ripgrep"], "ripgrep is installed more than once, so BrewxPort doesn't update it.")
    }

    /// With only the older record (`.crates.toml`), cargo's own list from the last listing says what's installed.
    @Test func upgradeAfterAnOlderRecordUsesCargosList() async throws {
        let (engine, _) = engine([listArguments: try captured("install-list")],
                                 files: [legacyRecordPath: try fixture("crates.toml")],
                                 registry: try offering(["ripgrep": "16.0.0"]))
        Self.expectRefused(engine, ["ripgrep"],
                           "BrewxPort can't find ripgrep among Cargo's installed crates, so it doesn't update it.")
        _ = try await engine.checkOutdated()
        #expect(try Self.upgrade(engine) == ["install", "--version", "=16.0.0", "ripgrep"])
    }

    // MARK: upgrading with the recorded options (ruling R11)

    private static func upgrade(_ engine: CargoEngine, _ names: [String] = ["ripgrep"]) throws -> [String] {
        try engine.command(for: .upgrade, names.map(crate), options: InstallOptions()).arguments
    }

    private static func expectRefused(_ engine: CargoEngine, _ names: [String], _ message: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try upgrade(engine, names)
            Issue.record("expected an error", sourceLocation: sourceLocation)
        } catch let error as EngineError {
            #expect(error.message == message, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    /// The captured installs are plain (no features, the release profile, the target of the Rust that built it), so
    /// their upgrades pass no options, only the offered version (R36): ripgrep (`crates2.json`) and tokei
    /// (`t13-tokei-prerelease-crates2.json`).
    @Test func upgradeOfAPlainInstallIsPlain() async throws {
        let (ripgrep, _) = engine(files: [recordPath: try fixture("crates2.json")],
                                  registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await ripgrep.checkOutdated()
        #expect(try Self.upgrade(ripgrep) == ["install", "--version", "=16.0.0", "ripgrep"])
        #expect(ripgrep.unsafeOptions.isEmpty)
        let (tokei, _) = engine(files: [recordPath: try fixture("t13-tokei-prerelease-crates2.json")],
                                registry: try offering(["tokei": "13.0.0-alpha.9"]))
        _ = try await tokei.checkOutdated()
        #expect(try Self.upgrade(tokei, ["tokei"]) == ["install", "--version", "=13.0.0-alpha.9", "tokei"])
        #expect(tokei.unsafeOptions.isEmpty)
    }

    /// The options cargo recorded, as captured: `--features fancy` (`t13-path-features-crates2.json`),
    /// `--no-default-features` (`t13-path-no-default-crates2.json`), and a plain install (`t13-path-crates2.json`).
    /// Those are path installs, never upgraded, so the engine-level upgrades below edit a crates.io record instead.
    @Test func optionsFromTheCapturedRecords() throws {
        func options(_ file: String) throws -> [String]? {
            let record = try JSONDecoder().decode(CargoEngine.Record.self, from: try fixture(file))
            let install = try #require(record.installs?.first { $0.key.hasPrefix("capture-crate ") }?.value)
            return CargoEngine.options(install)
        }
        #expect(try options("t13-path-features-crates2.json") == ["--features", "fancy"])
        #expect(try options("t13-path-no-default-crates2.json") == ["--no-default-features"])
        #expect(try options("t13-path-crates2.json") == [])
        #expect(try options("t13-path-bin-one-crates2.json") == [])
    }

    /// ripgrep installed with its `pcre2` feature (`info-ripgrep.txt`) keeps it, and is still offered; then with
    /// two features and `--all-features`.
    @Test func upgradeKeepsRecordedFeatures() async throws {
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let pcre2 = try record(changing: [#""features":[]"#: #""features":["pcre2"]"#])
        let (one, _) = engine(rustc: try captured("rustc-version"), files: [recordPath: pcre2], registry: registry)
        #expect(try await one.listOutdated().map(\.latestVersion) == ["16.0.0"])
        #expect(try Self.upgrade(one) == ["install", "--features", "pcre2", "--version", "=16.0.0", "ripgrep"])

        let both = try record(changing: [#""features":[]"#: #""features":["pcre2","simd-accel"]"#,
                                         #""all_features":false"#: #""all_features":true"#])
        let (all, _) = engine(files: [recordPath: both], registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await all.checkOutdated()
        #expect(try Self.upgrade(all) == ["install", "--features", "pcre2,simd-accel", "--all-features", "--version",
                                          "=16.0.0", "ripgrep"])
    }

    /// `--no-default-features` and a profile other than `release` are kept. A target (one of the Mac's own, R12) is
    /// passed only when it isn't the host of the Rust that built the crate (the record's `rustc` field names it), or
    /// when that host isn't recorded.
    @Test func upgradeKeepsNoDefaultFeaturesAndProfile() async throws {
        let version = ["--version", "=16.0.0", "ripgrep"]
        let changed = try record(changing: [#""no_default_features":false"#: #""no_default_features":true"#,
                                            #""profile":"release""#: #""profile":"dev""#])
        let (dev, _) = engine(files: [recordPath: changed], registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await dev.checkOutdated()
        #expect(try Self.upgrade(dev) == ["install", "--no-default-features", "--profile", "dev"] + version)

        let cross = try record(changing: [#""target":"aarch64-apple-darwin""#: #""target":"x86_64-apple-darwin""#])
        let (intel, _) = engine(files: [recordPath: cross], registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await intel.checkOutdated()
        #expect(try Self.upgrade(intel) == ["install", "--target", "x86_64-apple-darwin"] + version)

        let noHost = try record(changing: [#"host: aarch64-apple-darwin\n"#: ""])
        let (unknown, _) = engine(files: [recordPath: noHost], registry: try offering(["ripgrep": "16.0.0"]))
        _ = try await unknown.checkOutdated()
        #expect(try Self.upgrade(unknown) == ["install", "--target", "aarch64-apple-darwin"] + version)

        // Each of the Mac's own targets is accepted; the host that built it (aarch64 in the record) isn't passed.
        for target in ["aarch64-apple-darwin", "x86_64-apple-darwin", "arm64e-apple-darwin", "x86_64h-apple-darwin"] {
            let mac = try record(changing: [#""target":"aarch64-apple-darwin""#: "\"target\":\"\(target)\""])
            let (apple, _) = engine(files: [recordPath: mac], registry: try offering(["ripgrep": "16.0.0"]))
            _ = try await apple.checkOutdated()
            let expected = target == "aarch64-apple-darwin" ? [] : ["--target", target]
            #expect(try Self.upgrade(apple) == ["install"] + expected + version, "\(target)")
            #expect(apple.unsafeOptions.isEmpty, "\(target)")
        }
    }

    /// Every crate is upgraded in a command of its own, with its own recorded options and offered version (one
    /// command's options apply to every crate in it): the planner splits a batch (`maxTargetsPerCommand`), and a batch
    /// asked for directly is refused with the same rule.
    @Test func upgradeWithRecordedOptionsRunsAlone() async throws {
        let pcre2 = try record(changing: [#""features":[]"#: #""features":["pcre2"]"#])
        let (engine, _) = engine(files: [recordPath: try record(adding: [batKey: ["bat"]], to: pcre2)],
                                 registry: try offering(["ripgrep": "16.0.0", "bat": "0.25.0"]))
        _ = try await engine.checkOutdated()
        #expect(try Self.upgrade(engine, ["bat"]) == ["install", "--version", "=0.25.0", "bat"])
        #expect(try Self.upgrade(engine, ["ripgrep"]) == ["install", "--features", "pcre2", "--version", "=16.0.0",
                                                          "ripgrep"])
        Self.expectRefused(engine, ["ripgrep", "bat"], "Cargo updates one tool at a time")
    }

    /// A recorded value BrewxPort won't pass back to cargo (an option, a path, a list separator): the crate is listed,
    /// never offered or upgraded, and the reason is recorded. It's looked up, so its newer version shows as held back
    /// with that reason, from every update.
    @Test func upgradeRefusedWhenRecordedOptionIsUnsafe() async throws {
        let reason = "ripgrep was installed with options BrewxPort won't pass back to cargo, so BrewxPort doesn't "
            + "update it."
        let unsafe: [KeyValuePairs<String, String>] = [
            [#""features":[]"#: #""features":["--git=https://git.example.com/x"]"#],
            [#""features":[]"#: #""features":["pcre2,simd"]"#],
            [#""features":[]"#: #""features":[""]"#],
            [#""profile":"release""#: #""profile":"-Zbuild-std""#],
            [#""profile":"release""#: #""profile":"../dev""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"../custom.json""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"-x""#],
            // cargo reads a target ending `.json` as a target-spec file (from the home folder), which can name a
            // linker.
            [#""target":"aarch64-apple-darwin""#: #""target":"custom.json""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"CUSTOM.JSON""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x.json""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x86_64-apple-darwin.json""#],
            // Not one of the Mac's own targets (R12): rustc looks an unknown name up as `<name>.json` in
            // RUST_TARGET_PATH or the folder it runs in, so even a plain-looking triple could load a spec.
            [#""target":"aarch64-apple-darwin""#: #""target":"thumbv8m.main-none-eabi""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"evil-x""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x86_64-unknown-linux-gnu""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"Aarch64-Apple-Darwin""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x86_64""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x86_64--darwin""#],
            [#""target":"aarch64-apple-darwin""#: #""target":"x86_64-.apple-darwin""#],
            // A host that isn't the Mac's own doesn't make its target safe.
            [#""target":"aarch64-apple-darwin""#: #""target":"evil-x""#,
             #"host: aarch64-apple-darwin"#: #"host: evil-x"#],
        ]
        for change in unsafe {
            let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
            let (engine, _) = engine(rustc: try captured("rustc-version"),
                                     files: [recordPath: try record(changing: change)], registry: registry)
            #expect(try await engine.listInstalled().map(\.id.name) == ["ripgrep"], "\(change)")
            #expect(try await engine.listOutdated().isEmpty, "\(change)")
            let report = try await engine.checkOutdated()
            #expect(report.packages.isEmpty, "\(change)")
            #expect(report.held == [HeldUpdate(
                package: Package(id: crate("ripgrep"), displayName: "ripgrep", installedVersion: "14.1.0",
                                 latestVersion: "16.0.0"),
                hold: UpdateHold(reason: reason, blocksAutomatic: true, blocksManual: true))], "\(change)")
            #expect(registry.requested.map(\.absoluteString) == [ripgrepIndex, ripgrepIndex], "\(change)")
            #expect(engine.unsafeOptions == ["ripgrep": reason], "\(change)")
            do {
                _ = try Self.upgrade(engine)
                Issue.record("expected an error for \(change)")
            } catch let error as EngineError {
                #expect(error.message == reason)
            }
        }
    }

    @Test func commandRefusesWhatCargoCantDoHere() throws {
        let (engine, _) = engine()
        let ripgrep = [crate("ripgrep")]
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [], options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ripgrep, options: InstallOptions(version: "14.1.0"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ripgrep, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, ripgrep, options: InstallOptions(extraArgs: ["--locked"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, ripgrep, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .markDependency, ripgrep, options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .npm, kind: .tool, name: "ripgrep")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .cargo, kind: .formula, name: "ripgrep")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutCargoThrows() {
        let (engine, _) = engine(executable: nil)
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [crate("ripgrep")], options: InstallOptions())
        }
    }

    // MARK: R42

    /// Not a capture: crates.io's answer for one version (`/api/v1/crates/<name>/<version>`) wasn't captured; the
    /// captured crate answer's entry for that version (`api-crate-ripgrep.json`, same fields), in the `{"version": …}`
    /// object that endpoint returns, with `extraBins` added to its `bin_names`.
    private static func versionAnswer(_ version: String, extraBins: [String] = []) throws -> String {
        let crate = try #require(try JSONSerialization.jsonObject(with: fixture("api-crate-ripgrep.json")) as? [String: Any])
        let versions = try #require(crate["versions"] as? [[String: Any]])
        var entry = try #require(versions.first { $0["num"] as? String == version })
        entry["bin_names"] = ((entry["bin_names"] as? [String]) ?? []) + extraBins
        return String(decoding: try JSONSerialization.data(withJSONObject: ["version": entry]), as: UTF8.self)
    }

    private static func versionAPI(_ name: String, _ version: String) -> String {
        "https://crates.io/api/v1/crates/\(name)/\(version)"
    }

    /// R42 (reverses R37): `.crates2.json` records only the executables `--bin` installed (`t13-path-bin-one`:
    /// `cap-one`; a later `--bin cap-two` adds it, `t13-path-bin-two`). A strict subset of the crate's executables is
    /// kept: only then is `--bin` passed for each recorded one.
    @Test func binSubsetFromTheCapturedRecords() throws {
        func bins(_ file: String) throws -> [String] {
            try #require(try CargoEngine.crates(record: try fixture(file)).first { $0.name == "capture-crate" }).bins
        }
        let one = try bins("t13-path-bin-one-crates2.json")
        let all = try bins("t13-path-bin-two-crates2.json")
        #expect(one == ["cap-one"])
        #expect(all == ["cap-one", "cap-two"])
        #expect(try bins("t13-path-crates2.json") == all)
        #expect(CargoEngine.keptBins(recorded: one, all: all) == ["cap-one"])
        #expect(CargoEngine.keptBins(recorded: all, all: all) == nil)
        #expect(CargoEngine.keptBins(recorded: ["rg"], all: ["rg"]) == nil)
        #expect(CargoEngine.keptBins(recorded: [], all: ["rg"]) == nil)
        // Not one of the crate's (renamed since?), or not a plain name: nothing to keep, a plain upgrade.
        #expect(CargoEngine.keptBins(recorded: ["gone"], all: ["rg", "rgx"]) == nil)
        #expect(CargoEngine.keptBins(recorded: ["-x"], all: ["-x", "rg"]) == nil)
        #expect(CargoEngine.binNames(versionAnswer: Data(try Self.versionAnswer("14.1.0").utf8)) == ["rg"])
        #expect(CargoEngine.binNames(versionAnswer: Data("<html>".utf8)) == nil)
    }

    /// R42: an outdated check asks crates.io for the installed version's executables of each crate it offers, and an
    /// upgrade of one whose record has fewer passes `--bin` for each it has. ripgrep's record (`crates2.json`) names
    /// its one executable, `rg`, which is all of 14.1.0's: a plain upgrade. With a second executable in the answer
    /// (`versionAnswer`'s `extraBins`), `rg` is a subset and kept. When the lookup fails the upgrade stays plain, never
    /// held.
    @Test func upgradeKeepsARecordedBinSubset() async throws {
        let index = [ripgrepIndex: try text("index-ripgrep.txt")]
        func upgrade(_ answer: String?) async throws -> ([String], [String]) {
            var bodies = index
            if let answer { bodies[Self.versionAPI("ripgrep", "14.1.0")] = answer }
            let registry = FakeRegistryFetch(bodies: bodies)
            let (engine, _) = engine(rustc: try captured("rustc-version"), files: [recordPath: try fixture("crates2.json")],
                                     registry: registry)
            #expect(try await engine.listOutdated().map(\.latestVersion) == ["16.0.0"])
            return (try Self.upgrade(engine), registry.requested.map(\.absoluteString))
        }
        let (all, asked) = try await upgrade(try Self.versionAnswer("14.1.0"))
        #expect(all == ["install", "--version", "=16.0.0", "ripgrep"])
        #expect(asked == [ripgrepIndex, Self.versionAPI("ripgrep", "14.1.0")])
        #expect(try await upgrade(try Self.versionAnswer("14.1.0", extraBins: ["rgx"])).0
                == ["install", "--bin", "rg", "--version", "=16.0.0", "ripgrep"])
        #expect(try await upgrade(nil).0 == ["install", "--version", "=16.0.0", "ripgrep"])
        #expect(try await upgrade("<html>").0 == ["install", "--version", "=16.0.0", "ripgrep"])
    }

    /// Fix round 1: crates.io's API lookups go one at a time, at least `spacing` (1 s) apart, from one check to the
    /// next too (its crawler policy; a refused lookup would quietly drop a `--bin` subset); the sparse index stays
    /// concurrent. ripgrep and tokei both offered (`t13-tokei-prerelease-crates2.json`; their index lines aren't
    /// captures, `offering`): ripgrep's lookup, a wait, tokei's. A second check waits before its first lookup too.
    @Test func apiLookupsAreSpacedOneAtATime() async throws {
        let log = APILog()
        let clock = VirtualClock()
        let index = try offering(["ripgrep": "16.1.0", "tokei": "13.0.0-alpha.9"])
        let registry = LoggingRegistry(index, log: log)
        let pacing = CargoEngine.APIPacing(spacing: .seconds(1), budget: .seconds(20), now: { clock.now },
                                           sleep: { wait in log.add("wait \(wait)"); clock.sleep(wait) })
        let engine = CargoEngine(runner: FakeRunner([:]), registry: registry, executable: cargo, base: base,
                                 readRecord: { [crates = try? fixture("t13-tokei-prerelease-crates2.json")] path in
                                     path == recordPath ? crates : nil
                                 }, apiPacing: pacing)
        #expect(try await engine.listOutdated().map(\.id.name) == ["ripgrep", "tokei"])
        #expect(log.entries == [Self.versionAPI("ripgrep", "16.0.0"), "wait 1.0 seconds",
                                Self.versionAPI("tokei", "13.0.0-alpha.8")])
        _ = try await engine.listOutdated()
        #expect(log.entries.dropFirst(3).first == "wait 1.0 seconds")
        #expect(CargoEngine.APIPacing.live.spacing == .seconds(1))
        #expect(CargoEngine.APIPacing.live.budget == .seconds(20))
    }

    /// Fix round 2: the lookups get about 20 s a check, counted from the first, so a slow crates.io can't hold the
    /// whole Cargo check up to its time limit. Here each answer takes 10 s: a and b are looked up (0 to 10, 11 to 21)
    /// and the rest aren't; every crate is still offered, and the ones not looked up upgrade plain, never held. a's
    /// answer names a second executable, so its recorded `a` is kept. Not captures: the four crates beside ripgrep
    /// (`record(adding:)`), their index lines (`offering`) and a's API answer, in the endpoint's shape.
    @Test func apiLookupsStopAtTheBudget() async throws {
        let crates = "registry+https://github.com/rust-lang/crates.io-index"
        let record = try record(adding: ["a 1.0.0 (\(crates))": ["a"], "b 1.0.0 (\(crates))": ["b"],
                                         "c 1.0.0 (\(crates))": ["c"], "d 1.0.0 (\(crates))": ["d"]])
        var bodies = [
            Self.versionAPI("a", "1.0.0"): #"{"version":{"num":"1.0.0","bin_names":["a","a-extra"]}}"#,
            Self.versionAPI("d", "1.0.0"): #"{"version":{"num":"1.0.0","bin_names":["d","d-extra"]}}"#,
        ]
        for (name, vers) in [("a", "2.0.0"), ("b", "2.0.0"), ("c", "2.0.0"), ("d", "2.0.0"), ("ripgrep", "16.0.0")] {
            bodies[try #require(CargoEngine.indexURL(name)).absoluteString] = indexLine(name, vers)
        }
        let clock = VirtualClock()
        let engine = CargoEngine(runner: FakeRunner([:]),
                                 registry: SlowAPI(inner: FakeRegistryFetch(bodies: bodies), clock: clock,
                                                   apiTime: .seconds(10)),
                                 executable: cargo, base: base, readRecord: { $0 == recordPath ? record : nil },
                                 apiPacing: clock.pacing())
        let started = ContinuousClock.now
        #expect(try await engine.listOutdated().map(\.id.name) == ["a", "b", "c", "d", "ripgrep"])
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(clock.time <= .seconds(21))
        #expect(clock.sleeps == [.seconds(1)])
        #expect(try Self.upgrade(engine, ["a"]) == ["install", "--bin", "a", "--version", "=2.0.0", "a"])
        for name in ["b", "c", "d"] {
            #expect(try Self.upgrade(engine, [name]) == ["install", "--version", "=2.0.0", name], "\(name)")
        }
        #expect(engine.needsNewerRust.isEmpty && engine.unsafeOptions.isEmpty)
    }

    /// Fix round 2: a lookup still running when the budget ends is cut off on the real clock, and the check returns:
    /// a crates.io API that never answers, with a 0.2 s budget, leaves ripgrep offered with a plain upgrade.
    @Test func apiLookupThatHangsIsCutOff() async throws {
        let index = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let engine = CargoEngine(runner: FakeRunner([:]), registry: HungAPI(inner: index), executable: cargo,
                                 base: base, readRecord: { [crates = try? fixture("crates2.json")] path in
                                     path == recordPath ? crates : nil
                                 }, apiPacing: CargoEngine.APIPacing(spacing: .zero, budget: .milliseconds(200)))
        let started = ContinuousClock.now
        #expect(try await engine.listOutdated().map(\.latestVersion) == ["16.0.0"])
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try Self.upgrade(engine) == ["install", "--version", "=16.0.0", "ripgrep"])
    }

    /// Post-VM fix: a check cancelled while crates.io's API is being asked throws, as one cancelled anywhere else does,
    /// rather than returning as if it had finished: the cancelled lookup isn't taken for a failed one, and the offers
    /// stay as they were (none here), so the upgrade is still refused.
    @Test func cancelledDuringTheAPILookupsThrows() async throws {
        let index = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let (asked, signal) = AsyncStream<Void>.makeStream()
        let engine = CargoEngine(runner: FakeRunner([:]), registry: HungAPI(inner: index, asked: signal),
                                 executable: cargo, base: base, readRecord: { [crates = try? fixture("crates2.json")] path in
                                     path == recordPath ? crates : nil
                                 }, apiPacing: CargoEngine.APIPacing(spacing: .zero, budget: .seconds(20)))
        let check = Task { try await engine.checkOutdated() }
        var requests = asked.makeAsyncIterator()
        _ = await requests.next()
        check.cancel()
        await #expect(throws: CancellationError.self) { _ = try await check.value }
        Self.expectRefused(engine, ["ripgrep"], noOffer("ripgrep"))
    }

    /// Post-VM fix: the API lookups' 20 s is cut to what the whole check has left of its limit (the catalog's 60 s),
    /// less `APIPacing.handOver`, so a slow index plus the lookups can't run the check out of time. Here the five
    /// crates' index answers take 50 s, and each API answer 2 s: a (50 to 52), b (53 to 55) and c (56 to 58) are looked
    /// up, d isn't (its lookup would start at 59, past 58); with the full 20 s, d and ripgrep would have been too. Every
    /// crate is still offered, the ones not looked up with a plain upgrade. Not captures: as in
    /// `apiLookupsStopAtTheBudget`.
    @Test func apiLookupsEndWithinTheChecksLimit() async throws {
        let crates = "registry+https://github.com/rust-lang/crates.io-index"
        let record = try record(adding: ["a 1.0.0 (\(crates))": ["a"], "b 1.0.0 (\(crates))": ["b"],
                                         "c 1.0.0 (\(crates))": ["c"], "d 1.0.0 (\(crates))": ["d"]])
        var bodies = [Self.versionAPI("a", "1.0.0"): #"{"version":{"num":"1.0.0","bin_names":["a","a-extra"]}}"#]
        for (name, vers) in [("a", "2.0.0"), ("b", "2.0.0"), ("c", "2.0.0"), ("d", "2.0.0"), ("ripgrep", "16.0.0")] {
            bodies[try #require(CargoEngine.indexURL(name)).absoluteString] = indexLine(name, vers)
        }
        func check(indexTime: Duration) async throws -> (CargoEngine, [String], VirtualClock) {
            let clock = VirtualClock()
            let log = APILog()
            let registry = SlowRegistry(inner: FakeRegistryFetch(bodies: bodies), clock: clock, indexTime: indexTime,
                                        apiTime: .seconds(2), log: log)
            let engine = CargoEngine(runner: FakeRunner([:]), registry: registry, executable: cargo, base: base,
                                     readRecord: { $0 == recordPath ? record : nil }, apiPacing: clock.pacing())
            #expect(try await engine.listOutdated().map(\.id.name) == ["a", "b", "c", "d", "ripgrep"])
            return (engine, log.entries, clock)
        }

        let (engine, asked, clock) = try await check(indexTime: .seconds(10))
        #expect(asked == [Self.versionAPI("a", "1.0.0"), Self.versionAPI("b", "1.0.0"), Self.versionAPI("c", "1.0.0")])
        #expect(clock.time <= BrewxPortTimeouts.engineQuery - CargoEngine.APIPacing.handOver)
        #expect(try Self.upgrade(engine, ["a"]) == ["install", "--bin", "a", "--version", "=2.0.0", "a"])
        for name in ["b", "c", "d"] {
            #expect(try Self.upgrade(engine, [name]) == ["install", "--version", "=2.0.0", name], "\(name)")
        }
        #expect(try Self.upgrade(engine) == ["install", "--version", "=16.0.0", "ripgrep"])

        // The index alone used the check's time: crates.io's API isn't asked at all.
        let (late, none, _) = try await check(indexTime: .seconds(12))
        #expect(none.isEmpty)
        #expect(try Self.upgrade(late, ["a"]) == ["install", "--version", "=2.0.0", "a"])
        #expect(CargoEngine.APIPacing.live.checkLimit == BrewxPortTimeouts.engineQuery)
    }

    /// R42: cargo honours `install.root` in CARGO_HOME's `config.toml`: it installs there, keeps its record there and
    /// lists that root, while `~/.cargo/.crates2.json` stays as it was (`t13-config-root-*`). So the install root is
    /// CARGO_INSTALL_ROOT, else that setting (an absolute path only), else CARGO_HOME, for the record, the bin folder
    /// and the PATH note. Not a capture: `config.toml` itself, as the SOURCES note gives it (`[install]`
    /// `root = "/Users/tester/cargo-alt-root"`), and with other tables cargo reads beside it.
    @Test func installRootFromCargosConfig() async throws {
        let config = "[install]\nroot = \"/Users/tester/cargo-alt-root\"\n"
        let files = ["/Users/someone/.cargo/config.toml": Data(config.utf8),
                     "/Users/tester/cargo-alt-root/.crates2.json": try fixture("t13-config-root-crates2.json"),
                     recordPath: try fixture("t13-config-root-home-crates2.json")]
        let (alternate, runner) = engine([versionArguments: try captured("version")], files: files)
        _ = await alternate.detect()
        #expect(alternate.installLocation?.path == "/Users/tester/cargo-alt-root")
        #expect(alternate.binLocation?.path == "/Users/tester/cargo-alt-root/bin")
        #expect(try await alternate.listInstalled().map(\.id.name) == ["capture-crate"])
        #expect(try CargoEngine.crates(list: try captured("t13-config-root-install-list").stdout).map(\.name)
                == ["capture-crate"])
        #expect(runner.calls == [versionArguments])

        // CARGO_INSTALL_ROOT comes first; CARGO_HOME's own config is the one read.
        let (variable, _) = engine([versionArguments: try captured("version")], files: files,
                                   captured: ["CARGO_INSTALL_ROOT": "/Users/someone/tools"])
        _ = await variable.detect()
        #expect(variable.installLocation?.path == "/Users/someone/tools")
        let moved = ["/Users/someone/rust/cargo/config.toml": Data(config.utf8)]
        let (home, _) = engine([versionArguments: try captured("version")], files: moved,
                               captured: ["CARGO_HOME": "/Users/someone/rust/cargo"])
        _ = await home.detect()
        #expect(home.installLocation?.path == "/Users/tester/cargo-alt-root")

        for (text, root) in [
            ("[build]\njobs = 8\n\n[install]\nroot = \"/opt/tools\" # mine\n\n[net]\noffline = true\n", "/opt/tools"),
            ("[install]\nroot = \"tools\"\n", nil),
            ("[install]\nroot = 8\n", nil),
            ("[registries]\nmine = { index = \"sparse+https://example.com/\" }\n", nil),
            ("", nil),
        ] {
            #expect(CargoEngine.configRoot(text) == root, "\(text)")
        }
    }

    /// R42, the R36 guard: an upgrade passes `--version =<offered>`, which installs that version over whatever is
    /// there, newer or not: `--version =13.0.0-alpha.9` over tokei 15.0.0 went back down without a word
    /// (`t13-install-tokei-prerelease-down`). So the record is read again when the command is built, and when what's
    /// installed is already that version or newer (updated from Terminal since the check), the upgrade is refused in
    /// one line. ripgrep 14.1.0 offered 16.0.0, then 16.0.0 installed (`t13-start-crates2.json`,
    /// `t13-ripgrep-16-crates2.json`); tokei at alpha.8 offered alpha.9 (index line not captured, `offering`), then
    /// 15.0.0 (`t13-tokei-prerelease-crates2.json`, `t13-tokei-plain-crates2.json`).
    @Test func upgradeNeverInstallsAnOlderVersion() async throws {
        let down = try captured("t13-install-tokei-prerelease-down")
        #expect(down.exitCode == 0)
        let files = RecordFiles([recordPath: try fixture("t13-start-crates2.json")])
        let registry = FakeRegistryFetch(bodies: [ripgrepIndex: try text("index-ripgrep.txt")])
        let ripgrep = CargoEngine(runner: FakeRunner([:], byExecutable: ["rustc": [versionArguments:
                                                                                      try captured("rustc-version")]]),
                                  registry: registry, executable: cargo, base: base, readRecord: { files.read($0) })
        #expect(try await ripgrep.listOutdated().map(\.latestVersion) == ["16.0.0"])
        #expect(try Self.upgrade(ripgrep) == ["install", "--version", "=16.0.0", "ripgrep"])
        files.set(recordPath, try fixture("t13-ripgrep-16-crates2.json"))
        Self.expectRefused(ripgrep, ["ripgrep"],
                           "ripgrep is already at 16.0.0, so BrewxPort doesn't install 16.0.0 over it.")

        let tokeiFiles = RecordFiles([recordPath: try fixture("t13-tokei-prerelease-crates2.json")])
        let tokei = CargoEngine(runner: FakeRunner([:]), registry: try offering(["tokei": "13.0.0-alpha.9"]),
                                executable: cargo, base: base, readRecord: { tokeiFiles.read($0) })
        #expect(try await tokei.listOutdated().map(\.latestVersion) == ["13.0.0-alpha.9"])
        #expect(try Self.upgrade(tokei, ["tokei"]) == ["install", "--version", "=13.0.0-alpha.9", "tokei"])
        tokeiFiles.set(recordPath, try fixture("t13-tokei-plain-crates2.json"))
        Self.expectRefused(tokei, ["tokei"],
                           "tokei is already at 15.0.0, so BrewxPort doesn't install 13.0.0-alpha.9 over it.")
    }

    // MARK: reading the record

    /// The app's reader: nil for a file that isn't there, the bytes of one that is.
    @Test func readsRecordFilesFromDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-cargo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(".crates2.json")
        try fixture("crates2.json").write(to: file)
        #expect(try CargoEngine.readFile(file.path) == (try fixture("crates2.json")))
        #expect(try CargoEngine.readFile(root.appendingPathComponent(".crates.toml").path) == nil)
    }
}
