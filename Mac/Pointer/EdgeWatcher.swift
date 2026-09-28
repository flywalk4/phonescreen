import AppKit
import CoreGraphics
import QwoviKit

/// Watches for the cursor being pushed against the portal (the part of a display edge the phone sits at).
/// Pushing — not just resting — is what crosses over, so parking the cursor at the edge or dragging
/// a window there never throws it onto the phone.
@MainActor
final class EdgeWatcher {
    /// Accumulated outward movement (points) needed to cross.
    var threshold: Double = 18
    /// Where the cursor is (CG global coordinates) when it crosses.
    var onCross: ((CGPoint) -> Void)?
    /// Current portal; nil disables crossing.
    var portal: (display: CGRect, edge: ScreenEdge, segment: (start: CGPoint, end: CGPoint))?
    var isEnabled = true

    private var monitors: [Any] = []
    private var push: Double = 0

    func start() {
        // Listen-only monitors: need no permission and never delay events. Global = other apps are
        // frontmost, local = our own window is. Only plain moves count: drags (windows, files) never cross.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled, let portal else { push = 0; return }
        let location = Self.cursorLocation()
        guard ArrangementGeometry.isOnPortal(location, display: portal.display, edge: portal.edge, portal: portal.segment) else { push = 0; return }
        let outward = ArrangementGeometry.outwardComponent(dx: event.deltaX, dy: event.deltaY, edge: portal.edge)
        if outward > 0 {
            push += outward
        } else if outward < 0 {
            push = 0
        }
        if push >= threshold {
            push = 0
            onCross?(location)
        }
    }

    /// Cursor position in CG global coordinates (origin top-left of the main display, y down).
    static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
