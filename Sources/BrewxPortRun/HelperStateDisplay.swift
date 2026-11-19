import Foundation

/// What the helper row says, and whether it offers "Open Login Items".
public enum HelperStateDisplay {
    public static func text(for state: HelperState?) -> String {
        switch state {
        case nil: "Checking BrewxPort's helper…"
        case .notRegistered?: "BrewxPort's helper isn't set up yet."
        case .requiresApproval?:
            "BrewxPort's helper needs your approval. Turn on BrewxPort in System Settings > General > Login Items."
        case .enabled?: "BrewxPort's helper is ready."
        case .outdated?: "BrewxPort's helper is out of date. BrewxPort will replace it."
        case .failed(let reason)?: "BrewxPort's helper isn't working: \(reason)"
        }
    }

    public static func offersLoginItems(_ state: HelperState?) -> Bool {
        state == .requiresApproval
    }

    /// "Reinstall helper" is offered only for `.failed`, and only ever runs when the user clicks it.
    public static func offersReinstall(_ state: HelperState?) -> Bool {
        if case .failed? = state { return true }
        return false
    }
}
