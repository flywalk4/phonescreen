import AppKit
import ApplicationServices
import CoreGraphics

/// The phone as a real display of the Mac: a virtual display (private CGVirtualDisplay) placed in the Mac's
/// arrangement exactly where the phone sits. macOS then treats it like any monitor — windows are dragged onto
/// it, the cursor moves across on its own — and `DisplayStreamer` sends its picture to the phone.
///
/// Removing it makes macOS move its windows back to the other displays; their frames are remembered and put
/// back the next time the display appears, so leaving the page for a moment doesn't lose the layout.
@MainActor
final class PhoneDisplay {
    /// Pixels per point: HiDPI, so text on the phone is as sharp as on a Retina Mac.
    static let scale = 2
    /// Marks our virtual display, so the arrangement never offers it as a display to put the phone next to.
    nonisolated static let vendorID: UInt32 = 0x5053 // "PS"

    private(set) var display: CGVirtualDisplay?
    /// Size in points of the current mode.
    private(set) var size: CGSize = .zero
    /// Windows that were on the display when it went away: (pid, title, frame relative to the display).
    private var parked: [(pid: pid_t, title: String?, frame: CGRect)] = []

    var displayID: CGDirectDisplayID? { display?.displayID }

    /// Global bounds of the display (CG coordinates), as macOS actually placed it.
    var bounds: CGRect? { displayID.map(CGDisplayBounds) }

    /// macOS only offers a HiDPI desktop mode whose shorter side is at least this many points.
    static let minimumShortSide: CGFloat = 640

    /// Where the display goes for a given size (it depends on the size: a display left of another ends at its edge).
    private var origin: ((CGSize) -> CGPoint)?
    private var createdAt = Date.distantPast
    /// macOS ended the display itself.
    var onGone: (() -> Void)?

    /// The display object exists but macOS no longer shows it: the user disconnected it (Control Center or
    /// System Settings → Displays). Ignored for a moment after creation, while macOS is still setting it up.
    var isGone: Bool {
        guard display != nil, Date().timeIntervalSince(createdAt) > 2 else { return false }
        return !isLive
    }

    private var isLive: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsOnline(id) != 0 && CGDisplayIsActive(id) != 0
    }

    /// Forgets a display macOS already took away (its windows have moved off it by then).
    func discard() {
        display = nil
        size = .zero
    }

    /// Creates the display (or resizes it) at `points` (a HiDPI mode: twice as many pixels) and moves it to
    /// `origin(size)` in global CG coordinates. Returns false if the private API is unavailable.
    @discardableResult
    func show(points requested: CGSize, millimeters: CGSize, origin: @escaping (CGSize) -> CGPoint) -> Bool {
        let points = CGSize(width: requested.width.rounded(), height: requested.height.rounded())
        self.origin = origin
        // Disconnected on the Mac's side: the old object can't come back, so a fresh display replaces it.
        if isGone {
            AppModel.log.info("display: was disconnected, creating it again")
            discard()
        }
        if display == nil {
            let descriptor = CGVirtualDisplayDescriptor()
            descriptor.queue = .main
            descriptor.name = "iPhone (Qwovi)"
            // Room for a HiDPI mode of any phone in either orientation, so rotating only needs a new mode.
            descriptor.maxPixelsWide = 3200
            descriptor.maxPixelsHigh = 3200
            descriptor.sizeInMillimeters = millimeters
            descriptor.vendorID = Self.vendorID
            descriptor.productID = 0x0001
            descriptor.serialNum = 0x0001
            descriptor.terminationHandler = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onGone?() }
            }
            guard let created = CGVirtualDisplay(descriptor: descriptor) else {
                AppModel.log.error("display: CGVirtualDisplay refused")
                return false
            }
            display = created
            size = .zero
            createdAt = Date()
            AppModel.log.info("display: created \(created.displayID)")
        }
        guard let display else { return false }
        if points != size {
            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = 1
            settings.modes = [CGVirtualDisplayMode(width: UInt32(points.width), height: UInt32(points.height), refreshRate: 60)]
            guard display.apply(settings) else {
                AppModel.log.error("display: mode \(Int(points.width))×\(Int(points.height)) refused")
                return false
            }
            size = points
            switchToHiDPI(attempts: 15)
        } else {
            place(at: origin(size))
        }
        return true
    }

    /// A new virtual display starts in the 1× mode of twice the size; the HiDPI one (same pixels, half the
    /// points) is only selectable once macOS has set the display up, so this retries for a few seconds.
    private func switchToHiDPI(attempts: Int) {
        guard let id = displayID else { return }
        let target = size
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
            as? [CGDisplayMode] ?? []
        let current = CGDisplayCopyDisplayMode(id)
        if current?.width == Int(target.width), current?.pixelWidth == Int(target.width) * Self.scale {
            place(at: origin?(target) ?? .zero)
            return
        }
        if let mode = modes.first(where: { $0.width == Int(target.width) && $0.height == Int(target.height) && $0.pixelWidth == Int(target.width) * Self.scale }),
           CGDisplaySetDisplayMode(id, mode, nil) == .success {
            AppModel.log.info("display: HiDPI \(Int(target.width))×\(Int(target.height))")
            place(at: origin?(target) ?? .zero)
            return
        }
        guard attempts > 0 else {
            AppModel.log.error("display: no HiDPI mode, staying at 1×")
            place(at: origin?(CGDisplayBounds(id).size) ?? .zero)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.displayID == id, self.size == target else { return }
            self.switchToHiDPI(attempts: attempts - 1)
        }
    }

    /// Moves the display to `origin` in the arrangement (macOS snaps it to the nearest edge anyway).
    func place(at origin: CGPoint) {
        guard let id = displayID, CGDisplayBounds(id).origin != origin else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            AppModel.log.error("display: could not move to \(origin.x),\(origin.y)")
        }
    }

    /// Removes the display, remembering which windows were on it.
    func hide() {
        guard let bounds else { return }
        parked = Self.windows(in: bounds).map { ($0.pid, $0.title, $0.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)) }
        display = nil // releasing the object removes the display
        size = .zero
        AppModel.log.info("display: removed, \(self.parked.count) windows parked")
    }

    /// Puts windows that were on the display last time back onto it. Called shortly after `show`, once
    /// macOS has the new display in its layout.
    func restoreWindows() {
        guard let bounds, !parked.isEmpty else { return }
        let windows = parked
        parked = []
        DispatchQueue.global(qos: .userInitiated).async {
            for item in windows {
                let app = AXUIElementCreateApplication(item.pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let list = value as? [AXUIElement] else { continue }
                let match = list.first { Self.string($0, kAXTitleAttribute) == item.title } ?? (list.count == 1 ? list.first : nil)
                guard let window = match else { continue }
                var origin = CGPoint(x: bounds.minX + item.frame.minX, y: bounds.minY + item.frame.minY)
                var size = item.frame.size
                if let position = AXValueCreate(.cgPoint, &origin) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
                }
                if let extent = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
                }
            }
        }
    }

    /// Normal windows whose centre is inside `bounds` (global CG coordinates).
    private static func windows(in bounds: CGRect) -> [(pid: pid_t, title: String?, frame: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return (pid, window[kCGWindowName as String] as? String, frame)
        }
    }

    private nonisolated static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
