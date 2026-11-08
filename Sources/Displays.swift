import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable across reconnects and reboots, unlike the numeric display ID.
    var uuid: String {
        CGDisplayCreateUUIDFromDisplayID(displayID)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? String(displayID)
    }

    /// The camera cutout measured from the menu bar's free areas on each side of it, if this display has one.
    /// Measured live, so it follows a change of the display's scaling.
    var notch: (size: CGSize, centre: CGFloat)? {
        guard safeAreaInsets.top > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return (CGSize(width: right.minX - left.maxX, height: safeAreaInsets.top), (left.maxX + right.minX) / 2)
    }

    /// How much to enlarge the island on a display without a notch so it keeps its proportions on a big screen:
    /// 1 up to a 2048 pt-wide display, growing with it up to 1.4 (a 2560 pt monitor gets 1.25).
    var autoScale: CGFloat { min(max(frame.width / 2048, 1), 1.4) }

    /// The size of a virtual notch on a display without one: the menu bar's height, a width in proportion to the display.
    var virtualNotch: CGSize {
        CGSize(width: min(max((frame.width * 0.065).rounded(), 130), 190), height: NSStatusBar.system.thickness)
    }
}
