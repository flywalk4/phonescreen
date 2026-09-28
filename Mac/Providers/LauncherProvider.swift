import AppKit
import QwoviKit

/// What the phone can launch on the Mac: Dock apps (with their real icons), the user's Shortcuts,
/// and a few system actions. Only ids offered here are ever executed.
final class LauncherProvider: @unchecked Sendable {
    /// Called on the main thread.
    var onItems: (@MainActor ([LauncherItem]) -> Void)?

    private let queue = DispatchQueue(label: "qwovi.launcher", qos: .utility)
    private let script = AppleScriptRunner()
    private var items: [LauncherItem] = []

    private static let systemActions: [LauncherItem] = [
        LauncherItem(id: "sys:lock", title: String(localized: "Lock Screen"), kind: .system, symbol: "lock.fill"),
        LauncherItem(id: "sys:displaySleep", title: String(localized: "Turn Off Display"), kind: .system, symbol: "display"),
        LauncherItem(id: "sys:darkMode", title: String(localized: "Dark Mode"), kind: .system, symbol: "circle.lefthalf.filled"),
        LauncherItem(id: "sys:mute", title: String(localized: "Sound On/Off"), kind: .system, symbol: "speaker.slash.fill"),
        LauncherItem(id: "sys:screenshot", title: String(localized: "Screenshot"), kind: .system, symbol: "camera.viewfinder"),
        LauncherItem(id: "sys:missionControl", title: "Mission Control", kind: .system, symbol: "rectangle.3.group"),
    ]

    func refresh() {
        queue.async { [self] in
            items = Self.systemActions + Self.dockApps() + Self.shortcuts()
            let snapshot = items
            DispatchQueue.main.async { [onItems] in MainActor.assumeIsolated { onItems?(snapshot) } }
        }
    }

    func run(_ id: String) {
        queue.async { [self] in
            guard items.contains(where: { $0.id == id }) else {
                AppModel.log.error("launcher: refused unknown id \(id, privacy: .public)")
                return
            }
            let (kind, value) = Self.split(id)
            switch kind {
            case "app":
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: value), configuration: .init())
            case "shortcut":
                Self.exec("/usr/bin/shortcuts", ["run", value])
            case "sys":
                runSystem(value)
            default:
                break
            }
        }
    }

    private func runSystem(_ action: String) {
        switch action {
        case "lock":
            // ⌃⌘Q — the system "Lock Screen" shortcut.
            script.run("tell application \"System Events\" to keystroke \"q\" using {control down, command down}")
        case "displaySleep":
            Self.exec("/usr/bin/pmset", ["displaysleepnow"])
        case "darkMode":
            script.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case "mute":
            script.run("set volume output muted (not (output muted of (get volume settings)))")
        case "screenshot":
            Self.exec("/usr/bin/open", ["-b", "com.apple.screenshot.launcher"])
        case "missionControl":
            Self.exec("/usr/bin/open", ["-b", "com.apple.exposelauncher"])
        default:
            break
        }
    }

    // MARK: - Sources

    /// Apps pinned in the Dock, in Dock order.
    private static func dockApps() -> [LauncherItem] {
        guard let tiles = UserDefaults(suiteName: "com.apple.dock")?.array(forKey: "persistent-apps") as? [[String: Any]]
        else { return [] }
        return tiles.compactMap { tile -> LauncherItem? in
            guard let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let urlString = file["_CFURLString"] as? String,
                  let url = URL(string: urlString) ?? URL(fileURLWithPath: urlString) as URL?,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let name = (data["file-label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            return LauncherItem(id: "app:\(url.path)", title: name, kind: .app, icon: icon(for: url.path))
        }
    }

    /// The user's shortcuts from the Shortcuts app.
    private static func shortcuts() -> [LauncherItem] {
        let output = exec("/usr/bin/shortcuts", ["list"]) ?? ""
        return output.split(separator: "\n").prefix(30).map { name in
            LauncherItem(id: "shortcut:\(name)", title: String(name), kind: .shortcut, symbol: "square.stack.3d.up.fill")
        }
    }

    private static func icon(for path: String, side: CGFloat = 96) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func split(_ id: String) -> (String, String) {
        guard let colon = id.firstIndex(of: ":") else { return (id, "") }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }

    @discardableResult
    private static func exec(_ tool: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
