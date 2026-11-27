import Foundation

/// The result of checking one entry read from a bundle or a Brewfile.
public enum BundleVerdict: Equatable, Sendable {
    /// Safe to turn into a request. `options.version` is always nil: no engine command gets a version from a file.
    case accepted(ref: PackageRef, displayName: String, options: InstallOptions)
    /// Not handled. `reason` is shown to people as is; it never holds a raw control character.
    case rejected(reason: String)
}

/// The import validator. Bundle files and Brewfiles are untrusted: every entry passes `check` before it can become
/// an `ActionRequest`, and an entry that fails is listed as not handled, never trimmed into something that passes.
/// Each engine's `command(for:)` stays the second check.
public enum BundleRules {
    /// Longest name or mas display name accepted, in Unicode scalars.
    public static let maxLength = 200
    /// Longest mas app id, in digits.
    public static let maxMasIDLength = 15
    /// MacPorts extra arguments taken from a file: source-only and binary-only. Narrower than
    /// `RootArguments.macPortsExtraArgs`, which also covers flags people type in the app themselves.
    public static let macPortsExtraArgsFromFiles: Set<String> = ["-s", "-b"]
    /// Bundles don't carry language tools (Plan 9 design): an export leaves them out and an import refuses them.
    public static let languageToolReason = "language tools aren't included in bundles"

