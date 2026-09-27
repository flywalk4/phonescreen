import Foundation

/// A resolved piece of a JavaScript widget's UI, as the phone draws it (natively, in SwiftUI).
/// Built on the Mac from the widget's `view.json` template and its latest data; the phone never runs widget code.
public indirect enum WidgetNode: Codable, Equatable, Sendable {
    case vstack(spacing: Double?, align: String?, children: [WidgetNode])
    case hstack(spacing: Double?, align: String?, children: [WidgetNode])
    /// `style`: largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2.
    /// `font` overrides size / weight / design (big numbers, rounded or monospaced digits).
    case text(String, style: String?, color: String?, lines: Int?, align: String?, font: WidgetFont? = nil)
    /// An SF Symbol.
    case symbol(String, color: String?, size: Double?)
    /// Ring, value 0…1.
    case gauge(value: Double, label: String?, color: String?)
    /// Bar, value 0…1.
    case progress(value: Double, color: String?)
    /// Chart of the values. `style`: `line` (default), `area` (line with a gradient under it), `bar`.
    case chart(values: [Double], color: String?, style: String? = nil, height: Double? = nil)
    /// Calls the widget's `action(name)` on the Mac. The name may contain bindings: `"tap:{{index}}"`.
    case button(title: String, symbol: String?, action: String)
    /// Pixel-art animation: each frame is rows of characters, each character a palette colour
    /// (`.` or space = transparent); the phone plays the frames at `fps`.
    case sprite(frames: [[String]], palette: [String: String], fps: Double?)
    case spacer
    case divider
    /// A panel: children stacked vertically on a rounded surface. Without `background` the surface follows the
    /// theme (a subtle fill, glass, or an ASCII frame); with it, that colour at `opacity` (default 1).
    /// It takes the full width unless `fit` (then it hugs its content — pills, badges). With `action` the whole
    /// panel is a button (game cells, tappable tiles); `aspect` (width / height, e.g. 1) keeps its shape, content centred.
    case box(spacing: Double?, align: String?, padding: Double?, background: String?, opacity: Double?,
             radius: Double?, fit: Bool?, action: String? = nil, aspect: Double? = nil, children: [WidgetNode])
    /// Children laid out in `columns` equal columns, row by row.
    case grid(columns: Int, spacing: Double?, children: [WidgetNode])
    /// Children on top of each other (the first at the back), aligned by `align` (`center`, `top`, `bottomLeading`…).
    case layers(align: String?, children: [WidgetNode])
    /// An animated scene drawn by the phone (`kind`: aurora, stars, matrix, waves, bokeh, lava, snow, rain, gradient), filling its space.
    /// `colors` — the background (1–4), `tints` — the moving parts; the theme's colours when absent.
    case scene(kind: String, colors: [String]?, tints: [String]?, speed: Double?)
}

/// Text font overrides. `weight`: ultraLight, thin, light, regular, medium, semibold, bold, heavy, black.
/// `design`: default, rounded, monospaced, serif (unset — the theme's).
public struct WidgetFont: Codable, Equatable, Sendable {
    public var size: Double?
    public var weight: String?
    public var design: String?

    public init(size: Double? = nil, weight: String? = nil, design: String? = nil) {
        self.size = size
        self.weight = weight
        self.design = design
    }
}

/// Everything the phone needs to show one installed JavaScript widget.
public struct CustomWidgetState: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbol: String
    /// Resolved UI per size (`full`, `medium`, `small`); a missing size falls back to the next bigger one.
    public var views: [WidgetSize: WidgetNode]
    /// Shown instead of the UI when the widget failed (script error, network, missing secret…).
    public var error: String?
    public var updated: Date

    public init(id: String, name: String, symbol: String, views: [WidgetSize: WidgetNode], error: String?, updated: Date) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.views = views
        self.error = error
        self.updated = updated
    }

    public func view(for size: WidgetSize) -> WidgetNode? {
        switch size {
        case .full: views[.full] ?? views[.medium] ?? views[.small]
        case .medium: views[.medium] ?? views[.full] ?? views[.small]
        case .small: views[.small] ?? views[.medium] ?? views[.full]
        }
    }
}

