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
            ScrollView {
                NodeView(node: node, widgetID: id).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .pointerScrollable()
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
        case .text(let text, let style, let color, let lines, let align):
            Text(text)
                .font(font(style))
                .foregroundStyle(WidgetColor.style(color, theme: theme))
                .lineLimit(lines)
                .multilineTextAlignment(align == "center" ? .center : align == "trailing" ? .trailing : .leading)
        case .symbol(let name, let color, let size):
            Image(systemName: name)
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
        case .chart(let values, let color) where ascii:
            AsciiChart(values: values, color: tint(color))
        case .chart(let values, let color):
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v))
                    .foregroundStyle(tint(color))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(minHeight: 60, maxHeight: 120)
        case .button(let title, _, let action) where ascii:
            Button { model.customAction(widgetID, action) } label: { Text("[ \(title) ]").font(Ascii.font) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .pointerTarget { model.customAction(widgetID, action) }
        case .button(let title, let symbol, let action):
            Button { model.customAction(widgetID, action) } label: {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .buttonStyle(.bordered)
            .pointerTarget { model.customAction(widgetID, action) }
        case .sprite(let frames, let palette, let fps):
            SpriteView(frames: frames, palette: palette, fps: fps ?? 4)
        case .spacer:
            Spacer(minLength: 0)
        case .divider where ascii:
            AsciiRule(color: theme.secondaryText)
        case .divider:
            Divider()
        }
    }

    private func tint(_ name: String?) -> Color { WidgetColor.color(name, theme: theme) ?? theme.accent }

    private func horizontal(_ a: String?) -> HorizontalAlignment {
        switch a { case "center": .center; case "trailing": .trailing; default: .leading }
    }

    private func vertical(_ a: String?) -> VerticalAlignment {
        switch a { case "top": .top; case "bottom": .bottom; case "baseline": .firstTextBaseline; default: .center }
    }

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