    /// Checks one entry. Rules run in a fixed order (engine, kind, name, variants, extra arguments, display name)
    /// and the first failure is the reason.
    public static func check(
        engine: EngineID,
        kind: PackageKind,
        name: String,
        displayName: String?,
        variants: [String],
        extraArgs: [String]
    ) -> BundleVerdict {
        guard !engine.isLanguage else { return .rejected(reason: languageToolReason) }
        guard kindFits(kind, engine) else {
            return .rejected(reason: "\(engine.displayName) has no \(plural(kind))")
        }

        let nameOK: Bool
        switch engine {
        case .homebrew: nameOK = kind == .tap ? isValidTapName(name) : isValidFormulaName(name, engine: .homebrew)
        case .nanobrew: nameOK = isValidFormulaName(name, engine: .nanobrew)
        case .macports: nameOK = isPlainText(name) && RootArguments.isValidPortName(name)
        case .mas: nameOK = isValidMasID(name)
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: nameOK = false  // refused above
        }
        guard nameOK else {
            return .rejected(reason: "“\(shown(name))” isn't a valid \(engine.displayName) \(singular(kind)) name")
        }

        if engine == .macports {
            if let bad = variants.first(where: { !isPlainText($0) || !RootArguments.isValidVariant($0) }) {
                return .rejected(reason: "“\(shown(bad))” isn't a valid MacPorts variant")
            }
        } else if !variants.isEmpty {
            return .rejected(reason: "carries variants, which only MacPorts has: \(list(variants))")
        }

        let refused = engine == .macports ? extraArgs.filter { !macPortsExtraArgsFromFiles.contains($0) } : extraArgs
        if !refused.isEmpty {
            return .rejected(reason: "carries command-line options BrewxPort won't take from a file: \(list(refused))")
        }

        let shownName: String
        if engine == .mas {
            guard let raw = displayName else { return .rejected(reason: "has no app name") }
            let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !isControl($0) }))
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return .rejected(reason: "has no app name") }
            guard cleaned.unicodeScalars.count <= maxLength else {
                return .rejected(reason: "has an app name longer than \(maxLength) characters")
            }
            shownName = cleaned
        } else {
            shownName = name
        }

        return .accepted(
            ref: PackageRef(engine: engine, kind: kind, name: name),
            displayName: shownName,
            options: InstallOptions(version: nil, variants: engine == .macports ? variants : [], extraArgs: extraArgs)
        )
    }

    /// A Homebrew formula or cask name (`jq`, or tap-qualified `user/repo/jq`), or a nanobrew name (`jq` only).
    /// Each segment is `^[A-Za-z0-9][A-Za-z0-9@._+-]*$` (ASCII), so `.`, `..`, empty and dash-leading segments fail.
    /// A name ending in `.rb` or `.json` (any case) fails too: `brew` reads it as a local file. Other engines: false.
    public static func isValidFormulaName(_ name: String, engine: EngineID) -> Bool {
        guard isPlainText(name), !looksLikeLocalFile(name) else { return false }
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        switch engine {
        case .homebrew: guard segments.count == 1 || segments.count == 3 else { return false }
        case .nanobrew: guard segments.count == 1 else { return false }
        case .macports, .mas, .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return false
        }
        return segments.allSatisfy { isSegment($0, extra: "@._+-") }
    }

    /// A third-party tap: exactly `user/repo`, each `^[A-Za-z0-9][A-Za-z0-9_.-]*$` (ASCII), and not Homebrew's own
    /// `homebrew/core` or `homebrew/cask` (any case), and not ending in `.rb` or `.json`.
    public static func isValidTapName(_ name: String) -> Bool {
        guard isPlainText(name), !looksLikeLocalFile(name) else { return false }
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, segments.allSatisfy({ isSegment($0, extra: "_.-") }) else { return false }
        return !builtInTaps.contains(name.lowercased())
    }

    /// Homebrew's own taps, lowercased. Their packages install by bare name and need no tap added.
    public static let builtInTaps: Set<String> = ["homebrew/core", "homebrew/cask"]

    /// The tap of a tap-qualified `user/repo/name`, as `user/repo` lowercased; nil for any other number of segments.
    public static func tapPrefix(_ name: String) -> String? {
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        return "\(segments[0])/\(segments[1])".lowercased()
    }

    /// A Mac App Store app id: 1 to 15 ASCII digits.
    public static func isValidMasID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= maxMasIDLength else { return false }
        return scalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Matches an imported ref to an installed one: engine, kind and the last `/` segment of the name, lowercased
    /// (`"homebrew/formula/borders"` for both `felixkratz/formulae/Borders` and `borders`). A tap keeps its whole
    /// name (`"homebrew/tap/felixkratz/formulae"`), since two taps often share a repository name.
    public static func matchKey(_ ref: PackageRef) -> String {
        let name = ref.kind == .tap ? Substring(ref.name) : lastSegment(ref.name)
        return "\(ref.engine.rawValue)/\(ref.kind.rawValue)/\(name.lowercased())"
    }

    /// The cross-engine "same package" key: mas uses `displayName`, every other engine the last segment of `name`,
    /// lowercased. A tap keeps its whole name, prefixed so it can't equal a package's key.
    public static func duplicateKey(_ package: Package) -> String {
        if package.id.kind == .tap { return "tap:" + package.id.name.lowercased() }
        if package.id.engine == .mas { return package.displayName.lowercased() }
        return lastSegment(package.id.name).lowercased()
    }

    // MARK: helpers

    /// Ends in `.rb` or `.json`, any case: Homebrew takes such an argument as a formula or cask file on disk.
    private static func looksLikeLocalFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".rb") || lower.hasSuffix(".json")
    }

    private static func kindFits(_ kind: PackageKind, _ engine: EngineID) -> Bool {
        switch engine {
        case .homebrew: return kind == .formula || kind == .cask || kind == .tap
        case .nanobrew: return kind == .formula || kind == .cask
        case .macports: return kind == .port
        case .mas: return kind == .app
        case .npm, .pipx, .uv, .cargo, .bun, .gem, .mint: return kind == .tool
        }
    }

    private static func singular(_ kind: PackageKind) -> String {
        switch kind {
        case .formula: return "formula"
        case .cask: return "cask"
        case .port: return "port"
        case .app: return "app id"
        case .tap: return "tap"
        case .tool: return "tool"
        }
    }

    private static func plural(_ kind: PackageKind) -> String {
        switch kind {
        case .formula: return "formulae"
        case .cask: return "casks"
        case .port: return "ports"
        case .app: return "App Store apps"
        case .tap: return "taps"
        case .tool: return "tools"
        }
    }

    /// Non-empty, at most `maxLength` scalars, and no whitespace or control/format characters.
    private static func isPlainText(_ s: String) -> Bool {
        var count = 0
        for scalar in s.unicodeScalars {
            count += 1
            if count > maxLength || scalar.properties.isWhitespace || isControl(scalar) { return false }
        }
        return count > 0
    }

    /// Control (Cc), format (Cf: bidi overrides, zero-width characters, BOM) and line/paragraph separators.
    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func isSegment(_ segment: Substring, extra: String) -> Bool {
        guard let first = segment.unicodeScalars.first, isAlnum(first) else { return false }
        return segment.unicodeScalars.allSatisfy { isAlnum($0) || extra.unicodeScalars.contains($0) }
    }

    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }

    private static func lastSegment(_ name: String) -> Substring {
        name.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(name)
    }

    private static func list(_ tokens: [String]) -> String {
        let shownTokens = tokens.prefix(5).map { shown($0) }
        return shownTokens.joined(separator: ", ") + (tokens.count > 5 ? ", …" : "")
    }

    /// A hostile token made safe to show: control, format and non-space whitespace scalars escaped as `\u{…}`,
    /// and cut to 40 scalars.
    static func shown(_ token: String) -> String {
        escaped(token, limit: 40)
    }

    /// A file name made safe to show, escaped like `shown` and cut to 255 scalars (the longest name macOS allows).
    public static func shownFileName(_ name: String) -> String {
        escaped(name, limit: 255)
    }

    /// `token` with control, format and non-space whitespace scalars escaped as `\u{…}`, cut to `limit` scalars of
    /// the original plus "…". Shared by `shown`, `BundleFile`'s display text and (`keepTabs`, since Brewfiles are often
    /// tab-indented) `BrewfileReader`'s line text.
    static func escaped(_ token: String, limit: Int, keepTabs: Bool = false) -> String {
        var out = ""
        var count = 0
        for scalar in token.unicodeScalars {
            if count == limit { return out + "…" }
            count += 1
            if keepTabs && scalar == "\t" {
                out.unicodeScalars.append(scalar)
            } else if isControl(scalar) || (scalar.properties.isWhitespace && scalar != " ") {
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
