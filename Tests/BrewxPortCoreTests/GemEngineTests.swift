import Foundation
import Testing
@testable import BrewxPortCore

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

/// One captured RubyGems command from `Fixtures/gem` (see its SOURCES.md): stdout from `NAME.json` or `NAME.txt`,
/// stderr from `NAME-stderr.txt`, the exit code from `NAME.exit`. A stream that was empty has no file.
private func captured(_ name: String) throws -> CommandResult {
    func read(_ file: String) -> String? {
        try? String(contentsOf: fixtures.appendingPathComponent("gem/" + file), encoding: .utf8)
    }
    let exit = try #require(read("\(name).exit"))
    let code = try #require(Int32(exit.trimmingCharacters(in: .whitespacesAndNewlines)))
    return CommandResult(exitCode: code, stdout: read("\(name).json") ?? read("\(name).txt") ?? "",
                         stderr: read("\(name)-stderr.txt") ?? "")
}

/// A captured file from `Fixtures/gem`, as text (a registry body).
private func capturedText(_ file: String) throws -> String {
    try String(contentsOf: fixtures.appendingPathComponent("gem/" + file), encoding: .utf8)
}

/// The lines of a `gem list --local` answer: each gem's versions, newest first, and which are default gems.
private func entries(_ text: String) -> [(name: String, versions: [(version: String, isDefault: Bool)])] {
    text.split(separator: "\n").compactMap { line in
        guard line.hasSuffix(")"), let open = line.range(of: " (") else { return nil }
        let inside = line[open.upperBound..<line.index(before: line.endIndex)]
        let versions = inside.split(separator: ",").map { part -> (version: String, isDefault: Bool) in
            var entry = part.trimmingCharacters(in: .whitespaces)
            let isDefault = entry.hasPrefix("default: ")
            if isDefault { entry = String(entry.dropFirst("default: ".count)) }
            return (String(entry.split(separator: " ")[0]), isDefault)
        }
        return (String(line[..<open.lowerBound]), versions)
    }
}

/// Not a capture: the answer `GemEngine.executablesScript` gives since R38. T13 captured the script's answer before
/// R38 (`t13-executables-script`, `readsTheCapturedExecutablesAnswer`), in three states only; on Homebrew's Ruby every
/// bundled gem with executables there also has a linked copy the old script called `user`, which the script now
/// calls `ruby` (checked on a real Ruby, `scriptsTellALinkedGemspecFromTheUsersCopy`). So the answer is built here,
/// for whatever listing a test uses. The script says whether gem installs outside Ruby's own gem folder (Homebrew's
/// Ruby does: in `environment.txt` the Cellar's gem folder is a gem path apart from the installation directory), then
/// prints `name (version) place` for every copy of each gem with executables. Built from a `gem list --local` answer
/// (`listing`) for the named gems, which are ones that have executables: a `default: ` version is `default`; a version
/// Ruby already had before anything was installed (the captured `list-local-empty.txt`) is `ruby`; any other is
/// `user`. `extra` lines go at the end. No Ruby that installs into its own gem folder (rbenv, asdf, mise, chruby) was
/// captured, so `separate: false` is made up the same way.
private func withExecutables(_ names: [String], listing: String, separate: Bool = true,
                             extra: [String] = []) throws -> CommandResult {
    let rubys = Set(entries(try captured("list-local-empty").stdout).flatMap { gem in
        gem.versions.map { "\(gem.name) \($0.version)" }
    })
    var lines = [separate ? "ruby-gems-separate" : "ruby-gems-shared"]
    for gem in entries(listing) where names.contains(gem.name) {
        for (version, isDefault) in gem.versions {
            let place = isDefault ? "default" : (rubys.contains("\(gem.name) \(version)") ? "ruby" : "user")
            lines.append("\(gem.name) (\(version)) \(place)")
        }
    }
    return CommandResult(exitCode: 0, stdout: (lines + extra).map { $0 + "\n" }.joined(), stderr: "")
}

/// `withExecutables` for a captured `gem list --local` (`list`).
private func withExecutables(_ names: [String], from list: String = "list-local-final",
                             separate: Bool = true) throws -> CommandResult {
    try withExecutables(names, listing: try captured(list).stdout, separate: separate)
}

/// Gems that have executables, among the captured list's: the one list demo mode uses too.
private let gemsWithExecutables = Array(GemEngine.capturedGemsWithExecutables)

/// macOS's own Ruby 2.6's gem folder, and a gem with an executable in it, for the real-Ruby check of R38.
private let appleOwnGems = "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/lib/ruby/gems/2.6.0"
private let appleNokogiri = appleOwnGems + "/specifications/nokogiri-1.13.8.gemspec"

private let gem = URL(fileURLWithPath: "/opt/homebrew/bin/gem")
private let ruby = URL(fileURLWithPath: "/opt/homebrew/bin/ruby")
private let base = [
    "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8", "HOME": "/Users/someone", "USER": "someone", "NONINTERACTIVE": "1",
]
private let listArguments = ["list", "--local"]
private let scriptArguments = ["-e", GemEngine.executablesScript]
private let environmentArguments = ["environment"]
private let outdatedArguments = ["outdated"]

private func indexURL(_ name: String) -> String { "https://index.rubygems.org/info/\(name)" }

private func tool(_ name: String) -> PackageRef { PackageRef(engine: .gem, kind: .tool, name: name) }

/// The captured compact index answers for lolcat and thor (any other gem is a 404).
private func capturedIndex() throws -> FakeRegistryFetch {
    FakeRegistryFetch(bodies: [indexURL("lolcat"): try capturedText("index-info-lolcat.txt"),
                               indexURL("thor"): try capturedText("index-info-thor.txt")])
}

/// `capturedIndex`, with the lookups of `uncaptured` gems timing out. Not a capture: they're on RubyGems.org, but
/// their answers weren't captured, so they're tools the check couldn't look up (R6), not ones RubyGems.org hasn't got.
private func capturedIndex(timingOut uncaptured: [String]) throws -> FakeRegistryFetch {
    var answers: [String: Result<Data, Error>] = [
        indexURL("lolcat"): .success(Data(try capturedText("index-info-lolcat.txt").utf8)),
        indexURL("thor"): .success(Data(try capturedText("index-info-thor.txt").utf8)),
    ]
    for name in uncaptured { answers[indexURL(name)] = .failure(URLError(.timedOut)) }
    return FakeRegistryFetch(answers)
}

private func engine(_ responses: [[String]: CommandResult], script: CommandResult? = nil,
                    executable: URL? = gem, registry: FakeRegistryFetch = FakeRegistryFetch())
    -> (GemEngine, FakeRunner) {
    var byExecutable: [String: [[String]: CommandResult]] = [:]
    if let script { byExecutable["ruby"] = [scriptArguments: script] }
    let runner = FakeRunner(responses, byExecutable: byExecutable)
    return (GemEngine(runner: runner, registry: registry, executable: executable, base: base), runner)
}

/// The Homebrew Ruby of the captures, as `gem environment` described it.
private let homebrewRuntime = GemEngine.Runtime(ruby: "4.0.10", rubyGems: "4.1.0", platforms: ["ruby", "arm64-darwin-24"])

private func gemRow(_ name: String, _ version: String) -> GemEngine.Gem {
    GemEngine.Gem(name: name, version: version)
}

private struct Unrelated: Error, Equatable {}

/// A `CommandRunning` whose answers, keyed by arguments, come in order; the last one repeats. Unknown argv exits 127.
private final class SequenceRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]: [CommandResult]]

    init(_ answers: [[String]: [CommandResult]]) { self.answers = answers }

    func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        lock.withLock {
            guard var queue = answers[arguments], let first = queue.first else {
                return CommandResult(exitCode: 127, stdout: "", stderr: "SequenceRunner: no answer for \(arguments)")
            }
            if queue.count > 1 { queue.removeFirst() }
            answers[arguments] = queue
            return first
        }
    }

    func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        try await run(executable, arguments, options: options).exitCode
    }
}

@Suite struct GemEngineTests {
    // MARK: detect

    /// RubyGems' version, then what `gem environment` says: the gem folder, the executables' folder and which Ruby.
    @Test func detectsVersionFoldersAndRuby() async throws {
        let (found, runner) = engine([["--version"]: try captured("version"),
                                      environmentArguments: try captured("environment")])
        #expect(found.installLocation == nil)
        #expect(found.rubySource == nil)
        #expect(await found.detect() == .present(path: gem, version: "4.1.0"))
        #expect(runner.calls == [["--version"], environmentArguments])
        #expect(found.installLocation == URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems/4.0.0", isDirectory: true))
        #expect(found.binLocation == URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems/4.0.0/bin", isDirectory: true))
        #expect(found.rubySource == .homebrew)
        #expect(found.rubyVersion == "4.0.10")
    }

    /// A `gem environment` that fails or says nothing BrewxPort reads leaves RubyGems present, without folders; which
    /// Ruby it is still follows from where gem is.
    @Test func environmentGemDoesntGiveLeavesGemPresent() async throws {
        for answer in [CommandResult(exitCode: 1, stdout: "", stderr: "ERROR: boom"),
                       CommandResult(exitCode: 0, stdout: "something else\n", stderr: "")] {
            let (found, _) = engine([["--version"]: try captured("version"), environmentArguments: answer])
            #expect(await found.detect() == .present(path: gem, version: "4.1.0"))
            #expect(found.installLocation == nil)
            #expect(found.binLocation == nil)
            #expect(found.rubySource == .homebrew)
            #expect(found.rubyVersion == nil)
        }
    }

    @Test func detectMissingWithoutExecutable() async {
        let (missing, runner) = engine([:], executable: nil)
        #expect(await missing.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(missing.rubySource == nil)
    }

