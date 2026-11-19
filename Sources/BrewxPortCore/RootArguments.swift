import Foundation

/// Allow-lists for anything user- or bundle-supplied that ends up in a command run as root.
/// The BrewxPortHelper daemon re-validates MacPorts argv with `validateMacPorts` before it runs anything.
public enum RootArguments {
    /// MacPorts global flags that may be added to a root command: source-only, binary-only, no deps,
    /// also-dependents, uninstall-old, autoclean. These are parsed identically before or after the
    /// action (`parse_options` in macports-base `src/port/port.tcl`), so they sit right after the verb.
    public static let macPortsExtraArgs: Set<String> = ["-s", "-b", "-n", "-R", "-u", "-c"]

    /// Words `port` reads as pseudo-portnames or logical operators, not as a port. Derived from the
    /// pseudo-port regex block in `element` (macports-base src/port/port.tcl, ~line 1095) plus the
    /// `or`/`and`/`not` cases of orExpr/andExpr/unaryExpr (~lines 980-1060). Re-sync when MacPorts adds one.
    private static let reservedWords: Set<String> = [
        "all", "current", "active", "inactive", "actinact", "installed", "uninstalled", "outdated", "obsolete",
        "requested", "unrequested", "leaves", "rleaves", "and", "or", "not",
    ]

    /// A literal port name: `^[A-Za-z0-9][A-Za-z0-9._+-]*$` (ASCII), and not a reserved word.
    /// This keeps globs, `name:regex` selectors and pseudo-portnames out of a command that runs as root.
    public static func isValidPortName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, isAlnum(first) else { return false }
        guard name.unicodeScalars.allSatisfy({ isAlnum($0) || "._+-".unicodeScalars.contains($0) }) else { return false }
        return !reservedWords.contains(name.lowercased())
    }

    /// `+name` or `-name`, name of 2+ ASCII letters, digits or underscores. Single letters would read as port's global flags.
    public static func isValidVariant(_ v: String) -> Bool {
        guard let sign = v.first, sign == "+" || sign == "-" else { return false }
        let name = v.dropFirst()
        return name.count >= 2 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Throws an `EngineError` naming the first token that isn't allowed.
    public static func validateMacPorts(names: [String], variants: [String], extraArgs: [String]) throws {
        for arg in extraArgs where !macPortsExtraArgs.contains(arg) {
            throw EngineError(engine: .macports, message: "Argument not allowed for a root command: \(arg)")
        }
        for name in names where !isValidPortName(name) {
            throw EngineError(engine: .macports, message: "Invalid port name: \(name)")
        }
        for variant in variants where !isValidVariant(variant) {
            throw EngineError(engine: .macports, message: "Invalid variant: \(variant)")
        }
    }

    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}
