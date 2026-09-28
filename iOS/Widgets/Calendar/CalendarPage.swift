import EventKit
import SwiftUI

/// Today's agenda (and the start of tomorrow) straight from EventKit, with a live "now" line and a countdown
/// to the next meeting.
@MainActor
final class CalendarModel: ObservableObject {
    @Published private(set) var today: [EKEvent] = []
    @Published private(set) var tomorrow: [EKEvent] = []

    private let kit = EventKitStore.shared

    func reload() {
        guard kit.eventsAccess == .fullAccess else { return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let mid = cal.date(byAdding: .day, value: 1, to: start)!
        let end = cal.date(byAdding: .day, value: 2, to: start)!
        let predicate = kit.store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = kit.store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        today = events.filter { $0.startDate < mid && $0.endDate > start }
        tomorrow = Array(events.filter { $0.startDate >= mid }.prefix(4))
    }
}

struct CalendarPage: View {
    @Environment(\.widgetSize) private var size
    @StateObject private var model = CalendarModel()
    @ObservedObject private var kit = EventKitStore.shared

    var body: some View {
        Group {
            if kit.eventsAccess == .fullAccess {
                TimelineView(.everyMinute) { context in
                    if size == .full {
                        GeometryReader { geo in content(now: context.date, tall: geo.size.height > geo.size.width) }
                    } else {
                        compact(now: context.date)
                    }
                }
            } else {
                AccessPrompt(symbol: "calendar", title: "Календарь", status: kit.eventsAccess) {
                    await kit.requestEvents()
                    model.reload()
                }
            }
        }
        .onAppear { model.reload() }
        .onChange(of: kit.changeTick) { model.reload() }
    }

    /// Card version: what's next today, compact rows.
    private func compact(now: Date) -> some View {
        let upcoming = model.today.filter { $0.isAllDay || $0.endDate > now }
        return VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: now.formatted(.dateTime.weekday(.abbreviated).day()).capitalizedFirst, symbol: "calendar")
            if upcoming.isEmpty {
                Text(model.tomorrow.isEmpty ? "Свободный день" : "Сегодня всё. Завтра: \(model.tomorrow[0].title ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                MonthGrid(now: now, compact: true).frame(maxHeight: .infinity, alignment: .center)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(upcoming, id: \.eventIdentifier) { event in
                        let ongoing = !event.isAllDay && event.startDate <= now
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.title ?? "").font(.caption.weight(ongoing ? .bold : .medium)).lineLimit(1)
                                Text(event.isAllDay ? "весь день" : ongoing ? "сейчас"
                                     : event.startDate.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2.monospacedDigit()).foregroundStyle(ongoing ? .green : .secondary)
                            }
                        }
                    }
                }
            }
            .pointerScrollable()
        }
    }

    private func content(now: Date, tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WidgetHeader(title: now.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalizedFirst,
                         symbol: "calendar")
            if let next = model.today.first(where: { !$0.isAllDay && $0.startDate > now }) {
                NextUp(event: next, now: now)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let allDay = model.today.filter(\.isAllDay)
                    ForEach(allDay, id: \.eventIdentifier) { EventRow(event: $0, now: now) }
                    let timed = model.today.filter { !$0.isAllDay }
                    if timed.isEmpty && allDay.isEmpty {
                        Label("Сегодня встреч нет — свободный день", systemImage: "sun.max")
                            .foregroundStyle(.secondary).padding(.vertical, 8)
                        MonthGrid(now: now, compact: false, roomy: tall)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
                    }
                    ForEach(Array(timed.enumerated()), id: \.element.eventIdentifier) { index, event in
                        // The "now" line sits before the first event that hasn't started yet.
                        if event.startDate > now, index == 0 || timed[index - 1].startDate <= now {
                            NowLine(now: now)
                        }
                        EventRow(event: event, now: now)
                    }
                    if let last = timed.last, last.startDate <= now { NowLine(now: now) }
                    if !model.tomorrow.isEmpty {
                        Text("Завтра").font(.headline).foregroundStyle(.secondary).padding(.top, 12)
                        ForEach(model.tomorrow, id: \.eventIdentifier) { EventRow(event: $0, now: now) }
                    }
                }
            }
            .pointerScrollable()
        }
        .widgetPadding()
    }
}

