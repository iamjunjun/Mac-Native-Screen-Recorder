import AppKit
import CoreGraphics

final class AreaSelectionOverlayView: NSView {
    var onSelectionComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    var selectionRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = abs(current.x - start.x)
        let h = abs(current.y - start.y)
        guard w > 4 && h > 4 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        if let rect = selectionRect {
            onSelectionComplete?(rect)
        } else {
            onCancel?()
        }
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim the entire view
        NSColor.black.withAlphaComponent(0.4).setFill()
        bounds.fill()

        // Punch a hole for the selection area
        if let rect = selectionRect {
            rect.fill(using: .clear)

            // Selection border
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.stroke()

            // Dimension label
            let label = "\(Int(rect.width)) × \(Int(rect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let labelSize = label.size(withAttributes: attrs)
            let labelX = rect.midX - labelSize.width / 2
            let labelY = rect.maxY + 6
            // If label would go offscreen, put it inside the rect
            let finalY = (labelY + labelSize.height > bounds.height) ? rect.maxY - labelSize.height - 4 : labelY
            label.draw(at: NSPoint(x: labelX, y: finalY), withAttributes: attrs)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    /// Converts an AppKit rect (bottom-left origin, offset from display's origin in the overlay)
    /// to a Quartz rect (top-left origin, offset from display's origin) for SCStreamConfiguration.sourceRect.
    static func convertToQuartzSourceRect(appKitRect: CGRect, displayID: UInt32) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: appKitRect.origin.x,
            y: displayBounds.height - appKitRect.origin.y - appKitRect.height,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }
}

final class AreaSelectionOverlayWindow: NSWindow {
    static func create(on screen: NSScreen) -> AreaSelectionOverlayWindow {
        let window = AreaSelectionOverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.acceptsMouseMovedEvents = true
        window.ignoresMouseEvents = false
        window.makeKeyAndOrderFront(nil)

        let overlayView = AreaSelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = overlayView
        window.makeFirstResponder(overlayView)
        return window
    }
}
