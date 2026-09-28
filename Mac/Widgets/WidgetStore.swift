import CryptoKit
import Foundation
import PhoneScreenKit
import Security

/// An installed JavaScript widget package.
struct InstalledWidget: Identifiable {
    var id: String { manifest.id }
    let manifest: WidgetManifest
    /// Parsed `view.json`: `{"full": node, "medium": node, "small": node}` (at least one size).
    let view: [String: Any]
    let source: String
    /// Parsed `strings.json` (`{"en": {…}, "ru": {…}}`), empty when the widget has none.
    let strings: [String: Any]
    /// Where the files are read from (the installed copy, or the author's folder in development mode).
    let folder: URL
    let isDevelopment: Bool
    let modified: Date
}

/// Widget packages on disk: `~/Library/Application Support/PhoneScreen/Widgets/<id>/`.
/// A development install is a folder holding only `dev-link` (the path of the author's working folder),
/// which is re-read whenever its files change.
enum WidgetStore {
    static let requiredFiles = ["manifest.json", "view.json", "provider.js"]
    /// Copied and downloaded along when present.
    static let optionalFiles = ["strings.json"]
    static let maxFileBytes = 256 * 1024

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PhoneScreen/Widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Reading

    static func installed() -> [InstalledWidget] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? load(installFolder: $0) }.sorted { $0.manifest.name < $1.manifest.name }
    }

    static func load(installFolder: URL) throws -> InstalledWidget {
        let link = installFolder.appendingPathComponent("dev-link")
        if let path = try? String(contentsOf: link, encoding: .utf8) {
            return try read(package: URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines)), development: true)
        }
        return try read(package: installFolder, development: false)
    }

    /// Reads and validates a package folder.
    static func read(package folder: URL, development: Bool = false) throws -> InstalledWidget {
        var files: [String: Data] = [:]
        var modified = Date.distantPast
        for name in requiredFiles {
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { throw Failure(description: "No file \(name)") }
            guard data.count <= maxFileBytes else { throw Failure(description: "\(name) is over 256 KB") }
            files[name] = data
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                modified = max(modified, date)
            }
        }
        let manifest: WidgetManifest
        do {
            manifest = try JSONDecoder().decode(WidgetManifest.self, from: files["manifest.json"]!)
        } catch {
            throw Failure(description: "manifest.json: \(error.localizedDescription)")
        }
        try manifest.validate()
        guard let view = try? JSONSerialization.jsonObject(with: files["view.json"]!) as? [String: Any],
              !Set(view.keys).isDisjoint(with: ["full", "medium", "small"]) else {
            throw Failure(description: "view.json must be an object with the keys full / medium / small")
        }
        guard let source = String(data: files["provider.js"]!, encoding: .utf8) else {
            throw Failure(description: "provider.js isn't UTF-8")
        }
        var strings: [String: Any] = [:]
        let stringsURL = folder.appendingPathComponent("strings.json")
        if let data = try? Data(contentsOf: stringsURL) {
            guard data.count <= maxFileBytes, let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure(description: "strings.json: an object {\"en\": {…}, \"ru\": {…}}, up to 256 KB")
            }
            strings = parsed
            if let date = try? stringsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                modified = max(modified, date)
            }
        }
        return InstalledWidget(manifest: manifest, view: view, source: source, strings: strings, folder: folder,
                               isDevelopment: development, modified: modified)
    }

    // MARK: - Installing

    /// Copies a package folder in (or links it, for development).
    @discardableResult
    static func install(folder: URL, development: Bool) throws -> InstalledWidget {
        let widget = try read(package: folder)
        let target = root.appendingPathComponent(widget.id, isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        if development {
            try folder.path.write(to: target.appendingPathComponent("dev-link"), atomically: true, encoding: .utf8)
        } else {
            for name in requiredFiles {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
            for name in optionalFiles where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                try FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: target.appendingPathComponent(name))
            }
        }
        return try load(installFolder: target)
    }

    /// Downloads a catalog entry into a temporary folder and checks every file against its SHA-256.
    /// Returns the folder (not yet installed): the caller shows the permissions first.
    static func download(_ entry: WidgetCatalog.Entry, indexURL: URL) async throws -> URL {
        let base = indexURL.deletingLastPathComponent().appendingPathComponent(entry.path, isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("phonescreen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for name in requiredFiles + optionalFiles.filter({ entry.files[$0] != nil }) {
            guard let expected = entry.files[name]?.lowercased() else { throw Failure(description: "The catalog has no hash for \(name)") }
            let data = try await fetch(base.appendingPathComponent(name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw Failure(description: "\(name): the hash doesn't match the catalog — the file was changed") }
            try data.write(to: temp.appendingPathComponent(name))
        }
        let widget = try read(package: temp)
        guard widget.id == entry.id else { throw Failure(description: "The id in manifest.json doesn't match the catalog") }
        return temp
    }

    static func loadCatalog(_ url: URL) async throws -> WidgetCatalog {
        try JSONDecoder().decode(WidgetCatalog.self, from: try await fetch(url))
    }

    private static func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        guard url.scheme == "https" else { throw Failure(description: "The catalog must be served over HTTPS") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(description: "\(url.lastPathComponent): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    static func uninstall(_ id: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
        WidgetSecrets.removeAll(widget: id)
        UserDefaults.standard.removeObject(forKey: "widgetStorage.\(id)")
        UserDefaults.standard.removeObject(forKey: "widgetSettings.\(id)")
    }
}

/// Widget secrets (API keys…) in the login Keychain, one item per widget + key.
enum WidgetSecrets {
    private static func service(_ widget: String) -> String { "com.flywalk4.phonescreen.widget.\(widget)" }

    static func get(widget: String, key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(widget),
                                    kSecAttrAccount as String: key, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(widget: String, key: String, value: String?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(widget),
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removeAll(widget: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service(widget)] as CFDictionary)
    }
}
