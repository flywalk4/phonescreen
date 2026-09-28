import EventKit
import QwoviKit
import SwiftUI

/// One EventKit store for Reminders and Calendar — the same data as on the Mac through iCloud,
/// read straight on the phone. Publishes a tick whenever anything changes (on any device).
@MainActor
final class EventKitStore: ObservableObject {
    static let shared = EventKitStore()

    let store = EKEventStore()
    @Published private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var eventsAccess = EKEventStore.authorizationStatus(for: .event)
    /// Bumped on `EKEventStoreChanged`; models observe it to refetch.
    @Published private(set) var changeTick = 0

    private init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changeTick += 1 }
        }
    }

    func requestReminders() async {
        _ = try? await store.requestFullAccessToReminders()
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestEvents() async {
        _ = try? await store.requestFullAccessToEvents()
        eventsAccess = EKEventStore.authorizationStatus(for: .event)
    }
}

/// Shown instead of a widget until the user grants access.
struct AccessPrompt: View {
    let symbol: String
    let title: String
    let status: EKAuthorizationStatus
    let request: () async -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if status == .denied || status == .restricted {
                Text("Access denied. Allow it in Settings → Qwovi.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else {
                Button("Allow access") { Task { await request() } }
                    .buttonStyle(PillButtonStyle(fill: theme.accent))
                    .pointerTarget { Task { await request() } }
            }
        }
        .padding(24)
    }
}
