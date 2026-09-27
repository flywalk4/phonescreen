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
        listener.start()
    }

    /// iOS kills listening sockets in the background; re-arm on every foreground.
    func sceneBecameActive() {
        listener.start()
    }

    func userChangedPage(to index: Int) {
        guard !applyingRemotePage else { return }
        pool.send(.pageChanged(index: index))
    }

    func perform(_ action: MediaAction) {
        pool.send(.mediaAction(action))
    }

    private func handle(_ message: Message) {
        switch message {
        case .pages(let list, let current):
            pages = list
            applyRemotePage(current)
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
