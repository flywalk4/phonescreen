import AppKit
import PhoneScreenKit

/// Apps running on the Mac (the ones with a Dock icon), most recently used first like ⌘Tab, with their front
/// window's title. Pushed to the phone on every launch, quit, switch, hide and unhide, and only when something
/// changed. The phone only sends ids; nothing outside the current list is touched.
final class RunningAppsProvider: @unchecked Sendable {
    /// Called on the main thread with every app's icon; the caller strips icons the phone already has.
    var onApps: (@MainActor ([RunningApp]) -> Void)?

    private let queue = DispatchQueue(label: "phonescreen.runningApps", qos: .utility)
    /// Icons by app id, rendered once (PNG rendering is the slow part and stays off the main thread).
    private var icons: [String: Data] = [:]
    private var running: [String: NSRunningApplication] = [:]
    /// App ids, most recently activated first.
    private var recent: [String] = []
    private var last: [RunningApp]?
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                if name == NSWorkspace.didActivateApplicationNotification,
                   let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    let id = Self.id(of: app)
                    queue.async { self.recent.removeAll { $0 == id }; self.recent.insert(id, at: 0) }
                }
                refresh()
            }
        }
        refresh()
    }

    /// Sends the list again even if nothing changed (a new connection, the page just appeared).
    func resend() {
        queue.async { [self] in last = nil }
        refresh()
    }

    func refresh() {
        queue.async { [self] in
            let own = Bundle.main.bundleIdentifier
            let front = NSWorkspace.shared.frontmostApplication
            if let front, recent.first != Self.id(of: front) { recent.insert(Self.id(of: front), at: 0) }
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != own
            }
            let trusted = AXIsProcessTrusted()
            var list: [RunningApp] = []
            var byId: [String: NSRunningApplication] = [:]
            for app in apps {
                let id = Self.id(of: app)
                guard byId[id] == nil else { continue } // a second instance of the same app
                byId[id] = app
                if icons[id] == nil { icons[id] = Self.png(app.icon) }
                let windows = trusted ? Self.windows(of: app.processIdentifier) : nil
                list.append(RunningApp(id: id, name: app.localizedName ?? id,
                                       active: app.processIdentifier == front?.processIdentifier, hidden: app.isHidden,
                                       window: windows?.title, windows: windows?.count, icon: icons[id]))
            }
            running = byId
            icons = icons.filter { byId[$0.key] != nil }
            recent = recent.filter { byId[$0] != nil }
            // Recently used first; apps never activated since the agent started keep their launch order after them.
            let rank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
            list = list.enumerated().sorted { (rank[$0.element.id] ?? recent.count + $0.offset) < (rank[$1.element.id] ?? recent.count + $1.offset) }
                .map(\.element)
            guard list != last else { return }
            last = list
            DispatchQueue.main.async { [onApps] in MainActor.assumeIsolated { onApps?(list) } }
        }
    }

    func perform(_ action: AppAction, id: String) {
        queue.async { [self] in
            guard let app = running[id], !app.isTerminated else {
                AppModel.log.error("apps: refused unknown id \(id, privacy: .public)")
                return
            }
            switch action {
            case .activate:
                // Opening through Launch Services is what a Dock click does: it unhides, brings every window
                // forward and reopens a window if the app has none. `activate()` from a background agent is
                // refused by cooperative activation on macOS 14+, so it is only the fallback.
                if let url = app.bundleURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } else {
                    app.unhide()
                    app.activate(options: .activateAllWindows)
                }
            case .hide:
                app.hide()
            case .quit:
                app.terminate()
            }
        }
    }

    /// Where to put the cursor after switching to an app: the middle of its front window. A hidden app or one
    /// that opens a new window takes a moment to show it, so this tries for about a second; nil if none shows up.
    func frontWindowCenter(id: String, completion: @escaping @MainActor (CGPoint?) -> Void) {
        queue.async { [self] in
            guard let pid = running[id]?.processIdentifier, AXIsProcessTrusted() else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(nil) } }
                return
            }
            func attempt(_ left: Int) {
                let center = Self.frontWindowCenter(of: pid)
                if center == nil, left > 0 {
                    queue.asyncAfter(deadline: .now() + 0.2) { attempt(left - 1) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(center) } }
                }
            }
            attempt(5)
        }
    }

    private static func id(of app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    /// The front window's title and how many standard windows the app has, through Accessibility.
    /// A short timeout, so an app that hangs can't stall the list.
    private static func windows(of pid: pid_t) -> (title: String?, count: Int) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        let all = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success
            ? (value as? [AXUIElement] ?? []) : []
        let standard = all.filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
        var front: CFTypeRef?
        var title: String?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &front) == .success,
           let front, CFGetTypeID(front) == AXUIElementGetTypeID() {
            title = string(front as! AXUIElement, kAXTitleAttribute)
        }
        if title?.isEmpty ?? true { title = standard.lazy.compactMap { string($0, kAXTitleAttribute) }.first { !$0.isEmpty } }
        return (title?.isEmpty == false ? title : nil, standard.count)
    }

    /// Centre of the app's focused (or main, or first) window that isn't minimised, in global top-left coordinates.
    private static func frontWindowCenter(of pid: pid_t) -> CGPoint? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var candidates: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() { candidates.append(value as! AXUIElement) }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success {
            candidates += (windows as? [AXUIElement] ?? []).filter { string($0, kAXSubroleAttribute) == kAXStandardWindowSubrole as String }
        }
        for window in candidates {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
               minimized as? Bool == true { continue }
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { continue }
            var origin = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
            else { continue }
            // Some apps keep an invisible 1×1 "window" far off screen (Steam): only a real window on a display counts.
            let frame = CGRect(origin: origin, size: extent)
            guard extent.width >= 60, extent.height >= 40,
                  let visible = displayBounds().lazy.map({ $0.intersection(frame) }).first(where: { !$0.isNull && $0.width >= 20 && $0.height >= 20 })
            else { continue }
            // The middle of the part that is on screen, so a window hanging off the edge still gets the cursor.
            return CGPoint(x: visible.midX, y: visible.midY)
        }
        return nil
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func png(_ image: NSImage?, side: CGFloat = 96) -> Data? {
        guard let image,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
