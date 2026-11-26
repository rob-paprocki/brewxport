import os

/// The app model's log (subsystem com.brewxport.app, category "model"), for what's worth keeping but not worth
/// showing: an error's own debug text, say. Its own file: importing `os` into the model's file slows type-checking
/// there.
enum ModelLog {
    private static let log = Logger(subsystem: "com.brewxport.app", category: "model")

    static func error(_ message: String) {
        log.error("\(message, privacy: .private)")
    }
}
