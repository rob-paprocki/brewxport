import Foundation

/// Builds a `.brewxportbundle` from what's installed: every package (dependencies included) and every third-party tap.
///
/// Each one goes through `BundleRules.check`, the same check an import runs, so an export never holds an entry an
/// import would refuse. One that fails, or repeats a ref already written, is left out and named in `refused`.
/// Language tools are never in bundles (Plan 9): they're left out without a line each, and the summary counts them
/// (`languageTools`, `ExportSummary.languageToolsLine`).
public enum BundleExporter {
    /// Entry order: engine (`EngineID.allCases`), then kind (this order), then name (plain `String` order, not the
    /// locale's), so two exports of the same Mac are byte-identical.
    static let kindOrder: [PackageKind] = [.tap, .formula, .cask, .port, .app]

    public static func make(installed: [Package], taps: [String], appVersion: String, arch: Arch)
        -> (bundle: BundleFile, refused: [String]) {
        var entries: [BundleEntry] = []
        var refused: [String] = []
        var seen = Set<PackageRef>()

        func add(engine: EngineID, kind: PackageKind, name: String, displayName: String?, variants: [String],
                 installedVersion: String?) {
            switch BundleRules.check(engine: engine, kind: kind, name: name, displayName: displayName,
                                     variants: variants, extraArgs: []) {
            case .rejected(let reason):
                refused.append("\(engine.displayName) “\(BundleRules.shown(name))”: \(reason)")
            case .accepted(let ref, let shownName, let options):
                // The same ref twice would come back "listed twice" on import: the first is kept, the rest named.
                guard seen.insert(ref).inserted else {
                    let label = engine == .mas ? shownName : name
                    refused.append("\(engine.displayName) “\(BundleRules.shown(label))”: listed twice")
                    return
                }
                entries.append(BundleEntry(engine: ref.engine, kind: ref.kind, name: ref.name, displayName: shownName,
                                           installedVersion: installedVersion, versionPin: nil, options: options,
                                           id: nil))
            }
        }

        for tap in taps {
            add(engine: .homebrew, kind: .tap, name: tap, displayName: nil, variants: [], installedVersion: nil)
        }
        for package in installed where !package.id.engine.isLanguage {
            add(engine: package.id.engine, kind: package.id.kind, name: package.fullName ?? package.id.name,
                displayName: package.displayName,
                variants: package.id.engine == .macports ? package.requestedVariants : [],
                installedVersion: package.installedVersion)
        }

        let engineOrder = EngineID.allCases
        func rank(_ e: BundleEntry) -> (Int, Int) {
            (engineOrder.firstIndex(of: e.engine) ?? engineOrder.count,
             kindOrder.firstIndex(of: e.kind) ?? kindOrder.count)
        }
        entries.sort { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.name < b.name
        }
        refused.sort()
        let bundle = BundleFile(createdBy: "BrewxPort " + appVersion, arch: arch, entries: entries)
        return (bundle, refused)
    }

    /// How many language tools `installed` has, by manager: what an export leaves out of every bundle and Brewfile.
    public static func languageTools(_ installed: [Package]) -> [EngineID: Int] {
        Dictionary(grouping: installed.filter(\.id.engine.isLanguage), by: \.id.engine).mapValues(\.count)
    }

    /// For an export of only what the user installed: drops packages their engine marks as installed as a
    /// dependency (`installedOnRequest == false`). One the engine says nothing about (nil) stays, and its engine is
    /// named in `unknown` so the message after saving can say why its dependencies are still in. Taps aren't
    /// packages and are never dropped.
    public static func requestedOnly(_ installed: [Package])
        -> (kept: [Package], dependencies: Int, unknown: Set<EngineID>) {
        var kept: [Package] = []
        var dependencies = 0
        var unknown = Set<EngineID>()
        for package in installed {
            switch package.installedOnRequest {
            case false?:
                dependencies += 1
            case true?:
                kept.append(package)
            case nil:
                // A language tool isn't exported either way, so its manager has nothing to explain.
                if !package.id.engine.isLanguage { unknown.insert(package.id.engine) }
                kept.append(package)
            }
        }
        return (kept, dependencies, unknown)
    }
}

