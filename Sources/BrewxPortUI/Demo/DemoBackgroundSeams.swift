import Foundation

// Demo mode's background seams. None of them reaches the system: nothing is scheduled, notified or registered as a
// login item (scripts/demo.sh promises the demo leaves nothing behind). Scheduled checks don't run in demo mode;
// Check Now does.

/// Keeps the interval it was given and never runs the work.
@MainActor public final class DemoScheduler: BackgroundScheduling {
    /// The current schedule's interval; nil when there's none.
    public private(set) var interval: TimeInterval?

    public init() {}

    public func schedule(every seconds: TimeInterval, firstAfter delay: TimeInterval,
                         _ work: @escaping @MainActor () async -> Void) {
        interval = seconds
    }

    public func cancel() { interval = nil }
}

/// Grants permission and keeps what would have been posted; shows nothing.
@MainActor public final class DemoNotifier: UpdateNotifying {
    public struct Post: Equatable, Sendable {
        public let id: String
        public let title: String
        public let body: String
        public let target: NotificationTarget
    }

    public private(set) var permissionRequests = 0
    public private(set) var posted: [Post] = []
    /// Never called: nothing is posted, so nothing can be clicked.
    public var onOpen: (@MainActor (NotificationTarget, String) -> Void)?

    public init() {}

    /// Always granted, so the demo's Notifications switch stays on.
    public func requestPermission() async -> Bool {
        permissionRequests += 1
        return true
    }

    public func post(id: String, title: String, body: String, target: NotificationTarget) {
        posted.append(Post(id: id, title: title, body: body, target: target))
    }
}

/// Remembers the last choice for this launch; never registers anything.
@MainActor public final class DemoLoginItem: LoginItemControlling {
    public private(set) var isEnabled = false
    public let needsApproval = false
    /// Every `setEnabled` call, in order.
    public private(set) var changes: [Bool] = []

    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        changes.append(enabled)
        isEnabled = enabled
    }
}

/// The person is at the Mac, the screen is unlocked and the Mac is on power. Nothing ever changes.
@MainActor public final class DemoConditions: SystemConditions {
    public let screenLocked = false
    public let batteryLow = false
    public let lowPowerMode = false
    /// Never called.
    public var onChange: (@MainActor () -> Void)?

    public init() {}

    public func userIsActive(within seconds: TimeInterval) -> Bool { true }
}
