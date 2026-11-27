import Foundation
import BrewxPortCore

public enum FixtureRunnerError: Error, Equatable, Sendable, LocalizedError {
    /// No captured output for these arguments (after the executable).
    case unmapped([String])
    /// No captured answer for this registry URL (`DemoEngine.search` finds nothing for one).
    case unmappedURL(String)
    /// The table names a file the fixtures directory doesn't have.
    case missingFixture(String)
    /// Demo mode never streams: every change is simulated by `DemoRunExecutor`.
    case streamingNotSupported

    /// What an engine says when it words the error itself, as a lookup it couldn't make does.
    public var errorDescription: String? {
        switch self {
        case .unmapped(let arguments): "Demo mode has no captured output for \(arguments.joined(separator: " "))."
        case .unmappedURL(let url): "Demo mode has no captured answer for \(url)."
        case .missingFixture(let path): "Demo mode's fixtures don't have \(path)."
        case .streamingNotSupported: "Demo mode doesn't run commands."
        }
    }
}

/// Answers the engines' read-only commands from the captured fixtures. Nothing is ever launched.
///
/// The table is keyed by the tool (the executable's name) and the argv after it. A search query is a wildcard: every
/// search gets the one captured search, and `DemoEngine` filters it.
public final class FixtureRunner: CommandRunning {
    public let fixtures: URL
    public let host: Arch
    /// `--demo-states`: the executables script's answer says gem installs into Ruby's own gem folder, as with rbenv,
    /// asdf or mise (`gemExecutables`).
    public let rubySharesGemFolder: Bool

    public init(fixtures: URL, host: Arch, rubySharesGemFolder: Bool = false) {
        self.fixtures = fixtures
        self.host = host
        self.rubySharesGemFolder = rubySharesGemFolder
    }

