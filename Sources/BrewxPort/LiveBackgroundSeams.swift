import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import notify
import os
import ServiceManagement
import UserNotifications
import BrewxPortUI

// The real background seams. Only `LiveServices.make()` builds them, so tests, demo mode and a development Mac never
// do. The system calls some of these back on its own queues, so every callback is nonisolated or `@Sendable` and
// hops to the main actor itself; a callback Swift inferred as main-actor would trap there.

private let updatesLog = Logger(subsystem: "com.brewxport.app", category: "updates")

/// `NSBackgroundActivityScheduler`: the system aims for the interval give or take the tolerance, but picks the moment
/// itself and can put it off (while the Mac sleeps, say, running the check some time after it wakes). A first run
/// due sooner than a full interval (the time left since the last check, after a relaunch) is a one-off activity,
/// whose interval is the delay before it runs; the repeating one starts once it has.
@MainActor final class LiveBackgroundScheduler: BackgroundScheduling {
    static let identifier = "com.brewxport.app.update-check"
    static let firstIdentifier = "com.brewxport.app.update-check.first"
    private var activity: NSBackgroundActivityScheduler?
    /// Counts schedules and cancels, so a one-off run that ends after either starts no repeating schedule.
    private var generation = 0

    func schedule(every seconds: TimeInterval, firstAfter delay: TimeInterval,
                  _ work: @escaping @MainActor () async -> Void) {
        cancel()
        // Within the repeating activity's own tolerance of a full interval: it times the first run as well.
        guard delay < seconds * 0.9 else {
            activity = repeating(every: seconds, work)
            return
        }
        let current = generation
        let first = NSBackgroundActivityScheduler(identifier: Self.firstIdentifier)
        first.repeats = false
        first.interval = delay
        first.tolerance = delay / 10
        first.qualityOfService = .utility
        first.schedule { @Sendable [weak self] completion in
            Task { @MainActor [weak self] in
                await work()
                completion(.finished)
                guard let self, self.generation == current else { return }
                self.activity = self.repeating(every: seconds, work)
            }
        }
        activity = first
    }

    /// An invalidated scheduler can't be scheduled again, so each schedule gets a new one.
    private func repeating(every seconds: TimeInterval,
                           _ work: @escaping @MainActor () async -> Void) -> NSBackgroundActivityScheduler {
        let activity = NSBackgroundActivityScheduler(identifier: Self.identifier)
        activity.repeats = true
        activity.interval = seconds
        // The default is half the interval (six hours either side of a 12-hour check), which would make the menu's
        // "Next check" time meaningless.
        activity.tolerance = seconds / 10
        // The default (background) can hold a check back for a long time; it decides the menu bar badge.
        activity.qualityOfService = .utility
        activity.schedule { @Sendable completion in
            Task { @MainActor in
                await work()
                completion(.finished)
            }
        }
        return activity
    }

    func cancel() {
        generation += 1
        activity?.invalidate()
        activity = nil
    }
}

/// `UNUserNotificationCenter`. It's the center's delegate from the moment it's made (at launch, in
/// `LiveServices.make()`), so a click that launched BrewxPort is seen too. Outside an app bundle (`swift run`) the
/// center can't be used, so nothing is asked or posted and permission reads as denied.
@MainActor final class LiveUpdateNotifier: NSObject, UpdateNotifying, UNUserNotificationCenterDelegate {
    nonisolated static let targetKey = "target"

    private let center: UNUserNotificationCenter?
    /// A click that came before `onOpen` was set (its target and notification id); delivered when it is.
    private var pendingOpen: (target: NotificationTarget, id: String)?

    var onOpen: (@MainActor (NotificationTarget, String) -> Void)? {
        didSet {
            guard let onOpen, let pending = pendingOpen else { return }
            pendingOpen = nil
            onOpen(pending.target, pending.id)
        }
    }

