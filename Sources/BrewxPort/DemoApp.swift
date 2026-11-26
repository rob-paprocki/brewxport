import AppKit
import Foundation
import BrewxPortUI
import SwiftUI

/// What a `--demo` launch runs on. Set once in `main`, before SwiftUI starts. Only DemoServices, never the live ones.
@MainActor enum DemoLaunch {
    static private(set) var isActive = false
    static private(set) var options = DemoOptions()
    /// Nil when the demo services couldn't be built; `problem` says why.
    static private(set) var model: BrewxPortAppModel?
    static private(set) var problem: String?

    static func prepare(_ options: DemoOptions) {
        isActive = true
        self.options = options
        do {
            model = BrewxPortAppModel(services: try DemoServices.make(options))
        } catch DemoServicesError.noFixtures {
            problem = DemoServices.noFixturesMessage
        } catch {
            problem = "Demo mode couldn't read the captured engine output: \(error)"
        }
        if let problem { FileHandle.standardError.write(Data("BrewxPort demo: \(problem)\n".utf8)) }
    }
}

/// The real window on demo services: captured engine output, simulated runs, no helper.
struct DemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(DemoLaunch.model?.windowTitle ?? "BrewxPort (demo)", id: MainWindowScene.id) {
            Group {
                if let model = DemoLaunch.model {
                    RootView(model: model)
                        .frame(minWidth: 900, minHeight: 560)
                } else {
                    ContentUnavailableView {
                        Label("Demo mode can't start", systemImage: "shippingbox")
                    } description: {
                        Text(DemoLaunch.problem ?? DemoServices.noFixturesMessage)
                    }
                    .frame(minWidth: 480, minHeight: 240)
                }
            }
            .keepsMainWindowOpener()
        }
        .mainWindowPlacement()
        .commands { BrewxPortCommands(model: DemoLaunch.model) }
        MenuBarScene(model: DemoLaunch.model)
        // Demo settings live in memory for this launch only (`MemoryStore`), and touch nothing on this Mac.
        Settings {
            if let model = DemoLaunch.model {
                SettingsView(model: model)
            } else {
                Text(DemoLaunch.problem ?? DemoServices.noFixturesMessage)
                    .padding(24)
                    .frame(width: 480)
            }
        }
    }
}
