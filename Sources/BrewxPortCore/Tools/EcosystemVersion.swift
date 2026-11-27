import Foundation

/// Version order by each ecosystem's own rules, never as text (`1.10 > 1.9`, PEP 440 `26.10.1 > 26.5.1`).
///
/// - `semver`: npm, Bun, Cargo and Mint's git tags. SemVer 2.0.0 precedence, read tolerantly as npm and Mint do: a
///   leading `v` (or `=`) is dropped, missing minor and patch count as 0, build metadata (`+…`) is ignored.
/// - `pep440`: pipx and uv. Epochs, pre-, post- and dev-releases and local versions, with PEP 440's spellings
///   (`alpha`, `c`, `rev`, `1.0-1`…) normalized, ordered as Python's `packaging` does.
/// - `gem`: RubyGems' Gem::Version. Any letter makes a prerelease, a dash starts one, trailing zeros don't count.
///
/// Text that isn't a version of the scheme (`linked`, a git ref, a `swift-DEVELOPMENT-SNAPSHOT` tag) is never newer
/// or older than anything: `compare` says `.orderedSame`. Filter with `isValid` before sorting.
public enum EcosystemVersion {
    public enum Scheme: Sendable, Equatable {
        case semver, pep440, gem
    }

    /// The scheme a language engine compares its tools' versions by; nil for the system engines, whose versions have
    /// rules of their own.
    public static func scheme(for engine: EngineID) -> Scheme? {
        switch engine {
        case .npm, .cargo, .bun, .mint: return .semver
        case .pipx, .uv: return .pep440
        case .gem: return .gem
        case .homebrew, .nanobrew, .macports, .mas: return nil
        }
    }

    /// How `a` orders against `b`; `.orderedSame` when either isn't a version of the scheme.
    public static func compare(_ a: String, _ b: String, scheme: Scheme) -> ComparisonResult {
        switch scheme {
        case .semver:
            guard let x = SemanticVersion(a), let y = SemanticVersion(b) else { return .orderedSame }
            return x.compare(y)
        case .pep440:
            guard let x = PythonVersion(a), let y = PythonVersion(b) else { return .orderedSame }
            return x.compare(y)
        case .gem:
            guard let x = GemVersion(a), let y = GemVersion(b) else { return .orderedSame }
            return x.compare(y)
        }
    }

    /// Whether `version` reads as a version of the scheme.
    public static func isValid(_ version: String, scheme: Scheme) -> Bool {
        switch scheme {
        case .semver: return SemanticVersion(version) != nil
        case .pep440: return PythonVersion(version) != nil
        case .gem: return GemVersion(version) != nil
        }
    }

    /// A pre-release: a semver `-…` part, a PEP 440 pre- or dev-release, a gem version with a letter. False for text
    /// that isn't a version.
    public static func isPrerelease(_ version: String, scheme: Scheme) -> Bool {
        switch scheme {
        case .semver: return SemanticVersion(version)?.isPrerelease ?? false
        case .pep440: return PythonVersion(version)?.isPrerelease ?? false
        case .gem: return GemVersion(version)?.isPrerelease ?? false
        }
    }

    /// The highest of `candidates` when it's newer than `installed`, else nil. Candidates that aren't versions are
    /// skipped, and pre-releases count only when `installed` is one. Nil when `installed` isn't a version (a git or
    /// linked install isn't compared), and when the registry's latest is lower than what's installed.
    public static func newerVersion(than installed: String, among candidates: [String], scheme: Scheme) -> String? {
        guard isValid(installed, scheme: scheme) else { return nil }
        let takesPrereleases = isPrerelease(installed, scheme: scheme)
        let eligible = candidates.filter {
            isValid($0, scheme: scheme) && (takesPrereleases || !isPrerelease($0, scheme: scheme))
        }
        guard let best = eligible.max(by: { compare($0, $1, scheme: scheme) == .orderedAscending }),
              compare(best, installed, scheme: scheme) == .orderedDescending else { return nil }
        return best
    }
}

// MARK: Shared pieces

private extension Character {
    /// By byte value, so a digit with a combining mark (one Character) doesn't count.
    var isASCIIDigit: Bool { asciiValue.map { (0x30...0x39).contains($0) } ?? false }
    var isASCIILetter: Bool { asciiValue.map { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) } ?? false }
}

/// Two runs of ASCII digits compared as numbers of any length (no overflow), leading zeros ignored.
private func compareDigits(_ a: Substring, _ b: Substring) -> ComparisonResult {
    let x = a.drop { $0 == "0" }, y = b.drop { $0 == "0" }
    if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
    if x.elementsEqual(y) { return .orderedSame }
    return x.utf8.lexicographicallyPrecedes(y.utf8) ? .orderedAscending : .orderedDescending
}