/// What an export wrote and what it couldn't: the review sheet lists what's missing, and the message after saving
/// gives the count.
public struct ExportSummary: Equatable, Sendable {
    /// Entries written per engine, taps counted under Homebrew. Engines with no entries aren't listed.
    public var counts: [EngineID: Int]
    /// Engines whose installed list (or, for Homebrew, tap list) failed, with the error. What they failed to list
    /// isn't in the file.
    public var failedEngines: [EngineID: String]
    /// Packages and taps left out because they didn't pass `BundleRules.check`, by name with the reason.
    public var refused: [String]
    /// Dependencies left out because the export was for only what the user installed. Not a problem, so the review
    /// sheet doesn't list them; the message after saving gives the count.
    public var dependenciesLeftOut: Int
    /// Engines, in an export without dependencies, that don't say which packages were dependencies: all their
    /// packages are in.
    public var dependenciesUnknown: Set<EngineID>
    /// The language tools installed, by manager, which no bundle or Brewfile carries.
    public var languageTools: [EngineID: Int]
    /// The language managers whose listing failed: their tools aren't counted, and no file would carry them anyway,
    /// so they're named in `languageToolsLine`, never in `failedEngines`.
    public var languageToolsUnlisted: Set<EngineID>

    public init(counts: [EngineID: Int], failedEngines: [EngineID: String], refused: [String],
                dependenciesLeftOut: Int = 0, dependenciesUnknown: Set<EngineID> = [],
                languageTools: [EngineID: Int] = [:], languageToolsUnlisted: Set<EngineID> = []) {
        self.counts = counts
        self.failedEngines = failedEngines
        self.refused = refused
        self.dependenciesLeftOut = dependenciesLeftOut
        self.dependenciesUnknown = dependenciesUnknown
        self.languageTools = languageTools
        self.languageToolsUnlisted = languageToolsUnlisted
    }

    /// The one line saying the language tools aren't in the file: "Not included: 12 language tools (npm, Cargo)",
    /// the managers in the sidebar's order, then those that couldn't be listed: "… and pipx's tools, which couldn't
    /// be listed". Nil when there are none of either.
    public var languageToolsLine: String? {
        var parts: [String] = []
        let total = languageTools.values.reduce(0, +)
        if total > 0 {
            let managers = EngineID.allCases.filter { (languageTools[$0] ?? 0) > 0 }.map(\.displayName)
            let tools = total == 1 ? "1 language tool" : "\(total) language tools"
            parts.append("\(tools) (" + managers.joined(separator: ", ") + ")")
        }
        let unlisted = EngineID.allCases.filter(languageToolsUnlisted.contains).map(\.possessive)
        if let last = unlisted.last {
            let names = unlisted.count == 1 ? last : unlisted.dropLast().joined(separator: ", ") + " and " + last
            parts.append(names + " tools, which couldn't be listed")
        }
        guard !parts.isEmpty else { return nil }
        return "Not included: " + parts.joined(separator: " and ")
    }

    /// A failed tap listing counts as a Homebrew failure; when Homebrew's installed list failed too, both messages
    /// are kept, joined with "; ".
    public static func make(_ bundle: BundleFile, errors: [EngineError], tapsError: EngineError?, refused: [String])
        -> ExportSummary {
        var counts: [EngineID: Int] = [:]
        for entry in bundle.entries { counts[entry.engine, default: 0] += 1 }
        var failed: [EngineID: String] = [:]
        for error in errors + [tapsError].compactMap({ $0 }) {
            if let earlier = failed[error.engine] {
                failed[error.engine] = earlier + "; " + error.message
            } else {
                failed[error.engine] = error.message
            }
        }
        return ExportSummary(counts: counts, failedEngines: failed, refused: refused)
    }
}
