import Foundation

/// The package names BrewxPort passes to each engine's install, update and uninstall commands.
///
/// Language managers install from much more than a registry name: a URL, a git repository, a GitHub shorthand
/// (`someone/tool`, `github:someone/tool`), a local folder or archive. A typo or a pasted command could turn any of
/// those into "download and run this code", so only plain registry names in each ecosystem's own shape are allowed:
///
/// - npm and Bun: npm's name pattern (`@scope/name`; capitals allowed for old packages), at most 214 characters, not
///   a `.tgz`, `.tar.gz` or `.tar` file name (npm reads those as local files).
/// - pipx and uv: a PEP 508 project name, not an archive file name pip or uv would read as a local file.
/// - Cargo: a crates.io name (a letter, then letters, digits, `-` and `_`; at most 64 characters).
/// - RubyGems: letters, digits, `.`, `-` and `_` with at least one letter, not a `.gem` file name.
/// - Mint: exactly `owner/repo` on GitHub, never containing "github.com" (Mint would clone from the host before it).
///
/// Every name is printable ASCII without spaces and can't start with `-` (an option), `.`, `/` or `~` (a path). The
/// system engines (Homebrew, nanobrew, MacPorts, the Mac App Store) keep their own checks; here they only get the
/// shape every one of their names has.
public enum PackageNameRules {
    /// Throws an `EngineError` for `engine` when `name` isn't a name its registry could hold.
    public static func validate(_ name: String, for engine: EngineID) throws {
        guard isValid(name, for: engine) else {
            throw EngineError(engine: engine, message: refusal(name, for: engine))
        }
    }

    /// PEP 503's normalized form of a Python project name: lowercase, each run of `-`, `_` and `.` one `-`. PyPI and
    /// both tools compare names this way (`Zope.Interface` is `zope-interface`).
    public static func normalizedPythonName(_ name: String) -> String {
        var result = ""
        var inSeparator = false
        for character in name.lowercased() {
            if character == "-" || character == "_" || character == "." {
                if !inSeparator { result.append("-") }
                inSeparator = true
            } else {
                result.append(character)
                inSeparator = false
            }
        }
        return result
    }

    /// The longest name any engine accepts (npm's limit).
    static let maxLength = 214

    static func isValid(_ name: String, for engine: EngineID) -> Bool {
        guard !name.isEmpty, name.utf8.count <= maxLength,
              name.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              let first = name.first, !"-./~".contains(first) else { return false }
        switch engine {
        case .npm, .bun:
            return matches(name, npmName) && !hasSuffix(name, [".tgz", ".tar.gz", ".tar"])
        case .pipx, .uv:
            return matches(name, pythonName) && !hasSuffix(name, pythonArchives)
        case .cargo:
            return matches(name, crateName)
        case .gem:
            return matches(name, gemName) && name.contains(where: \.isLetter) && !hasSuffix(name, [".gem"])
        case .mint:
            // Mint clones `https://<name>.git` for any reference containing "github.com" (so `evil/github.com`
            // goes to the host `evil`); only a reference without it becomes `https://github.com/<name>.git`.
            return matches(name, mintName) && !name.lowercased().contains("github.com")
        case .homebrew, .nanobrew, .macports, .mas:
            return matches(name, systemName) && !name.contains("..") && !name.contains("//")
        }
    }

    // `@scope/name` or `name`; npm's pattern, with capitals for old packages like JSONStream.
    private static let npmName = regex(#"^(?:@[a-z0-9~-][a-z0-9._~-]*/)?[a-z0-9~-][a-z0-9._~-]*$"#, ignoringCase: true)
    // PEP 508: letters and digits at both ends, `.`, `_` and `-` between.
    private static let pythonName = regex(#"^(?:[a-z0-9]|[a-z0-9][a-z0-9._-]*[a-z0-9])$"#, ignoringCase: true)
    private static let crateName = regex(#"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#)
    private static let gemName = regex(#"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)
    // A GitHub owner (letters, digits, hyphens; no dot, which Mint would read as a host) and a repository of letters,
    // digits, `.`, `_` and `-` that doesn't start with `.` or `-` (so never `.` or `..`).
    private static let mintName = regex(#"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$"#)
    // Homebrew's `name`, `name@22`, `gtk+3`, `user/tap/name`; MacPorts' `p5.34-x`; the Mac App Store's IDs.
    private static let systemName = regex(#"^[A-Za-z0-9][A-Za-z0-9@+._/-]*$"#)

    /// The archive names pip and uv install as local files (pip's ARCHIVE_EXTENSIONS).
    private static let pythonArchives = [".whl", ".zip", ".tar.gz", ".tgz", ".tar", ".tar.bz2", ".tbz", ".tar.xz",
                                         ".txz", ".tlz", ".tar.lz", ".tar.lzma"]

    private static func regex(_ pattern: String, ignoringCase: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ignoringCase ? [.caseInsensitive] : [])
    }

    private static func matches(_ name: String, _ pattern: NSRegularExpression) -> Bool {
        pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static func hasSuffix(_ name: String, _ suffixes: [String]) -> Bool {
        let lower = name.lowercased()
        return suffixes.contains { lower.hasSuffix($0) }
    }

    private static func refusal(_ name: String, for engine: EngineID) -> String {
        let shown = "“\(BundleRules.shown(name))”"
        switch engine {
        case .mint:
            return "\(shown) isn't a GitHub owner/repo name. Mint packages are added as owner/repo."
        case .npm, .bun, .pipx, .uv, .cargo, .gem:
            return "\(shown) isn't a valid \(engine.displayName) package name. BrewxPort installs only by name "
                + "from the registry, not from a URL, a file or a git repository."
        case .homebrew, .nanobrew, .macports, .mas:
            return "Invalid package name: \(BundleRules.shown(name))"
        }
    }
}