/// Byte order, as SemVer's "ASCII sort order" and Ruby's String comparison use.
private func compareBytes(_ a: Substring, _ b: Substring) -> ComparisonResult {
    if a.utf8.elementsEqual(b.utf8) { return .orderedSame }
    return a.utf8.lexicographicallyPrecedes(b.utf8) ? .orderedAscending : .orderedDescending
}

private func compareCounts(_ a: Int, _ b: Int) -> ComparisonResult {
    a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
}

private func isDigits(_ text: Substring) -> Bool { !text.isEmpty && text.allSatisfy(\.isASCIIDigit) }

// MARK: semver

private struct SemanticVersion {
    /// Major, minor, patch as digit runs; missing ones are "0".
    let core: [Substring]
    /// Pre-release identifiers; empty for a release.
    let prerelease: [Substring]

    var isPrerelease: Bool { !prerelease.isEmpty }

    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = rest.first, first == "v" || first == "V" || first == "=" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") {
            guard Self.identifiers(rest[rest.index(after: plus)...]) != nil else { return nil }
            rest = rest[..<plus]
        }
        var prerelease: [Substring] = []
        if let dash = rest.firstIndex(of: "-") {
            guard let ids = Self.identifiers(rest[rest.index(after: dash)...]) else { return nil }
            prerelease = ids
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy(isDigits) else { return nil }
        core = parts + Array(repeating: "0", count: 3 - parts.count)
        self.prerelease = prerelease
    }

    /// Dot-separated, non-empty identifiers of ASCII letters, digits and hyphens; nil otherwise.
    private static func identifiers(_ text: Substring) -> [Substring]? {
        let ids = text.split(separator: ".", omittingEmptySubsequences: false)
        let valid = ids.allSatisfy { id in
            !id.isEmpty && id.allSatisfy { $0.isASCIIDigit || $0.isASCIILetter || $0 == "-" }
        }
        return valid ? ids : nil
    }

    func compare(_ other: SemanticVersion) -> ComparisonResult {
        for (x, y) in zip(core, other.core) {
            let result = compareDigits(x, y)
            if result != .orderedSame { return result }
        }
        // A release is above any of its pre-releases.
        switch (prerelease.isEmpty, other.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(prerelease, other.prerelease) {
            let result: ComparisonResult
            switch (isDigits(x), isDigits(y)) {
            case (true, true): result = compareDigits(x, y)
            case (true, false): result = .orderedAscending
            case (false, true): result = .orderedDescending
            case (false, false): result = compareBytes(x, y)
            }
            if result != .orderedSame { return result }
        }
        return compareCounts(prerelease.count, other.prerelease.count)
    }
}

// MARK: PEP 440

/// Below every value, a value, or above every value: how `packaging` fills in a missing pre, post or dev part.
private enum Bound<Value> {
    case low, value(Value), high

    func compare(_ other: Bound, _ values: (Value, Value) -> ComparisonResult) -> ComparisonResult {
        switch (self, other) {
        case (.low, .low), (.high, .high): return .orderedSame
        case (.low, _), (_, .high): return .orderedAscending
        case (.high, _), (_, .low): return .orderedDescending
        case (.value(let x), .value(let y)): return values(x, y)
        }
    }
}

