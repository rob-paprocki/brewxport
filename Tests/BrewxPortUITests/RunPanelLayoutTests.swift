import Testing
import AppKit
import SwiftUI
import BrewxPortCore
@testable import BrewxPortUI

/// The run panel must never ask the window for more height than it has. When it did, AppKit kept the window's size
/// and the content was laid out taller than the window and centred in it: the sidebar's first rows and the table
/// header slid up under the title bar, and the panel itself fell off the bottom, until the window was resized.
@MainActor @Suite struct RunPanelLayoutTests {
    typealias S = UninstallScenario

    /// RootView's shape (a split view whose detail is the page over the run panel) at the window's minimum size,
    /// without the real pages, which are slow to host.
    struct Window: View {
        let run: RunController
        let panel: Bool

        var body: some View {
            NavigationSplitView {
                List { Text("Installed") }
            } detail: {
                VStack(spacing: 0) {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if panel {
                        Divider()
                        RunPanel(run: run)
                    }
                }
            }
            .frame(minWidth: 900, minHeight: 560)
        }
    }

    /// The window content's height, hosted the way the app hosts it.
    static func contentHeight(_ run: RunController, panel: Bool) -> CGFloat {
        let host = NSHostingView(rootView: Window(run: run, panel: panel))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        return host.fittingSize.height
    }

    @Test func aProblemLineDoesNotGrowTheWindow() async throws {
        // A standard account confirming a MacPorts-only uninstall: the panel shows "Nothing ran" and one long problem.
        let s = S(isAdministrator: false)
        await s.start([S.curl])
        _ = try #require(await s.ready())
        s.model.uninstall.confirm()
        #expect(s.model.run.panelVisible && s.model.run.problems.count == 1)
        let shown = Self.contentHeight(s.model.run, panel: true)
        let hidden = Self.contentHeight(s.model.run, panel: false)
        #expect(shown <= hidden, "with the panel \(shown), without \(hidden)")
    }
}