    @Test func detectUnusableWhenVersionFailsOrIsntOne() async throws {
        let (failing, _) = engine([["--version"]: CommandResult(exitCode: 1, stdout: "", stderr: "boom")])
        #expect(isUnusable(await failing.detect(), at: gem))
        let (garbled, runner) = engine([["--version"]: CommandResult(exitCode: 0, stdout: "gem\n", stderr: "")])
        #expect(isUnusable(await garbled.detect(), at: gem))
        // Nothing else is asked of a gem that doesn't answer.
        #expect(runner.calls == [["--version"]])
        #expect(garbled.rubySource == nil)
    }

    /// R2: RubyGems versions can have four parts (Apple's Ruby has one). Built in code so the repository's address
    /// check doesn't read it as one.
    @Test func fourPartRubyGemsVersionIsAVersion() async throws {
        let version = "3.0.3" + ".1"
        let (found, _) = engine([["--version"]: CommandResult(exitCode: 0, stdout: version + "\n", stderr: ""),
                                 environmentArguments: CommandResult(exitCode: 1, stdout: "", stderr: "")])
        #expect(await found.detect() == .present(path: gem, version: version))
    }

    /// Every line of the captured `gem environment` that BrewxPort uses.
    @Test func readsTheEnvironment() throws {
        let environment = try #require(GemEngine.environment(try captured("environment").stdout))
        #expect(environment.rubyGemsVersion == "4.1.0")
        #expect(environment.rubyVersion == "4.0.10")
        #expect(environment.installDirectory == "/opt/homebrew/lib/ruby/gems/4.0.0")
        #expect(environment.executableDirectory == "/opt/homebrew/lib/ruby/gems/4.0.0/bin")
        #expect(environment.rubyExecutable == "/opt/homebrew/opt/ruby/bin/ruby")
        #expect(environment.platforms == ["ruby", "arm64-darwin-24"])
        #expect(GemEngine.environment("") == nil)
    }

