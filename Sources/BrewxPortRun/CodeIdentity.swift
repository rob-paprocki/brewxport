import Foundation
import Security

/// Code-signing requirements for BrewxPort's three signed binaries, built from the team that signed the running
/// process. Nothing here holds a team ID: it's read from this process's own signature at run time.
public enum CodeIdentity {
    public static let appIdentifier = "com.brewxport.app"
    public static let helperIdentifier = "com.brewxport.helper"
    public static let askpassIdentifier = "com.brewxport.askpass"

    /// The team identifier in this process's signature, or nil when the process isn't signed by a team (an
    /// unsigned or ad-hoc development build). Callers must fail closed on nil, never skip a check.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        // Without kSecCSSigningInformation the dictionary has no team identifier.
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return isTeamIdentifier(team) ? team : nil
    }

    /// Apple team identifiers are ten uppercase letters and digits. Anything else could change the meaning of a
    /// requirement string, so it's refused.
    public static func isTeamIdentifier(_ text: String) -> Bool {
        text.unicodeScalars.count == 10
            && text.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Marks a Developer ID certificate chain: the Developer ID intermediate CA (`certificate 1`) and a Developer ID
    /// Application leaf. Without it, any Apple-issued certificate for the team (an Apple Development one, say)
    /// would satisfy the requirement.
    public static let developerIDClause =
        "certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    /// `identifier "<identifier>" and anchor apple generic and certificate leaf[subject.OU] = "<team>" and
    /// <developerIDClause>`, or nil when `team` isn't a team identifier. `scripts/build-app.sh` and
    /// `Tests/scripts/test-build-app.sh` write the same string; change all three together.
    public static func requirement(identifier: String, team: String) -> String? {
        guard isTeamIdentifier(team) else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            + " and " + developerIDClause
    }
}