private struct NextUp: View {
    let event: EKEvent
    let now: Date

    var body: some View {
        let minutes = Int(event.startDate.timeIntervalSince(now) / 60)
        HStack {
            Glyph(systemName: "bell.fill").foregroundStyle(.orange)
            Text(minutes < 60 ? "Через \(minutes) мин" : "В \(event.startDate.formatted(date: .omitted, time: .shortened))")
                .font(.subheadline.weight(.semibold))
            Text(event.title ?? "").font(.subheadline).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(minutes < 15 ? 0.25 : 0.12)))
    }
}

private struct EventRow: View {
    let event: EKEvent
    let now: Date

    var body: some View {
        let ongoing = !event.isAllDay && event.startDate <= now && event.endDate > now
        let past = event.endDate <= now
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "Без названия").font(.body.weight(ongoing ? .semibold : .regular)).lineLimit(2)
                Text(event.isAllDay ? "Весь день"
                     : "\(event.startDate.formatted(date: .omitted, time: .shortened)) – \(event.endDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let location = event.location, !location.isEmpty {
                    Label { Text(location) } icon: { Glyph("mappin") }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if ongoing { Text("сейчас").font(.caption.weight(.bold)).foregroundStyle(.green) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(ongoing ? 0.12 : 0.05)))
        .opacity(past ? 0.45 : 1)
    }
}

private struct NowLine: View {
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(now.formatted(date: .omitted, time: .shortened)).font(.caption2.monospacedDigit().weight(.bold))
            Rectangle().frame(height: 1.5)
        }
        .foregroundStyle(.red)
        .padding(.vertical, 2)
    }
}

/// This month as a grid, weeks from Monday, today in the accent colour, weekends dimmed.
struct MonthGrid: View {
    let now: Date
    var compact = false
    /// Big rows for an upright whole page; lying sideways the grid must fit the short height.
    var roomy = true
    @Environment(\.theme) private var theme

    var body: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ru_RU")
        cal.firstWeekday = 2
        let month = cal.dateInterval(of: .month, for: now)!
        let days = cal.range(of: .day, in: .month, for: now)!.count
        let lead = (cal.component(.weekday, from: month.start) - cal.firstWeekday + 7) % 7
        let today = cal.component(.day, from: now)
        let cells = Array(repeating: 0, count: lead) + Array(1...days)
        let symbols = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        let font: Font = compact ? .caption : roomy ? .title3 : .callout
        return VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            if !compact {
                Text(now.formatted(.dateTime.month(.wide).year()).capitalizedFirst).font(.headline)
            }
            Grid(horizontalSpacing: 0, verticalSpacing: compact ? 2 : roomy ? 8 : 2) {
                GridRow {
                    ForEach(symbols.indices, id: \.self) { i in
                        Text(compact ? String(symbols[i].prefix(1)) : symbols[i])
                            .font(font.weight(.semibold)).foregroundStyle(i >= 5 ? .tertiary : .secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(cells.count + 6) / 7, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { d in
                            let i = week * 7 + d
                            let day = i < cells.count ? cells[i] : 0
                            Text(day == 0 ? "" : "\(day)")
                                .font(font.monospacedDigit().weight(day == today ? .bold : .regular))
                                .foregroundStyle(day == today ? AnyShapeStyle(.white) : d >= 5 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, compact ? 4 : roomy ? 12 : 2)
                                .background {
                                    if day == today { Circle().fill(theme.accent).aspectRatio(1, contentMode: .fit) }
                                }
                                .opacity(day != 0 && day < today ? 0.5 : 1)
                        }
                    }
                }
            }
        }
    }
}
