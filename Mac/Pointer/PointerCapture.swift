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
    private var _phoneTextFocus = false
    /// Key codes whose keyDown went to the phone: their keyUp must not reach the Mac either.
    private var swallowedKeys = Set<Int64>()
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

    /// A text field on the phone has focus: while captured, typing goes there.
    var phoneTextFocus: Bool {
        get { lock.withLock { _phoneTextFocus } }
        set { lock.withLock { _phoneTextFocus = newValue } }
    }

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
        lock.withLock { _captured = false; _phoneTextFocus = false }
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
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp]
        // Trackpad pinch (magnify, 30) and two-finger double tap (smart magnify, 32) have no CGEventType names.
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            | (CGEventMask(1) << Self.magnifyType) | (CGEventMask(1) << Self.smartMagnifyType)
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

    private static let magnifyType: UInt32 = 30
    private static let smartMagnifyType: UInt32 = 32

    /// Tap thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let (captured, scale, textFocus) = lock.withLock { (_captured, _scale, _phoneTextFocus) }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns slow taps off; turn it back on while we still own the cursor.
            if captured, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        guard captured else { return Unmanaged.passUnretained(event) }

        // Pinch / smart zoom go to the phone (page overview) instead of zooming the Mac app underneath.
        if type.rawValue == Self.magnifyType, let ns = NSEvent(cgEvent: event) {
            let phase: ScrollPhase = switch ns.phase {
            case .began, .mayBegin: .began
            case .ended, .cancelled: .ended
            default: .changed
            }
            send?(.pointerPinch(magnification: ns.magnification, phase: phase))
            return nil
        }
        if type.rawValue == Self.smartMagnifyType {
            send?(.pointerSmartZoom)
            return nil
        }

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
            return keyDown(event, textFocus: textFocus)
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowedKeys.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil // swallowed: the Mac doesn't see mouse input while it's on the phone
    }

    /// Tap thread. With a phone text field focused, typing goes to the phone (resolved through the Mac's
    /// current keyboard layout); shortcuts the phone has no use for stay with the Mac.
    private func keyDown(_ event: CGEvent, textFocus: Bool) -> Unmanaged<CGEvent>? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard textFocus else {
            if code == KeyMapping.Code.escape { // nothing to type into: Esc brings the cursor home
                swallowedKeys.insert(code)
                DispatchQueue.main.async { [onEscape] in MainActor.assumeIsolated { onEscape?() } }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 16)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let flags = event.flags
        let action = KeyMapping.action(keyCode: code, command: flags.contains(.maskCommand),
                                       option: flags.contains(.maskAlternate), control: flags.contains(.maskControl),
                                       text: String(utf16CodeUnits: chars, count: length))
        switch action {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .text(let text):
            send?(.keyText(text))
        case .special(let key):
            send?(.key(key))
        case .pasteMacClipboard:
            DispatchQueue.main.async { [send] in
                guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
                send?(.keyText(String(text.prefix(20_000))))
            }
        }
        swallowedKeys.insert(code)
        return nil
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
