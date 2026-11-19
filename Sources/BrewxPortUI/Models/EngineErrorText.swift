import Foundation
import BrewxPortCore

public enum EngineErrorText {
    /// The message as is when it already starts with the engine's display name, else "<Engine>: <message>".
    /// An empty message becomes a plain sentence, so an error never shows as blank.
    public static func line(_ error: EngineError) -> String {
        let name = error.engine.displayName
        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { return "\(name) failed and gave no reason." }
        return message.hasPrefix(name) ? message : "\(name): \(message)"
    }
}
