import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/mint")

/// One captured Mint or git command from `Fixtures/mint` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`,
/// stderr from `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

/// A captured file from `Fixtures/mint`, as it is on disk (`metadata.json`).
private func capturedData(_ file: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(file))
}

private let mint = URL(fileURLWithPath: "/opt/homebrew/bin/mint")
private let git = URL(fileURLWithPath: "/opt/homebrew/bin/git")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let ink = "JohnSundell/Ink"
private let inkURL = "https://github.com/JohnSundell/Ink.git"
/// Where the engine's commands say Mint's metadata is, for `base`'s HOME and no MINT_PATH.
private let metadataPath = "/Users/someone/.mint/metadata.json"

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .mint, kind: .tool, name: name) }

/// What `check` says about `listing` when Mint's metadata has `repositories` (nil: it couldn't be read).
private func failure(_ check: ConfirmationCheck, _ listing: String, _ repositories: [String]? = [inkURL]) -> String? {
    MintEngine.confirmationFailure(check, listing: listing, repositories: repositories)
}

private func linked(_ package: String, _ version: String) -> ConfirmationCheck {
    .mintLinked(package: package, version: version, metadata: metadataPath)
}

private func absent(_ package: String) -> ConfirmationCheck { .mintAbsent(package: package, metadata: metadataPath) }

/// R21's lookup, word for word: git's hardening options, then the captured `ls-remote --tags --refs <url>`.
private func lsRemote(_ name: String) -> [String] {
    ["-c", "protocol.allow=never", "-c", "protocol.https.allow=always", "-c", "credential.helper=", "-c",
     "core.askPass=", "ls-remote", "--tags", "--refs", "https://github.com/\(name).git"]
}

/// Answers the engine's metadata reads with one answer, and remembers which files it asked for.
private final class MetadataFiles: @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<Data?, any Error>
    private var paths: [String] = []

    init(_ answer: Result<Data?, any Error>) { self.answer = answer }

    var requested: [String] { lock.withLock { paths } }

    func read(_ path: String) throws -> Data? {
        lock.withLock { paths.append(path) }
        return try answer.get()
    }
}

private struct Unreadable: Error {}

/// Mint at a fixed path with git beside it; the metadata reader answers with the captured `metadata.json` unless
/// told otherwise.
private func makeEngine(_ responses: [[String]: CommandResult], executable: URL? = mint, git gitURL: URL? = git,
                        captured variables: [String: String] = [:], metadata: Result<Data?, any Error>? = nil,
                        runner custom: (any CommandRunning)? = nil) throws -> (MintEngine, FakeRunner, MetadataFiles) {
    let files = MetadataFiles(try metadata ?? .success(capturedData("metadata.json")))
    let runner = FakeRunner(responses)
    let engine = MintEngine(runner: custom ?? runner, executable: executable, git: gitURL, captured: variables,
                            base: base, readMetadata: { try files.read($0) })
    return (engine, runner, files)
}

/// `mint list` with two packages called Ink, each with its URL (a fork installed from a folder, and JohnSundell's), and
/// MultiTool from a folder, one version unlinked and one partly linked (`t13-list-two-inks`); Mint's metadata then
/// (`t13-metadata-two-inks.json`). A `file://` package stands in for one from a host that isn't GitHub.
private func twoInks() throws -> CommandResult { try captured("t13-list-two-inks") }
private func twoInksMetadata() throws -> Data { try capturedData("t13-metadata-two-inks.json") }
private func twoInksRepositories() throws -> [String] { try MintEngine.repositories(metadata: twoInksMetadata()) }

/// Not a capture: three packages from GitHub in one listing, which no capture has (T13's listings have one GitHub
/// package beside folder ones), in `mint list`'s shape, with their repositories in Mint's metadata.
private let threeFromGitHub = """
    🌱 Installed mint packages:
      Ink (https://github.com/JohnSundell/Ink.git)
        - 0.6.0 (ink-cli) *
      Ink (https://github.com/someone/Ink.git)
        - 1.0.0 (ink, ink-server) *
      SwiftLint
        - 0.65.1 *

    """
private let threeFromGitHubRepositories = [inkURL, "https://github.com/someone/Ink.git",
                                           "https://github.com/realm/SwiftLint.git"]

/// Not a capture: Mint's `metadata.json` shape (as captured) for made-up repositories, each with a folder name.
private func metadata(_ repositories: [String]) throws -> Data {
    try JSONEncoder().encode(["packages": Dictionary(uniqueKeysWithValues: repositories.map { ($0, "folder") })])
}

/// A runner that fails every git call the way `failure` says, and answers the rest like `FakeRunner`.
private final class FailingGit: CommandRunning, @unchecked Sendable {
    let fake: FakeRunner
    let failure: CommandRunnerError

    init(_ fake: FakeRunner, _ failure: CommandRunnerError) {
        self.fake = fake
        self.failure = failure
    }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        if executable.lastPathComponent == "git" { throw failure }
        return try await fake.run(executable, arguments, options: options)
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        try await fake.stream(executable, arguments, options: options, onOutput: onOutput)
    }
}

/// Counts calls, from any task.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func add() { lock.withLock { value += 1 } }
}

/// Answers like `FakeRunner`, but holds every git call after the first until `releaseHeld()`.
private final class HeldGit: CommandRunning, @unchecked Sendable {
    private let fake: FakeRunner
    private let lock = NSLock()
    private var gitCalls = 0
    private var isHeld = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ fake: FakeRunner) { self.fake = fake }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        if executable.lastPathComponent == "git", lock.withLock({ () -> Bool in gitCalls += 1; return gitCalls > 1 }) {
            await withCheckedContinuation { continuation in
                let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                    held = continuation
                    isHeld = true
                    defer { waiter = nil }
                    return waiter
                }
                waiting?.resume()
            }
        }
        return try await fake.run(executable, arguments, options: options)
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        try await fake.stream(executable, arguments, options: options, onOutput: onOutput)
    }

    /// Returns once a git call is held.
    func waitUntilHeld() async {
        await withCheckedContinuation { continuation in
            let already = lock.withLock { () -> Bool in
                if isHeld { return true }
                waiter = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    func releaseHeld() {
        lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }?.resume()
    }
}

/// Answers git calls with `answers` in order (the last one repeats), and anything else like `FakeRunner`.
private final class QueuedGit: CommandRunning, @unchecked Sendable {
    private let fake: FakeRunner
    private let lock = NSLock()
    private var answers: [CommandResult]

    init(_ fake: FakeRunner, _ answers: [CommandResult]) {
        self.fake = fake
        self.answers = answers
    }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        guard executable.lastPathComponent == "git" else {
            return try await fake.run(executable, arguments, options: options)
        }
        return lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        try await fake.stream(executable, arguments, options: options, onOutput: onOutput)
    }
}

@Suite struct MintEngineTests {
    // MARK: detect

