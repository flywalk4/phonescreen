import PhoneScreenKit
import SwiftUI

extension EnvironmentValues {
    /// How much room the widget has; widgets show less as it shrinks.
    @Entry var widgetSize: WidgetSize = .full
}

/// One page: its widgets laid out by `PageLayout`, each in a card (a single widget gets the whole screen).
struct PageView: View {
    let page: PageInfo

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let widgets = page.visibleWidgets
            let sizes = WidgetSize.sizes(for: page.layout)
            let slot = { (i: Int) -> AnyView in
                AnyView(Card(kind: widgets.indices.contains(i) ? widgets[i] : nil, size: sizes[i]))
            }
            Group {
                switch page.layout {
                case .single:
                    if let kind = widgets.first { WidgetView(kind: kind).environment(\.widgetSize, .full) }
                case .split:
                    let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
                    layout { slot(0); slot(1) }
                case .trio:
                    if landscape {
                        HStack(spacing: 12) { slot(0); VStack(spacing: 12) { slot(1); slot(2) } }
                    } else {
                        VStack(spacing: 12) { slot(0); HStack(spacing: 12) { slot(1); slot(2) } }
                    }
                case .grid:
                    VStack(spacing: 12) {
                        HStack(spacing: 12) { slot(0); slot(1) }
                        HStack(spacing: 12) { slot(2); slot(3) }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Multi-widget pages leave room for the connection badge and the page dots.
        .padding(.vertical, page.layout == .single ? 0 : 30)
    }
}

private struct Card: View {
    let kind: WidgetKind?
    let size: WidgetSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.07))
            if let kind {
                WidgetView(kind: kind)
                    .environment(\.widgetSize, size)
                    .padding(14)
            } else {
                Image(systemName: "plus.square.dashed").font(.title).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct WidgetView: View {
    let kind: WidgetKind

    var body: some View {
        switch kind {
        case .music: MusicPage()
        case .monitor: MonitorPage()
        case .calendar: CalendarPage()
        case .reminders: RemindersPage()
        case .notes: NotesPage()
        case .launcher: LauncherPage()
        case .weather: WeatherPage()
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
            content.padding(.horizontal, 20).padding(.vertical, 36)
        } else {
            content
        }
    }
}