    public func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
        if executable.lastPathComponent == "ruby", arguments == ["-e", GemEngine.executablesScript] {
            return CommandResult(exitCode: 0, stdout: try gemExecutables(), stderr: "")
        }
        guard let relative = Self.file(tool: executable.lastPathComponent, arguments, host: host) else {
            throw FixtureRunnerError.unmapped(arguments)
        }
        let url = fixtures.appendingPathComponent(relative)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw FixtureRunnerError.missingFixture(relative)
        }
        return CommandResult(exitCode: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
    }

    public func stream(_ executable: URL, _ arguments: [String], options: RunOptions,
                       onOutput: @escaping @Sendable (OutputEvent) -> Void) async throws -> Int32 {
        throw FixtureRunnerError.streamingNotSupported
    }

    /// The fixture for one command, relative to the fixtures directory. Nil when the table has none.
    static func file(tool: String, _ arguments: [String], host: Arch) -> String? {
        let argv = withoutQuery(arguments)
        let x86 = host == .x86_64
        switch tool {
        case "brew":
            switch argv {
            case ["--version"]: return "homebrew/version.txt"
            case ["search", "--formula"]: return "homebrew/search-formula.txt"
            case ["search", "--cask"]: return "homebrew/search-cask.txt"
            case ["info", "--json=v2", "--installed"]: return "homebrew/info-installed.json"
            case ["outdated", "--json=v2"]: return "homebrew/outdated.json"
            case ["tap"]: return "homebrew/tap.txt"
            case ["info", "--json=v2", "--formula", "ripgrep"]: return "homebrew/info-ripgrep.json"
            case ["info", "--json=v2", "--cask", "firefox"]: return "homebrew/info-cask-firefox.json"
            case ["info", "--json=v2", "--cask", "blackhole-2ch"]: return "homebrew/info-cask-blackhole-2ch.json"
            default: return nil
            }
        case "nb":
            switch argv {
            case ["help"]: return "nanobrew/version.txt"
            case ["search", "--json"]: return "nanobrew/search.json"
            case ["list", "--json"]: return "nanobrew/list.json"
            case ["outdated", "--json"]: return "nanobrew/outdated.json"
            case ["info", "--json", "ripgrep"]: return "nanobrew/info-ripgrep.json"
            case ["info", "--cask", "--json", "firefox"]: return "nanobrew/info-cask-firefox.json"
            case ["info", "--cask", "--json", "blackhole-2ch"]: return "nanobrew/info-cask-blackhole-2ch.json"
            default: return nil
            }
        case "port":
            switch argv {
            case ["version"]: return "macports/version.txt"
            case ["search", "--line"]: return x86 ? "macports/x86_64/search.txt" : "macports/search.txt"
            case ["-v", "-q", "installed", "active"]:
                return x86 ? "macports/x86_64/installed.txt" : "macports/installed.txt"
            // The demo's ports were all asked for: the requested list is the installed one (its lines start with
            // the same "name @version").
            case ["-q", "installed", "requested"]:
                return x86 ? "macports/x86_64/installed.txt" : "macports/installed.txt"
            // No x86_64 capture of `port outdated` has rows; the text format is the same on both.
            case ["-q", "outdated"]: return "macports/outdated.txt"
            case ["info", "--name", "--description", "--homepage", "--version", "--variants", "--depends_lib",
                  "--depends_run", "ripgrep"]:
                return "macports/info-ripgrep.txt"
            default: return nil
            }
        case "mas":
            switch argv {
            case ["version"]: return "mas/version.txt"
            case ["search", "--json"]: return "mas/search.json"
            case ["list", "--json"]: return "mas/list.json"
            case ["outdated", "--json"]: return "mas/outdated.json"
            case ["info", "--json", "1176074088"]: return "mas/info.json"
            default: return nil
            }
        // `npm outdated` exits 1 whenever anything is outdated; the runner's 0 reads the same to the engine.
        case "npm":
            switch argv {
            case ["--version"]: return "npm/version.txt"
            case ["prefix", "-g"]: return "npm/prefix-g.txt"
            case ["ls", "-g", "--json", "--depth=0"]: return "npm/ls-g.json"
            case ["outdated", "-g", "--json"]: return "npm/outdated-g.json"
            case ["search", "--json", "--searchlimit=50"]: return "npm/search-cowsay.json"
            // Captured with more fields than BrewxPort now asks for; the engine reads only the ones it asks for.
            case ["view", "cowsay@latest", "name", "version", "description", "homepage", "--json"]:
                return "npm/view-cowsay.json"
            default: return nil
            }
        case "pipx":
            switch argv {
            case ["--version"]: return "pipx/version.txt"
            case ["environment", "--value", "PIPX_HOME"]: return "pipx/environment-pipx-home.txt"
            case ["environment", "--value", "PIPX_BIN_DIR"]: return "pipx/environment-pipx-bin-dir.txt"
            case ["list", "--json"]: return "pipx/list-json.json"
            case ["list", "--outdated", "--output", "json"]: return "pipx/list-outdated-json.json"
            default: return nil
            }
        // The installed list is from while isort was still pinned; the outdated one, the snapshot's final state,
        // has isort unpinned (ruff stays pinned, so only isort is an update).
        case "uv":
            switch argv {
            case ["--version"]: return "uv/version.txt"
            case ["tool", "dir", "--color", "never", "--no-progress"]: return "uv/tool-dir.txt"
            case ["tool", "dir", "--bin", "--color", "never", "--no-progress"]: return "uv/tool-dir-bin.txt"
            case ["tool", "list", "--show-version-specifiers", "--color", "never", "--no-progress"]:
                return "uv/tool-list-specifiers.txt"
            case ["tool", "list", "--show-version-specifiers", "--outdated", "--color", "never", "--no-progress"]:
                return "uv/tool-list-final.txt"
            // Each tool's Python, for the runtime hold-back (Task 10).
            case ["tool", "list", "--show-version-specifiers", "--show-with", "--show-extras", "--show-python",
                  "--show-paths", "--color", "never", "--no-progress"]:
                return "uv/tool-list-all-flags.txt"
            default: return nil
            }
        // The installed crates are cargo's record (`cargoRecord`), so `install --list` isn't asked.
        case "cargo":
            switch argv {
            case ["--version"]: return "cargo/version.txt"
            case ["search", "--limit", "20", "--color", "never"]: return "cargo/search-ripgrep.txt"
            default: return nil
            }
        case "rustc":
            switch argv {
            case ["--version"]: return "cargo/rustc-version.txt"
            default: return nil
            }
        // The snapshot's final state: cowsay and semver installed at their older versions, both outdated.
        case "bun":
            switch argv {
            case ["--version"]: return "bun/version.txt"
            case ["pm", "bin", "-g"]: return "bun/pm-bin-g.txt"
            case ["pm", "ls", "-g"]: return "bun/pm-ls-g-final.txt"
            case ["outdated", "-g"]: return "bun/outdated-g-final.txt"
            case ["info", "cowsay", "--json"]: return "bun/info-cowsay-json.json"
            default: return nil
            }
        // The snapshot's final state: thor and lolcat at their older versions, among Ruby's own gems.
        case "gem":
            switch argv {
            case ["--version"]: return "gem/version.txt"
            case ["environment"]: return "gem/environment.txt"
            case ["list", "--local"]: return "gem/list-local-final.txt"
            case ["outdated"]: return "gem/outdated.txt"
            case ["search", "--remote"]: return "gem/search-remote-broad.txt"
            default: return nil
            }
        // The snapshot's final state: JohnSundell/Ink 0.5.0, linked. Its metadata is `mintMetadata`'s.
        case "mint":
            switch argv {
            case ["--version"]: return "mint/version.txt"
            case ["list"]: return "mint/list-final.txt"
            default: return nil
            }
        // Mint's tag lookup, captured for JohnSundell/Ink only (newest tag 0.6.0).
        case "git":
            return argv == MintEngine.lsRemoteArguments("JohnSundell/Ink") ? "mint/ls-remote-tags-refs.txt" : nil
        // The `ruby` beside gem answers `GemEngine.executablesScript` from the captures instead (`gemExecutables`).
        default:
            return nil
        }
    }

    /// Mint's metadata from the fixtures, whatever folder it's asked for (`MintEngine.MetadataReader`): the captured
    /// `metadata.json`, never the disk's. Nil for any other file.
    public func mintMetadata(_ path: String) throws -> Data? {
        guard (path as NSString).lastPathComponent == "metadata.json" else { return nil }
        let relative = "mint/metadata.json"
        guard let data = FileManager.default.contents(atPath: fixtures.appendingPathComponent(relative).path) else {
            throw FixtureRunnerError.missingFixture(relative)
        }
        return data
    }

    /// Cargo's record from the fixtures, whatever install root it's asked for (`CargoEngine.RecordReader`): the
    /// captured `.crates2.json` and `.crates.toml`, never the disk's. Nil for any other file.
    public func cargoRecord(_ path: String) throws -> Data? {
        let relative: String
        switch (path as NSString).lastPathComponent {
        case ".crates2.json": relative = "cargo/crates2.json"
        case ".crates.toml": relative = "cargo/crates.toml"
        default: return nil
        }
        guard let data = FileManager.default.contents(atPath: fixtures.appendingPathComponent(relative).path) else {
            throw FixtureRunnerError.missingFixture(relative)
        }
        return data
    }

    /// `GemEngine.executablesScript`'s answer, which wasn't captured, made from the captures: Homebrew's Ruby installs
    /// gems outside its own gem folder (`environment.txt`), and for each of `GemEngine.capturedGemsWithExecutables`
    /// (not a capture: the one list the tests use too, until Task 13 captures the script) in the final list
    /// (`list-local-final.txt`), a `default: ` version is a default gem, one Ruby already had before anything was
    /// installed (`list-local-empty.txt`) is in Ruby's own folder, and any other is the user's. So the bundled gems
    /// are there, at the version Ruby shipped, and the engine leaves them out (R18).
    ///
    /// With `rubySharesGemFolder` (`--demo-states`, not what the captured Ruby does) gem installs into Ruby's own
    /// folder, so every copy but a default gem's is there: the engine lists the bundled gems as tools that came with
    /// Ruby (R19).
    func gemExecutables() throws -> String {
        func entries(_ relative: String) throws -> [(name: String, versions: [(String, Bool)])] {
            guard let data = FileManager.default.contents(atPath: fixtures.appendingPathComponent(relative).path) else {
                throw FixtureRunnerError.missingFixture(relative)
            }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                guard line.hasSuffix(")"), let open = line.range(of: " (") else { return nil }
                let versions = line[open.upperBound..<line.index(before: line.endIndex)].split(separator: ",")
                    .map { part -> (String, Bool) in
                        var entry = part.trimmingCharacters(in: .whitespaces)
                        let isDefault = entry.hasPrefix("default: ")
                        if isDefault { entry = String(entry.dropFirst("default: ".count)) }
                        return (String(entry.split(separator: " ").first ?? ""), isDefault)
                    }
                return (String(line[..<open.lowerBound]), versions)
            }
        }
        let rubys = Set(try entries("gem/list-local-empty.txt").flatMap { gem in
            gem.versions.map { "\(gem.name) \($0.0)" }
        })
        var lines = [rubySharesGemFolder ? "ruby-gems-shared" : "ruby-gems-separate"]
        let named = GemEngine.capturedGemsWithExecutables
        for gem in try entries("gem/list-local-final.txt") where named.contains(gem.name) {
            for (version, isDefault) in gem.versions {
                let inRubys = rubySharesGemFolder || rubys.contains("\(gem.name) \(version)")
                let place = isDefault ? "default" : (inRubys ? "ruby" : "user")
                lines.append("\(gem.name) (\(version)) \(place)")
            }
        }
        return lines.map { $0 + "\n" }.joined()
    }

    /// A search's argv without its query (and the `--` that `searchArguments` puts before a query starting with `-`).
    private static func withoutQuery(_ arguments: [String]) -> [String] {
        guard arguments.first == "search", arguments.count >= 3 else { return arguments }
        var base = Array(arguments.dropLast())
        if base.last == "--" { base.removeLast() }
        return base
    }
}

