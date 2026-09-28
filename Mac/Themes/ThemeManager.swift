import Foundation
import PhoneScreenKit

/// Which theme the phone shows: the built-in ones plus installed themes (`ThemeStore`). Development installs are
/// re-read when their file changes, so the phone recolours as the author saves.
@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var installed: [Theme] = []
    /// Ids of development installs.
    @Published private(set) var development: Set<String> = []
    /// Development themes whose file doesn't read right now (the last good version stays in use).
    @Published private(set) var errors: [String: String] = [:]
    @Published var selectedID: String = UserDefaults.standard.string(forKey: "themeID") ?? Theme.dark.id {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: "themeID")
            sendCurrent()
        }
    }

    /// The user's adjustments on top of whichever theme is selected (Settings → Themes → Fine-tuning).
    @Published var tweaks: ThemeTweaks = ThemeTweaks.saved() {
        didSet {
            guard tweaks != oldValue else { return }
            tweaks.save()
            sendCurrent()
        }
    }

    /// Sends to the phone (the pool).
    var send: ((Message) -> Void)?

    private var devWatch: Timer?
    private var devSources: [String: (url: URL, modified: Date?)] = [:]

    var all: [Theme] { Theme.builtin + installed }
    /// The selected theme as chosen, before `tweaks`.
    var selected: Theme { all.first { $0.id == selectedID } ?? .dark }
    var current: Theme { tweaks.apply(to: selected) }

    func start() {
        reload()
        devWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDevChanges() }
        }
    }

    func sendCurrent() {
        send?(.theme(current))
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: ThemeStore.root, includingPropertiesForKeys: nil)) ?? []
        var themes: [Theme] = [], dev: Set<String> = [], sources: [String: (url: URL, modified: Date?)] = [:]
        var failures: [String: String] = [:]
        for file in files {
            do {
                let loaded = try ThemeStore.load(installed: file)
                themes.append(loaded.theme)
                if loaded.development {
                    dev.insert(loaded.theme.id)
                    sources[loaded.theme.id] = (loaded.source, ThemeStore.modified(loaded.source))
                }
            } catch {
                // A development file saved mid-edit: keep showing the last good version, report the error.
                guard file.pathExtension == "link", let source = ThemeStore.linkTarget(file) else { continue }
                let id = file.deletingPathExtension().lastPathComponent
                failures[id] = "\(error)"
                dev.insert(id)
                sources[id] = (source, ThemeStore.modified(source))
                if let previous = installed.first(where: { $0.id == id }) { themes.append(previous) }
            }
        }
        let before = current
        installed = themes.sorted { $0.name < $1.name }
        development = dev
        devSources = sources
        errors = failures
        if current != before { sendCurrent() }
    }

    @discardableResult
    func install(from url: URL, development: Bool) throws -> Theme {
        let theme = try ThemeStore.install(from: url, development: development)
        reload()
        return theme
    }

    @discardableResult
    func install(data: Data) throws -> Theme {
        let theme = try ThemeStore.install(data: data)
        reload()
        return theme
    }

    func uninstall(_ id: String) {
        ThemeStore.uninstall(id)
        if selectedID == id { selectedID = Theme.dark.id }
        reload()
    }

    private func checkDevChanges() {
        for (_, source) in devSources where ThemeStore.modified(source.url) != source.modified {
            return reload()
        }
    }
}

/// What the user changed on top of a theme; nil fields keep the theme's own value.
struct ThemeTweaks: Codable, Equatable {
    var accent: String?
    var style: Theme.Style?
    var font: Theme.FontDesign?
    var radius: Double?
    /// A background animation, or "none" for a still background.
    var animation: String?
    var speed: Double?
    var layout = Theme.Layout()

    var isEmpty: Bool { self == ThemeTweaks() }

    func apply(to theme: Theme) -> Theme {
        var t = theme
        if let accent { t.colors.accent = accent }
        if let style { t.style = style }
        if let font { t.font = font }
        if let radius { t.radius = radius }
        if let animation { t.background.animation = animation == "none" ? nil : animation }
        if let speed { t.background.speed = speed }
        var l = t.layout ?? Theme.Layout()
        if let v = layout.gap { l.gap = v }
        if let v = layout.margin { l.margin = v }
        if let v = layout.padding { l.padding = v }
        if let v = layout.dots { l.dots = v }
        if let v = layout.cardOpacity { l.cardOpacity = v }
        if let v = layout.textSize { l.textSize = v }
        if let v = layout.status { l.status = v }
        if let v = layout.shadow { l.shadow = v }
        if let v = layout.autoPage { l.autoPage = v }
        if let v = layout.haptics { l.haptics = v }
        t.layout = l == Theme.Layout() ? nil : l
        return t
    }

    static func saved() -> ThemeTweaks {
        UserDefaults.standard.data(forKey: "themeTweaks").flatMap { try? JSONDecoder().decode(ThemeTweaks.self, from: $0) } ?? ThemeTweaks()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "themeTweaks")
    }
}
