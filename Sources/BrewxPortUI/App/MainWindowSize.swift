import CoreGraphics

/// The main window's size on first launch: 1200×760, shrunk to fit the display's visible area with a margin, never
/// below the 900×560 minimum. The window opens centred; after that, window restoration keeps the user's frame.
public enum MainWindowSize {
    public static let ideal = CGSize(width: 1200, height: 760)
    public static let minimum = CGSize(width: 900, height: 560)
    /// Room left around the window on a display smaller than `ideal`.
    static let margin: CGFloat = 40

    public static func initial(visible: CGSize) -> CGSize {
        CGSize(width: max(minimum.width, min(ideal.width, visible.width - 2 * margin)),
               height: max(minimum.height, min(ideal.height, visible.height - 2 * margin)))
    }
}
