import CoreGraphics
import QwoviKit

/// Fingers on the phone's second screen, turned into real mouse events on the virtual display: a tap clicks,
/// dragging drags (windows included), a long press right-clicks, two fingers scroll. Needs Accessibility,
/// like the pointer capture.
enum DisplayInput {
    private static let source = CGEventSource(stateID: .hidSystemState)
    private static var pressed = false
    private static var clickState: Int64 = 1
    private static var lastDown: (time: CFAbsoluteTime, point: CGPoint)?

    /// `x`, `y` are 0…1 across the picture; `bounds` is the display in global CG coordinates.
    static func touch(_ phase: DisplayTouchPhase, x: Double, y: Double, in bounds: CGRect) {
        let point = CGPoint(x: bounds.minX + min(max(x, 0), 1) * (bounds.width - 1),
                            y: bounds.minY + min(max(y, 0), 1) * (bounds.height - 1))
        switch phase {
        case .hover:
            post(.mouseMoved, at: point, button: .left)
        case .began:
            // Two taps close together in time and place are a double click, as with a real mouse.
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastDown, now - last.time < 0.4, hypot(last.point.x - point.x, last.point.y - point.y) < 12 {
                clickState += 1
            } else {
                clickState = 1
            }
            lastDown = (now, point)
            post(.mouseMoved, at: point, button: .left)
            post(.leftMouseDown, at: point, button: .left)
            pressed = true
        case .moved:
            post(pressed ? .leftMouseDragged : .mouseMoved, at: point, button: .left)
        case .ended:
            if pressed { post(.leftMouseUp, at: point, button: .left) }
            pressed = false
        case .rightClick:
            if pressed { post(.leftMouseUp, at: point, button: .left); pressed = false }
            clickState = 1
            post(.mouseMoved, at: point, button: .right)
            post(.rightMouseDown, at: point, button: .right)
            post(.rightMouseUp, at: point, button: .right)
        }
    }

    static func scroll(dx: Double, dy: Double) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        event.post(tap: .cghidEventTap)
    }
}
