import PhoneScreenKit
import SwiftUI

extension EnvironmentValues {
    /// How much room the widget has; widgets show less as it shrinks.
    @Entry var widgetSize: WidgetSize = .full
    /// Corner radius for panels inside the widget, concentric with the card around it (nil: the theme's default).
    @Entry var innerRadius: CGFloat? = nil
    /// The page the pager shows (its neighbours are laid out too, ready for a swipe).
    @Entry var isCurrentPage = true
}

/// The page grid: one set of gaps and insets for every page, both orientations (a theme's `layout` can change them).
struct PageMetrics {
    var layout: Theme.Layout?

    init(_ theme: Theme) { layout = theme.layout }

    /// Between cards.
    var gap: CGFloat { CGFloat(layout?.gap ?? 10) }
    /// Around the pages; the Dynamic Island's edge gets `island` instead.
    var edge: CGFloat { CGFloat(layout?.margin ?? 10) }
    static let island: CGFloat = 50
    var showsDots: Bool { layout?.dots ?? true }
    /// Under the cards: the page dots.
    var dots: CGFloat { showsDots ? 16 : 0 }

    /// Inside a card: tighter in small tiles, roomier in half-page cards.
    func cardPadding(_ size: WidgetSize) -> CGFloat {
        let base = CGFloat(layout?.padding ?? 14)
        return size == .small ? max(6, base - 2) : base + 2
    }
}

/// One page: its widgets laid out by `PageLayout`, each in a card (a single widget gets the whole screen).
/// Lying sideways the cards line up in a row, so each keeps the shape it has upright:
/// a grid becomes four tall tiles, a trio a half-width card and two tiles.
struct PageView: View {
    let page: PageInfo
    @Environment(\.theme) private var theme

    var body: some View {
        let metrics = PageMetrics(theme)
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let widgets = page.visibleWidgets
            let sizes = WidgetSize.sizes(for: page.layout)
            let gap = metrics.gap
            let slot = { (i: Int) -> AnyView in
                AnyView(Card(ref: widgets.indices.contains(i) ? widgets[i] : nil, size: sizes[i], order: i, bare: page.bare == true))
            }
            Group {
                switch page.layout {
                case .single:
                    if let ref = widgets.first { WidgetView(ref: ref).environment(\.widgetSize, .full) }
                case .split:
                    let layout = landscape ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                    layout { slot(0); slot(1) }
                case .trio:
                    if landscape {
                        let tile = (geo.size.width - 2 * gap) / 4
                        HStack(spacing: gap) {
                            slot(0)
                            slot(1).frame(width: tile)
                            slot(2).frame(width: tile)
                        }
                    } else {
                        VStack(spacing: gap) { slot(0); HStack(spacing: gap) { slot(1); slot(2) } }
                    }
                case .stack:
                    let layout = landscape ? AnyLayout(HStackLayout(spacing: gap)) : AnyLayout(VStackLayout(spacing: gap))
                    layout { slot(0); slot(1); slot(2) }
                case .six:
                    let (rows, columns) = landscape ? (2, 3) : (3, 2)
                    VStack(spacing: gap) {
                        ForEach(0..<rows, id: \.self) { r in
                            HStack(spacing: gap) { ForEach(0..<columns, id: \.self) { c in slot(r * columns + c) } }
                        }
                    }
                case .grid:
                    if landscape {
                        HStack(spacing: gap) { slot(0); slot(1); slot(2); slot(3) }
                    } else {
                        VStack(spacing: gap) {
                            HStack(spacing: gap) { slot(0); slot(1) }
                            HStack(spacing: gap) { slot(2); slot(3) }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .debugLayout("page", .red)
        }
        .padding(.bottom, metrics.dots)
    }
}

private struct Card: View {
    let ref: WidgetRef?
    let size: WidgetSize
    var order = 0
    /// No surface: the widget sits on the page background.
    var bare = false
    @Environment(\.theme) private var theme
    @Environment(\.isCurrentPage) private var isCurrent
    @State private var shown = true

    var body: some View {
        let padding = PageMetrics(theme).cardPadding(size)
        ZStack {
            Color.clear
            if let ref {
                WidgetView(ref: ref)
                    .environment(\.widgetSize, size)
                    .environment(\.innerRadius, max(4, CGFloat(theme.radius) - padding))
                    .padding(padding)
            } else {
                Image(systemName: "plus.square.dashed").font(.title).foregroundStyle(.tertiary)
            }
        }
        .modifier(CardSurface(bare: bare))
        // Arriving on a page, its cards settle in one after another.
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0.5)
        .onChange(of: isCurrent) { _, now in
            guard now else { return }
            shown = false
            withAnimation(.spring(duration: 0.45, bounce: 0.25).delay(Double(order) * 0.045)) { shown = true }
        }
        .debugLayout("card", .yellow)
    }
}

private struct CardSurface: ViewModifier {
    let bare: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if bare { content } else { content.themedCard() }
    }
}

extension View {
    /// DEBUG `--debug-layout`: outlines the view and prints its size — for layout checks on screenshots.
    @ViewBuilder
    func debugLayout(_ label: String, _ color: Color) -> some View {
        #if DEBUG
        if DebugLayout.enabled {
            overlay {
                GeometryReader { geo in
                    Rectangle().stroke(color, lineWidth: 1)
                        .overlay(alignment: .topLeading) {
                            Text("\(label) \(Int(geo.size.width))×\(Int(geo.size.height)) @\(Int(geo.frame(in: .global).minX))")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color)
                                .background(.black.opacity(0.7))
                        }
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
enum DebugLayout {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--debug-layout")
}
#endif

struct WidgetView: View {
    let ref: WidgetRef

    var body: some View {
        switch ref {
        case .builtin(let kind):
            switch kind {
            case .music: MusicPage()
            case .monitor: MonitorPage()
            case .calendar: CalendarPage()
            case .reminders: RemindersPage()
            case .notes: NotesPage()
            case .launcher: LauncherPage()
            case .weather: WeatherPage()
            case .photos: PhotosPage()
            case .apps: AppsPage()
            }
        case .custom(let id):
            CustomWidgetView(id: id)
        }
    }
}

extension View {
    /// The generous page margins only apply when a widget has the whole screen; cards pad themselves.
    func widgetPadding() -> some View {
        modifier(WidgetPadding())
    }
}

private struct WidgetPadding: ViewModifier {
    @Environment(\.widgetSize) private var size

    func body(content: Content) -> some View {
        if size == .full {
            content.padding(.horizontal, 8).padding(.vertical, 6)
        } else {
            content
        }
    }
}
