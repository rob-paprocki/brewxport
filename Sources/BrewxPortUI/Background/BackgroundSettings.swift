import CoreFoundation
import Foundation
import Observation

/// How often BrewxPort checks for updates in the background. The raw values are what's stored, so they never change.
public enum CheckInterval: String, CaseIterable, Sendable {
    case hourly, fourHours, twelveHours, daily, never

    /// Nil for `.never`: no checks.
    public var seconds: TimeInterval? {
        switch self {
        case .hourly: 3600
        case .fourHours: 4 * 3600
        case .twelveHours: 12 * 3600
        case .daily: 24 * 3600
        case .never: nil
        }
    }
}

/// What a check does with the updates it finds. The raw values are what's stored, so they never change.
public enum AutoUpdateMode: String, CaseIterable, Sendable {
    /// Notify only; nothing changes until the person clicks.
    case notify
    /// Run the updates that need no password (`RunRouting.route == .user`); notify the rest.
    case passwordFree
    /// As `passwordFree`, then the password-needing updates once the person is at the Mac.
    case everything
}

/// The background checks' settings, kept in `services.store`. Each one is written when it changes; a missing or
/// unreadable value reads as its default.
@MainActor @Observable public final class BackgroundSettings {
    static let intervalKey = "checkInterval"
    static let modeKey = "autoUpdateMode"
    static let notificationsKey = "backgroundNotifications"
    static let openAtLoginKey = "openAtLogin"
    static let introShownKey = "backgroundIntroShown"

    /// A number of seconds in the `com.brewxport.app` domain that replaces the chosen interval, for testing in a VM:
    /// `defaults write com.brewxport.app BrewxPortTestCheckIntervalSeconds -int 120`. Ignored below 60.
    public static let testIntervalKey = "BrewxPortTestCheckIntervalSeconds"
    static let minimumTestInterval: TimeInterval = 60

    private let store: any KeyValueStoring
    /// The hidden test interval (`testIntervalKey`), or nil. Used only when it's at least 60 seconds.
    public let testIntervalOverride: TimeInterval?

    /// Default: every 12 hours.
    public var interval: CheckInterval {
        didSet { store.set(Data(interval.rawValue.utf8), forKey: Self.intervalKey) }
    }
    /// Default: notify only.
    public var mode: AutoUpdateMode {
        didSet { store.set(Data(mode.rawValue.utf8), forKey: Self.modeKey) }
    }
    /// Default: on. Off still updates the menu bar badge.
    public var notificationsOn: Bool {
        didSet { store.set(Self.flag(notificationsOn), forKey: Self.notificationsKey) }
    }
    /// Open BrewxPort at login. It follows the system's login item (`BackgroundUpdater.setOpenAtLogin(_:)` and
    /// `readLoginItem()`). Default: off.
    public var openAtLogin: Bool {
        didSet { store.set(Self.flag(openAtLogin), forKey: Self.openAtLoginKey) }
    }
    /// Whether the one-time "BrewxPort now checks for updates" sheet has been shown. Default: no.
    public var introShown: Bool {
        didSet { store.set(Self.flag(introShown), forKey: Self.introShownKey) }
    }

    /// `testIntervalOverride`: tests pass their own; the app passes `testIntervalOverride()`.
    public init(store: any KeyValueStoring, testIntervalOverride: TimeInterval?) {
        self.store = store
        self.testIntervalOverride = testIntervalOverride
        interval = Self.choice(store.data(forKey: Self.intervalKey)) ?? .twelveHours
        mode = Self.choice(store.data(forKey: Self.modeKey)) ?? .notify
        // On unless turned off; off unless turned on.
        notificationsOn = store.data(forKey: Self.notificationsKey) != Self.flag(false)
        openAtLogin = store.data(forKey: Self.openAtLoginKey) == Self.flag(true)
        introShown = store.data(forKey: Self.introShownKey) == Self.flag(true)
    }

    /// False when the interval is Never.
    public var checksOn: Bool { interval != .never }

    /// Seconds between scheduled checks, or nil when checks are off. A test interval of at least 60 seconds replaces
    /// the chosen one, but never turns checks on: Never stays off.
    public var effectiveInterval: TimeInterval? {
        guard let seconds = interval.seconds else { return nil }
        if let override = testIntervalOverride, override >= Self.minimumTestInterval { return override }
        return seconds
    }

    /// The hidden test interval, read with `CFPreferencesCopyAppValue` in the `com.brewxport.app` domain (like
    /// `StartupPolicy.isDevelopmentMac()`, so the bundled app and `swift run` agree). Nil when it isn't set or is
    /// below 60 seconds.
    public static func testIntervalOverride() -> TimeInterval? {
        testInterval(from: CFPreferencesCopyAppValue(testIntervalKey as CFString, StartupPolicy.domain as CFString))
    }

    /// The stored value as seconds: a number, or text holding one (`defaults write` without `-int`). Anything else,
    /// a boolean, or less than 60, is nil.
    static func testInterval(from value: CFPropertyList?) -> TimeInterval? {
        let seconds: TimeInterval?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            seconds = number.doubleValue
        } else if let text = value as? String {
            seconds = TimeInterval(text.trimmingCharacters(in: .whitespaces))
        } else {
            seconds = nil
        }
        guard let seconds, seconds.isFinite, seconds >= minimumTestInterval else { return nil }
        return seconds
    }

    private static func flag(_ on: Bool) -> Data { Data((on ? "1" : "0").utf8) }

    private static func choice<T: RawRepresentable<String>>(_ data: Data?) -> T? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        return T(rawValue: text)
    }
}
