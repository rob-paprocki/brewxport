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

    /// How often the setup sheet re-reads the helper's state while it waits for the user to approve it in System Settings.
    public static let helperApprovalPoll: Duration = .seconds(2)

    /// How long the helper waits for GitHub to answer a "latest release" query.
    public static let releaseQuery: Duration = .seconds(60)

    /// The longest one engine-setup download or install command may take (a Command Line Tools install is about 1 GB).
    public static let engineSetup: Duration = .seconds(1800)

    /// How long a language engine waits for one package registry request (npm, PyPI, crates.io, RubyGems, GitHub),
    /// redirects included.
    public static let registryQuery: Duration = .seconds(10)

    /// `duration` in seconds, for Foundation APIs that take a `TimeInterval`.
    public static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// "didn't answer within 60 seconds", with the seconds taken from `timeout`.
    public static func didntAnswer(within timeout: Duration) -> String {
        let parts = timeout.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
        return "didn't answer within \(text) seconds"
    }
}