/// Registry answers from the fixtures, for the engines that read a registry (pipx and uv read PyPI, Cargo crates.io's
/// index and API, Bun the npm registry's search, RubyGems RubyGems.org's compact index and API). A URL without a
/// captured answer is unmapped, like an uncaptured command; nothing is fetched.
extension FixtureRunner: RegistryFetching {
    public func get(_ url: URL) async throws -> Data {
        guard let relative = Self.file(registry: url) else {
            throw FixtureRunnerError.unmappedURL(url.absoluteString)
        }
        guard let data = FileManager.default.contents(atPath: fixtures.appendingPathComponent(relative).path) else {
            throw FixtureRunnerError.missingFixture(relative)
        }
        return data
    }

    /// The captured answer for one registry URL, relative to the fixtures directory. Nil when there's none. Every npm
    /// registry search gets the one captured search, as a search command does (`DemoEngine` filters it).
    static func file(registry url: URL) -> String? {
        if url.host == "registry.npmjs.org", url.path == "/-/v1/search" { return "bun/registry-search-cowsay.json" }
        switch url.absoluteString {
        case "https://pypi.org/pypi/cowsay/json": return "pipx/pypi-cowsay.json"
        case "https://index.crates.io/ri/pg/ripgrep": return "cargo/index-ripgrep.txt"
        case "https://crates.io/api/v1/crates/ripgrep": return "cargo/api-crate-ripgrep.json"
        case "https://index.rubygems.org/info/thor": return "gem/index-info-thor.txt"
        case "https://index.rubygems.org/info/lolcat": return "gem/index-info-lolcat.txt"
        case "https://rubygems.org/api/v1/gems/lolcat.json": return "gem/api-gem-lolcat.json"
        default: return nil
        }
    }
}
