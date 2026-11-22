import Foundation
import BrewxPortRun

/// The window that asks for the administrator password.
@MainActor public protocol PasswordPrompting: AnyObject {
    /// `previousAttemptFailed`: the same run's last password was rejected, so the sheet says to try again.
    func askForPassword(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer?
}

/// RunSession's (and DemoRunExecutor's) PasswordProviding. Forwards to `prompter`; no prompter means cancelled.
public final class PromptPasswordProvider: PasswordProviding, @unchecked Sendable {
    @MainActor public weak var prompter: (any PasswordPrompting)?

    public init() {}

    public func password(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer? {
        await ask(reason: reason, previousAttemptFailed: previousAttemptFailed)
    }

    @MainActor private func ask(reason: String, previousAttemptFailed: Bool) async -> SecretBuffer? {
        guard let prompter else { return nil }
        return await prompter.askForPassword(reason: reason, previousAttemptFailed: previousAttemptFailed)
    }
}
