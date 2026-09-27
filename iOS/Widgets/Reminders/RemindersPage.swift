import EventKit
import SwiftUI

/// Reminders straight from EventKit (iCloud-synced with the Mac): pick a list, tick items off, add new ones.
@MainActor
final class RemindersModel: ObservableObject {
    @Published private(set) var lists: [EKCalendar] = []
    @Published private(set) var items: [EKReminder] = []
    /// Ticked in this session; kept on screen briefly with a strike-through before they disappear.
    @Published private(set) var justCompleted: Set<String> = []
    @Published var selectedListID: String? {
        didSet { UserDefaults.standard.set(selectedListID, forKey: "remindersList"); reload() }
    }

    private let kit = EventKitStore.shared

    init() {
        selectedListID = UserDefaults.standard.string(forKey: "remindersList")
    }

    func reload() {
        guard kit.remindersAccess == .fullAccess else { return }
        lists = kit.store.calendars(for: .reminder).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        if selectedListID == nil || !lists.contains(where: { $0.calendarIdentifier == selectedListID }) {
            selectedListID = kit.store.defaultCalendarForNewReminders()?.calendarIdentifier ?? lists.first?.calendarIdentifier
            return // didSet reloads
        }
        let calendars = lists.filter { $0.calendarIdentifier == selectedListID }
        let predicate = kit.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        kit.store.fetchReminders(matching: predicate) { [weak self] reminders in
            let sorted = (reminders ?? []).sorted(by: Self.order)
            DispatchQueue.main.async {
                guard let self else { return }
                // Keep just-ticked items visible until their fade-out.
                let kept = self.items.filter { self.justCompleted.contains($0.calendarItemIdentifier) }
                self.items = sorted + kept.filter { k in !sorted.contains { $0.calendarItemIdentifier == k.calendarItemIdentifier } }
            }
        }
    }

    func toggle(_ reminder: EKReminder) {
        reminder.isCompleted.toggle()
        try? kit.store.save(reminder, commit: true)
        let id = reminder.calendarItemIdentifier
        if reminder.isCompleted {
            justCompleted.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.justCompleted.contains(id) else { return }
                withAnimation { self.justCompleted.remove(id); self.items.removeAll { $0.calendarItemIdentifier == id && $0.isCompleted } }
            }
        } else {
            justCompleted.remove(id)
        }
        objectWillChange.send()
    }

    func add(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let list = lists.first(where: { $0.calendarIdentifier == selectedListID }) else { return }
        let reminder = EKReminder(eventStore: kit.store)
        reminder.title = trimmed
        reminder.calendar = list
        try? kit.store.save(reminder, commit: true)
        reload()
    }

    /// Overdue and dated first (earliest due), then undated by creation.
    nonisolated private static func order(_ a: EKReminder, _ b: EKReminder) -> Bool {
        let da = a.dueDateComponents?.date, db = b.dueDateComponents?.date
        switch (da, db) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
        }
    }
}

struct RemindersPage: View {
    @Environment(\.widgetSize) private var size
    @StateObject private var model = RemindersModel()
    @ObservedObject private var kit = EventKitStore.shared
    @State private var draft = ""
    @FocusState private var adding: Bool

    var body: some View {
        Group {
            if kit.remindersAccess == .fullAccess {
                content
            } else {
                AccessPrompt(symbol: "checklist", title: "Напоминания", status: kit.remindersAccess) {
                    await kit.requestReminders()
                    model.reload()
                }
            }
        }
        .onAppear { model.reload() }
        .onChange(of: kit.changeTick) { model.reload() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Напоминания", symbol: "checklist",
                         subtitle: model.items.isEmpty ? "Всё сделано" : "\(model.items.filter { !$0.isCompleted }.count) осталось")
            if size == .full { listChips }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.items, id: \.calendarItemIdentifier) { reminder in
                        ReminderRow(reminder: reminder,
                                    color: Color(cgColor: reminder.calendar.cgColor),
                                    done: reminder.isCompleted) { model.toggle(reminder) }
                    }
                }
            }
            .pointerScrollable()
            if size != .small { addField }
        }
        .widgetPadding()
    }

    private var listChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.lists, id: \.calendarIdentifier) { list in
                    let selected = list.calendarIdentifier == model.selectedListID
                    Text(list.title)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(selected ? Color(cgColor: list.cgColor) : Color.primary.opacity(0.08)))
                        .onTapGesture { model.selectedListID = list.calendarIdentifier }
                        .pointerTarget { model.selectedListID = list.calendarIdentifier }
                }
            }
        }
    }

    private var addField: some View {
        HStack {
            Glyph(systemName: "plus.circle.fill").foregroundStyle(.secondary)
            TextField("Новое напоминание", text: $draft)
                .focused($adding)
                .submitLabel(.done)
                .onSubmit {
                    model.add(draft)
                    draft = ""
                    adding = true // keep typing the next one
                }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(adding ? 0.12 : 0.06)))
        .pointerTarget(highlight: false) { adding = true }
    }
}

private struct ReminderRow: View {
    let reminder: EKReminder
    let color: Color
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Glyph(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? color : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
                .pointerTarget(action: toggle)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title ?? "")
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                if let due = reminder.dueDateComponents?.date {
                    Text(due.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(due < Date() && !done ? .red : .secondary)
                }
            }
            Spacer()
            if reminder.priority > 0 && reminder.priority <= 4 {
                Glyph(systemName: "exclamationmark").foregroundStyle(.orange).font(.caption.weight(.bold))
            }
        }
        .padding(.vertical, 8)
        .animation(.snappy, value: done)
    }
}

/// Shared title row for widget pages.
struct WidgetHeader: View {
    let title: String
    let symbol: String
    var subtitle: String?
    @Environment(\.widgetSize) private var size

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label { Text(title) } icon: { Glyph(symbol) }
                .font(size == .full ? .title2.weight(.bold) : .subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let subtitle, size != .small {
                Text(subtitle).font(size == .full ? .subheadline : .caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
