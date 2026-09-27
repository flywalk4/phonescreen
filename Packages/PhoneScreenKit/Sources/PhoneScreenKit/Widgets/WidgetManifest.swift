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

    public struct Setting: Codable, Equatable, Sendable {
        public var key: String
        public var title: String
        public var `default`: String?

        public init(key: String, title: String, default value: String? = nil) {
            self.key = key
            self.title = title
            self.default = value
        }
    }

    public struct Permissions: Codable, Equatable, Sendable {
        /// Hosts `fetch` may reach over HTTPS (subdomains included). Nothing else is reachable.
        public var network: [String]?
        /// Secrets the user stores in the Mac's Keychain for this widget.
        public var secrets: [Secret]?

        public init(network: [String]? = nil, secrets: [Secret]? = nil) {
            self.network = network
            self.secrets = secrets
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

    public var refreshInterval: Double { max(30, refresh ?? 300) }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public func validate() throws {
        let idPattern = #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#
        guard id.range(of: idPattern, options: .regularExpression) != nil, id.count <= 100 else {
            throw Invalid(description: "id должен быть вида com.author.widget (строчные буквы, цифры, точки)")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 40 else {
            throw Invalid(description: "name обязателен, до 40 символов")
        }
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw Invalid(description: "version должен быть вида 1.2.3")
        }
        guard !author.isEmpty else { throw Invalid(description: "author обязателен") }
        for host in permissions?.network ?? [] {
            guard host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
                throw Invalid(description: "permissions.network: «\(host)» — нужен домен (api.example.com), без схемы, пути и масок")
            }
        }
        let secretKeys = (permissions?.secrets ?? []).map(\.key)
        let settingKeys = (settings ?? []).map(\.key)
        guard Set(secretKeys).count == secretKeys.count, Set(settingKeys).count == settingKeys.count else {
            throw Invalid(description: "ключи secrets и settings не должны повторяться")
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

    public init(widgets: [Entry]) {
        self.widgets = widgets
    }
}
