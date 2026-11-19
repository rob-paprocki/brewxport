import AppKit
import Foundation
import BrewxPortUI

/// The demo-only parts of launching: regular activation, a forced appearance, and `--snapshot`.
extension AppDelegate {
    /// How long a `--snapshot` run may take in all before it gives up with exit 1.
    static let snapshotDeadline: Double = 30

    var demo: DemoOptions? { DemoLaunch.isActive ? DemoLaunch.options : nil }

    /// A demo started from a script must still be a regular app with a Dock icon, so it can be driven and
    /// photographed. `--appearance` forces light or dark.
    func demoWillFinishLaunching() {
        guard let demo else { return }
        model = DemoLaunch.model
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
        guard let directory = demo.snapshot else { return }
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

    /// The scene's window once it's on screen, or nil after 10 s.
    private func sceneWindow() async -> NSWindow? {
        for _ in 0..<200 {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { return window }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}