    @Test func detectsMintsVersionAndFolders() async throws {
        let (engine, runner, _) = try makeEngine([["--version"]: try captured("version")])
        #expect(await engine.detect() == .present(path: mint, version: "0.18.0"))
        #expect(engine.installLocation == URL(fileURLWithPath: "/Users/someone/.mint", isDirectory: true))
        #expect(engine.binLocation == URL(fileURLWithPath: "/Users/someone/.mint/bin", isDirectory: true))
        #expect(runner.calls == [["--version"]])
        #expect(runner.optionsCalls.first?.environment?["NO_COLOR"] == "1")
        #expect(runner.optionsCalls.first?.workingDirectory == "/Users/someone")

        let (moved, _, _) = try makeEngine([["--version"]: try captured("version")],
                                           captured: ["MINT_PATH": "/Users/someone/tools/mint",
                                                      "MINT_LINK_PATH": "/Users/someone/bin"])
        _ = await moved.detect()
        #expect(moved.installLocation?.path == "/Users/someone/tools/mint")
        #expect(moved.binLocation?.path == "/Users/someone/bin")
    }

    /// `Version: 0.18.0` is Mint's; Homebrew's mintoolkit also installs a `mint`, which doesn't answer that way.
    @Test func versionMustBeMintsShape() throws {
        #expect(MintEngine.version(try captured("version").stdout) == "0.18.0")
        for other in ["0.18.0\n", "mint 1.2.3\n", "Version: latest\n", ""] {
            #expect(MintEngine.version(other) == nil, "\(other)")
        }
    }

    @Test func detectMissingWithoutExecutable() async throws {
        let (engine, runner, _) = try makeEngine([:], executable: nil)
        #expect(await engine.detect() == .missing)
        #expect(engine.installLocation == nil)
        #expect(runner.calls.isEmpty)
        await #expect(throws: EngineError.self) { _ = try await engine.listInstalled() }
    }

