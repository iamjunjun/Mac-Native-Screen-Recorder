import AppKit
import CoreGraphics

final class RecordingAreaOverlay: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let dashPattern: [CGFloat] = [6, 4]
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash(dashPattern, count: 2, phase: 0)
        NSColor(white: 0xCA / 255.0, alpha: 1.0).setStroke()
        path.stroke()
    }

    /// Creates a borderless overlay window for the recorded area.
    /// - Parameters:
    ///   - sourceRect: The area in Quartz coordinates (top-left origin, points, relative to display)
    ///   - displayID: The CGDirectDisplayID of the display being recorded
    static func show(sourceRect: CGRect, displayID: UInt32) -> NSWindow {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == displayID
        }) else {
            // Fallback: use main screen
            return createWindow(rect: sourceRect, screen: NSScreen.screens[0], displayID: displayID)
        }

        return createWindow(rect: sourceRect, screen: screen, displayID: displayID)
    }

    private static func createWindow(rect sourceRect: CGRect, screen: NSScreen, displayID: UInt32) -> NSWindow {
        let displayBounds = CGDisplayBounds(displayID)

        // Convert Quartz sourceRect (top-left origin, relative to display) to AppKit (bottom-left origin, absolute)
        let appKitX = displayBounds.origin.x + sourceRect.origin.x
        let appKitY = screen.frame.maxY - (displayBounds.origin.y - screen.frame.minY) - sourceRect.origin.y - sourceRect.height

        let windowFrame = CGRect(x: appKitX, y: appKitY, width: sourceRect.width, height: sourceRect.height)

        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.sharingType = .none
        window.orderFront(nil)

        let overlayView = RecordingAreaOverlay(frame: NSRect(origin: .zero, size: windowFrame.size))
        window.contentView = overlayView
        return window
    }
}
