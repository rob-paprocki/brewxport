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

    /// The sidebar row's subtitle.
    public static func shortText(for state: HelperState?) -> String {
        switch state {
        case nil: "Checking…"
        case .notRegistered?: "Not set up"
        case .requiresApproval?: "Needs approval"
        case .enabled?: "Ready"
        case .outdated?: "Out of date"
        case .failed?: "Not working"
        }
    }

    /// The sidebar row's status symbol: a tick when ready, a warning when it needs you.
    public static func symbol(for state: HelperState?) -> String {
        switch state {
        case .enabled?: "checkmark.circle.fill"
        case .requiresApproval?, .failed?: "exclamationmark.triangle.fill"
        case nil, .notRegistered?, .outdated?: "minus.circle"
        }
    }

    /// The helper page's explanation.
    public static let about = """
        The helper does the work that needs your administrator password: MacPorts installs and updates, and \
        setting up a package manager. Homebrew and nanobrew packages never use it. It asks for your password \
        each time and does nothing in between. macOS lists it in System Settings under General > Login Items \
        & Extensions, where you can turn it off.
        """

    public static func offersLoginItems(_ state: HelperState?) -> Bool {
        state == .requiresApproval
    }

    /// "Reinstall helper" is offered only for `.failed`, and only ever runs when the user clicks it.
    public static func offersReinstall(_ state: HelperState?) -> Bool {
        if case .failed? = state { return true }
        return false
    }
}
