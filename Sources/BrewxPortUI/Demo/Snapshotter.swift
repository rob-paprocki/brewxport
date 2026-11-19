import AppKit
import Foundation

public enum SnapshotMethod: String, Sendable { case screencapture, cacheDisplay }

public enum SnapshotError: Error, Equatable, Sendable {
    case noWindow
    case renderFailed
}

/// `--snapshot <dir>`: photographs the demo window's Discover, Updates and Installed views into PNGs, without the
/// menu bar or the desktop. With Screen Recording (granted to the terminal) it uses `screencapture`, which shows
/// vibrancy and the active window as people see them; without it, `cacheDisplay`, which draws them flat.
@MainActor public enum Snapshotter {
    public static let size = NSSize(width: 1200, height: 760)
    public static let views: [(name: String, item: SidebarItem)] =
        [("discover", .discover), ("updates", .updates), ("installed", .installed)]

    /// Photographs the window into a PNG at `url`: with `screencapture` when it can (the real composited window,
    /// sidebar and toolbar vibrancy included), else by rendering the view (`render`). Returns the method used.
    @discardableResult
    public static func write(window: NSWindow, to url: URL) throws -> SnapshotMethod {
        if screenCapture(window: window, to: url) { return .screencapture }
        try render(window: window, to: url)
        return .cacheDisplay
    }

    /// `screencapture -o -x -l <window>`. Without Screen Recording it can exit 0 with a picture of the desktop or a
    /// blank window, so it runs only when `CGPreflightScreenCaptureAccess()` says the permission is there (it's
    /// checked for this process, whose responsible app is the terminal that ran `scripts/demo.sh --snapshot`).
    /// False when it isn't or the capture fails, and `write` falls back to `render`.
    static func screenCapture(window: NSWindow, to url: URL) -> Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-o", "-x", "-l", String(window.windowNumber), url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    /// Renders the window's frame view (title bar and toolbar included) into a PNG at `url`. `cacheDisplay` draws
    /// sidebar and toolbar vibrancy flat and the window as inactive, so this is only the fallback.
    static func render(window: NSWindow, to url: URL) throws {
        guard let view = window.contentView?.superview ?? window.contentView else { throw SnapshotError.noWindow }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { throw SnapshotError.renderFailed }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.renderFailed }
        try data.write(to: url)
    }

    /// Sizes the window, then for each view runs the model's snapshot script, waits `settle` more and writes
    /// `<directory>/<view>-<appearance>.png`. Returns the files written.
    public static func run(model: BrewxPortAppModel, window: NSWindow, directory: URL, appearance: Appearance?,
                           settle: Duration = .milliseconds(500)) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        // Started from a terminal, the demo isn't made active by NSApp.activate() alone; photograph it as the
        // active window, the way people see it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let suffix = (appearance ?? currentAppearance(window)).rawValue
        var written: [URL] = []
        for view in views {
            await model.prepareSnapshot(view.item)
            try await Task.sleep(for: settle)
            window.displayIfNeeded()
            let url = directory.appendingPathComponent("\(view.name)-\(suffix).png")
            let method = try write(window: window, to: url)
            FileHandle.standardError.write(Data("BrewxPort demo: \(url.lastPathComponent) via \(method.rawValue)\n".utf8))
            written.append(url)
        }
        return written
    }

    private static func currentAppearance(_ window: NSWindow) -> Appearance {
        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}
