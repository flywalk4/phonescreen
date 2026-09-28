import Charts
import QwoviKit
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
                        // New data animates in: numbers roll, rings and bars glide, rows slide.
                        .animation(.smooth(duration: 0.5), value: node)
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
                    Text(model.status.active == nil ? L("No connection to the Mac") : L("The widget isn't installed on the Mac"))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func content(_ node: WidgetNode) -> some View {
        if let backdrop = node.backdrop {
            // The scene is drawn by the card (or the whole screen) behind; only what lies on it is laid out here —
            // one layer the usual way (a column fills the page, flows into columns lying sideways), several stacked.
            if case .layers(_, let layers) = backdrop.rest, layers.count == 1 {
                AnyView(content(layers[0]))
            } else {
                NodeView(node: backdrop.rest, widgetID: id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: NodeView.alignment(backdrop.align))
                    .widgetPadding()
            }
        } else if case .vstack(let spacing, _, let children) = node, let b = children.firstIndex(where: \.hasBoard) {
            // A game: the board as big as the card allows, whatever its shape (see `BoardPage`).
            BoardPage(widgetID: id, spacing: CGFloat(spacing ?? 10),
                      before: children[..<b].filter { $0 != .spacer }, board: children[b],
                      after: children[(b + 1)...].filter { $0 != .spacer })
                .widgetPadding()
        } else if size == .full, case .vstack(let spacing, let align, let children) = node {
            // A whole page: the column fills the height (spacers spread it out), and lying sideways it
            // flows into two columns. Too tall even so → it scrolls.
            GeometryReader { geo in
                let aspect = geo.size.width / max(geo.size.height, 1)
                let columns = aspect > 2.1 ? 3 : aspect > 1.25 ? 2 : 1
                ViewThatFits(in: .vertical) {
                    fullFlow(children: children, spacing: spacing, align: align, columns: columns, size: geo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Too much even in columns → the same layout a little smaller, before falling back to scrolling.
                    ForEach([0.85, 0.72], id: \.self) { k in
                        let big = CGSize(width: geo.size.width / k, height: geo.size.height / k)
                        fullFlow(children: children, spacing: spacing, align: align, columns: columns, size: big)
                            .frame(width: big.width)
                            .scaleEffect(k, anchor: .topLeading)
                            .modifier(ScaledHeight(k: k, width: geo.size.width))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    ScrollView {
                        NodeView(node: node, widgetID: id).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .pointerScrollable()
                }
            }
            .widgetPadding()
        } else if size == .full {
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
        } else if case .vstack(let spacing, let align, let children) = node {
            // A card: the same column, so spare height in tall tiles goes to charts before empty space.
            // Too much for a short tile even with charts squeezed → the whole card scales down a little, not cut off.
            GeometryReader { geo in
                // A game board in a wide, short tile: a board is as tall as it is wide, so the column narrows to
                // the tile's height (centred) — otherwise the board runs off the bottom.
                let board = geo.size.width > geo.size.height && children.contains(where: \.hasBoard)
                let width = board ? min(geo.size.width, max(geo.size.height - 64, 90)) : geo.size.width
                ViewThatFits(in: .vertical) {
                    cardColumn(spacing: spacing, align: align, children: children, size: CGSize(width: width, height: geo.size.height))
                        .frame(width: width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: board ? .top : .topLeading)
                    let box = CGSize(width: width, height: geo.size.height)
                    scaled(0.8, spacing: spacing, align: align, children: children, size: box)
                        .frame(width: width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: board ? .top : .topLeading)
                    scaled(0.66, spacing: spacing, align: align, children: children, size: box)
                        .frame(width: width, height: geo.size.height, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: board ? .center : .leading)
                }
            }
            .clipped()
        } else {
            // A row (picture beside text) sits in the middle of the card's height rather than at its top.
            let isRow: Bool = { if case .hstack = node { return true } else { return false } }()
            NodeView(node: node, widgetID: id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isRow ? .leading : .topLeading)
                .clipped()
        }
    }

    private func fullFlow(children: [WidgetNode], spacing: Double?, align: String?, columns: Int, size: CGSize) -> some View {
        FlowColumns(columns: columns, spacing: CGFloat(spacing ?? 8), align: align, width: size.width, height: size.height) {
            ForEach(children.indices, id: \.self) { i in
                NodeView(node: children[i], widgetID: id)
                    .layoutValue(key: FlowSpan.self, value: columns > 1 && i == 0 && children[i].isHeader)
                    .layoutValue(key: FlowGrows.self, value: children[i].grows)
                    .layoutValue(key: FlowSpacer.self, value: children[i] == .spacer)
            }
        }
    }

    /// The card column laid out `1/k` larger and drawn at `k`: reports its real (scaled) height, so `ViewThatFits`
    /// can tell whether it fits.
    private func scaled(_ k: CGFloat, spacing: Double?, align: String?, children: [WidgetNode], size: CGSize) -> some View {
        let big = CGSize(width: size.width / k, height: size.height / k)
        return cardColumn(spacing: spacing, align: align, children: children, size: big)
            .frame(width: big.width)
            .scaleEffect(k, anchor: .topLeading)
            .modifier(ScaledHeight(k: k, width: size.width))
    }

    private func cardColumn(spacing: Double?, align: String?, children: [WidgetNode], size: CGSize) -> some View {
        FlowColumns(columns: 1, spacing: CGFloat(spacing ?? 8), align: align, width: size.width, height: size.height) {
            ForEach(children.indices, id: \.self) { i in
                NodeView(node: children[i], widgetID: id)
                    .layoutValue(key: FlowGrows.self, value: children[i].grows)
                    .layoutValue(key: FlowSpacer.self, value: children[i] == .spacer)
            }
        }
    }

    private func failure(_ state: CustomWidgetState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(state.name, systemImage: state.symbol).font(.headline)
            Text(state.error ?? L("No data")).font(.caption).foregroundStyle(.red)
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
    @Environment(\.innerRadius) private var innerRadius
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
                .contentTransition(.numericText())
                .font(font(style, custom))
                .minimumScaleFactor(lines == 1 ? 0.5 : 1) // a one-line number shrinks rather than turning into "25:…"
                .foregroundStyle(WidgetColor.style(color, theme: theme))
                .lineLimit(lines)
                .multilineTextAlignment(align == "center" ? .center : align == "trailing" ? .trailing : .leading)
        case .symbol(let name, let color, let size):
            Glyph(name)
                .font(size.map { .system(size: CGFloat($0)) } ?? .body)
                .foregroundStyle(WidgetColor.style(color, theme: theme))
        case .gauge(let value, let label, let color, let text, _) where ascii:
            VStack(alignment: .leading, spacing: 2) {
                Text([label, text ?? "\(Int((value * 100).rounded()))%"].compactMap { $0 }.joined(separator: " ")).font(Ascii.font)
                AsciiBar(value: value, color: tint(color))
            }
        case .gauge(let value, let label, let color, let text, let fill):
            VStack(spacing: 4) {
                if fill == true {
                    // As big as the room allows, with the line and the centre text scaled to it.
                    GeometryReader { geo in
                        let d = max(34, min(geo.size.width, geo.size.height))
                        ring(value: value, color: color, text: text, diameter: d)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .frame(minWidth: 40, maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                } else {
                    ring(value: value, color: color, text: text, diameter: 56)
                }
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
            // `height` is what it needs; with room to spare (tall tiles, whole pages) it grows up to 3×.
            WidgetChart(values: values, color: tint(color), style: style ?? "line")
                .frame(minHeight: height.map { CGFloat($0) } ?? 60, maxHeight: height.map { CGFloat($0) * 3 } ?? 240)
        case .button(let title, let symbol, let action, _) where ascii:
            Button { model.customAction(widgetID, action) } label: {
                Text("[ \(title.isEmpty ? AsciiGlyphs.text(for: symbol ?? "") : title) ]").font(Ascii.font)
            }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .pointerTarget { model.customAction(widgetID, action) }
        case .button(let title, let symbol, let action, let color):
            let run = { model.customAction(widgetID, action) }
            let fill = WidgetColor.color(color, theme: theme)
            Group {
                if let symbol, !title.isEmpty {
                    // No room for the title (narrow cards) → just the icon, rather than "▶ С…". Whole buttons are
                    // compared, the pill's padding included.
                    ViewThatFits(in: .horizontal) {
                        Button(action: run) { Label(title, systemImage: symbol).lineLimit(1).fixedSize() }
                            .buttonStyle(PillButtonStyle(fill: fill))
                        Button(action: run) { Image(systemName: symbol) }
                            .buttonStyle(PillButtonStyle(fill: fill, round: true))
                    }
                } else if let symbol {
                    Button(action: run) { Image(systemName: symbol) }.buttonStyle(PillButtonStyle(fill: fill, round: true))
                } else {
                    // One line, shrinking a little rather than breaking a word in half.
                    Button(action: run) { Text(title).lineLimit(1).minimumScaleFactor(0.7) }
                        .buttonStyle(PillButtonStyle(fill: fill))
                }
            }
            .pointerTarget(action: run)
        case .sprite(let frames, let palette, let fps):
            SpriteView(frames: frames, palette: palette, fps: fps ?? 4)
        case .spacer:
            Spacer(minLength: 0).layoutValue(key: FlowSpacer.self, value: true)
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
            ZStack(alignment: Self.alignment(align)) {
                ForEach(children.indices, id: \.self) { AnyView(NodeView(node: children[$0], widgetID: widgetID)) }
            }
        case .scene:
            WidgetBackdrop(scene: node)
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius ?? max(0, min(CGFloat(theme.radius) - 6, 18)), style: .continuous))
        case .divider where ascii:
            AsciiRule(color: theme.secondaryText)
        case .divider:
            Divider()
        }
    }

    private func ring(value: Double, color: String?, text: String?, diameter d: CGFloat) -> some View {
        let line = max(6, d * 0.08)
        return ZStack {
            Circle().stroke(theme.text.opacity(0.12), lineWidth: line)
            Circle().trim(from: 0, to: value)
                .stroke(tint(color), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(text ?? "\(Int((value * 100).rounded()))%")
                .font(.system(size: max(12, d * (text == nil ? 0.22 : 0.24)), weight: .semibold, design: .rounded).monospacedDigit())
                .minimumScaleFactor(0.5).lineLimit(1)
                .padding(.horizontal, line * 1.5)
        }
        .frame(width: d - line, height: d - line)
    }

    private func tint(_ name: String?) -> Color { WidgetColor.color(name, theme: theme) ?? theme.accent }

    static func alignment(_ a: String?) -> Alignment {
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

extension WidgetNode {
    /// A title row (an `hstack` without anything tall in it): spans both columns when the page flows sideways.
    var isHeader: Bool {
        guard case .hstack(_, _, let children) = self else { return false }
        return !children.contains { node in
            switch node {
            case .chart, .box, .grid, .gauge, .sprite, .scene, .vstack, .layers: true
            default: false
            }
        }
    }
}

/// Marks what may take spare height in `FlowColumns`: charts, filling gauges, scenes (or panels holding them).
/// Everything else keeps its natural height, so a game board stays centred between its spacers.
struct FlowGrows: LayoutValueKey {
    static let defaultValue = false
}

extension WidgetNode {
    /// A game board: a grid of square cells (it grows with the width, never shrinks with the height).
    var hasBoard: Bool {
        switch self {
        case .grid(_, _, let c): c.contains { if case .box(_, _, _, _, _, _, _, _, let aspect, _) = $0 { aspect != nil } else { false } }
        case .vstack(_, _, let c), .hstack(_, _, let c), .layers(_, let c): c.contains(where: \.hasBoard)
        case .box(_, _, _, _, _, _, _, _, _, let c): c.contains(where: \.hasBoard)
        default: false
        }
    }

    var grows: Bool {
        switch self {
        case .chart, .scene: true
        case .gauge(_, _, _, _, let fill): fill == true
        case .vstack(_, _, let c), .hstack(_, _, let c), .layers(_, let c), .grid(_, _, let c): c.contains(where: \.grows)
        case .box(_, _, _, _, _, _, _, _, let aspect, let c): aspect == nil && c.contains(where: \.grows)
        default: false
        }
    }
}

/// Marks a `spacer`: `FlowColumns` gives it only the room nothing else wants.
struct FlowSpacer: LayoutValueKey {
    static let defaultValue = false
}

/// Marks a child of `FlowColumns` that runs across all columns (placed first).
struct FlowSpan: LayoutValueKey {
    static let defaultValue = false
}

/// A column of children — like a `VStack` that fills its height — which, with `columns: 2`, splits into two balanced
/// columns. Within a column every child gets its ideal height; spare height goes to what can grow (spacers, charts,
/// boards), and when there isn't enough, whatever can shrink (charts, square boards) gives way first.
struct FlowColumns: Layout {
    var columns: Int
    var spacing: CGFloat
    var align: String?
    /// The size it will get: `ViewThatFits` asks for the ideal size without one.
    var width: CGFloat
    var height: CGFloat
    var columnGap: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? self.width
        let plan = self.plan(width: width, height: proposal.height ?? height, subviews: subviews)
        return CGSize(width: width, height: max(proposal.height ?? 0, plan.needed))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = self.plan(width: bounds.width, height: bounds.height, subviews: subviews)
        for item in plan.items {
            let x: CGFloat
            switch align {
            case "center": x = bounds.minX + item.frame.midX
            case "trailing": x = bounds.minX + item.frame.maxX
            default: x = bounds.minX + item.frame.minX
            }
            let anchor: UnitPoint = align == "center" ? .top : align == "trailing" ? .topTrailing : .topLeading
            subviews[item.index].place(at: CGPoint(x: x, y: bounds.minY + item.frame.minY), anchor: anchor,
                                       proposal: ProposedViewSize(width: item.frame.width, height: item.frame.height))
        }
    }

    private struct Planned { let index: Int; let frame: CGRect }

    /// `columns` is the most it may use: it takes the fewest that fit, so nothing gets squeezed narrower than needed.
    private func plan(width: CGFloat, height: CGFloat?, subviews: Subviews) -> (items: [Planned], needed: CGFloat) {
        guard let height, columns > 1 else { return plan(width: width, height: height, columns: columns, subviews: subviews) }
        // "Fits" means at natural heights — squeezing charts flat to save a column doesn't count.
        let count = (1...columns).first { plan(width: width, height: nil, columns: $0, subviews: subviews).needed <= height + 0.5 } ?? columns
        return plan(width: width, height: height, columns: count, subviews: subviews)
    }

    private func plan(width: CGFloat, height: CGFloat?, columns: Int, subviews: Subviews) -> (items: [Planned], needed: CGFloat) {
        var items: [Planned] = []
        var top: CGFloat = 0
        let spanned = subviews.indices.filter { subviews[$0][FlowSpan.self] }
        for i in spanned {
            let h = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            items.append(Planned(index: i, frame: CGRect(x: 0, y: top, width: width, height: h)))
            top += h + spacing
        }
        let rest = subviews.indices.filter { !subviews[$0][FlowSpan.self] }
        let count = max(1, min(columns, rest.count))
        let columnWidth = (width - columnGap * CGFloat(count - 1)) / CGFloat(count)
        let ideal = rest.map { subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }

        let cuts = Self.partition(ideal, into: count, spacing: spacing)

        var needed = top
        var start = 0
        for (column, end) in cuts.enumerated() {
            let run = Array(start..<end)
            start = end
            let available = height.map { $0 - top - spacing * CGFloat(max(0, run.count - 1)) }
            let heights = allocate(run.map { rest[$0] }, ideal: run.map { ideal[$0] }, width: columnWidth,
                                   available: available, subviews: subviews)
            var y = top
            for (k, index) in run.enumerated() {
                items.append(Planned(index: rest[index],
                                     frame: CGRect(x: CGFloat(column) * (columnWidth + columnGap), y: y,
                                                   width: columnWidth, height: heights[k])))
                y += heights[k] + spacing
            }
            needed = max(needed, y - spacing)
        }
        return (items, needed)
    }

    /// Where to cut `heights` into `parts` runs (children keep their order) so the tallest run is as short as
    /// possible; returns each run's end index. Spacers weigh nothing, so they never decide a split.
    static func partition(_ heights: [CGFloat], into parts: Int, spacing: CGFloat) -> [Int] {
        let n = heights.count
        guard parts > 1, n > 1 else { return [n] }
        let k = min(parts, n)
        func run(_ a: Int, _ b: Int) -> CGFloat { // children a..<b stacked
            heights[a..<b].reduce(0, +) + spacing * CGFloat(max(0, b - a - 1))
        }
        // best[j][i]: the tallest run when the first i children fill j runs; cut[j][i]: where run j starts.
        var best = Array(repeating: Array(repeating: CGFloat.infinity, count: n + 1), count: k + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        best[0][0] = 0
        for j in 1...k {
            for i in j...n {
                for start in (j - 1)..<i where best[j - 1][start] < .infinity {
                    let tallest = max(best[j - 1][start], run(start, i))
                    if tallest < best[j][i] { best[j][i] = tallest; cut[j][i] = start }
                }
            }
        }
        var ends: [Int] = []
        var i = n
        for j in stride(from: k, through: 1, by: -1) { ends.append(i); i = cut[j][i] }
        return ends.reversed()
    }

    /// Heights for one column: ideal sizes, plus spare room for what grows, or minus a shortfall from what shrinks.
    private func allocate(_ indices: [Int], ideal: [CGFloat], width: CGFloat, available: CGFloat?,
                          subviews: Subviews) -> [CGFloat] {
        guard let available else { return ideal }
        let total = ideal.reduce(0, +)
        if total <= available {
            // A Spacer only stretches inside SwiftUI's own stacks; here it may take whatever is left.
            let most = indices.map { i in
                subviews[i][FlowSpacer.self] ? available
                    : min(subviews[i].sizeThatFits(ProposedViewSize(width: width, height: available)).height, available)
            }
            let growable = indices.indices.filter {
                (subviews[indices[$0]][FlowGrows.self] || subviews[indices[$0]][FlowSpacer.self]) && most[$0] > ideal[$0] + 0.5
            }
            guard !growable.isEmpty else { return ideal }
            var heights = ideal
            var spare = available - total
            // Hand out the spare evenly, capped at what each child can take: content first (charts, boards),
            // then spacers get what's left.
            let isSpacer = { (k: Int) in subviews[indices[k]][FlowSpacer.self] }
            for round in [growable.filter { !isSpacer($0) }, growable.filter(isSpacer)] {
            var open = round
            while spare > 0.5, !open.isEmpty {
                let share = spare / CGFloat(open.count)
                var next: [Int] = []
                for k in open {
                    let add = min(share, most[k] - heights[k])
                    heights[k] += add
                    spare -= add
                    if most[k] - heights[k] > 0.5 { next.append(k) }
                }
                open = next
            }
            }
            return heights
        }
        let least = indices.map { subviews[$0].sizeThatFits(ProposedViewSize(width: width, height: 0)).height }
        let give = zip(ideal, least).map { max(0, $0 - $1) }
        let givable = give.reduce(0, +)
        guard givable > 0 else { return ideal }
        let shortfall = min(total - available, givable)
        return ideal.indices.map { ideal[$0] - give[$0] * shortfall / givable }
    }
}

/// Reports a view drawn with `scaleEffect(k)` at its scaled size (scaleEffect alone keeps the unscaled one).
private struct ScaledHeight: ViewModifier {
    let k: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        ScaledLayout(k: k, width: width) { content }
    }
}

private struct ScaledLayout: Layout {
    let k: CGFloat
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let inner = subviews.first?.sizeThatFits(ProposedViewSize(width: width / k, height: proposal.height.map { $0 / k })) ?? .zero
        return CGSize(width: width, height: inner.height * k)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: width / k, height: bounds.height / k))
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

extension WidgetNode {
    /// A `layers` whose bottom layer is a `scene`: the scene is the widget's backdrop. It fills the whole card —
    /// or the whole screen when the widget has it — instead of a panel inset by the padding; `rest` lies on top.
    var backdrop: (scene: WidgetNode, rest: WidgetNode, align: String?)? {
        guard case .layers(let align, let children) = self, let first = children.first, case .scene = first else { return nil }
        return (first, .layers(align: align, children: Array(children.dropFirst())), align)
    }
}

/// A `scene` node drawn edge to edge (clip it to the shape it fills).
struct WidgetBackdrop: View {
    let scene: WidgetNode
    @Environment(\.theme) private var theme

    var body: some View {
        if case .scene(let kind, let colors, let tints, let speed) = scene {
            // ASCII keeps to its own colours: a widget's coloured glows would break the terminal look.
            let ascii = theme.style == .ascii
            let base = ((ascii ? nil : colors) ?? theme.background.colors).map { Color(hex: $0, fallback: .black) }
            let moving = ((ascii ? nil : tints) ?? theme.background.tints ?? [theme.colors.accent]).map { Color(hex: $0, fallback: theme.accent) }
            SceneView(kind: SceneView.Kind(rawValue: kind) ?? .aurora, base: base, tints: moving, speed: speed ?? 1)
        }
    }
}

/// A widget built around a board (a grid of square cells: games). Whatever the card's shape, the board is drawn from
/// one design at `reference` width and scaled as a whole to the biggest square that fits — so a 2×2 tile, a half page
/// and the whole screen show the same board, only bigger or smaller.
/// Upright: what comes before the board on top, what comes after it at the bottom, the board centred in between.
/// Wide: the board on the left at full height, the rest in a column beside it, where a row of panels (scores)
/// stands as a column too.
struct BoardPage: View {
    let widgetID: String
    let spacing: CGFloat
    let before: [WidgetNode]
    let board: WidgetNode
    let after: [WidgetNode]
    static let reference: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height * 1.2 {
                HStack(spacing: spacing + 6) {
                    fitted(side: min(geo.size.height, geo.size.width * 0.55, geo.size.width - 150))
                    VStack(alignment: .leading, spacing: spacing) {
                        parts(before, column: true)
                        Spacer(minLength: 0)
                        parts(after, column: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    parts(before)
                    GeometryReader { area in
                        fitted(side: min(area.size.width, area.size.height))
                            .frame(width: area.size.width, height: area.size.height)
                    }
                    parts(after)
                }
            }
        }
    }

    private func parts(_ nodes: [WidgetNode], column: Bool = false) -> some View {
        ForEach(nodes.indices, id: \.self) { i in
            if column, case .hstack(_, _, let row) = nodes[i], row.contains(where: { if case .box = $0 { true } else { false } }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(row.indices.filter { row[$0] != .spacer }, id: \.self) { j in
                        NodeView(node: row[j], widgetID: widgetID).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                NodeView(node: nodes[i], widgetID: widgetID).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fitted(side: CGFloat) -> some View {
        NodeView(node: board, widgetID: widgetID)
            .frame(width: Self.reference)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(max(side, 1) / Self.reference)
            .frame(width: side, height: side)
    }
}
