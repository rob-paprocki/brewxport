/// The main window's scene id, and how AppKit code tells that window from the others (Settings, say). SwiftUI gives a
/// `Window` scene's window the scene id as its identifier ("main"); a `WindowGroup` adds "-AppWindow-N". Being visible
/// and main-capable isn't enough: a Settings window is both.
public enum MainWindowScene {
    public static let id = "main"

    /// True for the identifier of a window that belongs to the main scene.
    public static func matches(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == id || identifier.hasPrefix(id + "-")
    }
}
