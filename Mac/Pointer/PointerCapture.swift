import AppKit
import ApplicationServices
import CoreGraphics
import PhoneScreenKit

// Lets a background (menu bar) app hide the cursor. Private, but the standard route —
// Barrier / Deskflow / Synergy rely on it; without it CGDisplayHideCursor only works while frontmost.
@_silgen_name("_CGSDefaultConnection") private func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

/// Takes the Mac cursor away while it is "on the phone": the cursor is frozen and hidden, and an event tap
/// swallows mouse input and sends it to the phone.
///
/// The tap runs on its own high-priority thread and sends straight from there: the main thread
/// (UI, AppleScript polling) can stall for tens of milliseconds, and the pointer must never wait for it.
final class PointerCapture: @unchecked Sendable {
    /// Sends a message to the phone. Must be thread-safe (`ChannelPool.send` is).
    var send: (@Sendable (Message) -> Void)?
    /// The user asked for the cursor back (Esc). Called on the main thread.
    var onEscape: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var _captured = false
    private var _scale = 1.0
    private var tap: CFMachPort?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var cursorHidden = false

    // Tap-thread state (only touched on the tap thread).
    private var pending = CGVector.zero
    private var lastSend: CFAbsoluteTime = 0
    private var flushTimer: CFRunLoopTimer?
    /// Cap for pointer messages: plenty for 120 Hz screens, and bounded for 1000 Hz gaming mice.
    private let minInterval = 1.0 / 240

    var isCaptured: Bool { lock.withLock { _captured } }

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) and opens the Accessibility pane.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// `scale` converts Mac points to phone points. Call on the main thread.
    @MainActor func begin(scale: Double) -> Bool {
        guard !isCaptured else { return true }
        guard installTap() else { return false }
        lock.withLock {
            _scale = scale
            _captured = true
        }
        CGAssociateMouseAndMouseCursorPosition(0)
        hideCursor()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return true
    }

    /// Give the cursor back at `point` (global CG coordinates). Call on the main thread.
    @MainActor func end(at point: CGPoint?) {
        guard isCaptured else { return }
        lock.withLock { _captured = false }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let point { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(1)
        showCursor()
    }

    // MARK: - Cursor

    @MainActor private func hideCursor() {
        guard !cursorHidden else { return }
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
    }

    @MainActor private func showCursor() {
        guard cursorHidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        cursorHidden = false
    }

    // MARK: - Event tap (own thread)

    @MainActor private func installTap() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return Unmanaged<PointerCapture>.fromOpaque(info).takeUnretainedValue().handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false // no Accessibility permission
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            // Flushes coalesced movement that arrived faster than `minInterval`.
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), self.minInterval, 0, 0) { [weak self] _ in
                self?.flush(force: false)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .commonModes)
            self.flushTimer = timer
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "PhoneScreen.pointer"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        ready.wait()
        return true
    }

    /// Tap thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let (captured, scale) = lock.withLock { (_captured, _scale) }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns slow taps off; turn it back on while we still own the cursor.
            if captured, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        guard captured else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pending.dx += event.getDoubleValueField(.mouseEventDeltaX) * scale
            pending.dy += event.getDoubleValueField(.mouseEventDeltaY) * scale
            flush(force: false)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            flush(force: true) // the click lands where the pointer is now
            let left = type == .leftMouseDown || type == .leftMouseUp
            send?(.pointerButton(button: left ? .left : .right, down: type == .leftMouseDown || type == .rightMouseDown))
        case .scrollWheel:
            flush(force: true)
            send?(scroll(event, scale: scale))
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // Esc
                DispatchQueue.main.async { [onEscape] in MainActor.assumeIsolated { onEscape?() } }
                return nil
            }
            return Unmanaged.passUnretained(event) // typing still goes to the Mac for now
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil // swallowed: the Mac doesn't see mouse input while it's on the phone
    }

    /// Tap thread. Sends accumulated movement now, or waits for the timer if we sent very recently.
    private func flush(force: Bool) {
        guard pending != .zero else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastSend >= minInterval else { return }
        send?(.pointerDelta(dx: pending.dx, dy: pending.dy))
        pending = .zero
        lastSend = now
    }

    private func scroll(_ event: CGEvent, scale: Double) -> Message {
        // Pixel deltas for trackpads / smooth mice; line deltas for classic wheels.
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let dy = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                            : event.getDoubleValueField(.scrollWheelEventDeltaAxis1) * 10
        let dx = continuous ? event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
                            : event.getDoubleValueField(.scrollWheelEventDeltaAxis2) * 10
        // kCGScrollPhase*: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may-begin. Momentum phase ≠ 0 = inertia.
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let phase: ScrollPhase = if momentum != 0 {
            .momentum
        } else {
            switch event.getIntegerValueField(.scrollWheelEventScrollPhase) {
            case 1, 128: .began
            case 2: .changed
            case 4, 8: .ended
            default: .wheel
            }
        }
        return .pointerScroll(dx: dx * scale, dy: dy * scale, phase: phase)
    }
}
