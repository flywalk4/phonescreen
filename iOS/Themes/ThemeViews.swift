import PhoneScreenKit
import SwiftUI

extension EnvironmentValues {
    /// The look chosen on the Mac (see `Theme`).
    @Entry var theme: Theme = .dark
}

extension Color {
    init(hex: String?, fallback: Color) {
        if let hex, let c = RGBA(hex: hex) {
            self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        } else {
            self = fallback
        }
    }
}

extension Theme {
    var text: Color { Color(hex: colors.text, fallback: .primary) }
    var secondaryText: Color { Color(hex: colors.secondary, fallback: .secondary) }
    var accent: Color { Color(hex: colors.accent, fallback: .accentColor) }
    var card: Color { Color(hex: colors.card, fallback: .clear) }
    var border: Color? { colors.border.map { Color(hex: $0, fallback: .clear) } }
    var colorScheme: ColorScheme { appearance == .light ? .light : .dark }

    var fontDesign: Font.Design {
        switch font {
        case .system: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        case .serif: .serif
        }
    }

    /// A widget colour name replaced by the theme (`palette`), if it is.
    /// A system colour as this theme paints it (its `palette` may replace it).
    func named(_ name: String, _ fallback: Color) -> Color { paletteColor(name) ?? fallback }

    /// A name the palette doesn't list falls back to its nearest relative that it does (mint → green, teal → cyan…),
    /// so a theme that recolours "green" also recolours "mint".
    func paletteColor(_ name: String) -> Color? {
        var key = name.lowercased()
        while true {
            if let hex = colors.palette?[key], let c = RGBA(hex: hex) {
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            }
            guard let next = Self.relatives[key] else { return nil }
            key = next
        }
    }

    private static let relatives = ["mint": "green", "teal": "cyan", "cyan": "blue", "indigo": "blue", "pink": "purple",
                                    "brown": "orange", "grey": "gray"]
}

extension View {
    /// Applies a theme to everything below: colour scheme, text colours (`.primary` / `.secondary` resolve to the
    /// theme's), accent and font.
    func themed(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.accent)
            .fontDesign(theme.fontDesign)
            .foregroundStyle(theme.text, theme.secondaryText, theme.secondaryText.opacity(0.6))
    }

    /// The card around a widget on a multi-widget page, drawn in the theme's style.
    func themedCard() -> some View {
        modifier(ThemedCard())
    }

    /// A panel inside a widget (`box`): the given fill, or a surface in the theme's style.
    func widgetBox(fill: Color?, radius: CGFloat?) -> some View {
        modifier(WidgetBox(fill: fill, radius: radius))
    }
}

private struct WidgetBox: ViewModifier {
    let fill: Color?
    let radius: CGFloat?
    @Environment(\.theme) private var theme
    @Environment(\.innerRadius) private var innerRadius

    @ViewBuilder
    func body(content: Content) -> some View {
        let fallback = innerRadius ?? max(0, min(CGFloat(theme.radius) - 6, 18))
        let shape = RoundedRectangle(cornerRadius: theme.radius == 0 ? 0 : (radius ?? fallback), style: .continuous)
        if let fill {
            content.background(shape.fill(fill)).clipShape(shape)
        } else {
            switch theme.style {
            case .flat:
                content.background(shape.fill(theme.text.opacity(0.07))).clipShape(shape)
            case .glass:
                glass(content, shape: shape)
            case .ascii:
                content.padding(2).overlay(AsciiFrame(color: theme.border ?? theme.secondaryText))
            }
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.thinMaterial, in: shape)
        }
        #else
        content.background(.thinMaterial, in: shape)
        #endif
    }
}

/// Page background: a colour or a linear gradient, animated when the theme says so.
struct ThemeBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let colors = theme.background.colors.map { Color(hex: $0, fallback: .black) }
        Group {
            if theme.background.animation == Theme.photoBackground {
                PhotoBackdrop(fallback: colors.first ?? .black)
            } else if let name = theme.background.animation, let kind = SceneView.Kind(rawValue: name) {
                SceneView(kind: kind, base: colors,
                          tints: (theme.background.tints ?? []).map { Color(hex: $0, fallback: theme.accent) },
                          speed: theme.background.speed ?? 1)
            } else if colors.count > 1 {
                let angle = Angle(degrees: theme.background.angle ?? 0)
                // 0° = top → bottom; the gradient line turns clockwise with the angle.
                let dx = sin(angle.radians) / 2, dy = cos(angle.radians) / 2
                LinearGradient(colors: colors, startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                               endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
            } else {
                colors.first ?? .black
            }
        }
        .ignoresSafeArea()
    }
}

/// A Favorites photo behind the pages: blurred and dimmed so cards stay readable; a new one every launch.
private struct PhotoBackdrop: View {
    let fallback: Color
    @StateObject private var library = PhotoLibrary(slideshow: false)
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                fallback
                if let image = library.image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                        .blur(radius: 24, opaque: true)
                        .overlay((theme.appearance == .light ? Color.white : Color.black).opacity(0.35))
                        .transition(.opacity)
                }
            }
            .task { await library.start(target: CGSize(width: 400, height: 800)) }
        }
    }
}

