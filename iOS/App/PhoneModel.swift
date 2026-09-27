import PhoneScreenKit
import SwiftUI
import UIKit

@MainActor
final class PhoneModel: ObservableObject {
    @Published private(set) var status = ChannelPool.Status(active: nil, available: [])
    @Published private(set) var pages: [PageInfo] = []
    @Published var currentPage = 0
    @Published private(set) var nowPlaying: NowPlaying? {
        didSet {
            // Decode the cover once per change, not on every render of the music page.
            if nowPlaying?.artwork != oldValue?.artwork { artwork = nowPlaying?.artwork.flatMap(UIImage.init(data:)) }
        }
    }
    @Published private(set) var artwork: UIImage?
    @Published private(set) var notes: [NoteSummary]?
    @Published private(set) var noteBodies: [String: String] = [:]
    @Published private(set) var launcher: [LauncherItem] = []
    @Published private(set) var stats: SystemStats?
    @Published private(set) var statsHistory: [SystemStats] = []
    /// How the phone lies next to the Mac. Remembered, so the UI is right before the Mac reconnects.
    @Published private(set) var layout: PhoneLayout = PhoneModel.savedLayout() {
        didSet {
            if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "layout") }
        }
    }

    let pointer = PointerController()
    private let pool: ChannelPool
    private let listener: Listener
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
    }

    func start() {
        pointer.onExit = { [weak self] along in self?.pool.send(.pointerExit(along: along)) }
        pointer.onSwipeEnd = { [weak self] step in self?.finishSwipe(step) }
        pool.onMessage = { [weak self] in self?.handle($0) }
        pool.onStatus = { [weak self] in self?.status = $0 }
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--demo") { listener.start() }
        #else
        listener.start()
        #endif
        #if DEBUG
        // `--demo [--page N]`: all pages without a Mac, for layout checks in the Simulator.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo") {
            pages = PageKind.allCases.map { PageInfo(id: $0.rawValue, kind: $0, title: $0.rawValue) }
            if let i = args.firstIndex(of: "--page"), i + 1 < args.count, let n = Int(args[i + 1]) { currentPage = n }
            nowPlaying = NowPlaying(title: "Тем кто с нами", artist: "Кино", album: "Группа крови", duration: 240, elapsed: 70, playing: true)
            notes = [NoteSummary(id: "1", title: "Покупки", snippet: "молоко, хлеб, кофе", folder: "Заметки", modified: Date().addingTimeInterval(-600)),
                     NoteSummary(id: "2", title: "Идеи для PhoneScreen", snippet: "дашборд 2×2, клавиатура на телефон", folder: "Проекты", modified: Date().addingTimeInterval(-86_400))]
            launcher = [LauncherItem(id: "sys:lock", title: "Блокировка", kind: .system, symbol: "lock.fill"),
                        LauncherItem(id: "sys:darkMode", title: "Тёмная тема", kind: .system, symbol: "circle.lefthalf.filled"),
                        LauncherItem(id: "shortcut:x", title: "Фокус: работа", kind: .shortcut, symbol: "square.stack.3d.up.fill")]
            let sample = SystemStats(cpu: 0.35, cpuPerCore: [0.2, 0.6, 0.4, 0.1, 0.8, 0.3, 0.2, 0.5], gpu: 0.2,
                                     memoryUsed: 11_000_000_000, memoryTotal: 16_000_000_000, netInBytesPerSec: 250_000, netOutBytesPerSec: 40_000)
            stats = sample
            statsHistory = (0..<60).map { i in var s = sample; s.cpu = 0.3 + 0.25 * sin(Double(i) / 6); s.gpu = 0.2 + 0.1 * cos(Double(i) / 5); return s }
        }
        #endif
    }

    /// iOS kills listening sockets in the background; re-arm on every foreground.
    func sceneBecameActive() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { return }
        #endif
        listener.start()
    }

    func userChangedPage(to index: Int) {
        requestDataIfNeeded(for: index)
        guard !applyingRemotePage else { return }
        pool.send(.pageChanged(index: index))
    }

    /// Notes are fetched through the Mac only while their page is on screen (asking Notes launches the app).
    private func requestDataIfNeeded(for index: Int) {
        guard pages.indices.contains(index) else { return }
        let kind = pages[index].kind
        if kind == .notes || kind == .launcher { refresh(kind) }
    }

    func perform(_ action: MediaAction) {
        pool.send(.mediaAction(action))
    }

    /// A page showing Mac-provided data appeared: ask for fresh data.
    func refresh(_ kind: PageKind) { pool.send(.refresh(kind)) }
    func openNote(_ id: String) { pool.send(.noteRequest(id: id)) }
    func createNote(_ text: String) { pool.send(.noteCreate(text: text)) }
    func showNoteOnMac(_ id: String) { pool.send(.noteShowOnMac(id: id)) }
    func run(_ item: LauncherItem) { pool.send(.command(id: item.id)) }

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
        case .pointerDelta(let dx, let dy):
            pointer.move(dx: dx, dy: dy)
        case .pointerButton(let button, let down):
            pointer.button(button, down: down)
        case .pointerScroll(let dx, let dy, let phase):
            pointer.scroll(dx: dx, dy: dy, phase: phase)
        case .pointerExit:
            pointer.hide()
        case .nowPlaying(let value):
            nowPlaying = value
        case .notes(let list):
            notes = list
        case .noteBody(let id, let text):
            noteBodies[id] = text
        case .launcher(let items):
            launcher = items
        case .stats(let value):
            stats = value
            statsHistory = Array((statsHistory + [value]).suffix(60))
        default:
            break
        }
    }

    /// A trackpad swipe ended: settle on the neighbouring page (or back on this one).
    private func finishSwipe(_ step: Int) {
        let target = min(max(currentPage + step, 0), max(pages.count - 1, 0))
        withAnimation(.snappy(duration: 0.3)) {
            currentPage = target
            pointer.swipe.offset = 0
        }
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