extension WidgetSize: CodingKeyRepresentable {}

/// Turns a `view.json` template plus the data returned by `refresh()` into `WidgetNode`s.
///
/// Template nodes are JSON objects with a `"type"`; any string may contain `{{path}}` bindings
/// (`"{{rate}}"` alone keeps the value's type — number, array — otherwise it's interpolated as text).
/// Extras: `"if": "{{path}}"` drops the node when the value is falsy; `{"type": "list", "items": "{{rows}}",
/// "template": {...}}` repeats a template with `item` / `index` bound (in `columns` columns if set). Unknown types are skipped, so newer
/// templates degrade gracefully on older apps.
public enum WidgetTemplate {
    public struct Error: Swift.Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public static let maxNodes = 500
    public static let maxText = 2_000

    public static func resolve(_ template: Any, data: Any) throws -> WidgetNode {
        var budget = maxNodes
        guard let node = try node(template, scope: ["$": data], budget: &budget) else {
            throw Error(description: "Шаблон пустой")
        }
        return node
    }

    // MARK: - Nodes

    private static func node(_ template: Any, scope: [String: Any], budget: inout Int) throws -> WidgetNode? {
        guard let t = template as? [String: Any] else { throw Error(description: "Узел шаблона должен быть объектом") }
        if let condition = t["if"], !truthy(value(condition, scope)) { return nil }
        budget -= 1
        guard budget >= 0 else { throw Error(description: "Слишком много элементов (больше \(maxNodes))") }

        func str(_ key: String) -> String? { t[key].map { text(value($0, scope)) } }
        func num(_ key: String) -> Double? { t[key].flatMap { number(value($0, scope)) } }
        func children() throws -> [WidgetNode] {
            try ((t["children"] as? [Any]) ?? []).compactMap { try node($0, scope: scope, budget: &budget) }
        }

        switch t["type"] as? String {
        case "vstack":
            return .vstack(spacing: num("spacing"), align: str("align"), children: try children())
        case "hstack":
            return .hstack(spacing: num("spacing"), align: str("align"), children: try children())
        case "text":
            let size = num("size").map { min(max($0, 6), 160) }
            let font = size != nil || t["weight"] != nil || t["design"] != nil
                ? WidgetFont(size: size, weight: str("weight"), design: str("design")) : nil
            return .text(String((str("text") ?? "").prefix(maxText)), style: str("style"), color: str("color"),
                         lines: num("lines").map { Int($0) }, align: str("align"), font: font)
        case "symbol":
            return .symbol(str("name") ?? "questionmark", color: str("color"), size: num("size"))
        case "gauge":
            return .gauge(value: clamp01(num("value")), label: str("label"), color: str("color"))
        case "progress":
            return .progress(value: clamp01(num("value")), color: str("color"))
        case "chart":
            let values = (t["values"].map { value($0, scope) } as? [Any] ?? []).compactMap(number)
            return .chart(values: Array(values.suffix(200)), color: str("color"), style: str("style"),
                          height: num("height").map { min(max($0, 20), 400) })
        case "button":
            guard let action = str("action"), !action.isEmpty else { throw Error(description: "У кнопки нет action") }
            return .button(title: str("title") ?? "", symbol: str("symbol"), action: action)
        case "sprite":
            let rawFrames = t["frames"].map { value($0, scope) } as? [Any] ?? []
            let frames = rawFrames.prefix(16).compactMap { ($0 as? [Any])?.prefix(48).map { String(text($0).prefix(48)) } }
            guard !frames.isEmpty else { throw Error(description: "У sprite нет frames") }
            let rawPalette = t["palette"].map { value($0, scope) } as? [String: Any] ?? [:]
            let palette = rawPalette.reduce(into: [String: String]()) { $0[String($1.key.prefix(1))] = text($1.value) }
            return .sprite(frames: frames, palette: palette, fps: num("fps"))
        case "box":
            return .box(spacing: num("spacing"), align: str("align"), padding: num("padding"),
                        background: str("background"), opacity: num("opacity").map { min(max($0, 0), 1) },
                        radius: num("radius"), fit: t["fit"].map { truthy(value($0, scope)) },
                        action: str("action").flatMap { $0.isEmpty ? nil : String($0.prefix(200)) },
                        aspect: num("aspect").map { min(max($0, 0.2), 5) }, children: try children())
        case "grid":
            return .grid(columns: columns(num("columns")), spacing: num("spacing"), children: try children())
        case "layers":
            return .layers(align: str("align"), children: try children())
        case "scene":
            let list = { (key: String) -> [String]? in
                (t[key].map { value($0, scope) } as? [Any]).map { $0.prefix(6).map { text(value($0, scope)) } }
            }
            return .scene(kind: str("kind") ?? "aurora", colors: list("colors"), tints: list("tints"),
                          speed: num("speed").map { min(max($0, 0.1), 5) })
        case "spacer":
            return .spacer
        case "divider":
            return .divider
        case "list":
            let items = t["items"].map { value($0, scope) } as? [Any] ?? []
            guard let itemTemplate = t["template"] else { throw Error(description: "У списка нет template") }
            var rows: [WidgetNode] = []
            for (i, item) in items.enumerated() {
                var inner = scope
                inner["item"] = item
                inner["index"] = i
                if let row = try node(itemTemplate, scope: inner, budget: &budget) { rows.append(row) }
            }
            if let n = num("columns"), n > 1 {
                return .grid(columns: columns(n), spacing: num("spacing"), children: rows)
            }
            return .vstack(spacing: num("spacing") ?? 6, align: str("align") ?? "leading", children: rows)
        default:
            return nil // unknown or missing type: skip
        }
    }

