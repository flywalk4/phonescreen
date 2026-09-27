import Foundation

/// How the whole phone looks: page background, cards, text, accent, font — for built-in and JavaScript
/// widgets alike. A theme is one `theme.json`; the Mac keeps the chosen one and sends it to the phone.
public struct Theme: Codable, Equatable, Sendable, Identifiable {
    /// How cards (and, for JavaScript widgets, progress bars, gauges and charts) are drawn.
    public enum Style: String, Codable, Sendable, CaseIterable {
        /// Filled rounded cards.
        case flat
        /// Liquid Glass (iOS 26; frosted material on older systems) over the background.
        case glass
        /// Everything as text: `+--+` frames, `[####....]` bars, `*` charts, monospaced type.
        case ascii
    }

    public enum Appearance: String, Codable, Sendable, CaseIterable {
        case dark, light
    }

    public enum FontDesign: String, Codable, Sendable, CaseIterable {
        case system, rounded, monospaced, serif
    }

    /// One colour, or 2–4 for a linear gradient (`angle` in degrees, 0 = top to bottom).
    public struct Background: Codable, Equatable, Sendable {
        public var colors: [String]
        public var angle: Double?

        public init(colors: [String], angle: Double? = nil) {
            self.colors = colors
            self.angle = angle
        }
    }

    /// Colours as `#RRGGBB` or `#RRGGBBAA`.
    public struct Colors: Codable, Equatable, Sendable {
        public var text: String
        public var secondary: String
        public var accent: String
        /// Card fill (flat and ascii) or glass tint.
        public var card: String?
        /// Card outline (and the `+--+` frame in ascii).
        public var border: String?
        /// Replacements for colour names widgets use: `{"green": "#39FF14", "secondary": "#1F8F3A"}`.
        public var palette: [String: String]?

        public init(text: String, secondary: String, accent: String, card: String? = nil, border: String? = nil,
                    palette: [String: String]? = nil) {
            self.text = text
            self.secondary = secondary
            self.accent = accent
            self.card = card
            self.border = border
            self.palette = palette
        }
    }

    /// Reverse-DNS, lowercase: `com.author.theme`.
    public var id: String
    public var name: String
    public var version: String
    public var author: String
    public var description: String?
    public var style: Style
    public var appearance: Appearance
    public var font: FontDesign
    /// Card corner radius, 0…40 pt.
    public var radius: Double
    public var background: Background
    public var colors: Colors

    public init(id: String, name: String, version: String = "1.0.0", author: String, description: String? = nil,
                style: Style, appearance: Appearance, font: FontDesign, radius: Double,
                background: Background, colors: Colors) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.style = style
        self.appearance = appearance
        self.font = font
        self.radius = radius
        self.background = background
        self.colors = colors
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public func validate() throws {
        guard id.range(of: #"^[a-z0-9]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil else {
            throw Invalid(description: "id: «\(id)» — обратный домен строчными буквами, например com.author.theme")
        }
        guard !name.isEmpty, name.count <= 40 else { throw Invalid(description: "name: от 1 до 40 символов") }
        guard (0...40).contains(radius) else { throw Invalid(description: "radius: от 0 до 40") }
        guard (1...4).contains(background.colors.count) else {
            throw Invalid(description: "background.colors: от 1 до 4 цветов")
        }
        var all = background.colors.map { ("background.colors", $0) }
        all += [("colors.text", colors.text), ("colors.secondary", colors.secondary), ("colors.accent", colors.accent)]
        if let c = colors.card { all.append(("colors.card", c)) }
        if let c = colors.border { all.append(("colors.border", c)) }
        for (key, value) in colors.palette ?? [:] { all.append(("colors.palette.\(key)", value)) }
        for (key, value) in all where RGBA(hex: value) == nil {
            throw Invalid(description: "\(key): «\(value)» — цвет вида #RRGGBB или #RRGGBBAA")
        }
    }
}

/// A colour parsed from `#RRGGBB` / `#RRGGBBAA`, components 0…1.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#"), s.count == 7 || s.count == 9,
              s.dropFirst().allSatisfy(\.isHexDigit), let v = UInt64(s.dropFirst(), radix: 16) else { return nil }
        let rgba = s.count == 7 ? (v << 8) | 0xFF : v
        self.init(r: Double((rgba >> 24) & 0xFF) / 255, g: Double((rgba >> 16) & 0xFF) / 255,
                  b: Double((rgba >> 8) & 0xFF) / 255, a: Double(rgba & 0xFF) / 255)
    }
}

// MARK: - Built-in themes

public extension Theme {
    static let dark = Theme(
        id: "builtin.dark", name: "Тёмная", author: "PhoneScreen",
        description: "Чёрный фон и тёмные карточки — как раньше.",
        style: .flat, appearance: .dark, font: .system, radius: 22,
        background: .init(colors: ["#000000"]),
        colors: .init(text: "#FFFFFF", secondary: "#98989F", accent: "#0A84FF", card: "#FFFFFF12"))

    static let light = Theme(
        id: "builtin.light", name: "Светлая", author: "PhoneScreen",
        description: "Светло-серый фон, белые карточки, тёмный текст.",
        style: .flat, appearance: .light, font: .system, radius: 22,
        background: .init(colors: ["#F2F2F7"]),
        colors: .init(text: "#000000", secondary: "#6C6C70", accent: "#007AFF", card: "#FFFFFF", border: "#0000000F"))

    static let glass = Theme(
        id: "builtin.glass", name: "Liquid Glass", author: "PhoneScreen",
        description: "Стеклянные карточки поверх яркого градиента, как в iOS 26.",
        style: .glass, appearance: .dark, font: .rounded, radius: 28,
        background: .init(colors: ["#1B2A6B", "#6A2C8F", "#0E7C86"], angle: 35),
        colors: .init(text: "#FFFFFF", secondary: "#FFFFFFB3", accent: "#7FD4FF", card: "#FFFFFF14", border: "#FFFFFF33"))

    static let ascii = Theme(
        id: "builtin.ascii", name: "ASCII", author: "PhoneScreen",
        description: "Всё как в терминале: рамки из +-|, полосы [####....], моноширинный зелёный текст.",
        style: .ascii, appearance: .dark, font: .monospaced, radius: 0,
        background: .init(colors: ["#050805"]),
        colors: .init(text: "#39FF14", secondary: "#1FA30C", accent: "#39FF14", border: "#1FA30C",
                      palette: ["primary": "#39FF14", "secondary": "#1FA30C", "tertiary": "#146B08",
                                "accent": "#39FF14", "green": "#39FF14", "mint": "#39FF14", "teal": "#39FF14",
                                "orange": "#FFB000", "yellow": "#FFE066", "red": "#FF3B30",
                                "blue": "#39FF14", "cyan": "#39FF14", "indigo": "#39FF14", "purple": "#39FF14",
                                "pink": "#FFB000", "white": "#39FF14", "gray": "#1FA30C"]))

    static let builtin: [Theme] = [.dark, .light, .glass, .ascii]
}
