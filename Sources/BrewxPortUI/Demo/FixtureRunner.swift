import Foundation
import BrewxPortCore

public enum FixtureRunnerError: Error, Equatable, Sendable {
    /// No captured output for these arguments (after the executable).
    case unmapped([String])
    /// The table names a file the fixtures directory doesn't have.
    case missingFixture(String)
    /// Demo mode never streams: every change is simulated by `DemoRunExecutor`.
    case streamingNotSupported
}

/// Answers the engines' read-only commands from the captured fixtures. Nothing is ever launched.
///
/// The table is keyed by the tool (the executable's name) and the argv after it. A search query is a wildcard: every
/// search gets the one captured search, and `DemoEngine` filters it.
public final class FixtureRunner: CommandRunning {
    public let fixtures: URL
    public let host: Arch

    public init(fixtures: URL, host: Arch) {
        self.fixtures = fixtures
        self.host = host
    }

    public func run(_ executable: URL, _ arguments: [String], options: RunOptions) async throws -> CommandResult {
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
            case ["info", "--description", "--homepage", "--version", "--variants", "--depends_lib", "--depends_run",
                  "ripgrep"]:
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
        default:
            return nil
        }
    }

    /// A search's argv without its query (and the `--` that `searchArguments` puts before a query starting with `-`).
    private static func withoutQuery(_ arguments: [String]) -> [String] {
        guard arguments.first == "search", arguments.count >= 3 else { return arguments }
        var base = Array(arguments.dropLast())
        if base.last == "--" { base.removeLast() }
        return base
    }
}
