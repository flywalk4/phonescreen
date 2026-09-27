import Charts
import PhoneScreenKit
import SwiftUI

/// An installed JavaScript widget. Its code runs on the Mac; this only draws the resolved UI natively.
struct CustomWidgetView: View {
    let id: String
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size

    var body: some View {
        Group {
            if let state = model.customWidgets[id] {
                if let node = state.view(for: size) {
                    content(node)
                        .overlay(alignment: .topTrailing) {
                            if let error = state.error {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help(error)
                            }
                        }
                } else {
                    failure(state)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.status.active == nil ? "Нет связи с Mac" : "Виджет не установлен на Mac")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func content(_ node: WidgetNode) -> some View {
        if size == .full {
            // Fits on the page → it gets the whole height (so `spacer`s spread the layout out); too tall → it scrolls.
            ViewThatFits(in: .vertical) {
                NodeView(node: node, widgetID: id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScrollView {
                    NodeView(node: node, widgetID: id).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .pointerScrollable()
            }
            .widgetPadding()
        } else {
            NodeView(node: node, widgetID: id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    private func failure(_ state: CustomWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.name, systemImage: state.symbol).font(.headline)
            Text(state.error ?? "Нет данных").font(.caption).foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetPadding()
    }
}

/// Draws one `WidgetNode` (recursively, through `AnyView` for children).
struct NodeView: View {
    let node: WidgetNode
    let widgetID: String
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.theme) private var theme
    private var ascii: Bool { theme.style == .ascii }

    var body: some View {
        switch node {
        case .vstack(let spacing, let align, let children):
            VStack(alignment: horizontal(align), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
        case .hstack(let spacing, let align, let children):
            HStack(alignment: vertical(align), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
        case .text(let text, let style, let color, let lines, let align, let custom):
            Text(text)
                .font(font(style, custom))
                .foregroundStyle(WidgetColor.style(color, theme: theme))
                .lineLimit(lines)
                .multilineTextAlignment(align == "center" ? .center : align == "trailing" ? .trailing : .leading)
        case .symbol(let name, let color, let size):
            Glyph(name)
                .font(size.map { .system(size: CGFloat($0)) } ?? .body)
                .foregroundStyle(WidgetColor.style(color, theme: theme))
        case .gauge(let value, let label, let color) where ascii:
            VStack(alignment: .leading, spacing: 2) {
                Text([label, "\(Int((value * 100).rounded()))%"].compactMap { $0 }.joined(separator: " ")).font(Ascii.font)
                AsciiBar(value: value, color: tint(color))
            }
        case .gauge(let value, let label, let color):
            VStack(spacing: 4) {
                ZStack {
                    Circle().stroke(theme.text.opacity(0.12), lineWidth: 6)
                    Circle().trim(from: 0, to: value)
                        .stroke(tint(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit().weight(.semibold))
                }
                .frame(width: 56, height: 56)
                if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
            }
        case .progress(let value, let color) where ascii:
            AsciiBar(value: value, color: tint(color))
        case .progress(let value, let color):
            ProgressView(value: value).tint(tint(color))
        case .chart(let values, let color, _, let height) where ascii:
            AsciiChart(values: values, color: tint(color))
                .frame(height: height.map { CGFloat($0) })
        case .chart(let values, let color, let style, let height):
            WidgetChart(values: values, color: tint(color), style: style ?? "line")
                .frame(minHeight: height.map { CGFloat($0) } ?? 60, maxHeight: height.map { CGFloat($0) } ?? 120)
        case .button(let title, _, let action) where ascii:
            Button { model.customAction(widgetID, action) } label: {
                Text("[ \(title) ]").font(Ascii.font).lineLimit(1).minimumScaleFactor(0.7)
            }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .pointerTarget { model.customAction(widgetID, action) }
        case .button(let title, let symbol, let action):
            Button { model.customAction(widgetID, action) } label: {
                // Tight on space: the icon alone, never a title broken mid-word.
                if let symbol {
                    ViewThatFits(in: .horizontal) {
                        Label(title, systemImage: symbol).lineLimit(1).fixedSize()
                        Image(systemName: symbol)
                    }
                } else {
                    Text(title).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .buttonStyle(.bordered)
            .pointerTarget { model.customAction(widgetID, action) }
        case .sprite(let frames, let palette, let fps):
            SpriteView(frames: frames, palette: palette, fps: fps ?? 4)
        case .spacer:
            Spacer(minLength: 0)
        case .box(let spacing, let align, let padding, let background, let opacity, let radius, let fit, let action, let aspect, let children):
            let panel = VStack(alignment: horizontal(align), spacing: spacing.map { CGFloat($0) } ?? 6) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
            .frame(maxWidth: fit == true ? nil : .infinity, maxHeight: aspect == nil ? nil : .infinity,
                   alignment: aspect == nil ? Alignment(horizontal: horizontal(align), vertical: .top) : .center)
            .padding(padding.map { CGFloat($0) } ?? 12)
            .modifier(Aspect(ratio: aspect))
            .widgetBox(fill: WidgetColor.color(background, theme: theme).map { $0.opacity(opacity ?? 1) },
                       radius: radius.map { CGFloat($0) })
            if let action {
                Button { model.customAction(widgetID, action) } label: { panel.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .pointerTarget { model.customAction(widgetID, action) }
            } else {
                panel
            }
        case .grid(let columns, let spacing, let children):
            let gap = spacing.map { CGFloat($0) } ?? 10
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: columns),
                      alignment: .leading, spacing: gap) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
        case .layers(let align, let children):
            ZStack(alignment: alignment(align)) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
        case .scene(let kind, let colors, let tints, let speed):
            let base = (colors ?? theme.background.colors).map { Color(hex: $0, fallback: .black) }
            let moving = (tints ?? theme.background.tints ?? [theme.colors.accent]).map { Color(hex: $0, fallback: theme.accent) }
            SceneView(kind: SceneView.Kind(rawValue: kind) ?? .aurora, base: base, tints: moving, speed: speed ?? 1)
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: max(0, min(CGFloat(theme.radius) - 6, 18)), style: .continuous))
        case .divider where ascii:
            AsciiRule(color: theme.secondaryText)
        case .divider:
            Divider()
        }
    }

    private func tint(_ name: String?) -> Color { WidgetColor.color(name, theme: theme) ?? theme.accent }

    private func alignment(_ a: String?) -> Alignment {
        switch a {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: .center
        }
    }

    private func horizontal(_ a: String?) -> HorizontalAlignment {
        switch a { case "center": .center; case "trailing": .trailing; default: .leading }
    }

    private func vertical(_ a: String?) -> VerticalAlignment {
        switch a { case "top": .top; case "bottom": .bottom; case "baseline": .firstTextBaseline; default: .center }
    }

    private func font(_ style: String?, _ custom: WidgetFont?) -> Font {
        guard let custom else { return font(style) }
        let weight = custom.weight.flatMap { Self.weights[$0] }
        let design: Font.Design? = switch custom.design {
        case "rounded": .rounded
        case "monospaced": .monospaced
        case "serif": .serif
        case "default": .default
        default: nil // the theme's
        }
        if let size = custom.size {
            return .system(size: CGFloat(size), weight: weight ?? .regular, design: design)
        }
        return .system(textStyle(style), design: design, weight: weight ?? defaultWeight(style))
    }

    private func textStyle(_ style: String?) -> Font.TextStyle {
        switch style {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "callout": .callout
        case "subheadline": .subheadline
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: .body
        }
    }

    /// Titles are semibold in `font(_:)`; keep that when only the design changes.
    private func defaultWeight(_ style: String?) -> Font.Weight {
        ["largeTitle", "title", "title2", "title3", "headline"].contains(style ?? "") ? .semibold : .regular
    }

    private static let weights: [String: Font.Weight] = [
        "ultraLight": .ultraLight, "thin": .thin, "light": .light, "regular": .regular, "medium": .medium,
        "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black,
    ]

    private func font(_ style: String?) -> Font {
        switch style {
        case "largeTitle": .largeTitle.weight(.semibold)
        case "title": .title.weight(.semibold)
        case "title2": .title2.weight(.semibold)
        case "title3": .title3.weight(.semibold)
        case "headline": .headline
        case "callout": .callout
        case "subheadline": .subheadline
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: .body
        }
    }
}

/// Keeps a `box` at a width / height ratio when one is set (and leaves layout alone otherwise).
private struct Aspect: ViewModifier {
    let ratio: Double?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let ratio { content.aspectRatio(CGFloat(ratio), contentMode: .fit) } else { content }
    }
}

/// A chart of `values`: a line, a line over a fading area, or bars.
struct WidgetChart: View {
    let values: [Double]
    let color: Color
    let style: String

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            switch style {
            case "bar":
                BarMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(3)
            case "area":
                AreaMark(x: .value("i", i), yStart: .value("min", low), yEnd: .value("v", v))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            default:
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: style == "bar" ? .automatic(includesZero: true) : .automatic(includesZero: false))
    }

    /// Bottom of the area: a little under the smallest value, so the fill doesn't start at zero.
    private var low: Double {
        guard let lo = values.min(), let hi = values.max() else { return 0 }
        return lo - (hi - lo) * 0.1
    }
}

/// Colours a widget may name: system names or `#RRGGBB` / `#RRGGBBAA`. The theme can replace any name
/// (`colors.palette`); `primary` / `secondary` / `accent` are the theme's own.
enum WidgetColor {
    static func color(_ name: String?, theme: Theme) -> Color? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        if let replaced = theme.paletteColor(name) { return replaced }
        switch name {
        case "primary": return theme.text
        case "secondary": return theme.secondaryText
        case "tertiary": return theme.secondaryText.opacity(0.6)
        case "accent": return theme.accent
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        case "brown": return .brown
        case "gray", "grey": return .gray
        case "white": return .white
        case "clear", "none": return .clear // a box without a surface
        default: return RGBA(hex: name).map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) }
        }
    }

    static func style(_ name: String?, theme: Theme) -> AnyShapeStyle {
        AnyShapeStyle(color(name, theme: theme) ?? theme.text)
    }
}

/// Pixel-art animation: frames of character rows, one palette colour per character (`.`/space transparent).
/// Scales to the space it gets with square pixels; plays at `fps`.
struct SpriteView: View {
    let frames: [[String]]
    let palette: [String: String]
    let fps: Double
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = frames.map(\.count).max() ?? 1
        let cols = frames.flatMap { $0 }.map(\.count).max() ?? 1
        let colors = palette.reduce(into: [Character: Color]()) { result, entry in
            if let ch = entry.key.first, let color = WidgetColor.color(entry.value, theme: theme) { result[ch] = color }
        }
        TimelineView(.periodic(from: .now, by: 1 / max(0.5, min(fps, 30)))) { context in
            let index = frames.count > 1 ? Int(context.date.timeIntervalSinceReferenceDate * fps) % frames.count : 0
            Canvas { ctx, size in
                let cell = floor(min(size.width / CGFloat(cols), size.height / CGFloat(rows)))
                guard cell > 0 else { return }
                let origin = CGPoint(x: (size.width - cell * CGFloat(cols)) / 2, y: (size.height - cell * CGFloat(rows)) / 2)
                for (y, line) in frames[index].enumerated() {
                    for (x, ch) in line.enumerated() {
                        guard let color = colors[ch] else { continue }
                        // +0.5 overlap hides anti-aliasing seams between neighbouring cells.
                        ctx.fill(Path(CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(y) * cell,
                                             width: cell + 0.5, height: cell + 0.5)), with: .color(color))
                    }
                }
            }
        }
        .aspectRatio(CGFloat(cols) / CGFloat(rows), contentMode: .fit)
        .frame(minWidth: 24, minHeight: 24)
    }
}
