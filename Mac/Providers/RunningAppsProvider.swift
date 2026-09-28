import AppKit
import PhoneScreenKit

/// Apps running on the Mac (the ones with a Dock icon), pushed to the phone on every launch, quit,
/// switch, hide and unhide — no polling. The phone only sends ids; nothing outside the current list is touched.
final class RunningAppsProvider: @unchecked Sendable {
    /// Called on the main thread with every app's icon; the caller strips icons the phone already has.
    var onApps: (@MainActor ([RunningApp]) -> Void)?

    private let queue = DispatchQueue(label: "phonescreen.runningApps", qos: .utility)
    /// Icons by app id, rendered once (PNG rendering is the slow part and stays off the main thread).
    private var icons: [String: Data] = [:]
    private var running: [String: NSRunningApplication] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        observers = names.map { center.addObserver(forName: $0, object: nil, queue: nil) { [weak self] _ in self?.refresh() } }
        refresh()
    }

    func refresh() {
        queue.async { [self] in
            let own = Bundle.main.bundleIdentifier
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            // `runningApplications` is in launch order: positions stay put, so taps hit the same place every time.
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated && $0.bundleIdentifier != own
            }
            var list: [RunningApp] = []
            var byId: [String: NSRunningApplication] = [:]
            for app in apps {
                let id = app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
                guard byId[id] == nil else { continue } // a second instance of the same app
                byId[id] = app
                if icons[id] == nil { icons[id] = Self.png(app.icon) }
                list.append(RunningApp(id: id, name: app.localizedName ?? id, active: app.processIdentifier == front,
                                       hidden: app.isHidden, icon: icons[id]))
            }
            running = byId
            icons = icons.filter { byId[$0.key] != nil }
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
