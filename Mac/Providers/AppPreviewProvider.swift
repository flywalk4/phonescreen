import AppKit
import QwoviKit
import ScreenCaptureKit

/// Small JPEG snapshots of each running app's front window, for the tiles of the apps page. Needs Screen
/// Recording; without it the phone shows icons instead. Captured only while that page is on screen, and an
/// app's snapshot goes out only when it changed.
final class AppPreviewProvider: @unchecked Sendable {
    /// Called on the main thread: a new snapshot, or empty data when the app has no windows left.
    var onPreview: (@MainActor (String, Data) -> Void)?

    /// Longest side of a snapshot, in pixels: about a phone tile at 3×.
    private static let side = 480
    private let lock = NSLock()
    private var busy = false
    private var asked = false
    /// The last snapshot sent per app: an unchanged window isn't sent again.
    private var last: [String: Data] = [:]

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Snapshots of the given apps (ids as in `RunningApp`). Skipped if the previous round is still running.
    func capture(ids: Set<String>) {
        guard Self.hasPermission else {
            // Ask once per launch, the first time the page asks for previews. The system dialog opens Settings.
            lock.withLock {
                if !asked { asked = true; DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() } }
            }
            return
        }
        let start = lock.withLock {
            if busy { return false }
            busy = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) { [self] in
            defer { lock.withLock { busy = false } }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            // Windows come front to back: the first normal-sized one of each app is the one to show.
            var front: [String: SCWindow] = [:]
            var hasWindows: Set<String> = []
            for window in content.windows where window.windowLayer == 0 && window.frame.width >= 120 && window.frame.height >= 90 {
                guard let app = window.owningApplication else { continue }
                let id = app.bundleIdentifier.isEmpty ? "pid:\(app.processID)" : app.bundleIdentifier
                guard ids.contains(id) else { continue }
                hasWindows.insert(id)
                // Minimised and hidden windows have nothing to draw; their last snapshot stays.
                if window.isOnScreen, front[id] == nil { front[id] = window }
            }
            for (id, window) in front {
                guard let data = await Self.snapshot(window) else { continue }
                if lock.withLock({ last[id] == data }) { continue }
                lock.withLock { last[id] = data }
                await MainActor.run { onPreview?(id, data) }
            }
            for id in lock.withLock({ Set(last.keys) }).subtracting(hasWindows) {
                lock.withLock { last[id] = nil }
                await MainActor.run { onPreview?(id, Data()) }
            }
        }
    }

    /// Forget what was sent, so the next round sends everything again (a new connection).
    func reset() {
        lock.withLock { last = [:] }
    }

    private static func snapshot(_ window: SCWindow) async -> Data? {
        let scale = CGFloat(side) / max(window.frame.width, window.frame.height)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6])
    }
}