    override init() {
        let bundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        center = bundled ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func requestPermission() async -> Bool {
        guard let center else { return false }
        return await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { @Sendable granted, error in
                if let error { updatesLog.error("Notification permission: \(error.localizedDescription)") }
                continuation.resume(returning: granted)
            }
        }
    }

    func post(id: String, title: String, body: String, target: NotificationTarget) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.targetKey: target.rawValue]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { @Sendable error in
            if let error { updatesLog.error("Notification not posted: \(error.localizedDescription)") }
        }
    }

    /// Shown even while BrewxPort is the frontmost app; otherwise macOS would drop it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// A click on the notification. One without a readable target opens Updates.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let raw = response.notification.request.content.userInfo[Self.targetKey] as? String
            let target = raw.flatMap(NotificationTarget.init(rawValue:)) ?? .updates
            let id = response.notification.request.identifier
            Task { @MainActor in self.opened(target, id: id) }
        }
        completionHandler()
    }

    private func opened(_ target: NotificationTarget, id: String) {
        if let onOpen { onOpen(target, id) } else { pendingOpen = (target, id) }
    }
}

/// `SMAppService.mainApp`: BrewxPort's own entry in System Settings > General > Login Items. Nothing is registered
/// until the person turns Open at login on.
@MainActor final class LiveLoginItem: LoginItemControlling {
    private var service: SMAppService { .mainApp }

    var isEnabled: Bool { service.status == .enabled }
    var needsApproval: Bool { service.status == .requiresApproval }

    /// Asking for the state it's already in does nothing (the system would throw). Waiting for approval counts as on:
    /// it's registered, and only the person can approve it, in System Settings > General > Login Items.
    func setEnabled(_ enabled: Bool) throws {
        let status = service.status
        if enabled {
            guard status != .enabled, status != .requiresApproval else { return }
            try service.register()
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}

/// Recent input from `CGEventSource`, the lock state from the screen-lock distributed notifications, the power
/// source from IOKit, and Low Power Mode from `ProcessInfo`. Lives as long as the app.
@MainActor final class LiveSystemConditions: NSObject, SystemConditions {
    static let lockedName = Notification.Name("com.apple.screenIsLocked")
    static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    private(set) var screenLocked: Bool
    var onChange: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var powerSourceToken: Int32 = 0

    override init() {
        screenLocked = Self.sessionIsLocked()
        super.init()
        // Delivered at once even while BrewxPort isn't the active app; by default the system holds distributed
        // notifications for inactive apps until they're activated.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: Self.lockedName, object: nil,
                                suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: Self.unlockedName, object: nil,
                                suspensionBehavior: .deliverImmediately)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        // Plugging in or unplugging. On battery the charge only falls, so this is enough to see "low" end.
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &powerSourceToken, .main) {
            @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
        if status != NOTIFY_STATUS_OK {
            // Wake, Low Power Mode and the lock still report; only plugging in goes unseen until one of them does.
            updatesLog.error("Power source changes won't be followed: notify_register_dispatch returned \(status)")
        }
    }

    func userIsActive(within seconds: TimeInterval) -> Bool {
        // `kCGAnyInputEventType` (~0): keyboard, mouse or trackpad.
        guard let anyInput = CGEventType(rawValue: ~0) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < seconds
    }

    var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    var batteryLow: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue(),
              providing as String == kIOPMBatteryPowerKey,
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return current * 100 < maximum * 20
        }
        return false
    }

    /// The lock state at launch, before any notification: the login session's `CGSSessionScreenIsLocked` (not a
    /// documented key; missing reads as unlocked).
    private static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    @objc private nonisolated func screenDidLock(_ notification: Notification) {
        Task { @MainActor in self.setLocked(true) }
    }

    @objc private nonisolated func screenDidUnlock(_ notification: Notification) {
        Task { @MainActor in self.setLocked(false) }
    }

    private func setLocked(_ locked: Bool) {
        screenLocked = locked
        changed()
    }

    private func changed() { onChange?() }
}
