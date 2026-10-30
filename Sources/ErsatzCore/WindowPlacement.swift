#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Pure geometry for keeping the main window reachable.
/// A window counts as reachable when enough of its title bar sits on a visible screen area.
public enum WindowPlacement {
    /// Height of the strip at the top of a window that must be on screen (title bar plus a margin).
    public static let titleStrip: CGFloat = 32
    /// Minimum width of that strip that must be visible.
    public static let minimumVisibleWidth: CGFloat = 120

    /// Returns true when no screen shows enough of the window's title bar to drag it.
    /// Frames use AppKit coordinates, where y grows upward and `maxY` is the top edge.
    public static func isOffScreen(window frame: CGRect, screens: [CGRect]) -> Bool {
        guard !screens.isEmpty else { return false }
        let strip = CGRect(
            x: frame.minX,
            y: frame.maxY - titleStrip,
            width: frame.width,
            height: titleStrip
        )
        for screen in screens {
            let overlap = strip.intersection(screen)
            if !overlap.isNull, overlap.width >= min(minimumVisibleWidth, frame.width), overlap.height >= 8 {
                return false
            }
        }
        return true
    }

    /// A frame centered on `screen`, shrunk to fit when it is bigger than the screen.
    public static func centered(_ frame: CGRect, on screen: CGRect) -> CGRect {
        let width = min(frame.width, screen.width)
        let height = min(frame.height, screen.height)
        return CGRect(
            x: (screen.midX - width / 2).rounded(),
            y: (screen.midY - height / 2).rounded(),
            width: width,
            height: height
        )
    }
}
