import AppKit
import PhoneScreenKit

/// Moving the Mac cursor onto the phone and back.
///
/// Push against the portal → capture (cursor frozen + hidden, mouse input goes to the phone as deltas in
/// phone points) → the phone moves its own pointer and reports when it leaves through the Mac-facing side →
/// the cursor reappears at the matching spot on the Mac edge.
extension AppModel {
    func startPointer() {
        edgeWatcher.onCross = { [weak self] location in self?.pointerCrossed(at: location) }
        edgeWatcher.start()
        let pool = self.pool
        pointerCapture.send = { pool.send($0) }
        pointerCapture.onEscape = { [weak self] in self?.releasePointer() }
        updatePortal()
        if !hasAccessibility { pollAccessibility() }
    }

    func requestAccessibility() {
        PointerCapture.requestAccessibility()
        pollAccessibility()
    }

    /// Bring the cursor back to the Mac: to `point` (the middle of a window just switched to from the phone),
    /// or where it left (Esc, ⌃⌥⌘P, disconnect, arrangement change).
    func releasePointer(to point: CGPoint? = nil) {
        guard pointerCapture.isCaptured else { return }
        pool.send(.pointerExit(along: 0))
        finishCapture(at: point ?? captureEntry.map(inset))
    }

    func updatePortal() {
        guard let display = arrangedDisplay, let phone = phoneRect,
              let segment = ArrangementGeometry.portal(display: display.bounds, phone: phone, edge: arrangement.edge,
                                                       otherDisplays: displays.filter { $0.id != display.id }.map(\.bounds))
        else {
            edgeWatcher.portal = nil
            return
        }
        edgeWatcher.portal = (display.bounds, arrangement.edge, segment)
        placePhoneDisplay()
    }

    // MARK: - Crossing

    private func pointerCrossed(at location: CGPoint) {
        guard !pointerCapture.isCaptured, pool.activeTransport != nil,
              let phone = phoneRect else { return }
        guard PointerCapture.hasAccessibility else {
            hasAccessibility = false
            requestAccessibility()
            return
        }
        let scale = arrangedDisplay.map { ArrangementGeometry.deltaScale(macPointsPerMM: $0.pointsPerMM) } ?? 1
        // Tell the phone first, so the first movement never arrives before the pointer exists.
        pool.send(.pointerEnter(along: ArrangementGeometry.along(ofMacPoint: location, phone: phone, edge: arrangement.edge)))
        guard pointerCapture.begin(scale: scale) else {
            pool.send(.pointerExit(along: 0))
            return
        }
        captureEntry = location
        isPointerOnPhone = true
        Self.log.info("pointer → phone")
    }

    func pointerLeftPhone(along: Double) {
        guard pointerCapture.isCaptured, let display = arrangedDisplay, let phone = phoneRect else { return }
        let point = ArrangementGeometry.exitPoint(along: along, phone: phone, display: display.bounds,
                                                  edge: arrangement.edge, portal: edgeWatcher.portal?.segment)
        finishCapture(at: point)
    }

    private func finishCapture(at point: CGPoint?) {
        pointerCapture.end(at: point)
        isPointerOnPhone = false
        isTypingOnPhone = false
        captureEntry = nil
        Self.log.info("pointer → mac")
    }

    /// A point `2 pt` back inside the display from where the cursor sits on the edge,
    /// so it doesn't immediately cross again.
    private func inset(_ p: CGPoint) -> CGPoint {
        switch arrangement.edge {
        case .right: CGPoint(x: p.x - 2, y: p.y)
        case .left: CGPoint(x: p.x + 2, y: p.y)
        case .bottom: CGPoint(x: p.x, y: p.y - 2)
        case .top: CGPoint(x: p.x, y: p.y + 2)
        }
    }

    private func pollAccessibility() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard PointerCapture.hasAccessibility else { return }
                self?.hasAccessibility = true
                timer.invalidate()
            }
        }
    }
}
