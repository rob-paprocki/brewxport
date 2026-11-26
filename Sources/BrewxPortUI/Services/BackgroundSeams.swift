import Foundation

// The operating-system facilities background checks use, one protocol each. `Services` holds one of each: the live
// copies (in the app target, built only by `LiveServices`), the demo copies (`DemoBackgroundSeams.swift`, which never
// touch the system) and the tests' fakes. All of them live on the main actor, like everything that uses them.

/// Runs the update check on a repeating schedule the system times (it spreads work and respects power and sleep; a
/// check that fell due while the Mac slept runs some time after it wakes).
@MainActor public protocol BackgroundScheduling: AnyObject, Sendable {
    /// Replaces any current schedule. `work` runs roughly `delay` from now (at most `seconds`: the time left since
    /// the last check), then roughly every `seconds` on average. The system picks each moment near that time and can
    /// put a run off for longer (sleep, load, low power), so no run has an exact time.
    func schedule(every seconds: TimeInterval, firstAfter delay: TimeInterval,
                  _ work: @escaping @MainActor () async -> Void)
    /// Stops the schedule. A run already going finishes.
    func cancel()
}

/// Where clicking a notification takes the person.
public enum NotificationTarget: String, Sendable, CaseIterable {
    /// The Updates page.
    case updates
    /// The run log, after automatic updates.
    case runLog
}

/// macOS notifications.
@MainActor public protocol UpdateNotifying: AnyObject, Sendable {
    /// Asks macOS for permission to notify (the system asks the person only the first time). True when allowed.
    func requestPermission() async -> Bool
    /// Posts one notification. A later post with the same `id` replaces it. Does nothing without permission.
    func post(id: String, title: String, body: String, target: NotificationTarget)
    /// Called on the main actor when the person clicks one of BrewxPort's notifications, with that notification's
    /// target and id.
    var onOpen: (@MainActor (NotificationTarget, String) -> Void)? { get set }
}

/// Open BrewxPort at login: the app's own login item (System Settings > General > Login Items).
@MainActor public protocol LoginItemControlling: AnyObject, Sendable {
    /// Registered and allowed to open at login.
    var isEnabled: Bool { get }
    /// Registered, but the person still has to approve it in System Settings > General > Login Items.
    var needsApproval: Bool { get }
    /// Registers (true) or unregisters (false) the login item. Throws the system's error.
    func setEnabled(_ enabled: Bool) throws
}

/// What the Mac is doing, for the "at the Mac" and battery rules.
@MainActor public protocol SystemConditions: AnyObject, Sendable {
    /// True when there was keyboard or mouse input in the last `seconds`.
    func userIsActive(within seconds: TimeInterval) -> Bool
    /// The screen is locked.
    var screenLocked: Bool { get }
    /// On battery power with less than 20% left. False on a Mac without a battery.
    var batteryLow: Bool { get }
    /// Low Power Mode is on.
    var lowPowerMode: Bool { get }
    /// Called on the main actor when any of the above may have changed: the screen locked or unlocked, the Mac woke
    /// from sleep, the power source changed, or Low Power Mode turned on or off. It carries nothing; read the
    /// properties again. There's no event for input after a quiet spell, so `userIsActive` has to be asked again
    /// (polled) while waiting for the person to come back.
    var onChange: (@MainActor () -> Void)? { get set }
}
