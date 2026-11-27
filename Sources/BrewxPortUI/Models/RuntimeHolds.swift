import Foundation
import BrewxPortCore

/// A Homebrew runtime update that would break language tools (design option A): held back from automatic updates,
/// told once in its own notice, and confirmed by the person before a manual update. Afterwards the engines whose
/// tools run on it offer Repair tools.
public struct RuntimeHold: Equatable, Sendable {
    public let hold: UpdateHold
    /// The notice's title: "Ruby 4.1 is ready". Its body is `hold.reason`.
    public let noticeTitle: String
    /// The runtime's name for people: "Ruby", "Node", "Python".
    public let runtime: String
    /// The version the update brings, as people say it: "4.1" (Ruby), "26" (Node), "3.15.3" (Python).
    public let version: String
    /// The engines whose tools need repairing afterwards, with the tools Installed would name (empty: all of them).
    public let engines: [EngineID: [String]]

    /// The manual update's warning: "Ruby 4.1 needs your gems reinstalled. After the update, use Repair tools on the
    /// RubyGems page."
    public var warning: String {
        let ids = RuntimeHolds.ordered(engines.keys)
        let pages = RuntimeHolds.list(ids.map(\.displayName)) + (ids.count == 1 ? " page" : " pages")
        return "\(runtime) \(version) needs \(RuntimeHolds.tools(ids)) \(RuntimeHolds.verb(ids)). After the update, "
            + "use Repair tools on the \(pages)."
    }
}

/// Which Homebrew runtime updates hold back, and the words for them. Ruby's minor updates move its gem folder, so
/// every gem is left behind; Node's major updates need native globals rebuilt; an update of a python@3.x (a patch
/// update: the formula is the minor version) replaces the Cellar copy that tools pinned to it were made with, while
/// a tool made through Homebrew's `opt` or `bin` link follows it (R29, `RuntimeUse.patchSafeTools`).
public enum RuntimeHolds {
    /// The engines whose tools may run on `formula`: npm on `node`, RubyGems on `ruby`, pipx and uv on a
    /// `python@3.x`. Empty for anything else.
    public static func engines(for formula: String) -> [EngineID] {
        if formula == "node" { return [.npm] }
        if formula == "ruby" { return [.gem] }
        if HomebrewFormula.python(version: String(formula.dropFirst("python@".count))) != nil,
           formula.hasPrefix("python@") { return [.pipx, .uv] }
        return []
    }

    /// A `python@3.x` formula.
    static func isPython(_ formula: String) -> Bool { engines(for: formula) == [.pipx, .uv] }

    /// The Homebrew rows on Updates that may need holding: `node`, `ruby` and `python@3.x` formulae.
    public static func candidates(_ rows: [Package]) -> [Package] {
        rows.filter { $0.id.engine == .homebrew && $0.id.kind == .formula && !engines(for: $0.id.name).isEmpty }
    }

    /// The holds for `rows` (Homebrew's), given what each engine said its tools run on: nil for an engine that
    /// couldn't say, which counts as running on every runtime it could (the careful reading). An engine without an
    /// answer (not installed) runs on none.
    public static func holds(_ rows: [Package], uses: [EngineID: [RuntimeUse]?]) -> [PackageRef: RuntimeHold] {
        var holds: [PackageRef: RuntimeHold] = [:]
        for row in candidates(rows) {
            let formula = row.id.name
            guard let installed = row.installedVersion, let latest = row.latestVersion,
                  breaks(formula, from: installed, to: latest) else { continue }
            var affected: [EngineID: [String]] = [:]
            for engine in engines(for: formula) {
                guard let answer = uses[engine] else { continue }
                guard let found = answer else {
                    affected[engine] = []
                    continue
                }
                guard let use = found.first(where: { $0.formula == formula }) else { continue }
                // R29: an update of a python@3.x formula is a patch update (the formula is the minor version), which
                // only breaks the tools pinned to the copy it replaces; npm's and RubyGems' rules above are per version.
                let tools = isPython(formula) ? use.tools.filter { !use.patchSafeTools.contains($0) } : use.tools
                if isPython(formula), tools.isEmpty, !use.tools.isEmpty { continue }
                affected[engine] = tools
            }
            guard !affected.isEmpty else { continue }
            let ids = ordered(affected.keys)
            let (runtime, version) = shown(formula, latest)
            let reason = "Updating it needs \(tools(ids)) \(verb(ids))."
            holds[row.id] = RuntimeHold(hold: UpdateHold(reason: reason, blocksAutomatic: true, blocksManual: false),
                                        noticeTitle: "\(runtime) \(version) is ready", runtime: runtime,
                                        version: version, engines: affected)
        }
        return holds
    }

    /// Whether going from `installed` to `latest` breaks the tools: a different Ruby minor version (major.minor), a
    /// different Node major version, any Python change. A version BrewxPort can't read counts as breaking.
    static func breaks(_ formula: String, from installed: String, to latest: String) -> Bool {
        let old = parts(installed), new = parts(latest)
        switch formula {
        case "ruby": return old.count < 2 || new.count < 2 || old.prefix(2) != new.prefix(2)
        case "node": return old.isEmpty || new.isEmpty || old[0] != new[0]
        default: return installed != latest
        }
    }

    /// A Homebrew version's numbers: `25.2.1_1` gives 25, 2, 1 (the `_1` is Homebrew's own revision). Stops at the
    /// first part that isn't a number.
    static func parts(_ version: String) -> [Int] {
        let plain = version.split(separator: "_").first.map(String.init) ?? version
        var numbers: [Int] = []
        for part in plain.split(separator: ".") {
            guard let number = Int(part) else { break }
            numbers.append(number)
        }
        return numbers
    }

    /// The runtime's name and the new version as people say it.
    static func shown(_ formula: String, _ latest: String) -> (String, String) {
        let numbers = parts(latest).map(String.init)
        switch formula {
        case "ruby": return ("Ruby", numbers.prefix(2).joined(separator: "."))
        case "node": return ("Node", numbers.first ?? latest)
        default: return ("Python", latest.split(separator: "_").first.map(String.init) ?? latest)
        }
    }

    /// "your gems", "your npm tools", "your pipx and uv tools".
    static func tools(_ engines: [EngineID]) -> String {
        if engines == [.gem] { return "your gems" }
        return "your " + list(engines.map(\.displayName)) + " tools"
    }

    /// npm rebuilds its globals; the others reinstall theirs.
    static func verb(_ engines: [EngineID]) -> String { engines == [.npm] ? "rebuilt" : "reinstalled" }

    /// The engines in the sidebar's order.
    static func ordered<C: Collection>(_ engines: C) -> [EngineID] where C.Element == EngineID {
        EngineID.allCases.filter(engines.contains)
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}
