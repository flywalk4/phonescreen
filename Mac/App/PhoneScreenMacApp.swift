import PhoneScreenKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()
    @MainActor private var arrangementWindow: NSWindow?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `--snapshot <file.png>`: render the arrangement editor offscreen and quit (visual checks without screen recording).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let renderer = ImageRenderer(content: PagesEditor().environmentObject(model).frame(width: 760, height: 520)
                .background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
            exit(0)
        }
        #endif
        model.start()
        // First run (or --arrangement): show where the phone is, so the user can place it right away.
        if !model.isArrangementConfigured || CommandLine.arguments.contains("--arrangement") {
            showSettings(.arrangement)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--pages") { showSettings(.pages) }
        #endif
    }

    @MainActor func showSettings(_ tab: AppModel.SettingsTab) {
        model.settingsTab = tab
        if arrangementWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
            window.title = "Настройки PhoneScreen"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 760, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            arrangementWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        arrangementWindow?.makeKeyAndOrderFront(nil)
    }
}

@main
struct PhoneScreenMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(showSettings: { delegate.showSettings($0) }).environmentObject(delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.status.active == nil ? "iphone.slash" : "iphone")
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    let showSettings: (AppModel.SettingsTab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connection
            Divider()
            Picker("Страница", selection: Binding(get: { model.currentPage }, set: { model.show(page: $0) })) {
                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    Text(page.title).tag(index)
                }
            }
            .pickerStyle(.menu)
            if let track = model.nowPlaying {
                Text("\(track.title) — \(track.artist)").font(.caption).lineLimit(1)
            }
            pointerSection
            Text("⌃⌥← / ⌃⌥→ — листать, ⌃⌥1…9 — страница").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Button("Страницы и виджеты…") { showSettings(.pages) }
            Button("Расположение iPhone…") { showSettings(.arrangement) }
            Button("Выйти") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder private var pointerSection: some View {
        if !model.hasAccessibility {
            VStack(alignment: .leading, spacing: 6) {
                Label("Нужен доступ «Универсальный доступ», чтобы уводить курсор на iPhone", systemImage: "cursorarrow.motionlines")
                    .font(.caption)
                Button("Разрешить…") { model.requestAccessibility() }
            }
        } else if model.isPointerOnPhone {
            Label(model.isTypingOnPhone
                  ? "Клавиатура печатает на iPhone — Esc закончит ввод"
                  : "Курсор на iPhone — Esc или ⌃⌥⌘P вернут его",
                  systemImage: model.isTypingOnPhone ? "keyboard" : "cursorarrow.rays")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Толкните курсор за край экрана (\(model.arrangement.edge.title.lowercased())), чтобы перейти на iPhone",
                  systemImage: "cursorarrow.motionlines")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var connection: some View {
        if let active = model.status.active {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.status.peerName ?? "iPhone", systemImage: "iphone").font(.headline)
                HStack {
                    Text("Канал: \(active.label)")
                    if let rtt = model.status.rtt {
                        Text(String(format: "· RTT %.1f мс", rtt * 1000)).monospacedDigit()
                    }
                }
                .font(.caption)
                if model.status.available.count > 1 {
                    Text("Доступно: " + model.status.available.map(\.label).joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Label("Ищу iPhone… (USB, Wi-Fi, Wi-Fi P2P)", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
        }
    }
}
