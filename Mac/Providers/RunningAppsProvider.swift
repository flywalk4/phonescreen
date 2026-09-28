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
