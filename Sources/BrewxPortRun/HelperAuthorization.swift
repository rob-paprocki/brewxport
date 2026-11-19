import Foundation
import Security

/// The authorization right that gates every helper run. The app acquires it once per run with the user's admin
/// password (Task 9); the helper only asks authd whether the app's authorization holds it (spike, ruling R7).
public let brewxPortRunRight = "com.brewxport.run"

/// The `com.brewxport.run` rule, as decided by the authorization spike (`private/spikes/2026-11-helper-authorization.md`).
public enum BrewxPortRunRule {
    /// Seconds a granted right stays valid on the helper's side. It covers the start of a run, which is the only
    /// time the helper checks; a long build keeps running after it expires.
    public static let timeout = 300

    /// For `AuthorizationRightSet`. A computed property: a global `[String: Any]` isn't `Sendable`.
    public static var dictionary: [String: Any] {
        [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            "allow-root": false,     // a root process must not pass on its own
            "shared": false,         // never satisfies another process's request
            "session-owner": false,
            "timeout": timeout,      // must be non-zero, or the app's check uses the credential up
            "comment": "BrewxPort: one administrator password per run of MacPorts as root.",
        ]
    }

    /// True when `installed` (from `AuthorizationRightGet`) is at least as strict as `dictionary`. authd adds
    /// `created`, `modified`, `version` and `requirement`, which are ignored. False flags may be absent: authd
    /// stores them as bits that default to off. Anything that delegates or adds mechanisms is refused.
    public static func matches(_ installed: [String: Any]) -> Bool {
        guard installed["class"] as? String == "user", installed["group"] as? String == "admin",
              bool(installed["authenticate-user"]) == true, number(installed["timeout"]) == timeout
        else { return false }
        for key in ["allow-root", "shared", "session-owner"] where installed[key] != nil {
            guard bool(installed[key]) == false else { return false }
        }
        for key in ["rule", "mechanisms", "k-of-n"] where installed[key] != nil {
            if let list = installed[key] as? [Any], list.isEmpty { continue }
            return false
        }
        return true
    }

    /// A real CFBoolean only, so `1` or `"false"` don't pass as a flag.
    private static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFBooleanGetTypeID() else { return nil }
        return (object as? NSNumber)?.boolValue
    }

    private static func number(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFNumberGetTypeID(), let n = object as? NSNumber else { return nil }
        return n.intValue
    }
}

public enum HelperAuthorization {
    public enum RightInstall: Equatable, Sendable {
        case installed
        case createFailed(OSStatus)
        case setFailed(OSStatus)
        case readBackFailed(OSStatus)
        /// authd accepted the write but reads back something weaker.
        case mismatch
    }

    /// Exactly `kAuthorizationExternalFormLength` bytes, or `notAuthorized`.
    public static func externalForm(from data: Data) throws -> AuthorizationExternalForm {
        guard data.count == Int(kAuthorizationExternalFormLength),
              data.count == MemoryLayout<AuthorizationExternalForm>.size
        else { throw HelperError.notAuthorized }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form) { data.copyBytes(to: $0) }
        return form
    }

    /// Throws `notAuthorized` unless the external form names an authorization that holds `brewxPortRunRight` right
    /// now. Never allows interaction, never extends rights, and frees (without destroying) the ref, so the app's
    /// own authorization is untouched. `log` gets the failing step and status, never the bytes.
    public static func authorize(externalForm data: Data, log: (String) -> Void = { _ in }) throws {
        var form: AuthorizationExternalForm
        do { form = try externalForm(from: data) } catch {
            log("external form has \(data.count) bytes, not \(kAuthorizationExternalFormLength)")
            throw error
        }
        var ref: AuthorizationRef?
        let created = AuthorizationCreateFromExternalForm(&form, &ref)
        guard created == errAuthorizationSuccess, let ref else {
            log("AuthorizationCreateFromExternalForm: \(created)")
            throw HelperError.notAuthorized
        }
        defer { AuthorizationFree(ref, []) }
        let status = brewxPortRunRight.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(ref, &rights, nil, [], nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            log("AuthorizationCopyRights(\(brewxPortRunRight)): \(status)")
            throw HelperError.notAuthorized
        }
    }

    /// Run by the helper (as root) at launch: overwrites any existing `com.brewxport.run`, so a definition planted
    /// before the helper ran can't stand, then reads it back and checks it with `BrewxPortRunRule.matches`.
    /// Anything but `.installed` means the helper must refuse every run.
    public static func installRight() -> RightInstall {
        var ref: AuthorizationRef?
        let created = AuthorizationCreate(nil, nil, [], &ref)
        guard created == errAuthorizationSuccess, let ref else { return .createFailed(created) }
        defer { AuthorizationFree(ref, []) }
        let set = AuthorizationRightSet(ref, brewxPortRunRight, BrewxPortRunRule.dictionary as CFDictionary, nil, nil, nil)
        guard set == errAuthorizationSuccess else { return .setFailed(set) }
        var definition: CFDictionary?
        let got = AuthorizationRightGet(brewxPortRunRight, &definition)
        guard got == errAuthorizationSuccess, let definition else { return .readBackFailed(got) }
        guard let dict = definition as? [String: Any], BrewxPortRunRule.matches(dict) else { return .mismatch }
        return .installed
    }
}
