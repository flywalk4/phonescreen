import PhoneScreenKit
import SwiftUI
import UIKit

@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var status = ChannelPool.Status(active: nil, available: [])
    @Published private(set) var pages: [PageInfo] = []
    @Published var currentPage = 0
    /// All pages as tiles (pinch in on the phone or the trackpad).
    @Published var overview = false
    @Published var nowPlaying: NowPlaying? {
        didSet {
            // Decode the cover once per change, not on every render of the music page.
            if nowPlaying?.artwork != oldValue?.artwork { artwork = nowPlaying?.artwork.flatMap(UIImage.init(data:)) }
        }
    }
    @Published private(set) var artwork: UIImage?
    @Published private(set) var musicQueue: MusicQueue?
    @Published var audio: AudioState?
    @Published private(set) var notes: [NoteSummary]?
    @Published private(set) var noteBodies: [String: String] = [:]
    @Published private(set) var launcher: [LauncherItem] = []
    /// Installed JavaScript widgets, as last rendered on the Mac.
    @Published private(set) var customWidgets: [String: CustomWidgetState] = [:]
    var customNames: [String: String] { customWidgets.mapValues(\.name) }
    @Published private(set) var stats: SystemStats?
    @Published private(set) var statsHistory: [SystemStats] = []
    /// The look chosen on the Mac; kept so the phone looks right before it reconnects.
    @Published private(set) var theme: Theme = PhoneModel.savedTheme() {
        didSet {
            if let data = try? JSONEncoder().encode(theme) { UserDefaults.standard.set(data, forKey: "theme") }
        }
    }
    /// How the phone lies next to the Mac. Remembered, so the UI is right before the Mac reconnects.
    @Published private(set) var layout: PhoneLayout = PhoneModel.savedLayout() {
        didSet {
            if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "layout") }
        }
    }

    let pointer = PointerController()
    let keyboard = KeyboardBridge()
    private let pool: ChannelPool
    private let listener: Listener
    private let bluetooth: BLEPeripheral
    /// Set while applying a page change that came from the Mac, so it is not echoed back.
    private var applyingRemotePage = false

    init() {
        let sessionId = UUID()
        let name = UIDevice.current.name
        let bounds = UIScreen.main.bounds
        let screen = ScreenInfo(width: bounds.width, height: bounds.height, scale: UIScreen.main.scale)
        let pool = ChannelPool { transport in
            Hello(role: .phone, name: name, sessionId: sessionId, screen: screen, lowBandwidth: transport == .bluetooth)
        }
        self.pool = pool
        listener = Listener(name: name) { pool.add($0) }
        bluetooth = BLEPeripheral(name: name) { pool.add($0) }
    }

    func start() {
        pointer.onExit = { [weak self] along in
            self?.keyboard.macInputActive = false
            self?.pool.send(.pointerExit(along: along))
        }
        pointer.onEmptyClick = { [weak self] in self?.keyboard.endEditing() }
        keyboard.onFocusChange = { [weak self] focused in self?.pool.send(.textFocus(focused)) }
        pointer.onSwipeEnd = { [weak self] step in self?.finishSwipe(step) }
        pointer.onPinch = { [weak self] pinchedIn in
            guard let self else { return }
            if pinchedIn { self.setOverview(true) }
            else if self.overview, !self.pointer.activateHovered() { self.setOverview(false) }
        }
        pointer.onSmartZoom = { [weak self] in
            guard let self else { return }
            if self.overview, self.pointer.activateHovered() { return }
            self.setOverview(!self.overview)
        }
        pool.onMessage = { [weak self] in self?.handle($0) }
        pool.onStatus = { [weak self] in self?.status = $0 }
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--demo") { listener.start(); bluetooth.start() }
        #else
        listener.start()
        bluetooth.start()
        #endif
        #if DEBUG
        // `--demo [--page N]`: all pages without a Mac, for layout checks in the Simulator.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") {
            pages = [PageInfo(id: "grid", layout: .grid, builtins: [.music, .weather, .calendar, .monitor]),
                     PageInfo(id: "trio", layout: .trio, builtins: [.music, .notes, .launcher]),
                     PageInfo(id: "split", layout: .split, builtins: [.reminders, .weather])]
                + WidgetKind.allCases.map { PageInfo($0) }
            if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let n = Int(args[i + 1]) { currentPage = n }
            if args.contains("--overview") { overview = true }
            let t = { (s: String, st: String?) in WidgetNode.text(s, style: st, color: nil, lines: nil, align: nil) }
            let row = { (c: String, v: String) in WidgetNode.hstack(spacing: nil, align: nil, children: [t(c, "headline"), .spacer, t(v, nil)]) }
            customWidgets["com.flywalk4.rates"] = CustomWidgetState(
                id: "com.flywalk4.rates", name: "Курсы валют", symbol: "dollarsign.arrow.circlepath",
                views: [.full: .vstack(spacing: 14, align: "leading", children: [
                            .hstack(spacing: 8, align: nil, children: [.symbol("dollarsign.arrow.circlepath", color: "green", size: nil),
                                                                       t("Курсы валют", "title2"), .spacer,
                                                                       .button(title: "Обновить", symbol: "arrow.clockwise", action: "reload")]),
                            t("1 USD = 84.27 RUB", "largeTitle"),
                            .text("▲ 0.35 за день", style: "headline", color: "green", lines: nil, align: nil),
                            .chart(values: [83.1, 83.4, 83.9, 83.7, 84.0, 84.27], color: "green"), .divider,
                            .vstack(spacing: 10, align: "leading", children: [row("USD", "84.27 RUB"), row("EUR", "96.08 RUB"), row("CNY", "12.63 RUB")])]),
                        .small: .vstack(spacing: 4, align: "leading", children: [
                            .text("USD", style: "caption", color: "secondary", lines: nil, align: nil), t("84.27", "title"),
                            .text("▲ 0.35", style: "caption2", color: "green", lines: nil, align: nil)])],
                error: nil, updated: Date())
            pages.insert(PageInfo(id: "custom", layout: .grid, widgets: [.custom("com.flywalk4.rates"), .builtin(.weather), .builtin(.music), .builtin(.monitor)]), at: 0)
            pages.insert(PageInfo(id: "custom-full", layout: .single, widgets: [.custom("com.flywalk4.rates")]), at: 0)
            // `--demo-widget <file>`: output of `PhoneScreen --widget-test` (Mac), shown as a real widget.
            if let i = args.firstIndex(of: "--demo-widget"), i + 1 < args.count,
               let data = FileManager.default.contents(atPath: args[i + 1]),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = json["id"] as? String, let rawViews = json["views"] as? [String: Any] {
                var views: [WidgetSize: WidgetNode] = [:]
                for (key, value) in rawViews {
                    if let size = WidgetSize(rawValue: key), let d = try? JSONSerialization.data(withJSONObject: value),
                       let node = try? JSONDecoder().decode(WidgetNode.self, from: d) { views[size] = node }
                }
                customWidgets[id] = CustomWidgetState(id: id, name: id, symbol: "sparkles", views: views, error: nil, updated: Date())
                pages.insert(PageInfo(id: "dw-trio", layout: .trio, widgets: [.custom(id), .custom(id), .builtin(.weather)]), at: 0)
                pages.insert(PageInfo(id: "dw-full", layout: .single, widgets: [.custom(id)]), at: 0)
            }
            musicQueue = MusicQueue(tracks: [QueueTrack(title: "Звезда по имени Солнце", artist: "Кино", duration: 225),
                                             QueueTrack(title: "Пачка сигарет", artist: "Кино", duration: 268)], note: "Далее в плейлисте")
            audio = AudioState(systemVolume: 0.45, muted: false,
                               airPlay: [AirPlayDevice(name: "Колонки MacBook Pro", kind: "computer", selected: true),
                                         AirPlayDevice(name: "HomePod", kind: "HomePod", selected: false)])
            nowPlaying = NowPlaying(title: "Тем кто с нами", artist: "Кино", album: "Группа крови", duration: 240, elapsed: 70, playing: true)
            nowPlaying?.player = "Music"; nowPlaying?.volume = 0.7; nowPlaying?.shuffle = true; nowPlaying?.repeatMode = "all"; nowPlaying?.liked = true
            notes = [NoteSummary(id: "1", title: "Покупки", snippet: "молоко, хлеб, кофе", folder: "Заметки", modified: Date().addingTimeInterval(-600)),
                     NoteSummary(id: "2", title: "Идеи для PhoneScreen", snippet: "дашборд 2×2, клавиатура на телефон", folder: "Проекты", modified: Date().addingTimeInterval(-86_400))]
            launcher = [LauncherItem(id: "sys:lock", title: "Блокировка", kind: .system, symbol: "lock.fill"),
                        LauncherItem(id: "sys:darkMode", title: "Тёмная тема", kind: .system, symbol: "circle.lefthalf.filled"),
                        LauncherItem(id: "shortcut:x", title: "Фокус: работа", kind: .shortcut, symbol: "square.stack.3d.up.fill")]
            let sample = SystemStats(cpu: 0.35, cpuPerCore: [0.2, 0.6, 0.4, 0.1, 0.8, 0.3, 0.2, 0.5], gpu: 0.2,
                                     memoryUsed: 11_000_000_000, memoryTotal: 16_000_000_000, netInBytesPerSec: 250_000, netOutBytesPerSec: 40_000)
            stats = sample
            statsHistory = (0..<60).map { i in var s = sample; s.cpu = 0.3 + 0.25 * sin(Double(i) / 6); s.gpu = 0.2 + 0.1 * cos(Double(i) / 5); return s }
            // `--demo-bundle <file>`: catalog widgets with sample data (`node scripts/widget-dev.mjs bundle`), their pages
            // and a theme — for screenshots of the real UI without a Mac. `--demo-theme <builtin id>` picks a built-in theme.
            if let i = args.firstIndex(of: "--demo-bundle"), i + 1 < args.count { loadDemoBundle(args[i + 1]) }
            if let i = args.firstIndex(of: "--demo-theme"), i + 1 < args.count,
               let builtin = Theme.builtin.first(where: { $0.id == args[i + 1] }) { theme = builtin }
            if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let n = Int(args[i + 1]), pages.indices.contains(n) { currentPage = n }
        }
        #endif
    }

    #if DEBUG
    /// `{ "widgets": [{ "id", "name", "symbol", "view": view.json, "data": refresh() result }],
    ///    "pages": [{ "layout": "grid", "widgets": ["custom:<id>", "music", …] }], "theme": theme.json }` — every part optional.
    /// Views are resolved here with the same `WidgetTemplate` the Mac uses.
    private func loadDemoBundle(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for widget in json["widgets"] as? [[String: Any]] ?? [] {
            guard let id = widget["id"] as? String, let view = widget["view"] as? [String: Any] else { continue }
            let payload = widget["data"] ?? NSNull()
            var views: [WidgetSize: WidgetNode] = [:]
            for size in [WidgetSize.full, .medium, .small] {
                if let template = view[size.rawValue], let node = try? WidgetTemplate.resolve(template, data: payload) { views[size] = node }
            }
            customWidgets[id] = CustomWidgetState(id: id, name: widget["name"] as? String ?? id,
                                                  symbol: widget["symbol"] as? String ?? "puzzlepiece.extension",
                                                  views: views, error: nil, updated: Date())
        }
        if let raw = json["pages"] as? [[String: Any]] {
            let list = raw.enumerated().compactMap { index, page -> PageInfo? in
                guard let layout = (page["layout"] as? String).flatMap(PageLayout.init(rawValue:)) else { return nil }
                let refs = (page["widgets"] as? [String] ?? []).compactMap(WidgetRef.init(rawValue:))
                return PageInfo(id: "demo-\(index)", layout: layout, widgets: refs)
            }
            if !list.isEmpty { pages = list; currentPage = 0 }
        }
        if let raw = json["theme"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode(Theme.self, from: data) { theme = decoded }
    }
    #endif

    /// iOS kills listening sockets in the background; re-arm on every foreground.
    func sceneBecameActive() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }
        #endif
        listener.start()
    }

    func userChangedPage(to index: Int) {
        keyboard.endEditing() // a field on the page we left must not keep focus (or the keyboard)
        requestDataIfNeeded(for: index)
        guard !applyingRemotePage else { return }
        pool.send(.pageChanged(index: index))
    }

    /// Notes are fetched through the Mac only while their page is on screen (asking Notes launches the app).
    private func requestDataIfNeeded(for index: Int) {
        guard pages.indices.contains(index) else { return }
        for kind in pages[index].visibleWidgets.compactMap(\.builtin) where kind == .notes || kind == .launcher { refresh(kind) }
    }

    func perform(_ action: MediaAction) {
        pool.send(.mediaAction(action))
    }

    func music(_ command: MusicCommand) {
        // Optimistic: sliders must not jump back while the Mac catches up.
        switch command {
        case .setPlayerVolume(let v): nowPlaying?.volume = v
        case .setSystemVolume(let v): audio?.systemVolume = v
        case .seek(let t): nowPlaying?.elapsed = t; nowPlaying?.timestamp = Date()
        default: break
        }
        switch command {
        case .setPlayerVolume, .setSystemVolume, .seek:
            // Sliders fire 60–120 times a second and each value is an AppleScript call on the Mac:
            // send at most every 80 ms, and always the latest value.
            throttledMusic = command
            guard !musicThrottleScheduled else { return }
            musicThrottleScheduled = true
            if Date().timeIntervalSince(lastThrottledSend) > 0.08 { flushThrottledMusic() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flushThrottledMusic() }
        default:
            pool.send(.music(command))
        }
    }

    private var throttledMusic: MusicCommand?
    private var musicThrottleScheduled = false
    private var lastThrottledSend = Date.distantPast

    private func flushThrottledMusic() {
        musicThrottleScheduled = false
        guard let command = throttledMusic else { return }
        throttledMusic = nil
        lastThrottledSend = Date()
        pool.send(.music(command))
    }

    /// A page showing Mac-provided data appeared: ask for fresh data.
    func refresh(_ kind: WidgetKind) { pool.send(.refresh(kind)) }
    func openNote(_ id: String) { pool.send(.noteRequest(id: id)) }
    func createNote(_ text: String) { pool.send(.noteCreate(text: text)) }
    func showNoteOnMac(_ id: String) { pool.send(.noteShowOnMac(id: id)) }
    func run(_ item: LauncherItem) { pool.send(.command(id: item.id)) }
    func customAction(_ id: String, _ action: String) { pool.send(.customAction(id: id, action: action)) }

    private func handle(_ message: Message) {
        switch message {
        case .pages(let list, let current):
            pages = list
            applyRemotePage(current)
            requestDataIfNeeded(for: currentPage)
        case .setPage(let index):
            applyRemotePage(index)
        case .layout(let value):
            withAnimation(.snappy) { layout = value }
        case .pointerEnter(let along):
            pointer.enter(along: along)
            keyboard.macInputActive = true
            pool.send(.textFocus(keyboard.hasFocus)) // a field may already be focused from before
        case .pointerDelta(let dx, let dy):
            pointer.move(dx: dx, dy: dy)
        case .pointerButton(let button, let down):
            pointer.button(button, down: down)
        case .pointerScroll(let dx, let dy, let phase):
            if !overview { pointer.scroll(dx: dx, dy: dy, phase: phase) }
        case .pointerPinch(let magnification, let phase):
            pointer.pinch(magnification: magnification, phase: phase)
        case .pointerSmartZoom:
            pointer.smartZoom()
        case .pointerExit:
            pointer.hide()
            keyboard.macInputActive = false
        case .keyText(let text):
            keyboard.insert(text)
        case .key(let key):
            keyboard.press(key)
        case .nowPlaying(let value):
            nowPlaying = value
        case .musicQueue(let q):
            musicQueue = q
        case .audio(let a):
            audio = a
        case .notes(let list):
            notes = list
        case .noteBody(let id, let text):
            noteBodies[id] = text
        case .launcher(let items):
            launcher = items
        case .customWidget(let state):
            customWidgets[state.id] = state
        case .customWidgetRemoved(let id):
            customWidgets[id] = nil
        case .theme(let value):
            withAnimation(.easeInOut(duration: 0.35)) { theme = value }
        case .stats(let value):
            stats = value
            statsHistory = Array((statsHistory + [value]).suffix(60))
        default:
            break
        }
    }

    func setOverview(_ on: Bool) {
        guard on != overview else { return }
        if on { keyboard.endEditing() }
        withAnimation(.snappy(duration: 0.35)) { overview = on }
    }

    /// Open a page from the overview.
    func openFromOverview(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        currentPage = index // no animation: the zoom-in is the transition
        setOverview(false)
    }

    /// A trackpad swipe ended: settle on the neighbouring page (or back on this one).
    private func finishSwipe(_ step: Int) {
        let target = min(max(currentPage + step, 0), max(pages.count - 1, 0))
        withAnimation(.snappy(duration: 0.3)) {
            currentPage = target
            pointer.swipe.offset = 0
        }
    }

    private static func savedTheme() -> Theme {
        UserDefaults.standard.data(forKey: "theme").flatMap { try? JSONDecoder().decode(Theme.self, from: $0) } ?? .dark
    }

    private static func savedLayout() -> PhoneLayout {
        UserDefaults.standard.data(forKey: "layout").flatMap { try? JSONDecoder().decode(PhoneLayout.self, from: $0) }
            ?? PhoneLayout(orientation: .portrait, macSide: .left)
    }

    private func applyRemotePage(_ index: Int) {
        guard pages.indices.contains(index), index != currentPage else { return }
        applyingRemotePage = true
        withAnimation(.snappy) { currentPage = index }
        DispatchQueue.main.async { self.applyingRemotePage = false }
    }
}
