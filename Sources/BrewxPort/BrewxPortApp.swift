import Foundation
import BrewxPortCore
import BrewxPortUI
import SwiftUI

/// The entry point. The launch mode is parsed before anything else. `--self-check` runs before SwiftUI and never
/// touches SMAppService or XPC, so the bundle can be checked on a development Mac without registering the helper.
/// A normal launch on a development Mac shows only a notice and builds no services at all.
@main
enum BrewxPortMain {
    @MainActor static func main() {
        let mode = LaunchMode.parse(CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
        if mode == .selfCheck {
            exit(SelfCheck.run())
        }
        // Files reach BrewxPort only from LaunchServices (`AppDelegate.application(_:open:)`), never from its
        // arguments. Without this, AppKit takes a path argument (`--demo-fixtures DIR`, `--snapshot DIR`) for a file
        // to open, and SwiftUI then presents no window at launch.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        switch StartupPolicy.decide(mode: mode, developmentMac: StartupPolicy.isDevelopmentMac()) {
        case .live:
            BrewxPortApp.main()
        case .developmentMacNotice:
            NoticeApp.main()
        case .demo:
            guard case .demo(let options) = mode else { return }
            DemoLaunch.prepare(options)
            DemoApp.main()
        }
    }
}

/// The real window, on live services.
struct BrewxPortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: BrewxPortAppModel

    init() {
        let model = BrewxPortAppModel(services: LiveServices.make())
        _model = State(initialValue: model)
        delegate.model = model
    }

    var body: some Scene {
        Window("BrewxPort", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { delegate.model = model }
                .keepsMainWindowOpener()
        }
        .mainWindowPlacement()
        .commands { BrewxPortCommands(model: model) }
    }
}

/// The only window a launch that mustn't touch this Mac's engines or helper gets. No model, no services.
struct NoticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Its own id, never "main": the two windows would share a saved frame, and the 900-wide main window
        // reopened partly off-screen at the 480-wide notice's origin. Nothing about it is worth restoring either.
        Window("BrewxPort", id: "notice") {
            ContentUnavailableView {
                Label("Development Mac", systemImage: "hammer")
            } description: {
                Text(StartupPolicy.developmentMacNotice)
            }
            .frame(minWidth: 480, minHeight: 240)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// The engines BrewxPort drives, found at their fixed paths.
enum Engines {
    /// Each engine looks its executable up again every time it's used, so one installed while BrewxPort runs
    /// (set up from the first-launch screen, say) is found by the next check without relaunching.
    static func make(runner: CommandRunning = ProcessRunner(), arch: Arch = .current,
                     locator: EngineLocator = EngineLocator()) -> [any Engine] {
        func path(_ id: EngineID) -> @Sendable () -> URL? { { locator.locate(id, arch: arch) } }
        return [
            HomebrewEngine(runner: runner, locate: path(.homebrew), arch: arch),
            NanobrewEngine(runner: runner, locate: path(.nanobrew)),
            MacPortsEngine(runner: runner, locate: path(.macports)),
            MasEngine(runner: runner, locate: path(.mas)),
        ]
    }
}

/// `BrewxPort --self-check`: prints which engines the catalog finds, then exits 0.
enum SelfCheck {
    static func run() -> Int32 {
        let arch = Arch.current
        let catalog = PackageCatalog(engines: Engines.make(arch: arch), arch: arch)
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set(await catalog.presentEngines())
            done.signal()
        }
        done.wait()
        let statuses = result.get()
        print("BrewxPort self-check (\(arch.rawValue))")
        var present = 0
        for id in PackageCatalog.defaultOrder(for: arch) {
            switch statuses[id] {
            case .present(let path, let version)?:
                present += 1
                print("  present  \(id.rawValue) \(version) at \(path.path)")
            case .unusable(let path, let reason)?:
                print("  unusable \(id.rawValue) at \(path.path): \(reason)")
            case .missing?, nil:
                print("  missing  \(id.rawValue)")
            }
        }
        print("\(present) engine(s) present")
        return 0
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [EngineID: EngineStatus] = [:]
        func set(_ value: [EngineID: EngineStatus]) { lock.withLock { self.value = value } }
        func get() -> [EngineID: EngineStatus] { lock.withLock { value } }
    }
}

extension Scene {
    /// First launch: a window that fits the display (`MainWindowSize`), centred. Window restoration keeps the
    /// user's frame after that.
    func mainWindowPlacement() -> some Scene {
        defaultSize(MainWindowSize.ideal)
            .defaultWindowPlacement { _, context in
                WindowPlacement(.center, size: MainWindowSize.initial(visible: context.defaultDisplay.visibleRect.size))
            }
    }
}
