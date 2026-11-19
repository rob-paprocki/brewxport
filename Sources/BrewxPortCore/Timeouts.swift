import Foundation

/// Timeouts shared by every engine, so no engine hangs the app longer than another.
public enum BrewxPortTimeouts {
    /// How long the catalog waits for one engine to answer a search, installed or outdated query.
    public static let engineQuery: Duration = .seconds(60)

    /// How long the app waits for BrewxPort's helper to answer a version check, at registration and before a run.
    public static let helperCall: Duration = .seconds(5)

    /// How long quitting waits for a cancelled run to end before it gives up on it.
    public static let quitCancel: Duration = .seconds(10)

    /// How long Installed waits for the user's login shell to print its PATH before it uses the system PATH.
    public static let loginShell: Duration = .seconds(5)

    /// "didn't answer within 60 seconds", with the seconds taken from `timeout`.
    public static func didntAnswer(within timeout: Duration) -> String {
        let parts = timeout.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        return "didn't answer within \(text) seconds"
    }
}