private struct PythonVersion {
    /// PEP 440's canonical pattern (Appendix B), case-insensitive.
    private static let pattern = try! NSRegularExpression(pattern: #"""
        ^\s*v?
        (?:(?<epoch>[0-9]+)!)?
        (?<release>[0-9]+(?:\.[0-9]+)*)
        (?<pre>[-_.]?(?<prel>alpha|a|beta|b|preview|pre|c|rc)[-_.]?(?<pren>[0-9]+)?)?
        (?<post>(?:-(?<postn1>[0-9]+))|(?:[-_.]?(?<postl>post|rev|r)[-_.]?(?<postn2>[0-9]+)?))?
        (?<dev>[-_.]?(?<devl>dev)[-_.]?(?<devn>[0-9]+)?)?
        (?:\+(?<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?
        \s*$
        """#, options: [.caseInsensitive, .allowCommentsAndWhitespace])

    let epoch: Substring
    let release: [Substring]
    /// (0 for a, 1 for b, 2 for rc; number)
    let pre: (rank: Int, number: Substring)?
    let post: Substring?
    let dev: Substring?
    let local: [Substring]?

    var isPrerelease: Bool { pre != nil || dev != nil }

    init?(_ text: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.pattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ name: String) -> Substring? {
            Range(match.range(withName: name), in: text).map { text[$0] }
        }
        epoch = group("epoch") ?? "0"
        release = group("release").map { $0.split(separator: ".") } ?? []
        if let label = group("prel")?.lowercased() {
            let rank = ["a": 0, "alpha": 0, "b": 1, "beta": 1][label] ?? 2
            pre = (rank, group("pren") ?? "0")
        } else {
            pre = nil
        }
        if group("post") != nil {
            post = group("postn1") ?? group("postn2") ?? "0"
        } else {
            post = nil
        }
        dev = group("dev") != nil ? (group("devn") ?? "0") : nil
        local = group("local").map { $0.split(whereSeparator: { "-_.".contains($0) }) }
    }

    func compare(_ other: PythonVersion) -> ComparisonResult {
        var result = compareDigits(epoch, other.epoch)
        if result != .orderedSame { return result }
        // Release segments padded with zeros, so 1.0 == 1.0.0.
        for i in 0..<max(release.count, other.release.count) {
            result = compareDigits(i < release.count ? release[i] : "0",
                                   i < other.release.count ? other.release[i] : "0")
            if result != .orderedSame { return result }
        }
        result = preKey.compare(other.preKey) { x, y in
            x.rank != y.rank ? compareCounts(x.rank, y.rank) : compareDigits(x.number, y.number)
        }
        if result != .orderedSame { return result }
        result = (post.map { Bound.value($0) } ?? .low).compare(other.post.map { Bound.value($0) } ?? .low,
                                                                compareDigits)
        if result != .orderedSame { return result }
        result = (dev.map { Bound.value($0) } ?? .high).compare(other.dev.map { Bound.value($0) } ?? .high,
                                                                compareDigits)
        if result != .orderedSame { return result }
        return (local.map { Bound.value($0) } ?? .low).compare(other.local.map { Bound.value($0) } ?? .low,
                                                               Self.compareLocal)
    }

    /// A dev release with no pre or post part (1.0.dev1) sorts before 1.0's pre-releases; a release with no pre part
    /// after them.
    private var preKey: Bound<(rank: Int, number: Substring)> {
        if let pre { return .value(pre) }
        return post == nil && dev != nil ? .low : .high
    }

    /// Local parts in order: numbers compare as numbers and above words, words case-insensitively; a longer local
    /// version is above its prefix.
    private static func compareLocal(_ a: [Substring], _ b: [Substring]) -> ComparisonResult {
        for (x, y) in zip(a, b) {
            let result: ComparisonResult
            switch (isDigits(x), isDigits(y)) {
            case (true, true): result = compareDigits(x, y)
            case (true, false): result = .orderedDescending
            case (false, true): result = .orderedAscending
            case (false, false): result = compareBytes(Substring(x.lowercased()), Substring(y.lowercased()))
            }
            if result != .orderedSame { return result }
        }
        return compareCounts(a.count, b.count)
    }
}

// MARK: Gem::Version

private struct GemVersion {
    /// Gem::Version's ANCHORED_VERSION_PATTERN, without the empty version it also allows.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^\s*[0-9]+(?:\.[0-9a-zA-Z]+)*(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\s*$"#)

    private enum Segment {
        case number(Substring), word(Substring)
    }

    /// Gem::Version's canonical_segments: the numeric part and the rest (from the first word), each without
    /// trailing zeros.
    private let segments: [Segment]
    let isPrerelease: Bool

    init?(_ text: String) {
        guard Self.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
            return nil
        }
        // Gem::Version reads "1.0.0-rc1" as "1.0.0.pre.rc1".
        let version = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: ".pre.")
        isPrerelease = version.contains(where: \.isASCIILetter)
        var all: [Segment] = []
        var rest = Substring(version)
        while let start = rest.firstIndex(where: { $0.isASCIIDigit || $0.isASCIILetter }) {
            rest = rest[start...]
            let digits = rest.first!.isASCIIDigit
            let run = rest.prefix { digits ? $0.isASCIIDigit : $0.isASCIILetter }
            all.append(digits ? .number(run) : .word(run))
            rest = rest[run.endIndex...]
        }
        let firstWord = all.firstIndex { if case .word = $0 { true } else { false } } ?? all.count
        segments = Self.droppingTrailingZeros(Array(all[..<firstWord]))
            + Self.droppingTrailingZeros(Array(all[firstWord...]))
    }

    private static func droppingTrailingZeros(_ segments: [Segment]) -> [Segment] {
        var result = segments
        while case .number(let digits)? = result.last, digits.allSatisfy({ $0 == "0" }) { result.removeLast() }
        return result
    }

    /// Segment by segment, a missing one counting as 0; a word is below a number, words compare by bytes.
    func compare(_ other: GemVersion) -> ComparisonResult {
        for i in 0..<max(segments.count, other.segments.count) {
            let x = i < segments.count ? segments[i] : .number("0")
            let y = i < other.segments.count ? other.segments[i] : .number("0")
            let result: ComparisonResult
            switch (x, y) {
            case (.number(let a), .number(let b)): result = compareDigits(a, b)
            case (.word(let a), .word(let b)): result = compareBytes(a, b)
            case (.word, .number): result = .orderedAscending
            case (.number, .word): result = .orderedDescending
            }
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}
