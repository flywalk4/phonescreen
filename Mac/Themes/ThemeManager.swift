import CryptoKit
import Foundation
import PhoneScreenKit

/// Themes: the built-in ones plus installed `theme.json` files in
/// `~/Library/Application Support/PhoneScreen/Themes/<id>.json`. A development install is `<id>.link` holding the
/// path of the author's file; it is re-read when the file changes, so the phone recolours as you save.
@MainActor
final class ThemeManager: ObservableObject {
    @Published private(set) var installed: [Theme] = []
    @Published private(set) var linked: Set<String> = []
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
    private var devModified: [String: Date] = [:]

    var all: [Theme] { Theme.builtin + installed }
    var current: Theme { all.first { $0.id == selectedID } ?? .dark }

    static let maxBytes = 64 * 1024

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PhoneScreen/Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        var themes: [Theme] = [], links: Set<String> = []
        for file in files {
            guard let loaded = try? Self.load(file) else { continue }
            let (theme, source) = loaded
            themes.append(theme)
            if source != file { links.insert(theme.id); devModified[theme.id] = Self.modified(source) }
        }
        let before = current
        installed = themes.sorted { $0.name < $1.name }
        linked = links
        if current != before { sendCurrent() }
    }

    /// Reads and validates a theme file.
    static func read(_ url: URL) throws -> Theme {
        guard let data = try? Data(contentsOf: url) else { throw Failure(description: "Не удалось прочитать \(url.lastPathComponent)") }
        guard data.count <= maxBytes else { throw Failure(description: "theme.json больше 64 КБ") }
        let theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            throw Failure(description: "theme.json: \(Self.describe(error))")
        }
        try theme.validate()
        guard !theme.id.hasPrefix("builtin.") else { throw Failure(description: "id не может начинаться с builtin.") }
        return theme
    }

    /// Copies a theme in, or links it for development.
    @discardableResult
    func install(file: URL, link: Bool) throws -> Theme {
        let theme = try Self.read(file)
        uninstallFiles(theme.id)
        if link {
            try file.path.write(to: Self.root.appendingPathComponent("\(theme.id).link"), atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.copyItem(at: file, to: Self.root.appendingPathComponent("\(theme.id).json"))
        }
        reload()
        return theme
    }

    /// Downloads a catalog entry (SHA-256 checked) and installs it.
    @discardableResult
    func install(_ entry: WidgetCatalog.Entry, indexURL: URL) async throws -> Theme {
        guard let expected = entry.files["theme.json"]?.lowercased() else { throw Failure(description: "В каталоге нет хеша theme.json") }
        let url = indexURL.deletingLastPathComponent().appendingPathComponent(entry.path, isDirectory: true)
            .appendingPathComponent("theme.json")
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            guard url.scheme == "https" else { throw Failure(description: "Каталог должен быть по HTTPS") }
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "theme.json: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
            data = body
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(description: "theme.json: хеш не совпадает с каталогом — файл изменён") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("phonescreen-theme-\(UUID().uuidString).json")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let theme = try Self.read(temp)
        guard theme.id == entry.id else { throw Failure(description: "id в theme.json не совпадает с каталогом") }
        return try install(file: temp, link: false)
    }

    func uninstall(_ id: String) {
        uninstallFiles(id)
        if selectedID == id { selectedID = Theme.dark.id }
        reload()
    }

    // MARK: - Private

    private func uninstallFiles(_ id: String) {
        for ext in ["json", "link"] { try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("\(id).\(ext)")) }
    }

    /// The theme in an installed file and the file it really came from (the author's, for a link).
    private static func load(_ file: URL) throws -> (Theme, URL) {
        switch file.pathExtension {
        case "json": return (try read(file), file)
        case "link":
            let path = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let source = URL(fileURLWithPath: path)
            return (try read(source), source)
        default: throw Failure(description: "не тема")
        }
    }

    private func checkDevChanges() {
        guard !linked.isEmpty else { return }
        for id in linked {
            let link = Self.root.appendingPathComponent("\(id).link")
            guard let path = try? String(contentsOf: link, encoding: .utf8) else { continue }
            let date = Self.modified(URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)))
            if date != devModified[id] { reload(); return }
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "нет поля «\(key.stringValue)»"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            "неверное значение «\(c.codingPath.map(\.stringValue).joined(separator: "."))»"
        case DecodingError.dataCorrupted(let c):
            c.codingPath.isEmpty ? "это не JSON" : "неверное значение «\(c.codingPath.map(\.stringValue).joined(separator: "."))»"
        default: error.localizedDescription
        }
    }
}
