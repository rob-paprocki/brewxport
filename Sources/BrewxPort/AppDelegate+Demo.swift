import AppKit
import Foundation
import BrewxPortUI

/// The demo-only parts of launching: regular activation, a forced appearance, and `--snapshot`.
extension AppDelegate {
    /// How long a `--snapshot` run may take in all before it gives up with exit 1.
    static let snapshotDeadline: Double = 30

    var demo: DemoOptions? { DemoLaunch.isActive ? DemoLaunch.options : nil }

    /// A demo started from a script must still be a regular app with a Dock icon, so it can be driven and
    /// photographed; `showsDockIcon` keeps it one after its window closes. `--appearance` forces light or dark.
    /// The demo's settings start fresh every launch, so it shows the one-time sheet each time, except in a
    /// `--snapshot` run: the pictures are of the pages.
    func demoWillFinishLaunching() {
        guard let demo else { return }
        model = DemoLaunch.model
        if demo.snapshot != nil { DemoLaunch.model?.background.settings.introShown = true }
        NSApp.setActivationPolicy(.regular)
        switch demo.appearance {
        case .light?: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark?: NSApp.appearance = NSAppearance(named: .darkAqua)
        case nil: break
        }
    }

    func demoDidFinishLaunching() {
        guard let demo else { return }
        NSApp.activate()
        if let name = demo.bundle { DemoLaunch.model?.snapshotSample = name }
        guard let directory = demo.snapshot else {
            // `--demo-bundle NAME`: open the sample on Bundles. A snapshot opens the same sample itself, once it
            // reaches Bundles (`prepareSnapshot`, `snapshotSample`), so the earlier views aren't disturbed.
            if let name = demo.bundle, let model = DemoLaunch.model {
                Task { @MainActor in await model.openDemoSample(name) }
            }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.snapshotDeadline) {
            FileHandle.standardError.write(Data("BrewxPort demo: snapshot didn't finish in 30 s\n".utf8))
            exit(1)
        }
        Task { @MainActor in await snapshot(into: directory, appearance: demo.appearance) }
    }

    /// Photographs the scene's own window. Writes the PNGs and quits: exit 0 when every file was written, 1
    /// otherwise.
    private func snapshot(into directory: URL, appearance: Appearance?) async {
        do {
            guard let model = DemoLaunch.model else { throw DemoServicesError.noFixtures }
            guard let window = await sceneWindow() else { throw SnapshotError.noWindow }
            let files = try await Snapshotter.run(model: model, window: window, directory: directory,
                                                  appearance: appearance)
            for file in files { print("BREWXPORT_SNAPSHOT \(file.path)") }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("BrewxPort demo: snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The main window once it's on screen, or nil after 10 s. Matched by its identifier, so a Settings window that
    /// happens to be open is never the one photographed.
    private func sceneWindow() async -> NSWindow? {
        for _ in 0..<200 {
            let main = NSApp.windows.first { $0.isVisible && MainWindowScene.matches($0.identifier?.rawValue) }
            if let main { return main }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
