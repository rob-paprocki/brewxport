import Foundation
import os
import Security

private let authLog = Logger(subsystem: "com.brewxport", category: "authorization")

public enum AppAuthorizationError: Error, Equatable, Sendable {
    /// authd failed for a reason other than the password (the status code).
    case failed(OSStatus)
}

/// The app's half of the helper authorization (spike `private/spikes/2026-11-helper-authorization.md`).
///
/// `acquire` creates an `AuthorizationRef` and gets `brewxPortRunRight` for it with the user's name and password in
/// the authorization environment, flags `extendRights` only: no `preAuthorize` (with it a wrong password
/// passes) and no `interactionAllowed` (no system dialog). The external form it returns is what the helper
/// checks. The ref stays alive, holding the right, until `end()`, which frees it with `destroyRights`.
///
/// The password goes to authd straight from the `SecretBuffer`'s locked memory; no copy is made.
public final class AppAuthorization: @unchecked Sendable {
    static let flags: AuthorizationFlags = [.extendRights]

    private let lock = NSLock()
    private let username: String
    private var ref: AuthorizationRef?

    public init(username: String = AppAuthorization.currentUserName()) {
        self.username = username
    }

    deinit { end() }

    /// The login name of the user running BrewxPort.
    public static func currentUserName() -> String {
        if let entry = getpwuid(getuid()), let name = entry.pointee.pw_name {
            return String(cString: name)
        }
        return NSUserName()
    }

    /// True while an acquired authorization is held.
    public var isHolding: Bool { lock.withLock { ref != nil } }

    /// Frees any authorization held so far, then acquires a new one and returns its external form
    /// (`kAuthorizationExternalFormLength` bytes). A wrong password, or a wiped secret, throws
    /// `HelperError.notAuthorized`; other failures throw `AppAuthorizationError.failed`.
    public func acquire(_ secret: SecretBuffer) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        releaseLocked()

        var created: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let created else {
            authLog.error("AuthorizationCreate: \(status)")
            throw AppAuthorizationError.failed(status)
        }
        let copied = secret.withUnwipedBytes { password in
            copyRight(created, password: password)
        }
        guard let copied else {
            AuthorizationFree(created, [.destroyRights])
            throw HelperError.notAuthorized
        }
        guard copied == errAuthorizationSuccess else {
            AuthorizationFree(created, [.destroyRights])
            authLog.error("AuthorizationCopyRights(\(brewxPortRunRight, privacy: .public)): \(copied)")
            throw Self.error(for: copied)
        }
        var form = AuthorizationExternalForm()
        let made = AuthorizationMakeExternalForm(created, &form)
        guard made == errAuthorizationSuccess else {
            AuthorizationFree(created, [.destroyRights])
            authLog.error("AuthorizationMakeExternalForm: \(made)")
            throw AppAuthorizationError.failed(made)
        }
        ref = created
        return withUnsafeBytes(of: &form) { Data($0) }
    }

    /// Frees the authorization and destroys its rights, so its external form stops working. Idempotent.
    public func end() {
        lock.withLock { releaseLocked() }
    }

    /// -60005 (denied) and -60007 (interaction not allowed) mean the password didn't work.
    static func error(for status: OSStatus) -> Error {
        switch status {
        case errAuthorizationDenied, errAuthorizationInteractionNotAllowed: HelperError.notAuthorized
        default: AppAuthorizationError.failed(status)
        }
    }

    private func releaseLocked() {
        guard let held = ref else { return }
        AuthorizationFree(held, [.destroyRights])
        ref = nil
    }

    /// `AuthorizationCopyRights` for `brewxPortRunRight` with `username` and `password` in the environment.
    /// authd only reads the item values; the mutable pointer is what the C struct asks for.
    private func copyRight(_ ref: AuthorizationRef, password: UnsafeRawBufferPointer) -> OSStatus {
        var user = Array(username.utf8)
        return brewxPortRunRight.withCString { rightName in
            kAuthorizationEnvironmentUsername.withCString { userKey in
                kAuthorizationEnvironmentPassword.withCString { passwordKey in
                    user.withUnsafeMutableBytes { userBytes in
                        var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                        return withUnsafeMutablePointer(to: &right) { rightPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var items = [
                                AuthorizationItem(name: userKey, valueLength: userBytes.count,
                                                  value: userBytes.baseAddress, flags: 0),
                                AuthorizationItem(name: passwordKey, valueLength: password.count,
                                                  value: UnsafeMutableRawPointer(mutating: password.baseAddress),
                                                  flags: 0),
                            ]
                            return items.withUnsafeMutableBufferPointer { itemPointer in
                                var environment = AuthorizationEnvironment(count: 2, items: itemPointer.baseAddress)
                                return AuthorizationCopyRights(ref, &rights, &environment, Self.flags, nil)
                            }
                        }
                    }
                }
            }
        }
    }
}
