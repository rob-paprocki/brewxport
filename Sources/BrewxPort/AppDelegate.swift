import AppKit
import BrewxPortUI
import os
import SwiftUI

/// Whether a launch was taken for a login item and where the Dock icon ended up, for checking a login on a test Mac.
private let launchLog = Logger(subsystem: "com.brewxport.app", category: "launch")

/// Quit, window and Dock handling. Quitting during a run asks first; confirming cancels the run (which kills its child
/// processes) and quits once it has ended or `BrewxPortTimeouts.quitCancel` has passed.
///
/// With background checks on, closing the window leaves BrewxPort running in the menu bar, and its Dock icon goes
/// until the window or Settings opens again (`showsDockIcon`). With them off, closing the window quits, except during a
/// run (`quitsWhenLastWindowCloses`). The window comes back from the Dock icon or opening BrewxPort again in the
/// Finder, from the menu bar's Open BrewxPort, from "Keep running", and at the end of a run the person started (a menu
/// bar Update included); a background run's end leaves it closed (`reopensWindowAfterRun`). A launch as a login item
/// shows no window while checks are on, and the window as usual while they're off (`opensWindowAtLoginLaunch`). Once
/// any launch has settled, the Dock icon follows the rule from what's on screen (`launchSettled`).
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nil in the notice-only window, which always quits at once.
    var model: BrewxPortAppModel? {
        // Set at launch and again when the window appears: the observer is added once per model.
        didSet {
            guard let model, model !== oldValue else { return }
            model.addRunEndedObserver { [weak model] in
                guard model?.reopensWindowAfterRun == true else { return }
                MainWindow.reopenIfClosed()
            }
            // Things the person clicked (the menu bar's Open BrewxPort, Show and Update, a notification): the window
            // comes back, or forward, in front of other apps.
            model.openMainWindow = { MainWindow.show() }
            // The password run nobody clicked for: only once BrewxPort is really the active app, both before the run
            // and when it asks for the password; a sheet that has to wait shows once the focus comes back.
            model.presentForPassword = { await MainWindow.presentForPassword() }
            model.run.canPresentPasswordSheet = { MainWindow.isActiveAndKey }
            let run = model.run
            focusObservers = [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { run.presentWaitingPrompt() }
                }
            }
        }
    }
    private var focusObservers: [any NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        demoWillFinishLaunching()
    }

    /// How long after launching the Dock icon follows the rule again (`launchSettled`): by then the window a launch
    /// opens is up and its content has said so.
    static let launchSettle: Duration = .seconds(1)

    /// The model starts here, not when the window appears, so it loads even when no window shows.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read first: the launch's Apple event is current only during this call (it's still nil in `main` and in
        // `applicationWillFinishLaunching`).
        let atLogin = LaunchMode.isLoginItemLaunch(NSAppleEventManager.shared().currentAppleEvent)
        model?.start()
        demoDidFinishLaunching()
        guard let model else { return }
        if atLogin { windowAfterLoginLaunch(model) }
        // A login launch has no window, so its Dock icon follows the rule at once. Any other launch is opening its
        // window (applying the rule now could flicker the icon): it follows once launch has settled, and then
        // whenever the rule changes.
        followDockIcon(of: model, applyNow: atLogin)
        launchLog.notice("""
            Launched: login item \(atLogin, privacy: .public), window \(MainWindow.isShowing, privacy: .public), \
            Dock icon \(NSApp.activationPolicy() == .regular, privacy: .public)
            """)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.launchSettle)
            self?.dockIconAfterLaunch(atLogin: atLogin)
        }
    }

    /// Once launch has settled, the Dock icon follows the rule from what's on screen (`launchSettled`), whatever the
    /// launch was taken for. A login launch that wasn't recognised as one (it shows no window either way) and a
    /// window closed at login before its content appeared both left a Dock icon with no window (VM finding 1);
    /// nothing changes `showsDockIcon` then, so nothing else would hide it.
    private func dockIconAfterLaunch(atLogin: Bool) {
        guard let model else { return }
        let onScreen = MainWindow.isShowing
        let shown = model.launchSettled(mainWindowOnScreen: onScreen, afterLoginLaunch: atLogin)
        applyDockIcon(shown)
        launchLog.notice("""
            Launch settled: window \(onScreen, privacy: .public), Dock icon \(shown, privacy: .public)
            """)
    }

    /// A login-item launch is menu bar only while BrewxPort stays in the menu bar. macOS itself presents no window for
    /// one (seen on macOS 27 with a simulated login-item launch, whatever `defaultLaunchBehavior` says), so closing it
    /// only covers a system that does. With background checks off there's no menu bar and nothing else would show,
    /// so the window opens as at any other launch (`opensWindowAtLoginLaunch`).
    private func windowAfterLoginLaunch(_ model: BrewxPortAppModel) {
        if model.opensWindowAtLoginLaunch {
            MainWindow.openAtLaunch()
        } else {
            MainWindow.close()
        }
    }

    /// Sets the activation policy from `showsDockIcon` (when `applyNow`) and again each time it changes: the window
    /// opens or closes, or background checks are turned on or off. Getting the Dock icon back also brings BrewxPort
    /// forward, so the window that opened is in front.
    private func followDockIcon(of model: BrewxPortAppModel, applyNow: Bool) {
        let shown = withObservationTracking { model.showsDockIcon } onChange: { [weak self, weak model] in
            // Called before the change lands: read it again once it has.
            Task { @MainActor in
                guard let self, let model else { return }
                self.followDockIcon(of: model, applyNow: true)
            }
        }
        if applyNow { applyDockIcon(shown) }
    }

    /// Shows or hides the Dock icon (the activation policy), when that's a change.
    private func applyDockIcon(_ shown: Bool) {
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if shown { NSApp.activate() }
    }

    /// A `.brewxportbundle` double-clicked in the Finder or dropped on the Dock icon: the window comes back if it was
    /// closed, and the file shows on Bundles once BrewxPort has started (at launch) and nothing modal is up
    /// (`openFromFinder`). One file is open at a time, so only the first of several is opened. The notice-only
    /// window has no model and ignores it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model, let url = urls.first else { return }
        MainWindow.reopenIfClosed()
        model.openFromFinder(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.quitsWhenLastWindowCloses ?? true
    }

    /// A Dock-icon click, or opening BrewxPort again in the Finder: the main window comes back if it was closed. Not
    /// only when no window is visible: the Settings window counts as one, and the main window should still come back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.reopenIfClosed()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let run = model?.run, run.quitDecision() == .confirm else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A run is in progress"
        alert.informativeText = "Quitting now stops the step that's running and skips the rest."
        alert.addButton(withTitle: "Cancel the run and quit")
        alert.addButton(withTitle: "Keep running")
        guard alert.runModal() == .alertFirstButtonReturn else {
            MainWindow.reopenIfClosed()
            return .terminateCancel
        }
        Task { @MainActor in
            _ = await run.cancelForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Reopens the main `Window` scene from AppKit code, through the `openWindow` action that scene content saved
/// (`keepsMainWindowOpener()`).
@MainActor enum MainWindow {
    static var open: (() -> Void)?

    /// The main window is on screen. Matched by its identifier: a Settings window is visible and main-capable too.
    static var isShowing: Bool {
        NSApp.windows.contains { $0.isVisible && MainWindowScene.matches($0.identifier?.rawValue) }
    }

    static func reopenIfClosed() {
        guard !isShowing else { return }
        open?()
    }

    /// Opens the window at launch, before any scene content may have appeared to save `open` (a login launch with
    /// checks off has no menu bar and no window). Then BrewxPort sends itself the reopen event a Dock click sends,
    /// and SwiftUI answers it by opening the window: checked in the demo, from `applicationDidFinishLaunching` of a
    /// simulated login-item launch with `open` cleared, within half a second. An event to itself needs no Automation
    /// permission.
    static func openAtLaunch() {
        guard !isShowing else { return }
        if let open {
            open()
            return
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        // Unsent, the window stays closed; the Dock icon (always there with checks off) still opens it.
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }

    /// Opens the window, or brings it forward when it's open (behind other apps, say), and asks to make BrewxPort the
    /// active app. Since macOS 14 the system decides whether to allow that: a real click in the menu bar menu was
    /// allowed, a menu item chosen through Accessibility wasn't. So once SwiftUI has put the window up, it's also
    /// ordered in front of other apps' windows, Dock icon or not. The Dock icon comes back once the window shows
    /// (`showsDockIcon`).
    static func show() {
        open?()
        NSApp.activate()
        Task { @MainActor in
            // SwiftUI opens the window a moment later; give it a second.
            for _ in 0..<20 {
                if let window = visibleWindow {
                    window.orderFrontRegardless()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// For a password run nobody clicked for. Asks macOS to make BrewxPort the active app and, only once it is,
    /// opens the window (or brings it forward) and makes it key: true then, within a second. Never orders the window
    /// over another app: if macOS refuses (the person is busy elsewhere), the window stays as it was and this says
    /// false, so no password sheet appears where a password typed for another app could land in it.
    /// Cancelled (the wait ended meanwhile): false at once.
    static func presentForPassword() async -> Bool {
        NSApp.activate()
        var opened = false
        for _ in 0..<20 {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
            guard NSApp.isActive else { continue }
            guard let window = visibleWindow else {
                if !opened { open?() }
                opened = true
                continue
            }
            window.makeKeyAndOrderFront(nil)
            if window.isKeyWindow { return true }
        }
        return false
    }

    /// BrewxPort is the active app and the main window has the keyboard (or a sheet on it does: the last password
    /// sheet, still going away when a wrong password's retry asks): a password sheet shown now gets what's typed.
    /// `RunController.canPresentPasswordSheet` asks it when a run nobody clicked for wants the password.
    static var isActiveAndKey: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow else { return false }
        return MainWindowScene.matches((key.sheetParent ?? key).identifier?.rawValue)
    }

    private static var visibleWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && MainWindowScene.matches($0.identifier?.rawValue) }
    }

    static func close() {
        for window in NSApp.windows where window.isVisible && MainWindowScene.matches(window.identifier?.rawValue) {
            window.close()
        }
    }
}

/// Saves the scene's `openWindow` action for `MainWindow` whenever content wearing it appears, so the first scene to
/// appear sets it. Any scene's action opens the main window: the menu bar's content can save it before the window has
/// ever shown.
private struct KeepsMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            MainWindow.open = { action(id: MainWindowScene.id) }
        }
    }
}

extension View {
    func keepsMainWindowOpener() -> some View { modifier(KeepsMainWindowOpener()) }
}
