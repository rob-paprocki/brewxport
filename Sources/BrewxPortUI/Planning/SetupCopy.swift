import BrewxPortCore

/// The words on the setup screen and its buttons. Kept out of the views so they can be tested and checked in one place.
public enum SetupCopy {
    public static let intelHomebrew = "Homebrew doesn't support Intel Macs. MacPorts does the same job."
    public static let demoHelp = "Not available in demo mode"
    public static let busyHelp = "Wait for the current task to finish."
    public static let needsAdminHelp = "Needs an administrator account."
    public static let masNeedsManager = "Set up Homebrew or MacPorts first: mas installs through one of them."

    public static let offerTitle = "Set up a package manager"
    public static let offerSubtitle = "BrewxPort needs one to install anything. Pick one to set up now."
    public static let recommendedLabel = "Recommended"
    public static let adminNote = "Needs an administrator password."

    public static let approvalTitle = "Approve BrewxPort's helper"
    public static let approvalText = """
        Setting up a package manager needs BrewxPort's helper. Open Login Items, switch BrewxPort on under \
        "Allow in the Background", and setup carries on by itself.
        """

    public static let failedTitle = "Setup didn't finish"
    public static let cannotTitle = "Setup couldn't start"

    /// One line on what it is.
    public static func blurb(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: "Installs command-line tools and Mac apps. The usual first choice."
        case .macports: "An older package manager for command-line tools and libraries. Runs on every Mac."
        case .nanobrew: "A small, fast package manager that installs Homebrew's packages."
        case .mas: "Installs and updates Mac App Store apps from the command line."
        }
    }

    /// Download size and password note, as the real downloads measured in the installer spike. nanobrew's size wasn't
    /// measured, so it only says small. mas goes in through whichever package manager is there: a Homebrew formula
    /// installs as the user, MacPorts goes through the helper.
    public static func detail(_ engine: EngineID) -> String {
        switch engine {
        case .homebrew: "About 160 MB. \(adminNote)"
        case .macports: "About 8 MB, plus Apple's Command Line Tools (about 1.3 GB) if you don't have them. \(adminNote)"
        case .nanobrew: "A small download. \(adminNote)"
        case .mas: "Installed through Homebrew or MacPorts. Through MacPorts it asks for an administrator password."
        }
    }

    public static func buttonTitle(_ engine: EngineID) -> String { "Set Up \(engine.displayName)…" }
    public static func readyTitle(_ engine: EngineID) -> String { "\(engine.displayName) is ready" }
    public static let readyText = "Its packages will show up in BrewxPort now."
}
