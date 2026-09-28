import Foundation

/// `manifest.json` of a JavaScript widget package.
public struct WidgetManifest: Codable, Equatable, Sendable {
    public struct Secret: Codable, Equatable, Sendable {
        /// Name used in `secrets.get(key)`.
        public var key: String
        /// Shown to the user in Settings (e.g. "Admin API key").
        public var title: String

        public init(key: String, title: String) {
            self.key = key
            self.title = title
        }
    }

    /// A user setting. Values reach the script as strings (`ctx.settings.<key>`) whatever the control:
    /// `choice` → the option's value, `toggle` → "true" / "false", `number` → the number as text.
    public struct Setting: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case text, choice, toggle, number
        }

        /// One entry of a `choice`: `"value"` or `{"value": "…", "title": "…"}` in JSON.
        public struct Option: Codable, Equatable, Sendable {
            public var value: String
            public var title: String?

            public init(value: String, title: String? = nil) {
                self.value = value
                self.title = title
            }

            public var label: String { title ?? value }

            private enum CodingKeys: String, CodingKey { case value, title }

            public init(from decoder: Decoder) throws {
                if let plain = try? decoder.singleValueContainer().decode(String.self) {
                    self.init(value: plain)
                } else {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    self.init(value: try c.decode(String.self, forKey: .value), title: try c.decodeIfPresent(String.self, forKey: .title))
                }
            }

            public func encode(to encoder: Encoder) throws {
                if let title {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(value, forKey: .value)
                    try c.encode(title, forKey: .title)
                } else {
                    var c = encoder.singleValueContainer()
                    try c.encode(value)
                }
            }
        }

        public var key: String
        public var title: String
        public var `default`: String?
        /// Control in Settings; `text` when absent.
        public var type: Kind?
        /// Small grey line under the control (format, examples).
        public var hint: String?
        /// For `choice`.
        public var options: [Option]?
        /// For `number`: a slider when both `min` and `max` are set, otherwise a stepper field.
        public var min: Double?
        public var max: Double?
        public var step: Double?
        /// Unit after a `number` ("min", "%").
        public var unit: String?

        public init(key: String, title: String, default value: String? = nil, type: Kind? = nil, hint: String? = nil,
                    options: [Option]? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil, unit: String? = nil) {
            self.key = key
            self.title = title
            self.default = value
            self.type = type
            self.hint = hint
            self.options = options
            self.min = min
            self.max = max
            self.step = step
            self.unit = unit
        }

        public var kind: Kind { type ?? .text }

        /// How a toggle reads a stored string (older widgets used yes / no).
        public static func isOn(_ value: String) -> Bool {
            ["true", "yes", "1", "on", "да"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    public struct Permissions: Codable, Equatable, Sendable {
        /// Hosts `fetch` may reach over HTTPS (subdomains included). Nothing else is reachable.
        public var network: [String]?
        /// Secrets the user stores in the Mac's Keychain for this widget.
        public var secrets: [Secret]?
        /// Read-only access to these paths in the user's home: `~/dir/` (a folder and everything in it) or `~/file`.
        public var files: [String]?

        public init(network: [String]? = nil, secrets: [Secret]? = nil, files: [String]? = nil) {
            self.network = network
            self.secrets = secrets
            self.files = files
        }
    }

    /// Reverse-DNS, lowercase: `com.author.widget`.
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var description: String?
    /// SF Symbol for menus and headers.
    public var symbol: String?
    /// Seconds between `refresh()` calls (at least 30; default 300).
    public var refresh: Double?
    public var permissions: Permissions?
    public var settings: [Setting]?

    public init(id: String, name: String, version: String, author: String, description: String? = nil,
                symbol: String? = nil, refresh: Double? = nil, permissions: Permissions? = nil, settings: [Setting]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.symbol = symbol
        self.refresh = refresh
        self.permissions = permissions
        self.settings = settings
    }

    /// At least 30 s for widgets that use the network (be kind to APIs); local-only widgets may poll every 5 s.
    public var refreshInterval: Double {
        let floor: Double = (permissions?.network ?? []).isEmpty ? 5 : 30
        return max(floor, refresh ?? 300)
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public func validate() throws {
        let idPattern = #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#
        guard id.range(of: idPattern, options: .regularExpression) != nil, id.count <= 100 else {
            throw Invalid(description: "id must look like com.author.widget (lowercase letters, digits, dots)")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 40 else {
            throw Invalid(description: "name is required, up to 40 characters")
        }
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw Invalid(description: "version must look like 1.2.3")
        }
        guard !author.isEmpty else { throw Invalid(description: "author is required") }
        for host in permissions?.network ?? [] {
            guard host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
                throw Invalid(description: "permissions.network: “\(host)” — a domain only (api.example.com), no scheme, path or wildcards")
            }
        }
        for path in permissions?.files ?? [] {
            guard path.hasPrefix("~/"), path.count > 2, !path.split(separator: "/").contains(".."),
                  !path.contains("*") else {
                throw Invalid(description: "permissions.files: “\(path)” — a path inside the home folder like ~/folder/ or ~/folder/file, no .. or *")
            }
        }
        let secretKeys = (permissions?.secrets ?? []).map(\.key)
        let settingKeys = (settings ?? []).map(\.key)
        guard Set(secretKeys).count == secretKeys.count, Set(settingKeys).count == settingKeys.count else {
            throw Invalid(description: "secrets and settings keys must not repeat")
        }
        for s in settings ?? [] {
            switch s.kind {
            case .choice:
                guard let options = s.options, !options.isEmpty else {
                    throw Invalid(description: "settings.\(s.key): choice needs non-empty options")
                }
            case .number:
                if let min = s.min, let max = s.max, min >= max {
                    throw Invalid(description: "settings.\(s.key): min must be less than max")
                }
            case .text, .toggle:
                break
            }
        }
    }

    /// Whether a path (as the script wrote it, `~/…`) is inside a declared `files` entry.
    /// `home` is the real home folder; callers must also check the resolved path (symlinks) with `allowsResolved`.
    public func allowsFile(_ path: String) -> Bool {
        guard path.hasPrefix("~/"), !path.split(separator: "/").contains("..") else { return false }
        return (permissions?.files ?? []).contains { entry in
            entry.hasSuffix("/") ? path.hasPrefix(entry) : path == entry
        }
    }

    /// The same check on an absolute, symlink-resolved path.
    public func allowsResolved(_ absolute: String, home: String) -> Bool {
        let h = home.hasSuffix("/") ? String(home.dropLast()) : home
        return (permissions?.files ?? []).contains { entry in
            let full = h + "/" + entry.dropFirst(2)
            return entry.hasSuffix("/") ? absolute.hasPrefix(full) : absolute == full
        }
    }

    /// Whether `fetch` may request this URL: HTTPS to a declared host or its subdomain.
    public func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return (permissions?.network ?? []).contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// `catalog/index.json`: what the GitHub catalog offers.
public struct WidgetCatalog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var version: String
        public var author: String
        public var description: String?
        public var symbol: String?
        /// Folder of the package, relative to the index.
        public var path: String
        /// SHA-256 (hex) of each file of the package, checked on install.
        public var files: [String: String]
        /// Name and description per language (`{"en": {"name": …, "description": …}}`), from its strings.json.
        public var localized: [String: [String: String]]?

        /// Name and description in `language` (falling back to English, then the entry's own).
        public func text(in language: String) -> (name: String, description: String?) {
            let table = localized?[language] ?? localized?["en"]
            return (table?["name"] ?? name, table?["description"] ?? description)
        }

        public init(id: String, name: String, version: String, author: String, description: String?,
                    symbol: String?, path: String, files: [String: String]) {
            self.id = id
            self.name = name
            self.version = version
            self.author = author
            self.description = description
            self.symbol = symbol
            self.path = path
            self.files = files
        }
    }

    public var widgets: [Entry]
    /// Themes: `path` is the theme's folder, `files` holds the hash of its `theme.json`. Absent in older indexes.
    public var themes: [Entry]?

    public init(widgets: [Entry], themes: [Entry]? = nil) {
        self.widgets = widgets
        self.themes = themes
    }
}
