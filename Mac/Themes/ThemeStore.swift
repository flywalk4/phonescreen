import CryptoKit
import Foundation
import PhoneScreenKit

/// Theme packages on disk, like `WidgetStore` for widgets: a theme is a folder with `theme.json` (the file alone
/// works too). Installed copies live in `~/Library/Application Support/PhoneScreen/Themes/<id>.json`; a development
/// install is `<id>.link` holding the path of the author's folder or file.
enum ThemeStore {
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

    /// `theme.json` inside a folder, or the file itself.
    static func file(at url: URL) -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue ? url.appendingPathComponent("theme.json") : url
    }

    /// Reads and validates a theme (folder or file).
    static func read(_ url: URL) throws -> Theme {
        let file = file(at: url)
        guard let data = try? Data(contentsOf: file) else { throw Failure(description: "No theme.json file") }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Theme {
        guard data.count <= maxBytes else { throw Failure(description: "theme.json is over 64 KB") }
        let theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            throw Failure(description: "theme.json: \(describe(error))")
        }
        try theme.validate()
        guard !theme.id.hasPrefix("builtin.") else { throw Failure(description: "The id can't start with builtin.") }
        return theme
    }

    /// An installed theme and the file it really comes from (the author's, for a development link).
    static func load(installed file: URL) throws -> (theme: Theme, source: URL, development: Bool) {
        switch file.pathExtension {
        case "json":
            return (try read(file), file, false)
        case "link":
            guard let source = linkTarget(file) else { throw Failure(description: "Can't read the development link") }
            return (try read(source), source, true)
        default:
            throw Failure(description: "not a theme")
        }
    }

    /// The author's `theme.json` a development link points to.
    static func linkTarget(_ link: URL) -> URL? {
        guard let path = try? String(contentsOf: link, encoding: .utf8) else { return nil }
        return file(at: URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// Copies a theme in, or links it for development.
    static func install(from url: URL, development: Bool) throws -> Theme {
        let theme = try read(url)
        uninstall(theme.id)
        if development {
            try url.path.write(to: root.appendingPathComponent("\(theme.id).link"), atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.copyItem(at: file(at: url), to: root.appendingPathComponent("\(theme.id).json"))
        }
        return theme
    }

    /// Installs a theme already downloaded and checked (`download`).
    static func install(data: Data) throws -> Theme {
        let theme = try decode(data)
        uninstall(theme.id)
        try data.write(to: root.appendingPathComponent("\(theme.id).json"))
        return theme
    }

    static func uninstall(_ id: String) {
        for ext in ["json", "link"] { try? FileManager.default.removeItem(at: root.appendingPathComponent("\(id).\(ext)")) }
    }

    /// Downloads a catalog entry's `theme.json` and checks it against its SHA-256. Themes are small, so the settings
    /// download every catalog theme up front to show previews; installing then just writes the same bytes.
    static func download(_ entry: WidgetCatalog.Entry, indexURL: URL) async throws -> (theme: Theme, data: Data) {
        guard let expected = entry.files["theme.json"]?.lowercased() else { throw Failure(description: "The catalog has no hash for theme.json") }
        let url = indexURL.deletingLastPathComponent().appendingPathComponent(entry.path, isDirectory: true)
            .appendingPathComponent("theme.json")
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            guard url.scheme == "https" else { throw Failure(description: "The catalog must be served over HTTPS") }
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure(description: "theme.json: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            data = body
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw Failure(description: "theme.json: the hash doesn't match the catalog — the file was changed") }
        let theme = try decode(data)
        guard theme.id == entry.id else { throw Failure(description: "The id in theme.json doesn't match the catalog") }
        return (theme, data)
    }

    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): "no field “\(key.stringValue)”"
        case DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            "an invalid value “\(c.codingPath.map(\.stringValue).joined(separator: "."))”"
        case DecodingError.dataCorrupted(let c):
            c.codingPath.isEmpty ? "not JSON" : "an invalid value “\(c.codingPath.map(\.stringValue).joined(separator: "."))”"
        default: error.localizedDescription
        }
    }
}