    @Test func fixedFoldersFollowTheArchitectureAndMintsOwnBinFolder() {
        #expect(MintEngine.fixedFolders(arch: .arm64, home: "/Users/someone", captured: [:])
                == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/Users/someone/.mint/bin"])
        #expect(MintEngine.fixedFolders(arch: .x86_64, home: "/Users/someone",
                                        captured: ["MINT_LINK_PATH": "/Users/someone/bin"])
                == ["/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/Users/someone/bin",
                    "/Users/someone/.mint/bin"])
    }

    // MARK: mint list

    @Test func listReadsTheCapturedShapes() throws {
        #expect(try MintEngine.listed(try captured("list-empty").stdout).isEmpty)
        #expect(try MintEngine.listed(try captured("list-after-uninstall").stdout).isEmpty)
        let one = try MintEngine.listed(try captured("list-one").stdout)
        #expect(one == [MintEngine.Listed(name: "Ink", repository: nil, versions: [
            MintEngine.ListedVersion(version: "0.5.0", executables: ["ink-cli"], linked: true)])])
        #expect(try MintEngine.listed(try captured("list-final").stdout) == one)
        #expect(try MintEngine.listed(try captured("list-after-network-refused").stdout) == one)
        #expect(try MintEngine.listed(try captured("list-two-versions").stdout) == [MintEngine.Listed(
            name: "Ink", repository: nil, versions: [
                MintEngine.ListedVersion(version: "0.5.0", executables: ["ink-cli"], linked: false),
                MintEngine.ListedVersion(version: "0.6.0", executables: ["ink-cli"], linked: true)])])
        #expect(try MintEngine.listed(try captured("list-relinked-old").stdout) == [MintEngine.Listed(
            name: "Ink", repository: nil, versions: [
                MintEngine.ListedVersion(version: "0.5.0", executables: ["ink-cli"], linked: true),
                MintEngine.ListedVersion(version: "0.6.0", executables: ["ink-cli"], linked: false)])])
    }

    /// The other shapes `mint list` prints, as captured: two packages with one name, each with its URL; a version not
    /// linked, and one with only some executables linked, which `--overwrite n` leaves without a word
    /// (`t13-list-two-inks`, `t13-list-overwrite-n-skip`); every executable linked (`t13-list-file-url`); and no
    /// brackets for a package whose one executable has its own name (`t13-list-same-name-executable`).
    @Test func listReadsMintsOtherShapes() throws {
        typealias Version = MintEngine.ListedVersion
        let multiTool = [Version(version: "1.0.0", executables: ["multi-a", "multi-b"], linked: false),
                         Version(version: "1.1.0", executables: ["multi-a", "multi-b"], linked: true,
                                 partlyLinked: true)]
        let listed = try MintEngine.listed(try twoInks().stdout)
        #expect(listed.map(\.name) == ["Ink", "Ink", "MultiTool"])
        #expect(listed[0].repository == "file:///Users/tester/mintpkgs/forks/Ink")
        #expect(listed[0].versions == [Version(version: "1.0.0", executables: ["ink-fork"], linked: true)])
        #expect(listed[1].repository == inkURL)
        #expect(listed[1].versions == [Version(version: "0.5.0", executables: ["ink-cli"], linked: true)])
        #expect(listed[2].repository == nil)
        #expect(listed[2].versions == multiTool)
        #expect(try MintEngine.listed(try captured("t13-list-overwrite-n-skip").stdout).last?.versions == multiTool)
        #expect(try MintEngine.listed(try captured("t13-list-file-url").stdout).last?.versions
                == [Version(version: "1.0.0", executables: ["multi-a", "multi-b"], linked: true)])
        // No brackets: the one executable has the package's name (Mint compares without case), so it isn't known.
        #expect(try MintEngine.listed(try captured("t13-list-same-name-executable").stdout) == [
            MintEngine.Listed(name: "solo", repository: nil,
                              versions: [Version(version: "1.0.0", executables: nil, linked: true)])])
        // Not a capture: `()`, which Mint 0.18.0's `Cache.swift` prints for a package without executables; Mint can't
        // build one (it needs an executable product), so T13 couldn't make it.
        #expect(try MintEngine.listed("🌱 Installed mint packages:\n  Empty\n    - 1.0.0 () *\n")
                .first?.versions == [Version(version: "1.0.0", executables: [], linked: true)])
    }

    /// Mint can exit 0 when it failed: output BrewxPort doesn't know is a failure, never a short list. Not captures:
    /// made up on purpose, no Mint printed these.
    @Test func listRefusesOutputItDoesNotKnow() {
        let unknown = [
            "Error: The folder doesn't exist.\n",
            "🌱 Installed mint packages:\n    - 1.0.0 *\n",
            "🌱 Installed mint packages:\n  Ink\n    - 1.0.0 *\nSomething else\n",
            "  Ink\n    - 1.0.0 *\n",
            "🌱 No mint packages installed\n  Ink\n",
            "🌱 Installed mint packages:\n  Ink\n    - 1.0.0 (ink-cli\n",
            "🌱 Installed mint packages:\n  Ink\n    - 1.0.0 (ink-cli) * extra\n",
            "🌱 Installed mint packages:\n  Ink\n    -\n",
        ]
        for text in unknown {
            #expect(throws: EngineError.self, "\(text)") { _ = try MintEngine.listed(text) }
        }
    }

    @Test func listFailureShowsMintsError() async throws {
        let (engine, _, files) = try makeEngine([["list"]: try captured("list-inconsistent-cache")])
        let error = try await #require(throws: EngineError.self) { _ = try await engine.listInstalled() }
        #expect(error.message.contains("exit 1"))
        #expect(error.message.contains("The folder “build” doesn’t exist."))
        #expect(files.requested.isEmpty)

        let quietFailure = CommandResult(exitCode: 0, stdout: "Error: something\n", stderr: "")
        let (silent, _, _) = try makeEngine([["list"]: quietFailure])
        await #expect(throws: EngineError.self) { _ = try await silent.listInstalled() }
    }

    // MARK: installed tools

    /// The listing names each package's commands (Ink's `ink-cli`); one Mint doesn't name has the repository's name.
    @Test func mintNamesAPackagesCommands() async throws {
        let (engine, _, _) = try makeEngine([["list"]: try captured("list-final")])
        #expect(engine.executables(of: ink) == nil)
        _ = try await engine.listInstalled()
        #expect(engine.executables(of: ink) == ["ink-cli"])
        // `solo` lists without brackets (`t13-list-same-name-executable`); its metadata wasn't captured, so the one
        // captured after the rows before it (`t13-metadata-end.json`, no packages) stands in: unmapped, still named.
        let (unnamed, _, _) = try makeEngine([["list"]: try captured("t13-list-same-name-executable")],
                                             metadata: .success(try capturedData("t13-metadata-end.json")))
        _ = try await unnamed.listInstalled()
        #expect(unnamed.executables(of: "solo") == ["solo"])
    }

    @Test func installedToolsComeFromTheListAndMintsMetadata() async throws {
        let (engine, runner, files) = try makeEngine([["list"]: try captured("list-final")])
        #expect(try await engine.listInstalled() == [
            Package(id: tool(ink), displayName: ink, installedVersion: "0.5.0", installedOnRequest: true)])
        #expect(files.requested == ["/Users/someone/.mint/metadata.json"])
        #expect(runner.calls == [["list"]])
        #expect(runner.executableCalls == [mint])
        let options = try #require(runner.optionsCalls.first)
        #expect(options.environment?["NO_COLOR"] == "1")
        #expect(options.environment?["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(options.workingDirectory == "/Users/someone")

        // MINT_PATH from the login shell moves the metadata, and Mint gets it too.
        let (moved, movedRunner, movedFiles) = try makeEngine([["list"]: try captured("list-two-versions")],
                                                              captured: ["MINT_PATH": "/Users/someone/tools/mint"])
        #expect(try await moved.listInstalled().map(\.installedVersion) == ["0.6.0"])
        #expect(movedFiles.requested == ["/Users/someone/tools/mint/metadata.json"])
        #expect(movedRunner.optionsCalls.first?.environment?["MINT_PATH"] == "/Users/someone/tools/mint")
    }

    @Test func nothingInstalledReadsNoMetadata() async throws {
        for list in ["list-empty", "list-after-uninstall"] {
            let (engine, _, files) = try makeEngine([["list"]: try captured(list)], metadata: .success(nil))
            #expect(try await engine.listInstalled().isEmpty)
            #expect(files.requested.isEmpty)
        }
    }

    /// Mint can't list a package without its metadata, so a listing BrewxPort can't match up is a failure.
    @Test func missingOrUnreadableMetadataFailsTheList() async throws {
        let answers: [Result<Data?, any Error>] = [.success(nil), .success(Data("not json".utf8)),
                                                   .failure(Unreadable())]
        for answer in answers {
            let (engine, _, _) = try makeEngine([["list"]: try captured("list-final")], metadata: answer)
            let error = try await #require(throws: EngineError.self) { _ = try await engine.listInstalled() }
            #expect(error.message.contains("metadata"))
            #expect(!error.message.contains("/Users/someone"))
        }
    }

    /// R24: every package `mint list` shows is listed. One BrewxPort can't map to exactly one plain GitHub
    /// `owner/repo` with a linked version is listed with what's known (its owner/repo or Mint's own name, its linked
    /// or highest version, its executables) and a one-line reason, recorded in `unmapped`. The fork and MultiTool came
    /// from folders (`t13-list-two-inks`), so neither is a GitHub package.
    @Test func mintListsPackagesItCannotMap() async throws {
        let listed = try MintEngine.listed(try twoInks().stdout)
        #expect(MintEngine.tools(listed, repositories: try twoInksRepositories()) == [
            MintEngine.Tool(name: "Ink", version: "1.0.0", executables: ["ink-fork"],
                            unmapped: MintEngine.notGitHub("Ink")),
            MintEngine.Tool(name: ink, version: "0.5.0", executables: ["ink-cli"]),
            MintEngine.Tool(name: "MultiTool", version: "1.1.0", executables: ["multi-a", "multi-b"],
                            unmapped: MintEngine.notGitHub("MultiTool")),
        ])
        #expect(MintEngine.notGitHub("MultiTool") == "Mint installed MultiTool from somewhere other than a plain "
                + "GitHub address, so BrewxPort doesn't update it.")

        // A name more than one repository could have, without Mint saying which (the captured metadata has two
        // Inks, beside an earlier listing that names neither), or none.
        let twice = try MintEngine.listed(try captured("list-final").stdout)
        let unknown = [MintEngine.Tool(name: "Ink", version: "0.5.0", executables: ["ink-cli"],
                                       unmapped: MintEngine.unknownRepository("Ink"))]
        #expect(MintEngine.tools(twice, repositories: try twoInksRepositories()) == unknown)
        #expect(MintEngine.tools(twice, repositories: []) == unknown)

        // Not a capture: a GitHub package with no linked version, which T13 didn't leave (MultiTool's unlinked 1.0.0
        // sits beside a linked 1.1.0).
        let unlinked = try MintEngine.listed("🌱 Installed mint packages:\n  Unlinked\n    - 3.0.0\n")
        #expect(MintEngine.tools(unlinked, repositories: ["https://github.com/someone/Unlinked.git"]) == [
            MintEngine.Tool(name: "someone/Unlinked", version: "3.0.0", executables: nil,
                            unmapped: MintEngine.notLinked("someone/Unlinked"))])

        // Not a capture: two packages BrewxPort could only call by the same name make one row that says so (T13 made
        // none: two Inks keep their URLs).
        let sameName = try MintEngine.listed("🌱 Installed mint packages:\n  tool (https://gitlab.com/a/tool.git)\n"
                                             + "    - 1.0.0 *\n  tool (https://gitlab.com/b/tool.git)\n    - 2.0.0 *\n")
        #expect(MintEngine.tools(sameName, repositories: []) == [
            MintEngine.Tool(name: "tool", version: "1.0.0", executables: nil, unmapped: MintEngine.sameName("tool"))])

        // Through the engine: Installed has every row, and `unmapped` the reasons, for Task 10a.
        let (engine, runner, _) = try makeEngine([["list"]: try twoInks()], metadata: .success(try twoInksMetadata()))
        let rows = try await engine.listInstalled()
        #expect(rows.map(\.id.name) == ["Ink", ink, "MultiTool"])
        #expect(rows.map(\.installedVersion) == ["1.0.0", "0.5.0", "1.1.0"])
        #expect(rows.allSatisfy { $0.installedOnRequest == true && $0.id.engine == .mint && $0.id.kind == .tool })
        #expect(engine.unmapped == ["Ink": MintEngine.notGitHub("Ink"), "MultiTool": MintEngine.notGitHub("MultiTool")])
        // Their details are what's known, without a lookup.
        #expect(try await engine.info(tool("MultiTool"))
                == PackageDetails(ref: tool("MultiTool"), installedVersion: "1.1.0",
                                  executables: ["multi-a", "multi-b"]))
        #expect(runner.calls == [["list"]])
    }

    /// R24: an unmapped package is never looked up, offered as an update, upgraded or installed, even after Discover
    /// found a tag for its name. It can be removed: by its URL when it's a GitHub owner/repo, else by Mint's own name
    /// when Mint's uninstall (which matches any package whose URL contains its argument) would find just that one,
    /// confirmed by `mint list` no longer showing it.
    @Test func mintUnmappedPackageNeverUpdated() async throws {
        let (engine, runner, _) = try makeEngine([["list"]: try twoInks(),
                                                  lsRemote(ink): try captured("ls-remote-tags-refs")],
                                                 metadata: .success(try twoInksMetadata()))
        let updates = try await engine.listOutdated()
        #expect(updates.map(\.id.name) == [ink])
        #expect(Array(runner.calls.dropFirst()) == [lsRemote(ink)])
        #expect(engine.couldntCheck.isEmpty)

        _ = try await engine.search("MultiTool")
        for name in ["Ink", "MultiTool"] {
            for operation in [PackageOperation.install, .upgrade] {
                #expect(throws: EngineError.self, "\(operation) \(name)") {
                    _ = try engine.command(for: operation, [tool(name)], options: InstallOptions())
                }
            }
        }

        // JohnSundell's Ink by its URL, which removes only that one (`t13-uninstall-github-url-two-inks`).
        let byURL = try engine.command(for: .remove, [tool(ink)], options: InstallOptions())
        #expect(byURL.arguments == ["uninstall", inkURL])
        #expect(byURL.confirmation?.check == absent(ink))
        // Mint's metadata after it wasn't captured; without it, the fork left behind (listed as plain `Ink` then,
        // `t13-list-after-uninstall-github-url`) can't be told from JohnSundell's, so it isn't taken as gone.
        #expect(failure(absent(ink), try captured("t13-list-after-uninstall-github-url").stdout, nil) != nil)
        // MultiTool by Mint's own name, which only its URL holds: every version goes (`t13-uninstall-name-multitool`).
        let byName = try engine.command(for: .remove, [tool("MultiTool")], options: InstallOptions())
        #expect(byName.arguments == ["uninstall", "MultiTool"])
        #expect(byName.confirmation == CommandConfirmation(executable: mint, arguments: ["list"],
                                                           check: absent("MultiTool")))
        #expect(failure(absent("MultiTool"), try twoInks().stdout, try twoInksRepositories()) != nil)
        #expect(failure(absent("MultiTool"), try captured("t13-list-after-uninstall-name-multitool").stdout) == nil)
        // Both Inks' URLs have "Ink" in them, so Mint's uninstall would find two packages by that name (it did remove
        // the fork by name only once JohnSundell's was gone, `t13-uninstall-name-ink`).
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .remove, [tool("Ink")], options: InstallOptions())
        }
        // A name not in the last listing is never passed to Mint's uninstall.
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .remove, [tool("other-tool")], options: InstallOptions())
        }
    }

    /// Mint's uninstall removes the packages whose URL contains its argument. Removing by Mint's own name needs the one
    /// URL that contains it to be the package's own: `site.github.io.git` lists as `sitehub.io` (every ".git" taken
    /// out), so `sitehub.io` is in another package's URL and not in its own.
    @Test func removalByNameNeedsThePackagesOwnAddress() async throws {
        // Not a capture: two packages whose names only Mint's naming makes alike, made up to check the rule.
        let listing = "🌱 Installed mint packages:\n  sitehub.io\n    - 1.0.0 *\n  sitehub.io-cli\n    - 2.0.0 *\n"
        let urls = ["https://gitlab.com/a/site.github.io.git", "https://github.com/x/sitehub.io-cli.git"]
        let (engine, _, _) = try makeEngine([["list"]: CommandResult(exitCode: 0, stdout: listing, stderr: "")],
                                            metadata: .success(try metadata(urls)))
        #expect(try await engine.listInstalled().map(\.id.name) == ["sitehub.io", "x/sitehub.io-cli"])
        #expect(engine.unmapped["sitehub.io"] == MintEngine.notGitHub("sitehub.io"))
        let error = try #require(throws: EngineError.self) {
            _ = try engine.command(for: .remove, [tool("sitehub.io")], options: InstallOptions())
        }
        #expect(error.message.contains("sitehub.io"))
        #expect(!error.message.contains("gitlab"))
        // The other package is removed by its own URL, which no other URL contains.
        #expect(try engine.command(for: .remove, [tool("x/sitehub.io-cli")], options: InstallOptions()).arguments
                == ["uninstall", "https://github.com/x/sitehub.io-cli.git"])
    }

    /// The same rule for a removal by URL: `https://github.com/o/r.git` is also part of
    /// `https://github.com/o/r.github.io.git`, so Mint would match both and BrewxPort refuses. A URL that's in no other
    /// one, or a package Mint's metadata doesn't have, follow it too.
    @Test func removalByURLNeedsTheOnlyMatchToBeItsOwn() throws {
        let (both, _, _) = try makeEngine([:], metadata: .success(try metadata(
            ["https://github.com/o/r.git", "https://github.com/o/r.github.io.git"])))
        func remove(_ engine: MintEngine, _ name: String) throws -> [String] {
            try engine.command(for: .remove, [tool(name)], options: InstallOptions()).arguments
        }
        let error = try #require(throws: EngineError.self) { _ = try remove(both, "o/r") }
        #expect(error.message.contains("would also match another package"))
        #expect(!error.message.contains("https://"))
        #expect(try remove(both, "o/r.github.io") == ["uninstall", "https://github.com/o/r.github.io.git"])
        // Not in Mint's metadata, or no metadata to check against: nothing to match safely.
        #expect(throws: EngineError.self) { _ = try remove(both, "o/q") }
        let (unknown, _, _) = try makeEngine([:], metadata: .success(nil))
        #expect(throws: EngineError.self) { _ = try remove(unknown, ink) }
        // GitHub's names ignore case, and so does Mint's match.
        let lowercased = try metadata(["https://github.com/johnsundell/ink.git"])
        let (cased, _, _) = try makeEngine([:], metadata: .success(lowercased))
        #expect(try remove(cased, ink) == ["uninstall", inkURL])
    }

    @Test func plainNamesAreSafeArguments() {
        for name in ["swift-tools", "sitehub.io", "_private", "a_b", "tool+1", "X9"] {
            #expect(MintEngine.isPlainName(name), "\(name)")
        }
        for name in ["", "-x", ".hidden", "+x", "a b", "a/b", "a;b", "a$b", "é", "a`b`"] {
            #expect(!MintEngine.isPlainName(name), "\(name)")
        }
    }

    @Test func packageNamesOnlyFromPlainGitHubURLs() {
        #expect(MintEngine.packageName(repository: inkURL) == ink)
        #expect(MintEngine.packageName(repository: "https://github.com/apple/swift-format.git") == "apple/swift-format")
        // A URL with credentials, built in two parts so the repository check doesn't read it as an email address.
        let withCredentials = "https://user:token" + "@github.com/JohnSundell/Ink.git"
        for other in ["https://github.com/JohnSundell/Ink", "git@github.com:JohnSundell/Ink.git",
                      withCredentials, "https://github.com/a/b/c.git",
                      "https://github.com/evil/github.com.git", "https://GitHub.com/JohnSundell/Ink.git",
                      "https://github.com/a/.git", "https://github.com/.git", "http://github.com/a/b.git",
                      "https://gitlab.com/a/b.git", "https://github.com/-a/b.git"] {
            #expect(MintEngine.packageName(repository: other) == nil, "\(other)")
        }
        #expect(MintEngine.repositoryURL(ink) == inkURL)
    }

    /// Mint names a package by its URL's last part with every ".git" taken out.
    @Test func listNameFollowsMint() {
        #expect(MintEngine.listName(repository: inkURL) == "Ink")
        #expect(MintEngine.listName(repository: "https://github.com/someone/site.github.io.git") == "sitehub.io")
    }

    // MARK: tags

    @Test func tagsFromLsRemote() throws {
        let expected = ["0.1.0", "0.1.1", "0.1.2", "0.1.3", "0.2.0", "0.3.0", "0.4.0", "0.5.0", "0.5.1", "0.6.0"]
        #expect(MintEngine.tags(try captured("ls-remote-tags-refs").stdout) == expected)
        #expect(MintEngine.tags(try captured("ls-remote-tags").stdout) == expected)
    }

    /// Mint puts a tag into a bash command line (`git clone -b <tag>`), and git allows `$`, `;` and backticks in
    /// tag names: only tags of letters, digits and `._+-`, starting with a letter or digit, are kept.
    @Test func tagsMintCouldMisreadAreDropped() {
        // Not a capture: hostile and odd ref lines around one plain tag, made up on purpose (the real `v` tags are in
        // `mintReadsVTags`).
        let output = ["aaaa\trefs/tags/1.0.0;touch x", "bbbb\trefs/tags/$(touch x)", "cccc\trefs/tags/-1.0.0",
                      "dddd\trefs/tags/v2.0.0", "eeee\trefs/tags/v2.0.0^{}", "ffff\trefs/heads/main",
                      "0000\trefs/tags/1.0.0`id`", "1111\trefs/tags/.hidden", "2222 refs/tags/3.0.0",
                      "3333\trefs/tags/release/4.0.0", "4444\trefs/tags/2.1.0-beta.1+build.5"]
            .joined(separator: "\n")
        #expect(MintEngine.tags(output) == ["v2.0.0", "2.1.0-beta.1+build.5"])
        for safe in ["0.6.0", "v1.2.3", "1.0.0-rc.1", "swift-DEVELOPMENT-SNAPSHOT-2026-01-01-a", "1.0+build"] {
            #expect(MintEngine.isSafeTag(safe), "\(safe)")
        }
        for unsafe in ["", "-1.0", ".1.0", "1.0;x", "1.0 x", "1.0/x", "1.0$x", "a`b`", "1.0\nx", "é1.0"] {
            #expect(!MintEngine.isSafeTag(unsafe), "\(unsafe)")
        }
    }

    @Test func newestTagIsTheHighestStableOne() {
        #expect(MintEngine.newest(["0.1.0", "v1.2.0", "1.10.0", "1.9.0", "2.0.0-beta.1", "nightly"],
                                  includingPrereleases: false) == "1.10.0")
        #expect(MintEngine.newest(["1.0.0", "2.0.0-beta.1"], includingPrereleases: true) == "2.0.0-beta.1")
        #expect(MintEngine.newest(["2.0.0-beta.1", "swift-DEVELOPMENT-SNAPSHOT-2026-01-01-a"],
                                  includingPrereleases: false) == nil)
        #expect(MintEngine.newest([], includingPrereleases: false) == nil)
    }

    // MARK: outdated

    @Test func outdatedLooksTagsUpWithHardenedGit() async throws {
        let (engine, runner, _) = try makeEngine([["list"]: try captured("list-final"),
                                                  lsRemote(ink): try captured("ls-remote-tags-refs")])
        #expect(try await engine.listOutdated() == [
            Package(id: tool(ink), displayName: ink, installedVersion: "0.5.0", latestVersion: "0.6.0")])
        #expect(engine.couldntCheck.isEmpty)
        #expect(runner.calls == [["list"], lsRemote(ink)])
        #expect(runner.executableCalls == [mint, git])
        let options = runner.optionsCalls[1]
        // R21: only the base environment and git's five variables; no Mint folders, no NO_COLOR, no login shell. HOME
        // and XDG_CONFIG_HOME point at an empty folder too, for a git older than 2.32 that ignores GIT_CONFIG_GLOBAL.
        #expect(options.environment == base.merging([
            "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false", "HOME": "/var/empty",
            "XDG_CONFIG_HOME": "/var/empty"]) { $1 })
        #expect(options.environment?["HOME"] == "/var/empty")
        // R25: from `/`, outside any repository.
        #expect(options.timeout == BrewxPortTimeouts.registryQuery)
        #expect(options.workingDirectory == "/")
    }

    @Test func upToDateToolsAreNotOffered() async throws {
        let (engine, _, _) = try makeEngine([["list"]: try captured("list-two-versions"),
                                             lsRemote(ink): try captured("ls-remote-tags-refs")])
        #expect(try await engine.listOutdated().isEmpty)
        #expect(engine.couldntCheck.isEmpty)
    }

    /// R6: a tool whose tag lookup failed is named in the check's report (git didn't answer for it), and the others'
    /// updates stand. Not a capture: `threeFromGitHub`, and a newer tag for two of its repositories.
    @Test func checkNamesWhatItCouldntLookUp() async throws {
        let newer = CommandResult(exitCode: 0, stdout: "aaaa\trefs/tags/9.0.0\n", stderr: "")
        let listing = CommandResult(exitCode: 0, stdout: threeFromGitHub, stderr: "")
        let (engine, _, _) = try makeEngine([["list"]: listing, lsRemote(ink): newer,
                                             lsRemote("realm/SwiftLint"): newer],
                                            metadata: .success(try metadata(threeFromGitHubRepositories)))
        let report = try await engine.checkOutdated()
        #expect(report.packages.map(\.id.name) == [ink, "realm/SwiftLint"])
        #expect(report.unchecked.names == ["someone/Ink"])
        #expect(report.unchecked.reasons == engine.couldntCheck)
        #expect(report.held.isEmpty)
    }

    @Test func nothingInstalledLooksNothingUp() async throws {
        let (engine, runner, _) = try makeEngine([["list"]: try captured("list-empty")])
        #expect(try await engine.listOutdated().isEmpty)
        #expect(runner.calls == [["list"]])
    }

    /// Each tool's tags against its installed version, by semver; a pre-release only for a pre-release, and the
    /// tag's own text (`v1.1.0`) is what's offered. A lookup that failed is that tool's alone (R6).
    @Test func updatesFollowSemverAndKeepFailuresPerTool() throws {
        let tools = [MintEngine.Tool(name: "someone/stable", version: "1.0.0", executables: nil),
                     MintEngine.Tool(name: "someone/beta", version: "1.2.0-beta.0", executables: nil),
                     MintEngine.Tool(name: "someone/latest", version: "v2.0.0", executables: nil),
                     MintEngine.Tool(name: "someone/gone", version: "1.0.0", executables: nil)]
        let tags: [String: Result<[String], any Error>] = [
            "someone/stable": .success(["0.9.0", "v1.1.0", "1.2.0-beta.1"]),
            "someone/beta": .success(["1.1.0", "1.2.0-beta.1"]),
            "someone/latest": .success(["1.0.0", "2.0.0"]),
            "someone/gone": .failure(EngineError(engine: .mint, message: "GitHub has no public repository")),
        ]
        let check = try MintEngine.updates(tools, tags: tags)
        #expect(check.updates.map(\.id.name) == ["someone/beta", "someone/stable"])
        #expect(check.couldntCheck.keys.sorted() == ["someone/gone"])
        #expect(check.updates.map(\.latestVersion) == ["1.2.0-beta.1", "v1.1.0"])
        #expect(check.updates.map(\.installedVersion) == ["1.2.0-beta.0", "1.0.0"])
        #expect(check.couldntCheck == ["someone/gone": "GitHub has no public repository"])

        let none: [String: Result<[String], any Error>] = ["someone/gone": .failure(Unreadable())]
        #expect(throws: EngineError.self) { _ = try MintEngine.updates([tools[3]], tags: none) }
    }

    /// A branch or commit install (`@main`) has no version to compare, so it's never looked up.
    @Test func onlyVersionedToolsAreChecked() {
        let tools = [MintEngine.Tool(name: "someone/a", version: "main", executables: nil),
                     MintEngine.Tool(name: "someone/b", version: "1.0.0", executables: nil),
                     MintEngine.Tool(name: "someone/c", version: "1.0.0", executables: nil,
                                     unmapped: MintEngine.notLinked("someone/c")),
                     MintEngine.Tool(name: "someone/d", version: nil, executables: nil)]
        #expect(MintEngine.checkable(tools).map(\.name) == ["someone/b"])
    }

    @Test func failedLookupsMeanCouldntCheck() async throws {
        let (unknown, _, _) = try makeEngine([["list"]: try captured("list-final"),
                                              lsRemote(ink): try captured("ls-remote-unknown-repo")])
        let error = try await #require(throws: EngineError.self) { _ = try await unknown.listOutdated() }
        #expect(error.message.contains("couldn't check"))
        #expect(error.message.contains("JohnSundell/Ink"))

        let (offline, _, _) = try makeEngine([["list"]: try captured("list-final"),
                                              lsRemote(ink): try captured("ls-remote-network-refused")])
        let refused = try await #require(throws: EngineError.self) { _ = try await offline.listOutdated() }
        #expect(refused.message.contains("Couldn't connect to server"))

        let (noGit, runner, _) = try makeEngine([["list"]: try captured("list-final")], git: nil)
        let missing = try await #require(throws: EngineError.self) { _ = try await noGit.listOutdated() }
        #expect(missing.message.contains("git"))
        #expect(runner.calls == [["list"]])

        let fake = FakeRunner([["list"]: try captured("list-final")])
        let (slow, _, _) = try makeEngine([:], runner: FailingGit(fake, .timedOut(.seconds(10))))
        let timedOut = try await #require(throws: EngineError.self) { _ = try await slow.listOutdated() }
        #expect(timedOut.message.contains("didn't answer within 10 seconds"))
    }

    @Test func unknownRepositorySaysSo() throws {
        let error = MintEngine.lookupFailure(ink, try captured("ls-remote-unknown-repo"))
        #expect(error.message == "GitHub has no public repository named JohnSundell/Ink.")
        // The hardened lookup (R21) says `unable to read askpass response` first, then the same words
        // (`t13-ls-remote-hardened-unknown`, exit 128); a refused network is git's own words
        // (`t13-ls-remote-hardened-network-refused`).
        let hardened = try captured("t13-ls-remote-hardened-unknown")
        #expect(hardened.stderr.contains("askpass"))
        #expect(MintEngine.lookupFailure(ink, hardened).message
                == "GitHub has no public repository named JohnSundell/Ink.")
        let refused = MintEngine.lookupFailure(ink, try captured("t13-ls-remote-hardened-network-refused"))
        #expect(refused.message.hasPrefix("git couldn't list the tags of JohnSundell/Ink (exit 128): "))
    }

    /// The hardened lookup answers as before (`t13-ls-remote-hardened-ink`). R.swift's tags mix `v`-prefixed older
    /// ones with plain ones, some not semver (`v1.0.0.beta.1`): the newest stable is the plain 7.8.0
    /// (`t13-ls-remote-hardened-v-tags`).
    @Test func mintReadsVTags() throws {
        #expect(MintEngine.tags(try captured("t13-ls-remote-hardened-ink").stdout)
                == MintEngine.tags(try captured("ls-remote-tags-refs").stdout))
        let tags = MintEngine.tags(try captured("t13-ls-remote-hardened-v-tags").stdout)
        #expect(tags.contains("v6.1.0") && tags.contains("7.8.0") && tags.contains("v1.0.0.beta.1"))
        #expect(MintEngine.newest(tags, includingPrereleases: false) == "7.8.0")
    }

    // MARK: search

    @Test func searchFindsAnOwnerRepoByItsNewestTag() async throws {
        let (engine, runner, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-tags-refs")])
        #expect(try await engine.search(" JohnSundell/Ink ") == [
            Package(id: tool(ink), displayName: ink, latestVersion: "0.6.0")])
        #expect(runner.calls == [lsRemote(ink)])
        #expect(runner.executableCalls == [git])
    }

    @Test func searchTakesOnlyOwnerRepo() async throws {
        let (engine, runner, _) = try makeEngine([:])
        for query in ["SwiftLint", "https://github.com/JohnSundell/Ink", "evil/github.com", "-x/y", "a/b/c",
                      "JohnSundell/Ink@0.6.0"] {
            #expect(try await engine.search(query).isEmpty, "\(query)")
        }
        #expect(runner.calls.isEmpty)
        await #expect(throws: EngineError.self) { _ = try await engine.search("  ") }
    }

    @Test func searchWithoutATagOrAnAnswerFindsNothing() async throws {
        let (unknown, _, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-unknown-repo")])
        #expect(try await unknown.search(ink).isEmpty)
        // Not a capture: a repository whose only tags aren't stable versions (every captured repository has one).
        let odd = CommandResult(exitCode: 0, stdout: "aaaa\trefs/tags/2.0.0-beta.1\nbbbb\trefs/tags/nightly\n",
                                stderr: "")
        let (untagged, _, _) = try makeEngine([lsRemote(ink): odd])
        #expect(try await untagged.search(ink).isEmpty)
        let (noGit, _, _) = try makeEngine([:], git: nil)
        #expect(try await noGit.search(ink).isEmpty)
    }

    // MARK: commands

    @Test func installUsesTheTagDiscoverFound() async throws {
        let (engine, runner, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-tags-refs")])
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool(ink)], options: InstallOptions())
        }
        _ = try await engine.search(ink)
        let spec = try engine.command(for: .install, [tool(ink)], options: InstallOptions())
        #expect(spec.executable == mint)
        #expect(spec.arguments == ["install", "--overwrite", "n", "JohnSundell/Ink@0.6.0"])
        #expect(!spec.needsRoot)
        #expect(spec.environment?["NO_COLOR"] == "1")
        #expect(spec.environment?["GIT_TERMINAL_PROMPT"] == nil)
        #expect(spec.workingDirectory == "/Users/someone")
        #expect(spec.confirmation == CommandConfirmation(executable: mint, arguments: ["list"],
                                                         check: linked(ink, "0.6.0")))
        #expect(engine.privilege(for: .install, tool(ink)) == .never)
        #expect(runner.calls == [lsRemote(ink)])
    }

    /// R49: a package's name takes "'s" whatever its last letter ("devtools's versions"); only a package manager's
    /// name ending in "s" takes the apostrophe alone.
    @Test func packageNameEndingInSTakesApostropheS() throws {
        let (engine, _, _) = try makeEngine([:])
        let error = try #require(throws: EngineError.self) {
            _ = try engine.command(for: .install, [tool("someone/devtools")], options: InstallOptions())
        }
        let expected = "BrewxPort hasn't looked up someone/devtools's versions on GitHub, so it doesn't know which to "
            + "install. Find it in Discover first."
        #expect(error.message == expected)
    }

    @Test func upgradeUsesTheNewerTagTheCheckFound() async throws {
        let (engine, _, _) = try makeEngine([["list"]: try captured("list-final"),
                                             lsRemote(ink): try captured("ls-remote-tags-refs")])
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .upgrade, [tool(ink)], options: InstallOptions())
        }
        _ = try await engine.listOutdated()
        let spec = try engine.command(for: .upgrade, [tool(ink)], options: InstallOptions())
        #expect(spec.arguments == ["install", "--overwrite", "n", "JohnSundell/Ink@0.6.0"])
        #expect(spec.confirmation?.check == linked(ink, "0.6.0"))

        // A check that found nothing newer leaves nothing to upgrade to.
        let (current, _, _) = try makeEngine([["list"]: try captured("list-two-versions"),
                                              lsRemote(ink): try captured("ls-remote-tags-refs")])
        _ = try await current.listOutdated()
        #expect(throws: EngineError.self) {
            _ = try current.command(for: .upgrade, [tool(ink)], options: InstallOptions())
        }
    }

    /// An update picked from the rows a check gave keeps its tag while the next check runs (a background check, Check
    /// Now); a check that fails as a whole leaves nothing to upgrade to.
    @Test func upgradeTagsLastUntilTheNextCheckEnds() async throws {
        let fake = FakeRunner([["list"]: try captured("list-final"),
                               lsRemote(ink): try captured("ls-remote-tags-refs")])
        let gate = HeldGit(fake)
        let (engine, _, _) = try makeEngine([:], runner: gate)
        _ = try await engine.listOutdated()
        let second = Task { try await engine.listOutdated() }
        await gate.waitUntilHeld()
        let spec = try engine.command(for: .upgrade, [tool(ink)], options: InstallOptions())
        #expect(spec.arguments == ["install", "--overwrite", "n", "JohnSundell/Ink@0.6.0"])
        gate.releaseHeld()
        #expect(try await second.value.map(\.latestVersion) == ["0.6.0"])

        let failing = QueuedGit(FakeRunner([["list"]: try captured("list-final")]),
                                [try captured("ls-remote-tags-refs"), try captured("ls-remote-unknown-repo")])
        let (failed, _, _) = try makeEngine([:], runner: failing)
        _ = try await failed.listOutdated()
        #expect(try failed.command(for: .upgrade, [tool(ink)], options: InstallOptions()).arguments.last
                == "JohnSundell/Ink@0.6.0")
        await #expect(throws: EngineError.self) { _ = try await failed.listOutdated() }
        #expect(throws: EngineError.self) {
            _ = try failed.command(for: .upgrade, [tool(ink)], options: InstallOptions())
        }
    }

    @Test func removeNamesTheRepositoryURL() throws {
        let (engine, _, _) = try makeEngine([:])
        let spec = try engine.command(for: .remove, [tool(ink)], options: InstallOptions())
        #expect(spec.arguments == ["uninstall", inkURL])
        #expect(spec.confirmation == CommandConfirmation(executable: mint, arguments: ["list"],
                                                         check: absent(ink)))
    }

    @Test func commandsRefuseWhatMintCannotDo() async throws {
        let (engine, _, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-tags-refs"),
                                             lsRemote("JohnSundell/Plot"): try captured("ls-remote-tags-refs")])
        _ = try await engine.search(ink)
        _ = try await engine.search("JohnSundell/Plot")
        let refused: [(PackageOperation, [PackageRef], InstallOptions)] = [
            (.install, [], InstallOptions()),
            (.install, [tool(ink), tool("JohnSundell/Plot")], InstallOptions()),
            (.remove, [tool(ink), tool("JohnSundell/Plot")], InstallOptions()),
            (.install, [PackageRef(engine: .cargo, kind: .tool, name: ink)], InstallOptions()),
            (.install, [PackageRef(engine: .mint, kind: .formula, name: ink)], InstallOptions()),
            (.install, [tool(ink)], InstallOptions(version: "0.5.0")),
            (.install, [tool(ink)], InstallOptions(variants: ["+x"])),
            (.install, [tool(ink)], InstallOptions(extraArgs: ["--verbose"])),
            (.remove, [tool("SwiftLint")], InstallOptions()),
            (.remove, [tool("evil/github.com")], InstallOptions()),
            (.markRequested, [tool(ink)], InstallOptions()),
            (.markDependency, [tool(ink)], InstallOptions()),
        ]
        for (operation, refs, options) in refused {
            #expect(throws: EngineError.self, "\(operation) \(refs) \(options)") {
                _ = try engine.command(for: operation, refs, options: options)
            }
        }
    }

    // MARK: confirming a change

    @Test func confirmationReadsMintsList() throws {
        let inkLinked = linked(ink, "0.6.0")
        #expect(failure(inkLinked, try captured("list-two-versions").stdout) == nil)
        #expect(failure(inkLinked, try captured("list-relinked-old").stdout) != nil)
        #expect(failure(inkLinked, try captured("list-final").stdout) != nil)
        #expect(failure(linked(ink, "0.5.0"), try captured("list-relinked-old").stdout) == nil)
        // GitHub's names ignore case, and so does Mint's.
        #expect(failure(linked("johnsundell/ink", "0.6.0"), try captured("list-two-versions").stdout) == nil)

        let inkAbsent = absent(ink)
        #expect(failure(inkAbsent, try captured("list-after-uninstall").stdout) == nil)
        #expect(failure(inkAbsent, try captured("list-empty").stdout) == nil)
        #expect(failure(inkAbsent, try captured("list-final").stdout)?.contains(ink) == true)

        // Unreadable output never confirms anything.
        #expect(failure(inkLinked, "Error: something\n") != nil)
        #expect(failure(inkAbsent, "Error: something\n") != nil)
    }

    /// The check reads Mint's metadata from the path it was given, as the run does: the captured `metadata.json`
    /// names JohnSundell/Ink. Without the file, nothing that needs it is confirmed.
    @Test func confirmationReadsTheMetadataItNames() throws {
        let capturedPath = fixtures.appendingPathComponent("metadata.json").path
        let list = try captured("list-final").stdout
        #expect(ConfirmationCheck.mintLinked(package: ink, version: "0.5.0", metadata: capturedPath)
            .failure(in: list) == nil)
        #expect(ConfirmationCheck.mintLinked(package: ink, version: "0.5.0", metadata: "/nonexistent/metadata.json")
            .failure(in: list) != nil)
        #expect(ConfirmationCheck.mintAbsent(package: ink, metadata: "/nonexistent/metadata.json")
            .failure(in: list) != nil)
    }

    /// A package is matched by its identity: the URL Mint prints beside it, else the one metadata URL of its name. A
    /// same-named package from elsewhere never confirms a GitHub install, and never makes a removal look undone.
    @Test func confirmationMatchesThePackagesOwnRepository() throws {
        let list = try captured("list-final").stdout
        let elsewhere = ["https://gitlab.com/someone/Ink.git"]
        #expect(failure(linked(ink, "0.5.0"), list, elsewhere) != nil)
        #expect(failure(linked(ink, "0.5.0"), list, [inkURL]) == nil)
        #expect(failure(linked(ink, "0.5.0"), list, nil) != nil)
        #expect(failure(linked(ink, "0.5.0"), list, [inkURL, "https://gitlab.com/someone/Ink.git"]) != nil)
        #expect(failure(absent(ink), list, elsewhere) == nil)
        #expect(failure(absent(ink), list, [inkURL]) != nil)
        #expect(failure(absent(ink), list, nil) != nil)

        // When two packages share a name, Mint adds each one's URL: only the right one confirms (`t13-list-two-inks`:
        // JohnSundell's Ink at 0.5.0, a fork from a folder at 1.0.0).
        let twoInks = try twoInks().stdout
        let repositories = try twoInksRepositories()
        #expect(failure(linked(ink, "0.5.0"), twoInks, repositories) == nil)
        #expect(failure(linked(ink, "1.0.0"), twoInks, repositories) != nil)
        #expect(failure(absent("other/Ink"), twoInks, repositories) == nil)
        #expect(failure(absent(ink), twoInks, repositories) != nil)
        // MultiTool came from a folder, so it isn't someone/MultiTool, linked or not.
        #expect(failure(linked("someone/MultiTool", "1.1.0"), twoInks, repositories) != nil)
        #expect(failure(absent("someone/MultiTool"), twoInks, repositories) == nil)
        // Not a capture: `threeFromGitHub`, where a second GitHub Ink confirms by its own URL.
        #expect(failure(linked("someone/Ink", "1.0.0"), threeFromGitHub, threeFromGitHubRepositories) == nil)
        #expect(failure(absent("someone/Ink"), threeFromGitHub, threeFromGitHubRepositories) != nil)
    }

    /// Every executable of the version must be linked: with `--overwrite n`, Mint skips one that's in the way and
    /// still exits 0, and the list then marks only the others (`1.1.0 (multi-a *, multi-b)`,
    /// `t13-list-overwrite-n-skip` after `t13-install-overwrite-n-skip`). MultiTool is matched by Mint's own name
    /// (R24); with every executable linked (`t13-list-file-url`) it confirms, and so does a package listed without
    /// brackets (`t13-list-same-name-executable`).
    @Test func confirmationNeedsEveryExecutableLinked() throws {
        let skipped = try captured("t13-list-overwrite-n-skip").stdout
        let repositories = try MintEngine.repositories(metadata: try capturedData("t13-metadata-file-url.json"))
        #expect(failure(linked("MultiTool", "1.1.0"), skipped, repositories)
                == "Mint finished, but its list doesn't show MultiTool 1.1.0 linked.")
        #expect(failure(linked("MultiTool", "1.0.0"), try captured("t13-list-file-url").stdout, repositories) == nil)
        #expect(failure(linked(ink, "0.5.0"), skipped, repositories) == nil)
        #expect(failure(linked("solo", "1.0.0"), try captured("t13-list-same-name-executable").stdout, []) == nil)
    }

    // MARK: finding git

    /// R21: git from the login shell's PATH, then Homebrew's; Apple's `/usr/bin/git` only with the Command Line
    /// Tools, because without them it opens Apple's install dialog, even when it comes first on the login PATH.
    @Test func gitFromTheLoginPathThenFixedFoldersAndTheShimOnlyWithTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MintGit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String, withGit: Bool = true) throws -> String {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if withGit {
                let file = url.appendingPathComponent("git")
                // Never run: only its name and execute bit matter.
                try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            return url.path
        }
        let login = try folder("login"), brew = try folder("brew"), shim = try folder("shim")
        let empty = try folder("empty", withGit: false)
        func real(_ path: String) -> URL { URL(fileURLWithPath: ToolLocator.realPath(path)! + "/git") }
        func locate(_ loginPath: [String], _ fixed: [String], tools: Bool) async -> URL? {
            await MintEngine.locateGit(loginPath: loginPath, fixed: fixed, system: shim) { tools }
        }
        #expect(await locate([login], [brew], tools: false) == real(login))
        #expect(await locate([empty], [brew], tools: false) == real(brew))
        #expect(await locate([], [empty], tools: true) == real(shim))
        #expect(await locate([], [empty], tools: false) == nil)
        #expect(await locate([shim, empty], [brew], tools: true) == real(shim))
        #expect(await locate([shim, empty], [brew], tools: false) == real(brew))

        // A link to Apple's git elsewhere (`~/bin/git -> /usr/bin/git`) is Apple's git too: the git file's own
        // resolved folder decides, so it's gated the same way.
        let linked = try folder("linked", withGit: false)
        try FileManager.default.createSymbolicLink(atPath: linked + "/git", withDestinationPath: shim + "/git")
        let asked = Counter()
        let gated = await MintEngine.locateGit(loginPath: [linked], fixed: [brew], system: shim) {
            asked.add()
            return false
        }
        #expect(gated == real(brew))
        #expect(asked.count == 1)
        #expect(await locate([linked], [empty], tools: true) == real(linked))
        #expect(await locate([linked], [empty], tools: false) == nil)
    }

    @Test func commandLineToolsAskXcodeSelect() async {
        let present = FakeRunner([["-p"]: CommandResult(exitCode: 0, stdout: "/Library/Developer/CommandLineTools\n",
                                                        stderr: "")])
        #expect(await MintEngine.commandLineToolsPresent(runner: present, base: base))
        #expect(present.executableCalls == [URL(fileURLWithPath: "/usr/bin/xcode-select")])
        #expect(present.optionsCalls.first?.timeout == BrewxPortTimeouts.registryQuery)
        let absent = FakeRunner([["-p"]: CommandResult(exitCode: 2, stdout: "", stderr: "xcode-select: error")])
        #expect(await !MintEngine.commandLineToolsPresent(runner: absent, base: base))
        #expect(await !MintEngine.commandLineToolsPresent(runner: ThrowingRunner(), base: base))
    }

    // MARK: info

    @Test func infoFromTheListingAndTheLookups() async throws {
        let (engine, runner, _) = try makeEngine([["list"]: try captured("list-final"),
                                                  lsRemote(ink): try captured("ls-remote-tags-refs")])
        _ = try await engine.listOutdated()
        let details = try await engine.info(tool(ink))
        #expect(details == PackageDetails(ref: tool(ink), homepage: URL(string: "https://github.com/JohnSundell/Ink"),
                                          installedVersion: "0.5.0", latestVersion: "0.6.0",
                                          executables: ["ink-cli"]))
        #expect(runner.calls.count == 2)

        // Nothing known yet: the tags are looked up for the newest version.
        let (fresh, freshRunner, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-tags-refs")])
        let found = try await fresh.info(tool(ink))
        #expect(found.latestVersion == "0.6.0")
        #expect(found.installedVersion == nil)
        #expect(freshRunner.calls == [lsRemote(ink)])

        // A failed lookup still gives the repository's page.
        let (offline, _, _) = try makeEngine([lsRemote(ink): try captured("ls-remote-network-refused")])
        let page = try await offline.info(tool(ink))
        #expect(page.homepage == URL(string: "https://github.com/JohnSundell/Ink"))
        #expect(page.latestVersion == nil)

        await #expect(throws: EngineError.self) { _ = try await engine.info(tool("SwiftLint")) }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .cargo, kind: .tool, name: ink))
        }
    }
}
