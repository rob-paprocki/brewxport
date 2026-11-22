import Foundation

/// Something a Brewfile export didn't carry, and why: a whole package, or a pin or options on a package it wrote.
public struct LeftOut: Equatable, Sendable {
    public var ref: PackageRef
    public var displayName: String
    /// Shown to people as is.
    public var reason: String

    public init(ref: PackageRef, displayName: String, reason: String) {
        self.ref = ref
        self.displayName = displayName
        self.reason = reason
    }
}

/// Writes a plain Brewfile: only what `brew bundle` reads on its own, so the file is useful without BrewxPort.
///
/// One header comment (BrewxPort and the date, nothing about the user or the Mac), then `tap`, `brew`, `cask` and
/// `mas "Name", id: N` lines in that order, each group sorted by plain `String` order. Strings are double-quoted
/// with `"` and `\` escaped, `#` escaped only before `{`, `@` or `$` (so `#{…}` in an app name can't run as Ruby,
/// while "C# Notes" stays plain and reads back) and control or format scalars written as `\u{…}`. Everything not
/// written is listed in `leftOut`, in the bundle's entry order.
public enum BrewfileWriter {
    static let nanobrewReason = "nanobrew packages aren't in Brewfiles"
    static let macPortsReason = "MacPorts packages aren't in Brewfiles"
    static let pinReason = "Brewfiles can't pin a version"
    static let optionsReason = "Brewfiles from BrewxPort carry no install options"
    static let octalReason = "app ids starting with 0 read as octal in a Brewfile"

    public static func write(_ bundle: BundleFile, date: Date) -> (text: String, leftOut: [LeftOut]) {
        write(bundle, date: date, timeZone: .current)
    }

    static func write(_ bundle: BundleFile, date: Date, timeZone: TimeZone) -> (text: String, leftOut: [LeftOut]) {
        var taps = Set<String>(), formulae = Set<String>(), casks = Set<String>()
        var apps: [(name: String, id: String)] = []
        var seenApps = Set<String>()
        var leftOut: [LeftOut] = []

        for entry in bundle.entries {
            func leave(_ reason: String) {
                leftOut.append(LeftOut(ref: entry.ref, displayName: entry.displayName, reason: reason))
            }
            switch entry.engine {
            case .nanobrew: leave(nanobrewReason); continue
            case .macports: leave(macPortsReason); continue
            case .homebrew, .mas: break
            }
            // The same check an import runs, on the package alone: pins and options are reported below instead.
            let verdict = BundleRules.check(engine: entry.engine, kind: entry.kind, name: entry.name,
                                            displayName: entry.displayName, variants: [], extraArgs: [])
            guard case .accepted(let ref, let shownName, _) = verdict else {
                if case .rejected(let reason) = verdict { leave(reason) }
                continue
            }
            switch ref.kind {
            case .tap: taps.insert(ref.name)
            case .formula: formulae.insert(ref.name)
            case .cask: casks.insert(ref.name)
            case .app:
                if ref.name.count > 1, ref.name.hasPrefix("0") {
                    leave(octalReason)
                    continue
                }
                if seenApps.insert(ref.name).inserted { apps.append((shownName, ref.name)) }
            case .port:
                // BundleRules never accepts a port outside MacPorts, but nothing is skipped without a reason.
                leave(macPortsReason)
                continue
            }
            if entry.versionPin != nil { leave(pinReason) }
            if entry.options != InstallOptions() { leave(optionsReason) }
        }

        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
        var lines = ["# Brewfile written by BrewxPort on \(day)"]
        lines += taps.sorted().map { "tap \(quoted($0))" }
        // Homebrew 7 wants `trusted: true` on formulae and casks from a third-party tap (see the Brewfile fixtures).
        func trust(_ name: String) -> String { BrewfileReader.isThirdPartyQualified(name) ? ", trusted: true" : "" }
        lines += formulae.sorted().map { "brew \(quoted($0))\(trust($0))" }
        lines += casks.sorted().map { "cask \(quoted($0))\(trust($0))" }
        lines += apps.sorted { ($0.name, $0.id) < ($1.name, $1.id) }.map { "mas \(quoted($0.name)), id: \($0.id)" }
        return (lines.joined(separator: "\n") + "\n", leftOut)
    }

    /// A Ruby double-quoted string literal that reads back as `text` and runs nothing.
    static func quoted(_ text: String) -> String {
        var out = "\""
        let scalars = Array(text.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            let next = i + 1 < scalars.count ? scalars[i + 1] : nil
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "#" where next == "{" || next == "@" || next == "$": out += "\\#"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    out += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
