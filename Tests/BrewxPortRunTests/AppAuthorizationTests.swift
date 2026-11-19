import Testing
import Foundation
import Security
@testable import BrewxPortRun

@Suite struct AppAuthorizationTests {
    @Test func deniedAndInteractionNotAllowedMeanNotAuthorized() {
        // -60005 and -60007: what authd returns for a wrong or missing password (spike).
        #expect(AppAuthorization.error(for: errAuthorizationDenied) as? HelperError == .notAuthorized)
        #expect(AppAuthorization.error(for: errAuthorizationInteractionNotAllowed) as? HelperError == .notAuthorized)
        #expect(errAuthorizationDenied == -60005)
        #expect(errAuthorizationInteractionNotAllowed == -60007)
    }

    @Test func otherStatusesAreReportedAsTheyAre() {
        #expect(AppAuthorization.error(for: errAuthorizationInternal) as? AppAuthorizationError
                == .failed(errAuthorizationInternal))
        #expect(AppAuthorization.error(for: errAuthorizationCanceled) as? AppAuthorizationError
                == .failed(errAuthorizationCanceled))
    }

    @Test func flagsExtendRightsOnly() {
        // Not preAuthorize (it skips the password check) and never interactionAllowed (no system dialog).
        #expect(AppAuthorization.flags == [.extendRights])
    }

    @Test func wipedSecretIsRefusedWithoutAskingAuthd() {
        let auth = AppAuthorization()
        let secret = SecretBuffer(copying: Array("anything".utf8))
        secret.wipe()
        #expect(throws: HelperError.notAuthorized) { _ = try auth.acquire(secret) }
        #expect(!auth.isHolding)
    }

    @Test func endIsIdempotentAndSafeBeforeAcquire() {
        let auth = AppAuthorization()
        auth.end()
        auth.end()
        #expect(!auth.isHolding)
    }

    @Test func usernameIsTheLoggedInUser() {
        #expect(!AppAuthorization.currentUserName().isEmpty)
        #expect(AppAuthorization.currentUserName() == NSUserName())
    }

    /// A real `AuthorizationCopyRights` with a deliberately wrong password. It fails quickly with no dialog, but
    /// leaves a failed authentication in the system log, so it only runs with BREWXPORT_AUTH_E2E=1. The right
    /// password is Task 12's VM test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BREWXPORT_AUTH_E2E"] == "1"))
    func wrongPasswordIsNotAuthorizedQuickly() {
        let auth = AppAuthorization()
        let secret = SecretBuffer(copying: Array("brewxport-deliberately-wrong-\(UUID().uuidString)".utf8))
        let start = Date()
        #expect(throws: HelperError.notAuthorized) { _ = try auth.acquire(secret) }
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(!auth.isHolding)
        auth.end()
    }
}
