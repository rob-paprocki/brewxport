import Foundation
import Observation

extension CheckInterval {
    /// The choice as Settings lists it.
    public var title: String {
        switch self {
        case .hourly: "Every hour"
        case .fourHours: "Every 4 hours"
        case .twelveHours: "Every 12 hours"
        case .daily: "Every 24 hours"
        case .never: "Never"
        }
    }
}

extension AutoUpdateMode {
    /// The choice as Settings lists it.
    public var title: String {
        switch self {
        case .notify: "Notify me"
        case .passwordFree: "Update what doesn't need a password"
        case .everything: "Update everything"
        }
    }
}

/// The Settings window (BrewxPort > Settings…, ⌘,) and the one-time sheet's switches: the background checks'
/// settings, what changing each one does, and what to say about it. The views only draw it.
///
/// - Changing the interval reschedules the checks at once.
/// - Turning notifications on asks macOS for permission; refused, the switch turns off again and says where to allow
///   them.
/// - Open at login registers or unregisters the login item at once. The system's error shows under the switch, and so
///   does the approval it may still need in System Settings.
/// - A standard account is told that "Update everything" only notifies what needs a password.
@MainActor @Observable public final class SettingsModel {
    public static let intervalLabel = "Check for updates"
    public static let modeLabel = "When updates are found"
    public static let notificationsLabel = "Show notifications"
    public static let openAtLoginLabel = "Open BrewxPort at login"
    static let notificationsDenied = "Allow notifications for BrewxPort in System Settings > Notifications."
    static let loginItemNeedsApproval = "Approve BrewxPort in System Settings > General > Login Items."
    static let standardAccount =
        "Your account isn't an administrator, so updates that need a password are only notified."

    @ObservationIgnored private let background: BackgroundUpdater
    @ObservationIgnored private let loginItem: any LoginItemControlling

    /// The stored settings the switches show.
    public var settings: BackgroundSettings { background.settings }

    /// Shown under the Notifications switch after macOS refused them.
    public private(set) var notificationsProblem: String?
    /// Why the last Open at login change failed, or nil.
    private var loginItemProblem: String?
    /// The login item is registered but waits for the person's approval in System Settings. Read when Settings
    /// appears, when BrewxPort becomes active and after each change: the system doesn't say when it changes.
    private var loginItemWaitsForApproval: Bool

    /// Shown under the choices, by "Update everything", on a standard account: that mode then works like "Update what
    /// doesn't need a password" (`BackgroundUpdater`'s rule). Nil for an administrator, and for an account that
    /// couldn't be read, where the mode stays as chosen.
    public let standardAccountNote: String?

    public init(model: BrewxPortAppModel) {
        background = model.background
        loginItem = model.services.loginItem
        loginItemWaitsForApproval = model.services.loginItem.needsApproval
        standardAccountNote = model.services.isAdministrator() == false ? Self.standardAccount : nil
    }

    /// Check for updates. Changing it reschedules the checks at once (Never stops them).
    public var interval: CheckInterval {
        get { settings.interval }
        set {
            guard newValue != settings.interval else { return }
            settings.interval = newValue
            background.scheduleFromSettings()
        }
    }

    /// When updates are found. Read again before every automatic run, so nothing else needs to happen.
    public var mode: AutoUpdateMode {
        get { settings.mode }
        set { settings.mode = newValue }
    }

    /// Show notifications. On asks macOS for permission first; refused, it stays off and says where to allow them.
    public func setNotifications(_ on: Bool) async {
        notificationsProblem = nil
        guard on else {
            settings.notificationsOn = false
            return
        }
        let allowed = await background.turnOnNotifications()
        if !allowed { notificationsProblem = Self.notificationsDenied }
    }

    /// Open BrewxPort at login: registered or unregistered at once. The switch then shows what the system says.
    public func setOpenAtLogin(_ on: Bool) {
        do {
            try background.setOpenAtLogin(on)
            loginItemProblem = nil
        } catch {
            loginItemProblem = "BrewxPort couldn't change its login item: \(error.localizedDescription)"
        }
        loginItemWaitsForApproval = loginItem.needsApproval
    }

    /// Under the Open at login switch: why the last change failed, or that System Settings still has to approve it.
    public var loginItemNote: String? {
        loginItemProblem ?? (loginItemWaitsForApproval ? Self.loginItemNeedsApproval : nil)
    }

    /// Settings appeared, or BrewxPort became active while it's open (back from System Settings, say): the Open at
    /// login switch and its note follow the system again. Only reads.
    public func refresh() {
        background.readLoginItem()
        loginItemWaitsForApproval = loginItem.needsApproval
    }
}
