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
                AnyView(Card(ref: widgets.indices.contains(i) ? widgets[i] : nil, size: sizes[i]))
            }
            Group {
                switch page.layout {
                case .single:
                    if let ref = widgets.first { WidgetView(ref: ref).environment(\.widgetSize, .full) }
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
            .debugLayout("page", .red)
        }
        // Multi-widget pages leave room for the connection badge and the page dots.
        .padding(.vertical, page.layout == .single ? 0 : 30)
    }
}

private struct Card: View {
    let ref: WidgetRef?
    let size: WidgetSize

    var body: some View {
        ZStack {
            Color.clear
            if let ref {
                WidgetView(ref: ref)
                    .environment(\.widgetSize, size)
                    .padding(14)
            } else {
                Image(systemName: "plus.square.dashed").font(.title).foregroundStyle(.tertiary)
            }
        }
        .themedCard()
        .debugLayout("card", .yellow)
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
            content.padding(.horizontal, 20).padding(.vertical, 36)
        } else {
            content
        }
    }
}
