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

    /// Sends to the phone (the pool).
    var send: ((Message) -> Void)?

    private var devWatch: Timer?
    private var devSources: [String: (url: URL, modified: Date?)] = [:]

    var all: [Theme] { Theme.builtin + installed }
    var current: Theme { all.first { $0.id == selectedID } ?? .dark }

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
