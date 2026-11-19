import Foundation
import BrewxPortRun

/// The window that asks for the administrator password.
@MainActor public protocol PasswordPrompting: AnyObject {
    func askForPassword(reason: String) async -> SecretBuffer?
}

/// RunSession's (and DemoRunExecutor's) PasswordProviding. Forwards to `prompter`; no prompter means cancelled.
public final class PromptPasswordProvider: PasswordProviding, @unchecked Sendable {
    @MainActor public weak var prompter: (any PasswordPrompting)?

    public init() {}

    public func password(reason: String) async -> SecretBuffer? {
        await ask(reason: reason)
    }

    @MainActor private func ask(reason: String) async -> SecretBuffer? {
        guard let prompter else { return nil }
        return await prompter.askForPassword(reason: reason)
    }
}