    // MARK: - Bindings

    private static let whole = try! NSRegularExpression(pattern: #"^\s*\{\{\s*([^}]+?)\s*\}\}\s*$"#)
    private static let inline = try! NSRegularExpression(pattern: #"\{\{\s*([^}]+?)\s*\}\}"#)

    /// A template value with its bindings applied.
    static func value(_ raw: Any, _ scope: [String: Any]) -> Any? {
        guard let s = raw as? String else { return raw }
        let ns = s as NSString
        if let m = whole.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            return lookup(ns.substring(with: m.range(at: 1)), scope)
        }
        var result = ""
        var last = 0
        for m in inline.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += text(lookup(ns.substring(with: m.range(at: 1)), scope))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// `a.b.0.c`; `item` / `index` inside lists, everything else from the data.
    static func lookup(_ path: String, _ scope: [String: Any]) -> Any? {
        var parts = path.split(separator: ".").map(String.init)
        guard let first = parts.first else { return nil }
        var current: Any?
        if first == "item" || first == "index" {
            current = scope[first]
            parts.removeFirst()
        } else {
            current = scope["$"]
        }
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let array = current as? [Any], let i = Int(part), array.indices.contains(i) {
                current = array[i]
            } else {
                return nil
            }
        }
        return current
    }

    static func text(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "да" : "нет" }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let d as Double: return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case let i as Int: return String(i)
        case let b as Bool: return b ? "да" : "нет"
        default: return String(describing: v!)
        }
    }

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return false
        case let n as NSNumber: return n.doubleValue != 0
        case let b as Bool: return b
        case let s as String: return !s.isEmpty && s != "false" && s != "0"
        case let a as [Any]: return !a.isEmpty
        default: return true
        }
    }

    private static func clamp01(_ v: Double?) -> Double { min(max(v ?? 0, 0), 1) }
    private static func columns(_ v: Double?) -> Int { min(max(Int(v ?? 2), 1), 12) }
}
