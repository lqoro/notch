import AppKit

/// Describes where the hardware notch (or a fallback pill) lives on the built-in display.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var midX: CGFloat
    var hasHardwareNotch: Bool
    var displayID: CGDirectDisplayID

    static let fallbackSize = CGSize(width: 200, height: 32)

    @MainActor
    static func builtInScreen() -> NSScreen? {
        func displayID(_ s: NSScreen) -> CGDirectDisplayID? {
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        if let s = NSScreen.screens.first(where: { displayID($0).map { CGDisplayIsBuiltin($0) != 0 } ?? false }) {
            return s
        }
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    @MainActor
    static func current() -> NotchGeometry {
        guard let screen = builtInScreen() else {
            return NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 notchSize: fallbackSize, midX: 720, hasHardwareNotch: false,
                                 displayID: CGMainDisplayID())
        }
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        if topInset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = max(frame.width - left.width - right.width, 40)
            return NotchGeometry(screenFrame: frame,
                                 notchSize: CGSize(width: width, height: topInset),
                                 midX: frame.minX + left.width + width / 2,
                                 hasHardwareNotch: true, displayID: id)
        }
        return NotchGeometry(screenFrame: frame, notchSize: fallbackSize, midX: frame.midX,
                             hasHardwareNotch: false, displayID: id)
    }

    /// Rect in global screen coordinates (origin bottom-left) of a top-centered pill of `size`.
    func rect(for size: CGSize) -> CGRect {
        CGRect(x: midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}
