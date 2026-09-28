import PhoneScreenKit
import SwiftUI

/// Apps running on the Mac, like the right side of the Dock: tap to switch to one, long-press to hide or quit it.
/// Icons keep their places (launch order), so a tap lands on the same app every time.
struct AppsPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size
    @State private var flashed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Программы", symbol: "macwindow.on.rectangle",
                         subtitle: model.runningApps.isEmpty ? nil : "\(model.runningApps.count) открыто")
            if model.runningApps.isEmpty {
                Spacer()
                Text("Нет связи с Mac").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size == .full ? 76 : 46), spacing: size == .full ? 12 : 8)],
                              spacing: size == .full ? 16 : 10) {
                        ForEach(model.runningApps) { app in
                            AppTile(app: app, icon: model.appIcons[app.id], flashed: flashed == app.id, compact: size != .full)
                                .contentShape(Rectangle())
                                .onTapGesture { activate(app) }
                                .pointerTarget { activate(app) }
                                .contextMenu {
                                    Button { activate(app) } label: { Label("Открыть", systemImage: "arrow.up.forward.app") }
                                    Button { model.appAction(app, .hide) } label: { Label("Скрыть", systemImage: "eye.slash") }
                                    Button(role: .destructive) { model.appAction(app, .quit) } label: { Label("Завершить", systemImage: "xmark.circle") }
                                }
                        }
                    }
                    .padding(.vertical, 4) // room for the active ring
                }
                .pointerScrollable()
            }
        }
        .widgetPadding()
    }

    private func activate(_ app: RunningApp) {
        model.appAction(app, .activate)
        withAnimation(.snappy(duration: 0.15)) { flashed = app.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { if flashed == app.id { flashed = nil } } }
    }
}

private struct AppTile: View {
    let app: RunningApp
    let icon: UIImage?
    let flashed: Bool
    let compact: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let icon {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else if theme.style == .ascii {
                    AsciiFrame(color: theme.secondaryText)
                    Text(String(app.name.prefix(1))).font(compact ? .body : .title2).foregroundStyle(theme.text)
                } else {
                    // No icon over Bluetooth: the app's initial on a plain tile.
                    RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.35).gradient)
                    Text(String(app.name.prefix(1))).font((compact ? Font.body : .title2).weight(.semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: compact ? 40 : 58, height: compact ? 40 : 58)
            .opacity(app.hidden ? 0.45 : 1)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: compact ? 11 : 16).stroke(theme.accent, lineWidth: app.active ? 2.5 : 0))
            .scaleEffect(flashed ? 0.88 : 1)
            if !compact {
                Text(app.name).font(.caption2.weight(app.active ? .semibold : .regular)).lineLimit(2)
                    .multilineTextAlignment(.center).frame(height: 28, alignment: .top)
            }
        }
        .animation(.snappy(duration: 0.2), value: app.active)
    }
}
