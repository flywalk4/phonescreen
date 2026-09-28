import QwoviKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The language is settled first (English by default), before any text is looked up.
    @MainActor let model: AppModel = { AppLanguage.bootstrap(); return AppModel() }()
    @MainActor private var arrangementWindow: NSWindow?
    @MainActor private var onboardingWindow: NSWindow?
    private static let onboardingKey = "onboardingShown"

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `--snapshot-tour <step 0…7> <file.png> [--awake]`: one page of the welcome tour, rendered offscreen
        // (ImageRenderer: unlike cacheDisplay it keeps the blur and the 3D-tilted phone).
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-tour"), i + 2 < CommandLine.arguments.count {
            let step = OnboardingView.Step(rawValue: Int(CommandLine.arguments[i + 1]) ?? 0) ?? .idle
            let file = URL(fileURLWithPath: CommandLine.arguments[i + 2])
            let awake = CommandLine.arguments.contains("--awake")
            // As in the video: a connected phone; `--tour-done` also ticks off the try-it steps.
            model.demoTourLink = "USB"
            if CommandLine.arguments.contains("--tour-done") {
                model.demoTourEvent(.clicked)
                model.demoTourEvent(.touched)
            }
            let delay = Double(ProcessInfo.processInfo.environment["TOUR_DELAY"] ?? "") ?? 1.5
            let root = OnboardingView(step: step, awake: awake) {}.environmentObject(model)
            // Let onAppear/task-driven state settle in a live hosting view first, then render.
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(x: 0, y: 0, width: 940, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let renderer = ImageRenderer(content: OnboardingView(step: step, awake: awake) {}.environmentObject(self.model))
                renderer.scale = 2
                if let cg = renderer.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: file)
                }
                exit(0)
            }
            return
        }
        // `--record-tour <file.mov>`: the tour playing itself through, recorded from its own window (the README video).
        // The window stays behind other windows and the app isn't activated; the phone connects as usual.
        if let i = CommandLine.arguments.firstIndex(of: "--record-tour"), i + 1 < CommandLine.arguments.count {
            let file = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            model.start()
            recordTour(to: file)
            return
        }
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
        // `--snapshot-tab widgets|themes|pages <file.png>`: a settings tab in a real (offscreen) window, native controls
        // included — ImageRenderer leaves pickers and sliders blank.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-tab"), i + 2 < CommandLine.arguments.count {
            model.themes.reload()
            model.widgets.reloadAll()
            let tab = CommandLine.arguments[i + 1]
            // `window-<tab>`: the whole settings window (sidebar included) on that section.
            if tab.hasPrefix("window-") {
                model.settingsTab = ["widgets": .widgets, "themes": .themes, "arrangement": .arrangement][String(tab.dropFirst(7))] ?? .pages
            }
            let root: AnyView = switch tab {
            case "themes": AnyView(ThemesSettings(themes: model.themes))
            case "pages": AnyView(PagesEditor())
            case let t where t.hasPrefix("window-"): AnyView(SettingsView())
            case "menu": AnyView(MenuBarView(showSettings: { _ in }).background(.regularMaterial))
            default: AnyView(WidgetsSettings(widgets: model.widgets))
            }
            let view = NSHostingView(rootView: root.environmentObject(model).frame(width: tab == "menu" ? 340 : tab.hasPrefix("window-") ? 1000 : 760, height: tab == "menu" ? 520 : tab.hasPrefix("window-") ? 680 : tab == "pages" ? 560 : 2300)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = NSRect(x: 0, y: 0, width: tab == "menu" ? 340 : tab.hasPrefix("window-") ? 1000 : 760, height: tab == "menu" ? 520 : tab.hasPrefix("window-") ? 680 : tab == "pages" ? 560 : 2300)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFront(nil)
            let file = URL(fileURLWithPath: CommandLine.arguments[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: file)
                }
                exit(0)
            }
            return
        }
        // `--widget-test <package folder>`: run a widget once headlessly, print the resolved UI (or the error), quit.
        if let i = CommandLine.arguments.firstIndex(of: "--widget-test"), i + 1 < CommandLine.arguments.count {
            WidgetTestRunner.run(folder: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        // `--theme-test <folder or theme.json>`: read a theme the way the app installs it, print it (or the error), quit.
        if let i = CommandLine.arguments.firstIndex(of: "--theme-test"), i + 1 < CommandLine.arguments.count {
            ThemeTestRunner.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--catalog-test"), i + 1 < CommandLine.arguments.count {
            WidgetTestRunner.runCatalog(CommandLine.arguments[i + 1])
            return
        }
        #endif
        model.start()
        // First run (or --onboarding): the welcome tour, which ends in Arrangement if the phone isn't placed yet.
        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) || CommandLine.arguments.contains("--onboarding") {
            showOnboarding()
        } else if !model.isArrangementConfigured || CommandLine.arguments.contains("--arrangement") {
            // Show where the phone is, so the user can place it right away.
            showSettings(.arrangement)
        }
        #if DEBUG
        if CommandLine.arguments.contains("--pages") { showSettings(.pages) }
        if CommandLine.arguments.contains("--widgets") { showSettings(.widgets) }
        if CommandLine.arguments.contains("--themes") { showSettings(.themes) }
        #endif
    }

    #if DEBUG
    @MainActor private func recordTour(to file: URL) {
        let recorder = TourRecorder()
        Task { @MainActor in
            // The video shows a connected phone, whether or not one is around.
            model.demoTourLink = "USB"
            var window: NSWindow?
            let root = OnboardingView(autoplayEnded: {
                Task { @MainActor in
                    await recorder.stop()
                    exit(0)
                }
            }) {}.environmentObject(model)
            let controller = NSHostingController(rootView: root)
            window = NSWindow(contentViewController: controller)
            guard let window else { return }
            // A titled window keeps rendering behind others (a borderless one stops). macOS badges a captured
            // window's title bar with a "being recorded" pill: crop the top 28 pt off the movie.
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: .darkAqua)
            window.setContentSize(NSSize(width: 940, height: 600))
            window.center()
            window.orderBack(nil)
            do {
                try await recorder.start(windowNumber: window.windowNumber, size: window.frame.size, to: file)
            } catch {
                print("record-tour: \(error)")
                exit(1)
            }
        }
    }
    #endif

    @MainActor func showOnboarding() {
        // Once is enough, however it's closed; the menu has it for later.
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        if onboardingWindow == nil {
            // `--onboarding-step N`: open the tour on that step (checks on the real phone without clicking through).
            var step = OnboardingView.Step.idle
            if let i = CommandLine.arguments.firstIndex(of: "--onboarding-step"), i + 1 < CommandLine.arguments.count {
                step = OnboardingView.Step(rawValue: Int(CommandLine.arguments[i + 1]) ?? 0) ?? .idle
            }
            let root = OnboardingView(step: step) { [weak self] in self?.finishOnboarding() }.environmentObject(model)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = "Qwovi"
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    /// "Get started" or "Skip": the phone still needs a place next to the screen.
    @MainActor private func finishOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        if !model.isArrangementConfigured { showSettings(.arrangement) }
    }

    @MainActor func showSettings(_ tab: AppModel.SettingsTab) {
        model.settingsTab = tab
        if arrangementWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
            window.title = String(localized: "Qwovi Settings")
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
struct QwoviMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(showSettings: { delegate.showSettings($0) }, showTour: { delegate.showOnboarding() })
                .environmentObject(delegate.model)
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

/// The menu bar window: status, pages as thumbnails, what's playing, the pointer hint and shortcuts into Settings.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    let showSettings: (AppModel.SettingsTab) -> Void
    var showTour: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pagesStrip
            if let track = model.nowPlaying { nowPlaying(track) }
            pointerSection
            shortcuts
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.peerName ?? "Qwovi").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(model.status.active == nil ? Color.orange : Color.green).frame(width: 7, height: 7)
                    if let active = model.status.active {
                        Text(active.label)
                        if let rtt = model.status.rtt {
                            Text("\(Int((rtt * 1000).rounded())) ms").monospacedDigit().foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("Searching: USB, Wi-Fi, Bluetooth")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Pages

    private var pagesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pages").font(.subheadline.weight(.semibold))
                Spacer()
                Text("⌃⌥← →").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                        PageChip(page: page, index: index, current: index == model.currentPage,
                                 title: page.title(customNames: model.widgets.names)) {
                            model.show(page: index)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Now playing

    private func nowPlaying(_ track: NowPlaying) -> some View {
        HStack(spacing: 10) {
            Group {
                if let data = track.artwork, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: track.playing ? "waveform" : "pause.fill")
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: track.playing)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Pointer

    @ViewBuilder private var pointerSection: some View {
        if !model.hasAccessibility {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.motionlines").foregroundStyle(.orange)
                Text("Allow Accessibility to move the cursor onto the iPhone").font(.caption)
                Spacer()
                Button("Allow") { model.requestAccessibility() }.controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        } else if model.isPointerOnPhone {
            Label(model.isTypingOnPhone ? String(localized: "The keyboard types on the iPhone — Esc stops") : String(localized: "The cursor is on the iPhone — Esc brings it back"),
                  systemImage: model.isTypingOnPhone ? "keyboard" : "cursorarrow.rays")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Push the cursor past the screen's edge (\(model.arrangement.edge.title.lowercased())) and it moves to the iPhone",
                  systemImage: "cursorarrow.motionlines")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ShortcutTile(title: String(localized: "Pages"), symbol: "rectangle.grid.2x2.fill", tint: .blue) { showSettings(.pages) }
            ShortcutTile(title: String(localized: "Widgets"), symbol: "puzzlepiece.extension.fill", tint: .purple) { showSettings(.widgets) }
            ShortcutTile(title: String(localized: "Themes"), symbol: "paintpalette.fill", tint: .pink) { showSettings(.themes) }
            ShortcutTile(title: String(localized: "Arrangement"), symbol: "iphone.gen3", tint: .orange) { showSettings(.arrangement) }
        }
    }

    private var footer: some View {
        HStack {
            Text("⌃⌥1…9 — a page").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Welcome tour") { showTour() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }
}

/// A page in the menu: a tiny drawing of its layout, its number and name; the current one is highlighted.
private struct PageChip: View {
    let page: PageInfo
    let index: Int
    let current: Bool
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                LayoutGlyph(layout: page.layout).frame(width: 30, height: 44)
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                Text(title).font(.caption2).lineLimit(1).frame(width: 64)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(current ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Page \(index + 1): \(title)")
    }
}

/// A big tappable tile into a Settings section.
private struct ShortcutTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