private struct ThemedCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        card(content)
            .shadow(color: .black.opacity(theme.layout?.shadow == true ? (theme.appearance == .light ? 0.10 : 0.35) : 0),
                    radius: 12, y: 5)
    }

    @ViewBuilder
    private func card(_ content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius, style: .continuous)
        switch theme.style {
        case .flat:
            content
                .background(shape.fill(theme.card.opacity(theme.layout?.cardOpacity ?? 1)))
                .overlay(shape.strokeBorder(theme.border ?? .clear, lineWidth: 1))
                .clipShape(shape)
        case .glass:
            glass(content, shape: shape)
        case .ascii:
            content
                .padding(4)
                .background(theme.card)
                .overlay(AsciiFrame(color: theme.border ?? theme.secondaryText))
        }
    }

    @ViewBuilder
    private func glass(_ content: Content, shape: RoundedRectangle) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(theme.card), in: shape)
        } else {
            frosted(content, shape: shape)
        }
        #else
        frosted(content, shape: shape)
        #endif
    }

    private func frosted(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(theme.card))
            .overlay(shape.strokeBorder(theme.border ?? .clear, lineWidth: 1))
            .clipShape(shape)
    }
}

// MARK: - ASCII drawing

/// Monospaced cell the ASCII style draws with.
enum Ascii {
    static let font = Font.system(size: 12, weight: .regular, design: .monospaced)

    /// How many character cells fit along `width`, and the step between their origins so that the first and
    /// last cells touch the edges exactly.
    static func cells(width: CGFloat, cell: CGFloat) -> (count: Int, step: CGFloat) {
        let count = max(2, Int(width / max(cell, 1)))
        return (count, (width - cell) / CGFloat(count - 1))
    }
}

/// A `+--+` / `|  |` frame drawn with text characters, filling its space.
struct AsciiFrame: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let text = ctx // resolving text doesn't need the inout context; closures may not capture it
            let glyph = { (s: String) in text.resolve(Text(s).font(Ascii.font).foregroundStyle(color)) }
            let plus = glyph("+"), dash = glyph("-"), pipe = glyph("|")
            let cell = dash.measure(in: size)
            guard cell.width > 0, cell.height > 0 else { return }
            let (cols, dx) = Ascii.cells(width: size.width, cell: cell.width)
            let (rows, dy) = Ascii.cells(width: size.height, cell: cell.height)
            let at = { (c: Int, r: Int) in
                CGPoint(x: CGFloat(c) * dx + cell.width / 2, y: CGFloat(r) * dy + cell.height / 2)
            }
            for c in 0..<cols {
                let g = c == 0 || c == cols - 1 ? plus : dash
                ctx.draw(g, at: at(c, 0))
                ctx.draw(g, at: at(c, rows - 1))
            }
            for r in 1..<max(1, rows - 1) {
                ctx.draw(pipe, at: at(0, r))
                ctx.draw(pipe, at: at(cols - 1, r))
            }
        }
        .allowsHitTesting(false)
    }
}

/// `[#######.......]` across the available width.
struct AsciiBar: View {
    let value: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let text = ctx // resolving text doesn't need the inout context; closures may not capture it
            let glyph = { (s: String, c: Color) in text.resolve(Text(s).font(Ascii.font).foregroundStyle(c)) }
            let cell = glyph("#", color).measure(in: size)
            guard cell.width > 0 else { return }
            let (cols, dx) = Ascii.cells(width: size.width, cell: cell.width)
            let inner = max(0, cols - 2)
            let filled = Int((Double(inner) * min(1, max(0, value))).rounded())
            let full = glyph("#", color), empty = glyph(".", color.opacity(0.45)), edge = glyph("[", color), end = glyph("]", color)
            for c in 0..<cols {
                let g = c == 0 ? edge : c == cols - 1 ? end : c <= filled ? full : empty
                ctx.draw(g, at: CGPoint(x: CGFloat(c) * dx + cell.width / 2, y: size.height / 2))
            }
        }
        .frame(height: 16)
    }
}

/// A line chart drawn with `*` on a grid of characters, `.` as the baseline.
struct AsciiChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let star = ctx.resolve(Text("*").font(Ascii.font).foregroundStyle(color))
            let dot = ctx.resolve(Text(".").font(Ascii.font).foregroundStyle(color.opacity(0.35)))
            let cell = star.measure(in: size)
            guard cell.width > 0, cell.height > 0, values.count > 1,
                  let lo = values.min(), let hi = values.max() else { return }
            let (cols, dx) = Ascii.cells(width: size.width, cell: cell.width)
            let (rows, dy) = Ascii.cells(width: size.height, cell: cell.height)
            for c in 0..<cols {
                let v = values[min(values.count - 1, Int(Double(c) / Double(max(1, cols - 1)) * Double(values.count - 1)))]
                let level = hi > lo ? (v - lo) / (hi - lo) : 0.5
                let row = rows - 1 - Int((level * Double(rows - 1)).rounded())
                let x = CGFloat(c) * dx + cell.width / 2
                ctx.draw(star, at: CGPoint(x: x, y: CGFloat(row) * dy + cell.height / 2))
                if row < rows - 1 { ctx.draw(dot, at: CGPoint(x: x, y: CGFloat(rows - 1) * dy + cell.height / 2)) }
            }
        }
        .frame(minHeight: 60, maxHeight: 120)
    }
}

/// `----------` across the available width.
struct AsciiRule: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let dash = ctx.resolve(Text("-").font(Ascii.font).foregroundStyle(color))
            let cell = dash.measure(in: size)
            guard cell.width > 0 else { return }
            let (cols, dx) = Ascii.cells(width: size.width, cell: cell.width)
            for c in 0..<cols { ctx.draw(dash, at: CGPoint(x: CGFloat(c) * dx + cell.width / 2, y: size.height / 2)) }
        }
        .frame(height: 14)
    }
}
