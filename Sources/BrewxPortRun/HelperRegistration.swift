import Foundation
import BrewxPortCore
import ServiceManagement
import Synchronization

public enum HelperState: Equatable, Sendable {
    case notRegistered
    /// Registered, but the user hasn't approved it in System Settings > Login Items yet.
    case requiresApproval
    case enabled
    /// Enabled, but the running helper's version differs from the bundled one.
    case outdated
    case failed(String)
}

/// `SMAppService.Status` without the ServiceManagement types, so tests need none of them.
public enum DaemonStatus: Sendable, Equatable {
    case notRegistered, enabled, requiresApproval, notFound
    /// A status this build of BrewxPort doesn't know about (a future macOS added one).
    case unknown
}

/// Wraps `SMAppService` for the helper's LaunchDaemon.
public protocol DaemonService: Sendable {
    var status: DaemonStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettingsLoginItems()
}

/// Asks the running helper which protocol version it speaks.
public protocol VersionReporting: Sendable {
    func helperVersion() async throws -> Int
    /// Drops any open connection to the helper, so the next call reaches the helper launchd runs now rather than
    /// one that was just unregistered.
    func resetConnection()
}

extension VersionReporting {
    public func resetConnection() {}
}

/// The real service. Never used in tests, and never called on a development Mac.
public struct LiveDaemonService: DaemonService {
    public static let plistName = "com.brewxport.helper.plist"
    public init() {}

    private var service: SMAppService { SMAppService.daemon(plistName: Self.plistName) }

    public var status: DaemonStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
    public func register() throws { try service.register() }
    public func unregister() async throws { try await service.unregister() }
    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Registers the helper and checks that it's the version this app expects.
///
/// `.notFound` maps to `.notRegistered`. On macOS 15, `SMAppService.status` reports `.notFound` for a daemon
/// that has simply never been registered, even when its plist is in the bundle. So `.notFound` can't be
/// trusted to mean "the plist is missing". Registering is the real test.
///
/// `register()` also throws ("Operation not permitted") on the first registration, before the user has approved
/// the helper in Login Items, and the status then becomes `.requiresApproval` (spike
/// `private/spikes/2026-11-helper-authorization.md`). So a throw is followed by a fresh status read, and is only
/// reported as `.failed` when that status isn't `.requiresApproval` or `.enabled`.
///
/// `ensureRegistered()` and `reinstall()` are single flight: a call to either while one of them is in flight awaits
/// that call's result instead of starting another. `refresh()` only reads, and always runs.
public final class HelperRegistration: Sendable {
    static let defaultTimeout: Duration = BrewxPortTimeouts.helperCall

    private let service: any DaemonService
    private let connection: any HelperConnecting & VersionReporting
    private let bundledVersion: Int
    private let timeout: Duration
    /// The registration call in flight, with an id so only that call clears it.
    private let inFlight = Mutex<(id: UUID, task: Task<HelperState, Never>)?>(nil)

    public convenience init(service: any DaemonService, connection: any HelperConnecting & VersionReporting) {
        self.init(service: service, connection: connection, bundledVersion: brewxPortHelperVersion,
                  timeout: Self.defaultTimeout)
    }

    init(service: any DaemonService, connection: any HelperConnecting & VersionReporting,
         bundledVersion: Int, timeout: Duration) {
        self.service = service
        self.connection = connection
        self.bundledVersion = bundledVersion
        self.timeout = timeout
    }

    public func refresh() async -> HelperState {
        switch service.status {
        case .notRegistered, .notFound: return .notRegistered
        case .unknown: return .failed("Unknown helper status")
        case .requiresApproval: return .requiresApproval
        case .enabled:
            let connection = self.connection
            do {
                let installed = try await firstResult(within: timeout) { try await connection.helperVersion() }
                return HelperCompatibility.check(installed: installed, bundled: bundledVersion) ? .enabled : .outdated
            } catch is CallTimedOut {
                return .failed("The helper didn't answer within \(timeout.components.seconds) seconds.")
            } catch {
                return .failed("Couldn't ask the helper for its version: \(error.localizedDescription)")
            }
        }
    }

    /// Registers when needed and returns the resulting state. `.requiresApproval` means the caller should show
    /// the "Open Login Items" button.
    ///
    /// It only re-registers on its own when there's evidence the registration itself is wrong. Unregistering an
    /// approved helper can send it back to Login Items approval, so a helper that merely didn't answer is never
    /// unregistered here.
    ///
    /// - `.notRegistered` (including `.notFound`): register.
    /// - `.outdated` (the helper answered with another version) or an `.unknown` status: `reinstall()`.
    /// - `.failed` because the version call failed or timed out (a cold on-demand launch, a loaded machine, an XPC
    ///   interruption): drop the connection and ask once more on a fresh one. If that fails too, report `.failed`
    ///   and leave the registration alone; the user can choose "Reinstall helper".
    public func ensureRegistered() async -> HelperState {
        await singleFlight { [self] in await performEnsureRegistered() }
    }

    private func performEnsureRegistered() async -> HelperState {
        let state = await refresh()
        switch state {
        case .notRegistered:
            return await registerThenRefresh()
        case .outdated:
            return await performReinstall()
        case .failed:
            if service.status == .unknown { return await performReinstall() }
            connection.resetConnection()
            return await refresh()
        case .requiresApproval, .enabled:
            return state
        }
    }

    /// Unregisters (errors ignored: a broken registration may not unregister cleanly, and registering again is
    /// still the way out), registers, and reads the status again. The app calls this only when the user clicks
    /// "Reinstall helper", never on its own for a helper that didn't answer.
    public func reinstall() async -> HelperState {
        await singleFlight { [self] in await performReinstall() }
    }

    private func performReinstall() async -> HelperState {
        try? await service.unregister()
        connection.resetConnection()
        return await registerThenRefresh()
    }

    public func openLoginItems() { service.openSystemSettingsLoginItems() }

    /// Joins the registration call in flight, or starts `work` as the new one. The task is created under the lock,
    /// so two callers can't both start one, and it clears itself (by id) when it ends.
    private func singleFlight(_ work: @escaping @Sendable () async -> HelperState) async -> HelperState {
        let task = inFlight.withLock { current -> Task<HelperState, Never> in
            if let current { return current.task }
            let id = UUID()
            let task = Task { [self] in
                let state = await work()
                inFlight.withLock { if $0?.id == id { $0 = nil } }
                return state
            }
            current = (id, task)
            return task
        }
        return await task.value
    }

    /// Registers, drops any connection to the helper that ran before, and reads the status again. A throw from
    /// `register()` is reported as `.failed` only when the status afterwards isn't `.requiresApproval` or
    /// `.enabled`.
    private func registerThenRefresh() async -> HelperState {
        var registerError: (any Error)?
        do { try service.register() } catch { registerError = error }
        connection.resetConnection()
        let after = await refresh()
        guard let registerError else { return after }
        switch after {
        case .requiresApproval, .enabled: return after
        default: return .failed("Couldn't register the helper: \(registerError.localizedDescription)")
        }
    }
}
