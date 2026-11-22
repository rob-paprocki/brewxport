import AppKit
import BrewxPortUI
import SwiftUI

/// Quit and window handling. Quitting during a run asks first; confirming cancels the run (which kills its child
/// processes) and quits once it has ended or `BrewxPortTimeouts.quitCancel` has passed.
///
/// Closing the window during a run doesn't quit (`quitsWhenLastWindowCloses`), and BrewxPort never stays without a
/// window for long: clicking the Dock icon, answering "Keep running", or the run ending brings the window back.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Nil in the notice-only window, which always quits at once.
    var model: BrewxPortAppModel? {
        // Set at launch and again when the window appears: the observer is added once per model.
        didSet {
            guard model !== oldValue else { return }
            model?.addRunEndedObserver { MainWindow.reopenIfClosed() }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        demoWillFinishLaunching()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        demoDidFinishLaunching()
    }

    /// A `.brewxportbundle` double-clicked in the Finder or dropped on the Dock icon: the window comes back if it was
    /// closed, and the file shows on Bundles once the window has started and nothing modal is up
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindow.reopenIfClosed() }
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

/// Reopens the one `Window` scene ("main") from AppKit code, through the `openWindow` action its content saved.
@MainActor enum MainWindow {
    static var open: (() -> Void)?

    static var isShowing: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    static func reopenIfClosed() {
        guard !isShowing else { return }
        open?()
    }
}

private struct KeepsMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let action = openWindow
            MainWindow.open = { action(id: "main") }
        }
    }
}

extension View {
    func keepsMainWindowOpener() -> some View { modifier(KeepsMainWindowOpener()) }
}