    /// Which Ruby gem belongs to, from its Ruby's path first, then gem's own. Apple's is `.system`: Task 10 turns its
    /// actions off.
    @Test func tellsWhichRuby() {
        let home = "/Users/someone"
        func source(_ gem: String, _ ruby: String? = nil) -> GemEngine.RubySource {
            GemEngine.rubySource(gem: gem, ruby: ruby, home: home)
        }
        #expect(source("/usr/bin/gem") == .system)
        #expect(source("/usr/bin/gem", "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/bin/ruby") == .system)
        #expect(source("/opt/homebrew/bin/gem", "/opt/homebrew/opt/ruby/bin/ruby") == .homebrew)
        #expect(source("/usr/local/bin/gem", "/usr/local/opt/ruby/bin/ruby") == .homebrew)
        #expect(source("/opt/homebrew/opt/ruby@3.4/bin/gem") == .homebrew)
        #expect(source("/opt/local/bin/gem", "/opt/local/bin/ruby4.0") == .macports)
        #expect(source(home + "/.rbenv/shims/gem", home + "/.rbenv/versions/3.4.1/bin/ruby") == .rbenv)
        #expect(source(home + "/.asdf/shims/gem", home + "/.asdf/installs/ruby/3.4.1/bin/ruby") == .asdf)
        #expect(source(home + "/.local/share/mise/shims/gem", home + "/.local/share/mise/installs/ruby/3.4/bin/ruby")
                == .mise)
        #expect(source(home + "/.rubies/ruby-3.4.1/bin/gem") == .chruby)
        #expect(source("/opt/rubies/ruby-3.4.1/bin/gem") == .chruby)
        #expect(source("/Users/someone/tools/bin/gem") == .other)
        // The Ruby decides: rbenv's shim set to `system` runs Homebrew's Ruby, whose gem folder that is.
        #expect(source(home + "/.rbenv/shims/gem", "/opt/homebrew/opt/ruby/bin/ruby") == .homebrew)
        // A relative or missing Ruby path is ignored.
        #expect(source("/usr/bin/gem", "ruby") == .system)
    }

    /// Every RubyGems command, and the `ruby` beside gem, runs with gem's own folder first on PATH, only RubyGems'
    /// login-shell variables and NO_COLOR, from the home folder.
    @Test func commandsRunWithGemsEnvironmentFromHome() async throws {
        let own = URL(fileURLWithPath: "/Users/someone/.rbenv/shims/gem")
        let runner = FakeRunner([["--version"]: try captured("version"), environmentArguments: try captured("environment"),
                                 listArguments: try captured("list-local-final")],
                                byExecutable: ["ruby": [scriptArguments: try withExecutables(["thor"])]])
        let captured = ["GEM_HOME": "/Users/someone/.gem", "GEM_PATH": "/Users/someone/.gem:/opt/gems",
                        "XDG_CACHE_HOME": "/Users/someone/.cache", "CARGO_HOME": "/Users/someone/.cargo",
                        "NVM_DIR": "/Users/someone/.nvm"]
        let engine = GemEngine(runner: runner, registry: FakeRegistryFetch(), executable: own, captured: captured,
                               base: base)
        _ = await engine.detect()
        _ = try await engine.listInstalled()
        #expect(runner.calls == [["--version"], environmentArguments, listArguments, scriptArguments])
        #expect(runner.executableCalls.last == URL(fileURLWithPath: "/Users/someone/.rbenv/shims/ruby"))
        for options in runner.optionsCalls {
            let env = try #require(options.environment)
            #expect(env["PATH"]?.hasPrefix("/Users/someone/.rbenv/shims:/opt/homebrew/bin:") == true)
            #expect(env["GEM_HOME"] == "/Users/someone/.gem")
            #expect(env["GEM_PATH"] == "/Users/someone/.gem:/opt/gems")
            #expect(env["XDG_CACHE_HOME"] == "/Users/someone/.cache")
            #expect(env["CARGO_HOME"] == nil)
            #expect(env["NVM_DIR"] == nil)
            #expect(env["NO_COLOR"] == "1")
            #expect(options.workingDirectory == "/Users/someone")
        }
    }

    // MARK: finding gem

    @Test func liveEngineUsesTheLoginShellsCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-gem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".rbenv/shims")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("gem")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let realBin = try #require(ToolLocator.realPath(bin.path))

        let runner = FakeRunner([["--version"]: try captured("version")])
        let context = LoginShellContext(path: ["/nonexistent-brewxport/bin", bin.path],
                                        environment: ["GEM_HOME": root.path + "/.gem"])
        // The captured folders are the VM's: this test is about finding gem, so they count as writable.
        let engine = GemEngine(runner: runner, registry: FakeRegistryFetch(), loginShell: { context }, arch: .arm64,
                               base: base, isWritable: { _ in true })
        #expect(engine.executableURL == nil)
        #expect(await engine.detect() == .present(path: URL(fileURLWithPath: realBin + "/gem"), version: "4.1.0"))
        #expect(engine.executableURL?.path == realBin + "/gem")
        #expect(runner.optionsCalls.first?.environment?["GEM_HOME"] == root.path + "/.gem")
        let spec = try engine.command(for: .install, [tool("thor")], options: InstallOptions())
        #expect(spec.executable.path == realBin + "/gem")
    }

    @Test func liveEngineWithoutGemIsMissing() async {
        let runner = FakeRunner([:])
        let engine = GemEngine(runner: runner, registry: FakeRegistryFetch(),
                               loginShell: { LoginShellContext(path: ["/nonexistent-brewxport/bin"], environment: [:]) },
                               arch: .arm64, base: base, fixedFolders: { _ in ["/nonexistent-brewxport/fixed"] })
        #expect(await engine.detect() == .missing)
        #expect(runner.calls.isEmpty)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("thor")], options: InstallOptions()) }
    }

    /// Homebrew's Ruby (this Mac's prefix first, and the keg-only formula's folder), MacPorts', the version managers'
    /// shims, and Apple's Ruby last.
    @Test func fixedFoldersPutTheMachinesHomebrewFirstAndAppleLast() {
        let arm = GemEngine.fixedFolders(arch: .arm64, home: "/Users/someone", captured: [:])
        #expect(arm == ["/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/ruby/bin", "/usr/local/opt/ruby/bin",
                        "/opt/local/bin", "/Users/someone/.rbenv/shims", "/Users/someone/.asdf/shims",
                        "/Users/someone/.local/share/mise/shims", "/usr/bin"])
        let intel = GemEngine.fixedFolders(arch: .x86_64, home: "/Users/someone", captured: [:])
        #expect(Array(intel.prefix(2)) == ["/usr/local/bin", "/opt/homebrew/bin"])
        #expect(intel.last == "/usr/bin")
    }

    /// R30: the Ruby a gem's own path says it belongs to, as the app reads it to offer Homebrew's Ruby beside macOS's
    /// or MacPorts' (both read-only).
    @Test func rubySourceFromTheGemPathAlone() {
        #expect(GemEngine.rubySource(gemPath: "/usr/bin/gem") == .system)
        #expect(GemEngine.rubySource(gemPath: "/opt/local/bin/gem") == .macports)
        #expect(GemEngine.rubySource(gemPath: "/opt/homebrew/bin/gem") == .homebrew)
        #expect(GemEngine.rubySource(gemPath: "/opt/homebrew/Cellar/ruby/4.0.10/bin/gem") == .homebrew)
        #expect(GemEngine.rubySource(gemPath: "/Users/someone/.rbenv/shims/gem", home: "/Users/someone") == .rbenv)
        #expect(GemEngine.rubySource(gemPath: "/somewhere/else/gem") == nil)
    }

    // MARK: installed

    /// R18: gems that come with Ruby aren't tools. Of the captured list's gems with executables, bundler and erb are
    /// default gems, and irb, rake, rbs, rdoc and typeprof are bundled, at the version Ruby put in its own gem folder;
    /// only lolcat and thor were installed. The bundled ones are in `gem outdated` (rbs 3.10.0 < 4.2.0, a major), but
    /// they're never looked up, offered or updated.
    @Test func bundledGemsAtShippedVersionAreNotTools() async throws {
        let registry = try capturedIndex()
        let (engine, runner) = engine([listArguments: try captured("list-local-final"),
                                       outdatedArguments: try captured("outdated"),
                                       environmentArguments: try captured("environment")],
                                      script: try withExecutables(gemsWithExecutables), registry: registry)
        let rows = try await engine.listInstalled()
        #expect(rows.map(\.id.name) == ["lolcat", "thor"])
        #expect(rows.map(\.installedVersion) == ["100.0.0", "1.3.2"])
        #expect(rows.allSatisfy { $0.id.kind == .tool && $0.installedOnRequest == true })
        #expect(runner.calls == [listArguments, scriptArguments])
        #expect(runner.executableCalls == [gem, ruby])

        let named = GemEngine.outdatedNames(try captured("outdated").stdout)
        #expect(["irb", "rake", "rbs", "rdoc", "typeprof", "bundler"].allSatisfy(named.contains))
        #expect(try await engine.listOutdated().map(\.id.name) == ["lolcat", "thor"])
        #expect(Set(registry.requested.map(\.absoluteString)) == [indexURL("lolcat"), indexURL("thor")])
        #expect(engine.sharesRubysGemFolder == false)
        #expect(engine.shippedWithRuby.isEmpty)
        for name in ["debug", "irb", "racc", "rake", "rbs", "rdoc", "typeprof", "bundler", "erb"] {
            #expect(throws: EngineError.self, "\(name)") {
                _ = try engine.command(for: .upgrade, [tool(name)], options: InstallOptions())
            }
        }
    }

    /// R18: a newer copy the user installed beside Ruby's bundled one is a tool, at that version; so is a newer copy of
    /// a default gem, and a copy the user installed at the very version Ruby bundled. Not captures: list lines in
    /// RubyGems' `entry_versions` shape (like `list-local-two-versions.txt`).
    @Test func userInstalledNewerBundledGemIsATool() async throws {
        let list = try captured("list-local-final").stdout
            .replacingOccurrences(of: "rake (13.3.1)\n", with: "rake (13.4.2, 13.3.1)\n")
            .replacingOccurrences(of: "bundler (default: 4.1.0)\n", with: "bundler (4.1.1, default: 4.1.0)\n")
        let script = try withExecutables(gemsWithExecutables, listing: list, extra: ["rbs (3.10.0) user"])
        #expect(script.stdout.contains("rake (13.4.2) user\nrake (13.3.1) ruby\n"))
        let (engine, _) = engine([listArguments: CommandResult(exitCode: 0, stdout: list, stderr: "")],
                                 script: script)
        let rows = try await engine.listInstalled()
        #expect(rows.map(\.id.name) == ["bundler", "lolcat", "rake", "rbs", "thor"])
        #expect(rows.map(\.installedVersion) == ["4.1.1", "100.0.0", "13.4.2", "3.10.0", "1.3.2"])
        _ = try engine.command(for: .upgrade, [tool("rake")], options: InstallOptions())
    }

    /// When gem installs into Ruby's own gem folder (rbenv, asdf, mise, chruby), Ruby gives no way to tell its bundled
    /// copies from the user's: only default gems are left out.
    /// R19: when gem installs into Ruby's own gem folder (rbenv, asdf, mise, chruby), Ruby's bundled gems are listed
    /// (only default gems can be told apart there), and the ones in `bundledWithExecutables` are marked
    /// `shippedWithRuby`, which Task 10's hold-back reads to keep them out of automatic updates. They can still be
    /// updated by hand.
    @Test func sharedFolderBundledGemIsMarkedShippedWithRuby() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-final"),
                                  outdatedArguments: try captured("outdated"),
                                  environmentArguments: try captured("environment")],
                                 script: try withExecutables(gemsWithExecutables, separate: false),
                                 registry: try capturedIndex())
        #expect(engine.sharesRubysGemFolder == nil)
        #expect(try await engine.listInstalled().map(\.id.name)
                == ["debug", "irb", "lolcat", "minitest", "racc", "rake", "rbs", "rdoc", "test-unit", "thor",
                    "typeprof"])
        #expect(engine.sharesRubysGemFolder == true)
        #expect(engine.shippedWithRuby == ["debug", "irb", "minitest", "racc", "rake", "rbs", "rdoc", "test-unit",
                                           "typeprof"])
        #expect(engine.shippedWithRuby == GemEngine.bundledWithExecutables)
        let upgrade = try engine.command(for: .upgrade, [tool("rbs"), tool("thor")], options: InstallOptions())
        #expect(upgrade.arguments == ["update", "--remote", "--no-document", "rbs", "thor"])
        // The outdated check reads the listing it makes, and keeps the mark.
        _ = try await engine.listOutdated()
        #expect(engine.shippedWithRuby == GemEngine.bundledWithExecutables)
    }

    /// R19: an update of a gem that came with Ruby stays an update the person can pick, and is held back from automatic
    /// updates with why; the user's own tools aren't held. The captured listing and `gem outdated` in a shared folder;
    /// rake's index answer isn't captured, so it's named as not checked (R6), and thor's captured answer stands in for
    /// a bundled gem in the value check below.
    @Test func gemShippedWithRubyNotAutomatic() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-final"),
                                  outdatedArguments: try captured("outdated"),
                                  environmentArguments: try captured("environment")],
                                 script: try withExecutables(gemsWithExecutables, separate: false),
                                 registry: try capturedIndex(timingOut: ["irb", "rake", "rbs", "rdoc", "typeprof"]))
        let report = try await engine.checkOutdated()
        #expect(report.packages.map(\.id.name) == ["lolcat", "thor"])
        #expect(report.held.isEmpty)
        #expect(report.unchecked.names == ["irb", "rake", "rbs", "rdoc", "typeprof"])
        #expect(Set(engine.couldntCheck.keys) == Set(report.unchecked.names))

        // Values: thor's captured index for a gem that came with Ruby.
        let index: [String: Result<[GemEngine.IndexVersion], any Error>] = [
            "thor": .success(try #require(GemEngine.indexVersions(try capturedText("index-info-thor.txt")))),
            "lolcat": .success(try #require(GemEngine.indexVersions(try capturedText("index-info-lolcat.txt")))),
        ]
        let shipped = GemEngine.Gem(name: "thor", version: "1.3.2", shippedWithRuby: true)
        let check = try GemEngine.updates([gemRow("lolcat", "100.0.0"), shipped], index: index,
                                          runtime: homebrewRuntime)
        #expect(check.updates.map(\.id.name) == ["lolcat", "thor"])
        let thor = try #require(check.updates.last)
        #expect(check.held == [HeldUpdate(package: thor, hold: UpdateHold(
            reason: "Came with Ruby, so BrewxPort updates it only when you ask.", blocksAutomatic: true,
            blocksManual: false))])
    }

    /// R19: removing a bundled gem from a gem folder Ruby shares would remove Ruby's own copy (`--all`), so it's
    /// refused at plan time, alone or with others; the user's own tools still go.
    @Test func sharedFolderBundledGemUninstallRefused() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-final")],
                                 script: try withExecutables(gemsWithExecutables, separate: false))
        _ = try await engine.listInstalled()
        for refs in [[tool("rake")], [tool("thor"), tool("rbs")]] {
            do {
                _ = try engine.command(for: .remove, refs, options: InstallOptions())
                Issue.record("expected an error for \(refs)")
            } catch let error as EngineError {
                let name = refs.last!.name
                #expect(error.message == "\(name) came with Ruby; removing it would break Ruby's own copy.")
            }
        }
        let remove = try engine.command(for: .remove, [tool("thor"), tool("lolcat")], options: InstallOptions())
        #expect(remove.arguments == ["uninstall", "--all", "--executables", "--abort-on-dependent", "thor", "lolcat"])
    }

    /// R19 changes nothing when gem installs outside Ruby's own gem folder (Homebrew's Ruby): Ruby's copies aren't
    /// listed, nothing is marked, and a newer rake the user installed is an ordinary tool that can be removed.
    @Test func nonSharedFolderUnchanged() async throws {
        let list = try captured("list-local-final").stdout
            .replacingOccurrences(of: "rake (13.3.1)\n", with: "rake (13.4.2, 13.3.1)\n")
        let (engine, _) = engine([listArguments: CommandResult(exitCode: 0, stdout: list, stderr: "")],
                                 script: try withExecutables(gemsWithExecutables, listing: list))
        #expect(try await engine.listInstalled().map(\.id.name) == ["lolcat", "rake", "thor"])
        #expect(engine.sharesRubysGemFolder == false)
        #expect(engine.shippedWithRuby.isEmpty)
        let remove = try engine.command(for: .remove, [tool("rake")], options: InstallOptions())
        #expect(remove.arguments.last == "rake")
    }

    /// A check whose listing fails leaves no earlier per-tool "couldn't check" list behind.
    @Test func failedListingClearsCouldntCheck() async throws {
        let registry = FakeRegistryFetch([indexURL("lolcat"): .failure(URLError(.timedOut)),
                                          indexURL("thor"): .success(Data(try capturedText("index-info-thor.txt").utf8))])
        let runner = SequenceRunner([listArguments: [try captured("list-local-final"),
                                                     CommandResult(exitCode: 1, stdout: "", stderr: "ERROR: boom")],
                                     outdatedArguments: [try captured("outdated")],
                                     environmentArguments: [try captured("environment")],
                                     scriptArguments: [try withExecutables(["lolcat", "thor"])]])
        let engine = GemEngine(runner: runner, registry: registry, executable: gem, base: base)
        _ = try await engine.listOutdated()
        #expect(Array(engine.couldntCheck.keys) == ["lolcat"])
        await #expect(throws: EngineError.self) { _ = try await engine.listOutdated() }
        #expect(engine.couldntCheck.isEmpty)
    }

    /// Before anything was installed, Ruby's own gems only: none is a tool.
    @Test func nothingInstalledIsEmpty() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-empty")],
                                 script: try withExecutables(gemsWithExecutables, from: "list-local-empty"))
        #expect(try await engine.listInstalled().isEmpty)
    }

    /// The list's shapes: versions newest first (`thor (1.5.0, 1.3.2)`), a default gem's `default: `, a platform after
    /// the version.
    @Test func readsEveryListShape() throws {
        let twoVersions = try captured("list-local-two-versions").stdout
        #expect(try GemEngine.listed(twoVersions) == [GemEngine.Listed(name: "thor", versions: ["1.5.0", "1.3.2"])])
        // Not captures: RubyGems' `entry_versions` shapes the research describes, in the captured line form.
        let list = try captured("list-local-final").stdout
            .replacingOccurrences(of: "bundler (default: 4.1.0)\n", with: "bundler (4.1.1, default: 4.1.0)\n")
            .replacingOccurrences(of: "nkf (0.2.0)\n", with: "nokogiri (1.19.7 arm64-darwin, 1.18.0 ruby arm64-darwin)\n")
        let gems = try GemEngine.listed(list)
        #expect(gems.count == 88)
        #expect(gems.first { $0.name == "bundler" }?.versions == ["4.1.1", "4.1.0"])
        #expect(gems.first { $0.name == "json" }?.versions == ["2.18.3"])
        #expect(gems.first { $0.name == "nokogiri" }?.versions == ["1.19.7", "1.18.0"])
        // A terminal's `*** LOCAL GEMS ***` header and blank lines aren't gems.
        #expect(try GemEngine.listed("\n*** LOCAL GEMS ***\n\nthor (1.5.0)\n").map(\.name) == ["thor"])
    }

    /// The executables script's answer, as captured on Homebrew's Ruby 4.0.10 before R38 (`t13-executables-script`,
    /// and after `update` and at the end): gem installs outside Ruby's own folder, and each copy with where it is. Every
    /// gem Ruby bundles with executables shows twice at one version, `ruby` and `user`: the `user` one is the gemspec
    /// Homebrew links from the Cellar (SOURCES.md), which the script calls Ruby's since R38. Those nine are exactly
    /// `bundledWithExecutables` (minitest and test-unit added), and every gem with executables in the answer is in
    /// `capturedGemsWithExecutables`, which demo mode and the tests make answers from.
    @Test func readsTheCapturedExecutablesAnswer() throws {
        let answer = try GemEngine.executables(try captured("t13-executables-script").stdout)
        #expect(answer.separate)
        let rubys = Set(answer.copies.filter { $0.place == .ruby }.map(\.name))
        #expect(rubys == GemEngine.bundledWithExecutables)
        for name in rubys {
            let copies = answer.copies.filter { $0.name == name }
            #expect(copies.map(\.place) == [.user, .ruby], "\(name)")
            #expect(Set(copies.map(\.version)).count == 1, "\(name)")
        }
        #expect(Set(answer.copies.filter { $0.place == .default }.map(\.name)) == ["bundler", "erb", "syntax_suggest"])
        #expect(Set(answer.copies.map(\.name)) == GemEngine.capturedGemsWithExecutables)
        // The user's own: lolcat and thor, then mustache and a second thor after `update`, a second lolcat at the end.
        func users(_ name: String) throws -> [String] {
            try GemEngine.executables(try captured(name).stdout).copies
                .filter { $0.place == .user && !GemEngine.bundledWithExecutables.contains($0.name) }
                .map { "\($0.name) \($0.version)" }
        }
        #expect(try users("t13-executables-script") == ["lolcat 100.0.0", "thor 1.3.2"])
        #expect(try users("t13-executables-script-after-update")
                == ["lolcat 100.0.0", "mustache 1.1.3", "thor 1.5.0", "thor 1.3.2"])
        #expect(try users("t13-executables-script-end")
                == ["lolcat 100.0.1", "lolcat 100.0.0", "thor 1.5.0", "thor 1.3.2"])
        let shared = try GemEngine.executables("ruby-gems-shared\n")
        #expect(!shared.separate && shared.copies.isEmpty)
        // Not captures: answers no Ruby gave, made up to check they're refused.
        for output in ["", "thor (1.5.0) user\n", "ruby-gems-separate\nthor (1.5.0) elsewhere\n",
                       "ruby-gems-separate\nthor (1.5.0)\n", "ruby-gems-separate\nthor (banana) user\n"] {
            #expect(throws: EngineError.self, "\(output)") { _ = try GemEngine.executables(output) }
        }
    }

    /// Before R38, the captured answer made Ruby's linked copies the user's: rake, irb, rdoc and the rest were tools,
    /// offered as updates. The captured listing of that state (`list-local-final`, the state T13 started from) with
    /// that answer shows the problem; with the bundled gems' links read as Ruby's (what the script prints since R38,
    /// checked on a real Ruby in `scriptsTellALinkedGemspecFromTheUsersCopy`), only lolcat and thor are tools.
    @Test func linkedBundledGemsAreRubys() throws {
        let listed = try GemEngine.listed(try captured("list-local-final").stdout)
        let before = try GemEngine.executables(try captured("t13-executables-script").stdout)
        #expect(GemEngine.tools(listed, executables: before).map(\.name)
                == ["debug", "irb", "lolcat", "minitest", "racc", "rake", "rbs", "rdoc", "test-unit", "thor",
                    "typeprof"])
        let linksAsRubys = GemEngine.Executables(separate: before.separate, copies: before.copies.map { copy in
            guard copy.place == .user, before.copies.contains(GemEngine.Copy(name: copy.name, version: copy.version,
                                                                             place: .ruby)) else { return copy }
            return GemEngine.Copy(name: copy.name, version: copy.version, place: .ruby)
        })
        #expect(GemEngine.tools(listed, executables: linksAsRubys) == [gemRow("lolcat", "100.0.0"),
                                                                       gemRow("thor", "1.3.2")])
    }

    /// The confirmation captures (the script before R38, on Homebrew's Ruby): gems the user still has are named on
    /// stderr (exit 1); a default gem, a gem not installed and one just removed confirm (exit 0). rake, with only Ruby's
    /// own copy and its link left, was named too (`t13-confirmation-bundled-gem`): what R38 stops, since the script
    /// now ignores the link (`scriptsTellALinkedGemspecFromTheUsersCopy`). An uninstall's step is confirmed by that
    /// script, with the names after `--`.
    @Test func confirmationCaptures() async throws {
        let installed = try captured("t13-confirmation-installed")
        #expect(installed.exitCode == 1)
        #expect(installed.stderr == "thor is still installed.\nlolcat is still installed.\n")
        for name in ["t13-confirmation-default-gem", "t13-confirmation-not-installed", "t13-confirmation-after-uninstall"] {
            #expect(try captured(name).exitCode == 0, "\(name)")
        }
        let bundled = try captured("t13-confirmation-bundled-gem")
        #expect(bundled.exitCode == 1 && bundled.stderr == "rake is still installed.\n")
        let (engine, _) = engine([listArguments: try captured("list-local-final")],
                                 script: try captured("t13-executables-script"))
        _ = try await engine.listInstalled()
        let remove = try engine.command(for: .remove, [tool("thor"), tool("lolcat")], options: InstallOptions())
        #expect(remove.confirmation?.arguments == ["-e", GemEngine.confirmationScript, "--", "thor", "lolcat"])
    }

    /// R38 against a real Ruby: macOS's own Ruby 2.6 (the test is skipped where it isn't there). A gem folder of the
    /// test's own holds nokogiri's gemspec from Ruby's own gem folder as a link, the way Homebrew links its bundled
    /// gems: the executables script calls that copy Ruby's, and the confirmation doesn't count it as left. The same
    /// gemspec as a regular file is the user's copy: listed as `user`, and named as left. Ruby runs with only
    /// GEM_HOME and GEM_PATH set (the test's folder, then Ruby's own), from that folder. RubyGems 3.0 lists one copy
    /// per name and version, the first gem folder's, so Ruby's own isn't listed beside it here (Ruby 4.0 lists both,
    /// `t13-executables-script`). Before R38 the link was `user` and the confirmation named it.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: appleNokogiri)))
    func scriptsTellALinkedGemspecFromTheUsersCopy() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("brewxport-gem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let specifications = home.appendingPathComponent("specifications")
        try FileManager.default.createDirectory(at: specifications, withIntermediateDirectories: true)
        let spec = specifications.appendingPathComponent("nokogiri-1.13.8.gemspec")

        func run(_ script: String, _ arguments: [String] = []) throws -> (Int32, String, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
            process.arguments = ["-e", script] + arguments
            process.environment = ["GEM_HOME": home.path, "GEM_PATH": home.path + ":" + appleOwnGems,
                                   "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            process.currentDirectoryURL = home
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, stdout, stderr)
        }
        func copies(_ output: String) -> [String] {
            output.split(separator: "\n").filter { $0.hasPrefix("nokogiri ") }.map(String.init)
        }

        try FileManager.default.createSymbolicLink(atPath: spec.path, withDestinationPath: appleNokogiri)
        let (listed, linkedOutput, _) = try run(GemEngine.executablesScript)
        #expect(listed == 0)
        #expect(linkedOutput.hasPrefix("ruby-gems-separate\n"))
        #expect(copies(linkedOutput) == ["nokogiri (1.13.8) ruby"])
        let (confirmed, _, quiet) = try run(GemEngine.confirmationScript, ["--", "nokogiri"])
        #expect(confirmed == 0)
        #expect(quiet.isEmpty)

        // Fix round 1: a link into another folder than Ruby's own (an older Ruby's keg left behind) is Ruby's too: any
        // gemspec link that resolves outside the folder it sits in.
        let keg = home.appendingPathComponent("Cellar/ruby/3.9.9/specifications")
        try FileManager.default.createDirectory(at: keg, withIntermediateDirectories: true)
        let kegSpec = keg.appendingPathComponent("nokogiri-1.13.8.gemspec")
        try FileManager.default.copyItem(atPath: appleNokogiri, toPath: kegSpec.path)
        try FileManager.default.removeItem(at: spec)
        try FileManager.default.createSymbolicLink(atPath: spec.path, withDestinationPath: kegSpec.path)
        let (_, kegOutput, _) = try run(GemEngine.executablesScript)
        #expect(copies(kegOutput) == ["nokogiri (1.13.8) ruby"])
        #expect(try run(GemEngine.confirmationScript, ["--", "nokogiri"]).0 == 0)

        try FileManager.default.removeItem(at: spec)
        try FileManager.default.copyItem(atPath: appleNokogiri, toPath: spec.path)
        let (_, copiedOutput, _) = try run(GemEngine.executablesScript)
        #expect(copies(copiedOutput) == ["nokogiri (1.13.8) user"])
        let (left, _, named) = try run(GemEngine.confirmationScript, ["--", "nokogiri"])
        #expect(left == 1)
        #expect(named == "nokogiri is still installed.\n")
    }

    /// R2: Homebrew's Ruby bundles net-imap at a four-part version (the line the fixtures had to lose). Built in code
    /// so the repository's address check doesn't read it as one.
    @Test func fourPartVersionsInTheList() throws {
        let version = "0.6.4" + ".1"
        let list = try captured("list-local-final").stdout + "net-imap (0.6.8, \(version))\n"
        let gems = try GemEngine.listed(list)
        #expect(gems.first { $0.name == "net-imap" }?.versions == ["0.6.8", version])
        let answer = GemEngine.Executables(separate: true, copies: [
            GemEngine.Copy(name: "net-imap", version: "0.6.8", place: .ruby),
            GemEngine.Copy(name: "net-imap", version: version, place: .user),
        ])
        // The user's four-part copy is the row; Ruby's own 0.6.8 is what `gem update` would update from.
        let tools = GemEngine.tools(gems, executables: answer)
        #expect(tools == [GemEngine.Gem(name: "net-imap", version: version, highest: "0.6.8")])
        let index: [String: Result<[GemEngine.IndexVersion], any Error>] = [
            "net-imap": .success(try #require(GemEngine.indexVersions("---\n\(version) |a:b\n0.6.8 |a:b\n0.6.9 |a:b\n"))),
        ]
        let check = try GemEngine.updates(tools, index: index, runtime: homebrewRuntime)
        #expect(check.updates.map(\.installedVersion) == [version])
        #expect(check.updates.map(\.latestVersion) == ["0.6.9"])
    }

    /// The version compared is the highest copy installed of any kind, which `gem update` updates from: a user's older
    /// bundler beside Ruby's newer default copy gets no update when the index's newest equals Ruby's, which would be
    /// "Nothing to update" every time. Not captures: list and index lines in the captured shapes.
    @Test func noUpdateWhenRubysOwnCopyIsAlreadyThatNew() async throws {
        let list = try captured("list-local-final").stdout
            .replacingOccurrences(of: "bundler (default: 4.1.0)\n", with: "bundler (default: 4.1.0, 4.0.9)\n")
        let script = try withExecutables(gemsWithExecutables, listing: list)
        #expect(script.stdout.contains("bundler (4.1.0) default\nbundler (4.0.9) user\n"))
        func engineAnswering(_ index: String) throws -> GemEngine {
            let registry = FakeRegistryFetch(bodies: [indexURL("bundler"): index,
                                                      indexURL("lolcat"): try capturedText("index-info-lolcat.txt"),
                                                      indexURL("thor"): try capturedText("index-info-thor.txt")])
            return engine([listArguments: CommandResult(exitCode: 0, stdout: list, stderr: ""),
                           outdatedArguments: try captured("outdated"),
                           environmentArguments: try captured("environment")],
                          script: script, registry: registry).0
        }
        let current = try engineAnswering("---\n4.0.9 |checksum:a\n4.1.0 |checksum:b\n")
        #expect(try await current.listInstalled().first { $0.id.name == "bundler" }?.installedVersion == "4.0.9")
        #expect(try await current.listOutdated().map(\.id.name) == ["lolcat", "thor"])
        // A version newer than Ruby's copy is an update, shown from the user's version.
        let newer = try engineAnswering("---\n4.0.9 |checksum:a\n4.1.0 |checksum:b\n4.1.1 |checksum:c\n")
        let row = try await newer.listOutdated().first { $0.id.name == "bundler" }
        #expect(row?.installedVersion == "4.0.9")
        #expect(row?.latestVersion == "4.1.1")
    }

    @Test func installedRefusesOutputItDoesntKnow() async throws {
        for output in ["thor 1.5.0\n", "thor (1.5.0\n", "thor ()\n", "thor (not a version)\n", "thor (1.5.0, x)\n"] {
            let (engine, _) = engine([listArguments: CommandResult(exitCode: 0, stdout: output, stderr: "")],
                                     script: try withExecutables(["thor"]))
            do {
                _ = try await engine.listInstalled()
                Issue.record("expected an error for \(output)")
            } catch let error as EngineError {
                #expect(error.engine == .gem)
                #expect(!error.message.contains("thor"))
            }
        }
        let (garbled, _) = engine([listArguments: try captured("list-local-final")],
                                  script: CommandResult(exitCode: 0, stdout: "thor (1.3.2)\n", stderr: ""))
        do {
            _ = try await garbled.listInstalled()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(!error.message.contains("thor"))
        }
    }

    @Test func installedFailsWhenGemOrRubyFails() async throws {
        let (failing, _) = engine([listArguments: CommandResult(exitCode: 1, stdout: "", stderr: "ERROR: boom")],
                                  script: try withExecutables(["thor"]))
        await #expect(throws: EngineError.self) { _ = try await failing.listInstalled() }
        let (noScript, _) = engine([listArguments: try captured("list-local-final")],
                                   script: CommandResult(exitCode: 1, stdout: "", stderr: "ruby: boom"))
        await #expect(throws: EngineError.self) { _ = try await noScript.listInstalled() }
    }

    // MARK: outdated

    /// `gem outdated` names the candidates; each tool among them is looked up in RubyGems.org's compact index, and the
    /// newest version this Ruby can run is offered. Default gems and libraries in `gem outdated` aren't looked up.
    @Test func outdatedChecksTheCandidatesInTheIndex() async throws {
        let registry = try capturedIndex()
        let (engine, runner) = engine([listArguments: try captured("list-local-final"),
                                       outdatedArguments: try captured("outdated"),
                                       environmentArguments: try captured("environment")],
                                      script: try withExecutables(["bundler", "lolcat", "thor"]), registry: registry)
        let rows = try await engine.listOutdated()
        #expect(rows.map(\.id.name) == ["lolcat", "thor"])
        #expect(rows.map(\.installedVersion) == ["100.0.0", "1.3.2"])
        #expect(rows.map(\.latestVersion) == ["100.0.1", "1.5.0"])
        #expect(Set(registry.requested.map(\.absoluteString)) == [indexURL("lolcat"), indexURL("thor")])
        #expect(runner.calls == [listArguments, scriptArguments, outdatedArguments, environmentArguments])
        #expect(engine.couldntCheck.isEmpty)
    }

    /// The Ruby and RubyGems found by `detect()` are used; `gem environment` isn't asked again.
    @Test func outdatedUsesWhatDetectFound() async throws {
        let (engine, runner) = engine([["--version"]: try captured("version"),
                                       environmentArguments: try captured("environment"),
                                       listArguments: try captured("list-local-final"),
                                       outdatedArguments: try captured("outdated")],
                                      script: try withExecutables(["thor"]), registry: try capturedIndex())
        _ = await engine.detect()
        #expect(try await engine.listOutdated().map(\.latestVersion) == ["1.5.0"])
        #expect(runner.calls.filter { $0 == environmentArguments }.count == 1)
    }

    /// With the network refused, `gem outdated` prints nothing and exits 0, like "nothing outdated". So every tool is
    /// looked up, and when none answers the check fails: "couldn't check", never "up to date".
    @Test func silentOutdatedWithNoAnswerCouldntCheck() async throws {
        let offline = FakeRegistryFetch([indexURL("lolcat"): .failure(URLError(.notConnectedToInternet)),
                                         indexURL("thor"): .failure(URLError(.notConnectedToInternet))])
        let (engine, _) = engine([listArguments: try captured("list-local-final"),
                                  outdatedArguments: try captured("outdated-network-refused"),
                                  environmentArguments: try captured("environment")],
                                 script: try withExecutables(["lolcat", "thor"]), registry: offline)
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.engine == .gem)
            #expect(error.message.hasPrefix("BrewxPort couldn't check RubyGems.org for newer versions: "))
        }
        #expect(Set(offline.requested.map(\.absoluteString)) == [indexURL("lolcat"), indexURL("thor")])
    }

    /// When `gem outdated` names no tool but the index answers, the index is the check: what it has is offered.
    @Test func silentOutdatedWithAnAnswerUsesTheIndex() async throws {
        let registry = try capturedIndex()
        let (engine, _) = engine([listArguments: try captured("list-local-final"),
                                  outdatedArguments: try captured("outdated-network-refused"),
                                  environmentArguments: try captured("environment")],
                                 script: try withExecutables(["lolcat", "thor"]), registry: registry)
        #expect(try await engine.listOutdated().map(\.id.name) == ["lolcat", "thor"])
    }

    /// R6: a tool whose lookup fails is left out and recorded; the others still count.
    @Test func oneFailedLookupLeavesOnlyThatToolOut() async throws {
        let registry = FakeRegistryFetch([indexURL("lolcat"): .failure(URLError(.timedOut)),
                                          indexURL("thor"): .success(Data(try capturedText("index-info-thor.txt").utf8))])
        let (partial, _) = engine([listArguments: try captured("list-local-final"),
                                   outdatedArguments: try captured("outdated"),
                                   environmentArguments: try captured("environment")],
                                  script: try withExecutables(["lolcat", "thor"]), registry: registry)
        #expect(try await partial.listOutdated().map(\.id.name) == ["thor"])
        #expect(Array(partial.couldntCheck.keys) == ["lolcat"])
        #expect(partial.couldntCheck["lolcat"]?.contains("RubyGems.org") == true)
        #expect(partial.notOnRubyGems.isEmpty)
        #expect(partial.note == nil)
        // Final review: a gem RubyGems.org doesn't have (404) isn't one it couldn't check: it can't be checked there
        // at all (a private gem server's, one built on this Mac). It's named on the engine's page instead, never as a
        // failure. Here a rake the user installed at the version Ruby bundled, with a 404 standing in (Not a capture).
        let script = try withExecutables(["lolcat", "rake", "thor"], listing: try captured("list-local-final").stdout,
                                         extra: ["rake (13.3.1) user"])
        let (missing, _) = engine([listArguments: try captured("list-local-final"),
                                   outdatedArguments: try captured("outdated"),
                                   environmentArguments: try captured("environment")],
                                  script: script, registry: try capturedIndex())
        let report = try await missing.checkOutdated()
        #expect(report.packages.map(\.id.name) == ["lolcat", "thor"])
        #expect(report.unchecked.isEmpty)
        #expect(missing.couldntCheck.isEmpty)
        #expect(missing.notOnRubyGems == ["rake"])
        #expect(missing.note == "rake isn't on RubyGems.org, so BrewxPort can't check it for updates.")
    }

    /// The finding's case: `gem outdated` names nothing (as it does when nothing is outdated), so every tool is looked
    /// up on RubyGems.org, and the only one isn't there (404). That isn't a failed check, then or ever: nothing is
    /// offered, nothing is "couldn't check", and the page names it. Two such tools are named together.
    @Test func aToolNotOnRubyGemsNeverFailsTheCheck() async throws {
        let listing = try captured("list-local-final").stdout
        let (one, _) = engine([listArguments: try captured("list-local-final"),
                               outdatedArguments: try captured("outdated-network-refused"),
                               environmentArguments: try captured("environment")],
                              script: try withExecutables(["rake"], listing: listing, extra: ["rake (13.3.1) user"]),
                              registry: try capturedIndex())
        let report = try await one.checkOutdated()
        #expect(report.packages.isEmpty)
        #expect(report.unchecked.isEmpty)
        #expect(one.note == "rake isn't on RubyGems.org, so BrewxPort can't check it for updates.")

        let (two, _) = engine([listArguments: try captured("list-local-final"),
                               outdatedArguments: try captured("outdated-network-refused"),
                               environmentArguments: try captured("environment")],
                              script: try withExecutables(["rake", "rdoc"], listing: listing,
                                                          extra: ["rake (13.3.1) user", "rdoc (7.0.4) user"]),
                              registry: try capturedIndex())
        #expect(try await two.checkOutdated().unchecked.isEmpty)
        #expect(two.notOnRubyGems == ["rake", "rdoc"])
        #expect(two.note == "rake and rdoc aren't on RubyGems.org, so BrewxPort can't check them for updates.")

        // One not on RubyGems.org and one whose lookup timed out: RubyGems.org did answer, so the check doesn't fail;
        // the other is one it couldn't check (R6).
        let mixed = FakeRegistryFetch([indexURL("rdoc"): .failure(URLError(.timedOut))])
        let (both, _) = engine([listArguments: try captured("list-local-final"),
                                outdatedArguments: try captured("outdated-network-refused"),
                                environmentArguments: try captured("environment")],
                               script: try withExecutables(["rake", "rdoc"], listing: listing,
                                                           extra: ["rake (13.3.1) user", "rdoc (7.0.4) user"]),
                               registry: mixed)
        #expect(try await both.checkOutdated().unchecked.names == ["rdoc"])
        #expect(both.notOnRubyGems == ["rake"])
    }

    /// No tool gems: nothing to check, so neither `gem outdated` nor the index is asked.
    @Test func noToolsAsksNothing() async throws {
        let registry = FakeRegistryFetch()
        let (engine, runner) = engine([listArguments: try captured("list-local-empty")],
                                      script: try withExecutables(["bundler"], from: "list-local-empty"),
                                      registry: registry)
        #expect(try await engine.listOutdated().isEmpty)
        #expect(runner.calls == [listArguments, scriptArguments])
        #expect(registry.requested.isEmpty)
    }

    @Test func outdatedFailsOnAnotherExitCode() async throws {
        let token = CommandResult(exitCode: 1, stdout: "",
                                  stderr: "ERROR:  Could not fetch https://user:s3cret@gems.example.com/specs.4.8.gz")
        let (engine, _) = engine([listArguments: try captured("list-local-final"), outdatedArguments: token],
                                 script: try withExecutables(["thor"]))
        do {
            _ = try await engine.listOutdated()
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.hasPrefix("gem outdated failed (exit 1)"))
            #expect(!error.message.contains("s3cret"))
        }
    }

    /// `gem outdated`'s lines: `name (installed < latest)`.
    @Test func readsOutdatedNames() throws {
        let names = GemEngine.outdatedNames(try captured("outdated").stdout)
        #expect(names.count == 50)
        #expect(names.contains("thor") && names.contains("lolcat") && names.contains("bundler"))
        #expect(GemEngine.outdatedNames(try captured("outdated-network-refused").stdout).isEmpty)
    }

    /// The compact index's lines: `version[-platform] dependencies|checksum:…,ruby:…,rubygems:…,created_at:…`, after a
    /// `---` line.
    @Test func readsTheCompactIndex() throws {
        let thor = try #require(GemEngine.indexVersions(try capturedText("index-info-thor.txt")))
        #expect(thor.count == 58)
        #expect(thor.first == GemEngine.IndexVersion(version: "0.9.7", platform: nil, ruby: nil, rubyGems: nil))
        #expect(thor.last == GemEngine.IndexVersion(version: "1.5.0", platform: nil, ruby: ">= 2.6.0",
                                                     rubyGems: ">= 1.3.5"))
        let lolcat = try #require(GemEngine.indexVersions(try capturedText("index-info-lolcat.txt")))
        #expect(lolcat.last == GemEngine.IndexVersion(version: "100.0.1", platform: nil, ruby: nil, rubyGems: nil))
        // Not a capture: a platform line, and several requirements joined with `&`, as the research quotes them.
        let line = "1.19.7-arm64-darwin racc:~> 1.4|checksum:abc,ruby:< 4.1.dev&>= 3.2,rubygems:>= 3.3.22\n"
        #expect(GemEngine.indexVersions("---\n" + line)
                == [GemEngine.IndexVersion(version: "1.19.7", platform: "arm64-darwin", ruby: "< 4.1.dev&>= 3.2",
                                           rubyGems: ">= 3.3.22")])
        #expect(GemEngine.indexVersions(try capturedText("index-info-unknown.txt")) == nil)
    }

    /// Versions whose `ruby:` or `rubygems:` requirement this Ruby doesn't meet are held back: `gem outdated` offers
    /// them anyway.
    @Test func updatesHoldBackVersionsThisRubyCantRun() throws {
        let thor = try #require(GemEngine.indexVersions(try capturedText("index-info-thor.txt")))
        let lolcat = try #require(GemEngine.indexVersions(try capturedText("index-info-lolcat.txt")))
        let tools = [gemRow("lolcat", "100.0.0"), gemRow("thor", "1.2.2")]
        let index: [String: Result<[GemEngine.IndexVersion], any Error>] = ["lolcat": .success(lolcat),
                                                                            "thor": .success(thor)]
        let current = try GemEngine.updates(tools, index: index, runtime: homebrewRuntime)
        #expect(current.updates.map(\.latestVersion) == ["100.0.1", "1.5.0"])
        // thor 1.3 and later need Ruby 2.6: an older Ruby gets nothing newer than its 1.2.2.
        let old = GemEngine.Runtime(ruby: "2.5.9", rubyGems: "4.1.0", platforms: ["ruby"])
        #expect(try GemEngine.updates(tools, index: index, runtime: old).updates.map(\.id.name) == ["lolcat"])
        // thor 0.14.5 and later need RubyGems 1.3.5.
        let ancient = [gemRow("thor", "0.14.4")]
        let oldGems = GemEngine.Runtime(ruby: "4.0.10", rubyGems: "1.3.0", platforms: ["ruby"])
        #expect(try GemEngine.updates(ancient, index: index, runtime: oldGems).updates.isEmpty)
        // Not known: not checked.
        let unknown = GemEngine.Runtime(ruby: nil, rubyGems: nil, platforms: ["ruby"])
        #expect(try GemEngine.updates(tools, index: index, runtime: unknown).updates.map(\.latestVersion)
                == ["100.0.1", "1.5.0"])
    }

    /// Only the `ruby` platform and this Mac's own count; pre-releases only for a pre-release install; R2 four-part
    /// versions. Not captures: index lines in the captured shape.
    @Test func updatesFollowPlatformsAndPreReleases() throws {
        let lines = ["1.19.7-arm64-darwin |checksum:a", "1.19.8-x86_64-darwin |checksum:b", "1.19.9-java |checksum:c",
                     "1.20.0-arm64-darwin-22 |checksum:d", "1.21.0.rc1 |checksum:e"]
        let versions = try #require(GemEngine.indexVersions("---\n" + lines.joined(separator: "\n") + "\n"))
        let index: [String: Result<[GemEngine.IndexVersion], any Error>] = ["nokogiri": .success(versions)]
        let arm = try GemEngine.updates([gemRow("nokogiri", "1.19.6")], index: index, runtime: homebrewRuntime)
        #expect(arm.updates.map(\.latestVersion) == ["1.19.7"])
        let intel = GemEngine.Runtime(ruby: "4.0.10", rubyGems: "4.1.0", platforms: ["ruby", "x86_64-darwin-24"])
        #expect(try GemEngine.updates([gemRow("nokogiri", "1.19.6")], index: index, runtime: intel).updates
                .map(\.latestVersion) == ["1.19.8"])
        let pre = try GemEngine.updates([gemRow("nokogiri", "1.21.0.beta")], index: index, runtime: homebrewRuntime)
        #expect(pre.updates.map(\.latestVersion) == ["1.21.0.rc1"])
        // Odd platform text never matches, and never stops the check.
        #expect(!GemEngine.platformMatches("-", local: ["ruby", "arm64-darwin-24"]))
        #expect(!GemEngine.platformMatches("java", local: ["ruby", "", "-"]))
        #expect(GemEngine.platformMatches("universal-darwin", local: ["ruby", "arm64-darwin24"]))
        #expect(GemEngine.indexVersions("---\n1.0-- |checksum:a\n")?.first?.platform == "-")
        let fourPart = "0.6.4" + ".1"
        let imap = try #require(GemEngine.indexVersions("---\n0.6.4 |checksum:a\n\(fourPart) |checksum:b\n0.6.8 |c:d\n"))
        let imapIndex: [String: Result<[GemEngine.IndexVersion], any Error>] = ["net-imap": .success(imap)]
        #expect(try GemEngine.updates([gemRow("net-imap", fourPart)], index: imapIndex, runtime: homebrewRuntime)
                .updates.map(\.latestVersion) == ["0.6.8"])
    }

    /// Nothing answered, or nothing could be looked up, is a failure; a gem with no newer version isn't.
    @Test func updatesFailOnlyWithoutAnyAnswer() throws {
        let failed: [String: Result<[GemEngine.IndexVersion], any Error>] = ["thor": .failure(URLError(.timedOut))]
        #expect(throws: EngineError.self) {
            _ = try GemEngine.updates([gemRow("thor", "1.3.2")], index: failed, runtime: homebrewRuntime)
        }
        #expect(throws: EngineError.self) {
            _ = try GemEngine.updates([gemRow("thor", "1.3.2")], index: [:], runtime: homebrewRuntime)
        }
        let current: [String: Result<[GemEngine.IndexVersion], any Error>] = [
            "thor": .success(try #require(GemEngine.indexVersions(try capturedText("index-info-thor.txt")))),
        ]
        #expect(try GemEngine.updates([gemRow("thor", "1.5.0")], index: current, runtime: homebrewRuntime)
                .updates.isEmpty)
    }

    /// Gem::Requirement's operators, and several joined with `&` (all must hold).
    @Test func requirements() {
        #expect(GemEngine.satisfies("4.0.10", ">= 2.6.0"))
        #expect(!GemEngine.satisfies("2.5.9", ">= 2.6.0"))
        #expect(GemEngine.satisfies("4.0.10", "< 4.1.dev&>= 3.2"))
        #expect(!GemEngine.satisfies("4.1.0", "< 4.1.dev&>= 3.2"))
        #expect(!GemEngine.satisfies("3.1.6", "< 4.1.dev&>= 3.2"))
        #expect(GemEngine.satisfies("2.1.9", "~> 2.1"))
        #expect(!GemEngine.satisfies("3.0.0", "~> 2.1"))
        #expect(GemEngine.satisfies("2.1.9", "~> 2.1.0"))
        #expect(!GemEngine.satisfies("2.2.0", "~> 2.1.0"))
        #expect(!GemEngine.satisfies("2.0.9", "~> 2.1.0"))
        #expect(GemEngine.satisfies("2.9", "~> 2"))
        #expect(!GemEngine.satisfies("3.0", "~> 2"))
        #expect(GemEngine.satisfies("1.0", "= 1.0.0"))
        #expect(GemEngine.satisfies("1.0", "1"))
        #expect(!GemEngine.satisfies("1.0", "!= 1"))
        #expect(GemEngine.satisfies("1.1", "> 1"))
        #expect(GemEngine.satisfies("1.0", "<= 1.0"))
        #expect(!GemEngine.satisfies("1.0.a", ">= 1.0"))
        // A requirement BrewxPort can't read holds a version back.
        #expect(!GemEngine.satisfies("4.0.10", "=~ 4"))
        #expect(!GemEngine.satisfies("4.0.10", ">= banana"))
        #expect(!GemEngine.satisfies("4.0.10", ""))
    }

    // MARK: search

    /// `gem search --remote`: the exact name first, then names that start with the query, then the rest in gem's order.
    @Test func searchesRubyGemsOrg() async throws {
        let (broad, runner) = engine([["search", "--remote", "lolcat"]: try captured("search-remote-broad")])
        let rows = try await broad.search(" lolcat ")
        #expect(rows.map(\.id.name) == ["lolcat", "lolcation_client", "can-has-lolcat", "remi-lolcats"])
        #expect(rows.map(\.latestVersion) == ["100.0.1", "0.2.7", "1.1.1", "0.1.1"])
        #expect(rows.allSatisfy { $0.id.kind == .tool && $0.installedVersion == nil })
        #expect(runner.calls == [["search", "--remote", "lolcat"]])
        let (one, _) = engine([["search", "--remote", "lolcat"]: try captured("search-remote-lolcat")])
        #expect(try await one.search("lolcat").map(\.id.name) == ["lolcat"])
    }

    /// The query is text, not a pattern: gem reads its argument as a regular expression, so its special characters are
    /// escaped.
    @Test func searchEscapesThePattern() {
        #expect(GemEngine.pattern("rails") == "rails")
        #expect(GemEngine.pattern("a.b*c+d?(e)[f]{g}|h^i$j\\k") == "a\\.b\\*c\\+d\\?\\(e\\)\\[f\\]\\{g\\}\\|h\\^i\\$j\\\\k")
        #expect(GemEngine.pattern("net-http_x") == "net-http_x")
    }

    @Test func searchWithoutMatchesIsEmpty() async throws {
        let (engine, _) = engine([["search", "--remote", "zzqxbrewxportnomatch"]: try captured("search-remote-nomatch")])
        #expect(try await engine.search("zzqxbrewxportnomatch").isEmpty)
    }

    /// An empty query is refused; one gem would read as an option finds nothing, without asking.
    @Test func searchRefusesEmptyAndOptionQueries() async throws {
        let (engine, runner) = engine([:])
        await #expect(throws: EngineError.self) { _ = try await engine.search("  ") }
        #expect(try await engine.search("--source").isEmpty)
        #expect(runner.calls.isEmpty)
    }

    /// At most 50 rows, the best first; names gem couldn't install by name are left out. Not a capture: lines in the
    /// captured shape.
    @Test func searchKeepsTheBestFifty() {
        let many = (1...60).map { "tool-\($0) (1.0.0)" } + ["tool (2.0.0)", "_hidden (1.0.0)", "not a line"]
        let rows = GemEngine.searchResults(many.joined(separator: "\n") + "\n", query: "tool")
        #expect(rows.count == 50)
        #expect(rows.first?.id.name == "tool")
        #expect(!rows.contains { $0.id.name == "_hidden" })
    }

    /// Not a capture of `gem search`: the captured network-refused `gem install` answer (exit 2, gem's words on
    /// stderr) stands in for it.
    @Test func searchFailureIsGemsOwnWords() async throws {
        let (engine, _) = engine([["search", "--remote", "thor"]: try captured("install-network-refused")])
        do {
            _ = try await engine.search("thor")
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message.hasPrefix("gem search failed (exit 2): ERROR:  Could not find a valid gem"))
        }
    }

    // MARK: info

    /// RubyGems.org's API answer, with the installed version from the last listing.
    @Test func infoFromRubyGemsOrg() async throws {
        let registry = FakeRegistryFetch(bodies: ["https://rubygems.org/api/v1/gems/lolcat.json":
                                                    try capturedText("api-gem-lolcat.json")])
        let (engine, _) = engine([listArguments: try captured("list-local-final")],
                                 script: try withExecutables(["lolcat"]), registry: registry)
        _ = try await engine.listInstalled()
        let details = try await engine.info(tool("lolcat"))
        #expect(details.summary == "Rainbows and unicorns!")
        #expect(details.homepage == URL(string: "https://github.com/busyloop/lolcat"))
        #expect(details.latestVersion == "100.0.1")
        #expect(details.installedVersion == "100.0.0")
        #expect(details.reportedName == "lolcat")
    }

    @Test func infoForAnUnknownGemFails() async throws {
        let (engine, _) = engine([:])
        do {
            _ = try await engine.info(tool("no-such-gem-for-brewxport"))
            Issue.record("expected an error")
        } catch let error as EngineError {
            #expect(error.message == "RubyGems.org has no gem named no-such-gem-for-brewxport")
        }
    }

    @Test func infoOfflineFailsAndOtherErrorsPassThrough() async throws {
        let offline = FakeRegistryFetch(["https://rubygems.org/api/v1/gems/thor.json":
                                            .failure(URLError(.notConnectedToInternet))])
        let (unreachable, _) = engine([:], registry: offline)
        await #expect(throws: EngineError.self) { _ = try await unreachable.info(tool("thor")) }
        let odd = FakeRegistryFetch(["https://rubygems.org/api/v1/gems/thor.json": .failure(Unrelated())])
        let (other, _) = engine([:], registry: odd)
        await #expect(throws: Unrelated.self) { _ = try await other.info(tool("thor")) }
    }

    @Test func infoChecksTheNameBeforeAsking() async {
        let registry = FakeRegistryFetch()
        let (engine, _) = engine([:], registry: registry)
        await #expect(throws: EngineError.self) { _ = try await engine.info(tool("../thor")) }
        await #expect(throws: EngineError.self) {
            _ = try await engine.info(PackageRef(engine: .npm, kind: .tool, name: "thor"))
        }
        #expect(registry.requested.isEmpty)
    }

    // MARK: commands

    /// R16: install and update always from RubyGems' sources (`--remote`, never a `*.gem` file in the folder) without
    /// documentation; an uninstall removes every version and its executables, never breaks a dependent, and is
    /// confirmed afterwards by the `ruby` beside gem.
    @Test func commandShapes() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-final")],
                                 script: try withExecutables(["lolcat", "thor"]))
        _ = try await engine.listInstalled()
        let install = try engine.command(for: .install, [tool("thor"), tool("lolcat")], options: InstallOptions())
        #expect(install.executable == gem)
        #expect(install.arguments == ["install", "--remote", "--no-document", "thor", "lolcat"])
        #expect(install.confirmation == nil)
        let upgrade = try engine.command(for: .upgrade, [tool("thor"), tool("lolcat")], options: InstallOptions())
        #expect(upgrade.arguments == ["update", "--remote", "--no-document", "thor", "lolcat"])
        let remove = try engine.command(for: .remove, [tool("thor")], options: InstallOptions())
        #expect(remove.arguments == ["uninstall", "--all", "--executables", "--abort-on-dependent", "thor"])
        let confirmation = try #require(remove.confirmation)
        #expect(confirmation.executable == ruby)
        #expect(confirmation.arguments == ["-e", GemEngine.confirmationScript, "--", "thor"])
        for spec in [install, upgrade, remove] {
            #expect(!spec.needsRoot)
            #expect(!spec.arguments.contains("--force") && !spec.arguments.contains("--local"))
        }
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(engine.privilege(for: op, tool("thor")) == .never)
        }
    }

    /// The scripts BrewxPort passes Ruby are fixed text: names go in as arguments, never into the script.
    @Test func scriptsTakeNoText() {
        for script in [GemEngine.executablesScript, GemEngine.confirmationScript] {
            #expect(!script.contains("\n"))
            #expect(!script.contains("#{ARGV"))
            #expect(!script.contains("eval") && !script.contains("system") && !script.contains("`"))
        }
        #expect(GemEngine.confirmationScript.contains("ARGV"))
        #expect(!GemEngine.executablesScript.contains("ARGV"))
        // A gemspec Ruby can't load: skipped when listing, counted as still there when confirming a removal.
        #expect(GemEngine.executablesScript.contains("find_all_by_name(latest.name) || []).each { |spec| next if spec.nil?;"))
        #expect(GemEngine.confirmationScript.contains("find_all_by_name(name) || []).any? { |spec| spec.nil? || "))
    }

    @Test func commandsCarryGemsEnvironmentAndHome() async throws {
        let (engine, _) = engine([:])
        let spec = try engine.command(for: .remove, [tool("thor")], options: InstallOptions())
        let env = try #require(spec.environment)
        #expect(env["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(env["NO_COLOR"] == "1")
        #expect(env["HOME"] == "/Users/someone")
        #expect(spec.workingDirectory == "/Users/someone")
    }

    /// An update is only for a tool the last listing showed: never a default gem (updating one installs a second
    /// copy), a library, or before any listing.
    @Test func upgradeOnlyForListedTools() async throws {
        let (engine, _) = engine([listArguments: try captured("list-local-final")],
                                 script: try withExecutables(["bundler", "thor"]))
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .upgrade, [tool("thor")], options: InstallOptions())
        }
        _ = try await engine.listInstalled()
        _ = try engine.command(for: .upgrade, [tool("thor")], options: InstallOptions())
        for name in ["bundler", "json", "paint", "not-installed"] {
            do {
                _ = try engine.command(for: .upgrade, [tool("thor"), tool(name)], options: InstallOptions())
                Issue.record("expected an error for \(name)")
            } catch let error as EngineError {
                #expect(error.message == "BrewxPort can't find \(name) among RubyGems' installed tools, so it doesn't "
                        + "update it.")
            }
        }
        // Removing isn't limited: the confirmation says whether it worked.
        _ = try engine.command(for: .remove, [tool("paint")], options: InstallOptions())
    }

    /// Nothing but a gem name reaches gem.
    @Test func gemRefusesNonRegistrySpecs() throws {
        let (engine, _) = engine([:])
        let specs = ["https://example.com/tool.gem", "github:someone/tool", "git+https://example.com/tool.git",
                     "../path", "./tool", "/tmp/tool", "~/tool", "-e", "--local", "--source", "tool.gem", "THOR.GEM",
                     "someone/tool", "tool:1.0", "tool-1.0.0.gem", "bad name!", "_", "123", ""]
        for name in specs {
            for op in [PackageOperation.install, .upgrade, .remove] {
                #expect(throws: EngineError.self, "\(op) \(name)") {
                    _ = try engine.command(for: op, [tool("thor"), tool(name)], options: InstallOptions())
                }
            }
        }
    }

    @Test func commandRefusesWhatGemCantDoHere() throws {
        let (engine, _) = engine([:])
        let thor = [tool("thor")]
        // Without names, `gem update` would update every gem, default gems too.
        for op in [PackageOperation.install, .upgrade, .remove] {
            #expect(throws: EngineError.self) { _ = try engine.command(for: op, [], options: InstallOptions()) }
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, thor, options: InstallOptions(version: "1.3.2"))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, thor, options: InstallOptions(variants: ["+x"]))
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, thor, options: InstallOptions(extraArgs: ["--force"]))
        }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markRequested, thor, options: InstallOptions()) }
        #expect(throws: EngineError.self) { _ = try engine.command(for: .markDependency, thor, options: InstallOptions()) }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .npm, kind: .tool, name: "thor")],
                                   options: InstallOptions())
        }
        #expect(throws: EngineError.self) {
            _ = try engine.command(for: .install, [PackageRef(engine: .gem, kind: .formula, name: "thor")],
                                   options: InstallOptions())
        }
    }

    @Test func commandWithoutGemThrows() {
        let (engine, _) = engine([:], executable: nil)
        #expect(throws: EngineError.self) { _ = try engine.command(for: .install, [tool("thor")], options: InstallOptions()) }
    }

    // MARK: where gem writes, and what it runs on

    /// A name gem wouldn't install by name is refused on its own, with why; the other tools are still repaired.
    @Test func gemRepairRefusesABadNameAlone() throws {
        let (found, _) = engine([:])
        let steps = try found.repairCommands(for: ["thor", "-bad", "lolcat"])
        #expect(steps.map(\.tool) == ["lolcat", "thor"])
        #expect(found.repairRefusals(for: ["thor", "-bad", "lolcat"])
                == ["-bad": "BrewxPort doesn't repair -bad: it isn't a name RubyGems installs by."])
        // Only refused names: nothing runs, and the refusals say why.
        #expect(try found.repairCommands(for: ["-bad"]).isEmpty)
        #expect(throws: EngineError.self) { try found.repairCommands(for: []) }
    }

    /// macOS's own Ruby and MacPorts' Ruby keep their gems where only an administrator can write, so their gems are
    /// read-only whatever the access check says, with the fix. Homebrew's Ruby in a writable folder isn't.
    @Test func systemAndMacPortsRubyAreReadOnly() async throws {
        let refused = CommandResult(exitCode: 1, stdout: "", stderr: "ERROR: boom")
        let system = "This is macOS's own Ruby, and only an administrator can change its gems. Set up Homebrew's "
            + "Ruby to manage gems with BrewxPort."
        let macPorts = "MacPorts' Ruby keeps its gems in /opt/local, which only an administrator can change. Set up "
            + "Homebrew's Ruby to manage gems with BrewxPort."
        for (path, reason) in [("/usr/bin/gem", system), ("/opt/local/bin/gem", macPorts)] {
            let (found, _) = engine([["--version"]: try captured("version"), environmentArguments: refused],
                                    executable: URL(fileURLWithPath: path))
            _ = await found.detect()
            #expect(found.readOnlyReason == reason)
            #expect(throws: EngineError(engine: .gem, message: reason)) {
                try found.command(for: .install, [tool("thor")], options: InstallOptions())
            }
            #expect(throws: EngineError.self) { try found.repairCommands(for: ["thor"]) }
        }
        let (homebrew, _) = engine([["--version"]: try captured("version"),
                                    environmentArguments: try captured("environment")])
        _ = await homebrew.detect()
        #expect(homebrew.readOnlyReason == nil)
    }

    /// Homebrew's `ruby` formula runs the captured gem (`RUBY EXECUTABLE: /opt/homebrew/opt/ruby/bin/ruby`), so a Ruby
    /// minor update leaves its gems behind in the old version's folder.
    @Test func gemRunsOnHomebrewRuby() async throws {
        let (found, _) = engine([["--version"]: try captured("version"),
                                 environmentArguments: try captured("environment")])
        _ = await found.detect()
        #expect(try await found.runtimeUses() == [RuntimeUse(formula: "ruby")])
        let (system, _) = engine([["--version"]: try captured("version"),
                                  environmentArguments: CommandResult(exitCode: 1, stdout: "", stderr: "")],
                                 executable: URL(fileURLWithPath: "/usr/bin/gem"))
        _ = await system.detect()
        #expect(try await system.runtimeUses().isEmpty)
    }

    /// R29's careful reading: a gem that couldn't say which Ruby it runs (no detect yet, `gem --version` failing, or
    /// no `gem environment` from a gem whose path doesn't say either) says nothing rather than "none", so the caller
    /// holds a Ruby update for it and keeps a dependency-only Ruby.
    @Test func gemThatCouldntSayWhatItRunsOnThrows() async throws {
        let (undetected, _) = engine([["--version"]: try captured("version"),
                                      environmentArguments: try captured("environment")])
        await #expect(throws: EngineError.self) { _ = try await undetected.runtimeUses() }
        let (broken, _) = engine([["--version"]: CommandResult(exitCode: 1, stdout: "", stderr: "dyld: Library not loaded")])
        _ = await broken.detect()
        await #expect(throws: EngineError.self) { _ = try await broken.runtimeUses() }
        let (unknown, _) = engine([["--version"]: try captured("version"),
                                   environmentArguments: CommandResult(exitCode: 1, stdout: "", stderr: "")],
                                  executable: URL(fileURLWithPath: "/Users/someone/tools/bin/gem"))
        _ = await unknown.detect()
        await #expect(throws: EngineError.self) { _ = try await unknown.runtimeUses() }
    }
}
