import CryptoKit
import Foundation

/// Decides whether a downloaded installer is safe to run. Pure: the caller runs pkgutil and spctl and passes the text.
public enum EngineSetupTrust {
    /// Homebrew's Developer ID Installer team (Task 0 capture). MacPorts' signer is a personal ID that changes, so it is not pinned.
    public static let homebrewTeamID = "927JGANW46"

    /// SHA-256 of a file as lowercase hex, read in 1 MB chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Nil means trusted. Anything not explicitly good is a verification error.
    public static func pkgVerdict(target: SetupTarget, pkgutil: String, spctl: String) -> SetupError? {
        let spctlLines = spctl.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let accepted = spctlLines.first.map { $0.hasSuffix(": accepted") } ?? false
        let notarized = spctlLines.contains("source=Notarized Developer ID")
        guard accepted, notarized else {
            return .verification("macOS did not accept the installer as a notarized Developer ID package.")
        }
        let pkgutilLines = pkgutil.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard pkgutilLines.contains("Notarization: trusted by the Apple notary service") else {
            return .verification("The installer's signature is not notarized by Apple.")
        }
        if target == .homebrew {
            guard let team = installerTeam(in: pkgutil) else {
                return .verification("The installer has no Developer ID Installer signature.")
            }
            guard team == homebrewTeamID else {
                return .verification("The installer is signed by an unexpected team (\(team)).")
            }
        }
        return nil
    }

    /// The team ID in parentheses on certificate 1 of the chain ("1. Developer ID Installer: ..."). The
    /// `Package "<path>":` line is never consulted, so a hostile file name cannot supply it.
    private static func installerTeam(in pkgutil: String) -> String? {
        let prefix = "1. Developer ID Installer:"
        for raw in pkgutil.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            guard let open = rest.lastIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close else { return nil }
            return String(rest[rest.index(after: open)..<close])
        }
        return nil
    }
}

/// The file the Homebrew pkg reads to learn which user owns the install.
public enum HomebrewPkgUser {
    public static let path = "/var/tmp/.homebrew_pkg_user.plist"

    public static func plist(user: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["HOMEBREW_PKG_USER": user], format: .xml, options: 0)
    }
}
