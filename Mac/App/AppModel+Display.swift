import AppKit
import QwoviKit

/// The phone as a second screen: while a page with the "second screen" widget is on the phone (and the link is
/// fast enough), a virtual display sits where the phone is in the arrangement and its picture streams to the
/// phone. Windows get there the usual way — drag them across the edge.
extension AppModel {
    /// Seconds the display survives after its page is left, so a quick swipe away and back doesn't throw
    /// the windows off it.
    private static let removalDelay: TimeInterval = 5

    /// Whether the second screen should exist right now.
    private var wantsSecondScreen: Bool {
        currentWidgets.contains(.display) && pool.activeTransport != nil && !pool.isLowBandwidth
    }

    func updateSecondScreen() {
        if wantsSecondScreen {
            phoneDisplayRemoval?.invalidate()
            phoneDisplayRemoval = nil
            showPhoneDisplay()
        } else if phoneDisplay.display != nil {
            // Streaming stops at once; the display itself lingers a little.
            displayStreamer.stop()
            guard phoneDisplayRemoval == nil else { return }
            let delay = pool.activeTransport == nil ? 0 : Self.removalDelay
            phoneDisplayRemoval = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.removePhoneDisplay() }
            }
        }
    }

    /// Displays changed on the Mac. If the user disconnected the second screen there, drop it and tell the phone,
    /// which then offers to turn it back on (it isn't recreated behind the user's back).
    func secondScreenDisplaysChanged() {
        guard phoneDisplay.isGone else { return }
        secondScreenLost()
    }

    private func secondScreenLost() {
        guard phoneDisplay.display != nil else { return }
        Self.log.info("display: disconnected on the Mac")
        displayStreamer.stop()
        phoneDisplay.discard()
        isSecondScreenOn = false
        edgeWatcher.isEnabled = true
        pool.send(.displayStop)
    }

    /// Keeps the display where the phone is after the arrangement or orientation changed.
    func placePhoneDisplay() {
        guard phoneDisplay.display != nil else { return }
        let before = phoneDisplay.size
        showDisplayWhereThePhoneIs()
        if phoneDisplay.size != before, displayStreamer.isRunning { startStreaming() }
    }

    /// The virtual display has the phone's shape, but at least `PhoneDisplay.minimumShortSide` points across
    /// (macOS offers no HiDPI mode below that), and sits against the same edge, centred on the phone.
    @discardableResult
    private func showDisplayWhereThePhoneIs() -> Bool {
        guard let phone = phoneRect, let display = arrangedDisplay else { return false }
        let grow = max(1, PhoneDisplay.minimumShortSide / min(phone.width, phone.height))
        let points = CGSize(width: phone.width * grow, height: phone.height * grow)
        let edge = arrangement.edge, mac = display.bounds
        return phoneDisplay.show(points: points, millimeters: Self.millimeters(phone.size, on: display)) { size in
            switch edge {
            case .right: CGPoint(x: mac.maxX, y: phone.midY - size.height / 2)
            case .left: CGPoint(x: mac.minX - size.width, y: phone.midY - size.height / 2)
            case .bottom: CGPoint(x: phone.midX - size.width / 2, y: mac.maxY)
            case .top: CGPoint(x: phone.midX - size.width / 2, y: mac.minY - size.height)
            }
        }
    }

    func handleSecondScreen(_ message: Message) {
        switch message {
        case .displayVisible(let visible):
            // The phone app went to the background or came back; the Mac already follows the page itself.
            if visible { updateSecondScreen(); displayStreamer.requestKeyframe() }
        case .displayKeyframe:
            displayStreamer.requestKeyframe()
        case .displayTouch(let phase, let x, let y):
            guard let bounds = phoneDisplay.bounds else { return }
            if !PointerCapture.hasAccessibility { requestAccessibility(); return }
            DisplayInput.touch(phase, x: x, y: y, in: bounds)
        case .displayScroll(let dx, let dy):
            guard phoneDisplay.bounds != nil else { return }
            DisplayInput.scroll(dx: dx, dy: dy)
        default:
            break
        }
    }

    private func showPhoneDisplay() {
        releasePointer() // the cursor now reaches the phone as a real display
        phoneDisplay.onGone = { [weak self] in self?.secondScreenLost() }
        let isNew = phoneDisplay.display == nil || phoneDisplay.isGone
        guard showDisplayWhereThePhoneIs() else { return }
        isSecondScreenOn = true
        edgeWatcher.isEnabled = false
        if isNew {
            // Give macOS a moment to lay the new display out before putting windows back onto it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.phoneDisplay.restoreWindows() }
        }
        startStreaming()
    }

    private func startStreaming() {
        guard let id = phoneDisplay.displayID else { return }
        let pixels = CGSize(width: phoneDisplay.size.width * CGFloat(PhoneDisplay.scale),
                            height: phoneDisplay.size.height * CGFloat(PhoneDisplay.scale))
        let pool = self.pool
        displayStreamer.send = { pool.send($0) }
        displayStreamer.start(displayID: id, pixels: pixels)
    }

    private func removePhoneDisplay() {
        phoneDisplayRemoval = nil
        guard !wantsSecondScreen else { return }
        displayStreamer.stop()
        phoneDisplay.hide()
        isSecondScreenOn = false
        edgeWatcher.isEnabled = true
    }

    #if DEBUG
    /// `--display-selftest`: create the display and stream it with no phone attached, to check the private API,
    /// the HiDPI mode and the encoder from the logs.
    func selfTestSecondScreen() {
        guard showDisplayWhereThePhoneIs() else { return }
        startStreaming()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let id = self.phoneDisplay.displayID else { return }
            let mode = CGDisplayCopyDisplayMode(id)
            Self.log.info("""
                display selftest: bounds=\(NSStringFromRect(CGDisplayBounds(id)), privacy: .public) \
                mode=\(mode?.width ?? 0)x\(mode?.height ?? 0)@\(mode?.pixelWidth ?? 0) \
                phone=\(NSStringFromRect(self.phoneRect ?? .zero), privacy: .public)
                """)
        }
    }
    #endif

    private static func millimeters(_ points: CGSize, on display: DisplayInfo) -> CGSize {
        CGSize(width: points.width / display.pointsPerMM, height: points.height / display.pointsPerMM)
    }
}
