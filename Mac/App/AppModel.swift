import AppKit
import os
import PhoneScreenKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let log = Logger(subsystem: "com.flywalk4.phonescreen", category: "connection")

    @Published private(set) var status = ChannelPool.Status(active: nil, available: [])
    @Published private(set) var currentPage = 0
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var displays: [DisplayInfo] = DisplayInfo.current() {
        didSet { updatePortal() }
    }
    /// Phone size in its own UI points, portrait (from its hello). iPhone 15 until the phone says otherwise.
    @Published private(set) var phonePortraitPoints = CGSize(width: 393, height: 852) {
        didSet { updatePortal() }
    }
    @Published var arrangement: PhoneArrangement {
        didSet {
            guard arrangement != oldValue else { return }
            Self.saveArrangement(arrangement)
            if arrangement.layout != oldValue.layout {
                releasePointer() // geometry changed under the captured pointer
                pool.send(.layout(arrangement.layout))
            }
            updatePortal()
        }
    }

    // Pointer (see AppModel+Pointer.swift)
    @Published var isPointerOnPhone = false
    @Published var hasAccessibility = PointerCapture.hasAccessibility
    let pointerCapture = PointerCapture()
    let edgeWatcher = EdgeWatcher()
    /// Where the cursor left the Mac; it comes back here if the capture is cancelled.
    var captureEntry: CGPoint?
    var accessibilityPoll: Timer?

    let pages: [PageInfo] = [
        PageInfo(id: "music", kind: .music, title: "Музыка"),
        PageInfo(id: "monitor", kind: .monitor, title: "Мониторинг"),
    ]

    private let sessionId = UUID()
    let pool: ChannelPool
    private var bonjour: BonjourBrowser?
    private var usb: USBMuxClient?
    private let music = NowPlayingProvider()
    private let stats = SystemStatsProvider()
    private let hotKeys = HotKeys()

    init() {
        let sessionId = self.sessionId
        let name = Host.current().localizedName ?? "Mac"
        pool = ChannelPool { transport in
            Hello(role: .mac, name: name, sessionId: sessionId, lowBandwidth: transport == .bluetooth)
        }
        let displays = DisplayInfo.current()
        arrangement = Self.loadArrangement(displays: displays)
            ?? Self.defaultArrangement(displays: displays, phonePoints: CGSize(width: 393, height: 852))
    }

    // MARK: - Arrangement

    /// The display the phone is attached to (falls back to the main display if that one is gone).
    var arrangedDisplay: DisplayInfo? {
        displays.first { $0.id == arrangement.displayID } ?? displays.first(where: \.isMain) ?? displays.first
    }

    func phoneSize(for orientation: PhoneOrientation, on display: DisplayInfo) -> CGSize {
        ArrangementGeometry.phoneSize(portraitPoints: phonePortraitPoints, orientation: orientation,
                                      macPointsPerMM: display.pointsPerMM)
    }

    /// Phone rectangle in global Mac coordinates.
    var phoneRect: CGRect? {
        guard let display = arrangedDisplay else { return nil }
        return ArrangementGeometry.phoneRect(display: display.bounds, edge: arrangement.edge, offset: arrangement.offset,
                                             size: phoneSize(for: arrangement.orientation, on: display))
    }

    func rotatePhone(clockwise: Bool) {
        guard let display = arrangedDisplay else { return }
        let new = clockwise ? arrangement.orientation.rotatedClockwise : arrangement.orientation.rotatedCounterClockwise
        let offset = ArrangementGeometry.recentredOffset(arrangement.offset, edge: arrangement.edge,
                                                         from: phoneSize(for: arrangement.orientation, on: display),
                                                         to: phoneSize(for: new, on: display))
        arrangement.orientation = new
        arrangement.offset = ArrangementGeometry.clampedOffset(offset, display: display.bounds, edge: arrangement.edge,
                                                               size: phoneSize(for: new, on: display))
    }

    func setOrientation(_ orientation: PhoneOrientation) {
        guard orientation != arrangement.orientation else { return }
        // Two quarter turns for upside-down keep the centre the same way a single rotation does.
        while arrangement.orientation != orientation { rotatePhone(clockwise: true) }
    }

    func attach(to display: DisplayInfo, edge: ScreenEdge) {
        let size = phoneSize(for: arrangement.orientation, on: display)
        arrangement = PhoneArrangement(displayID: display.id, edge: edge,
                                       offset: ArrangementGeometry.centredOffset(display: display.bounds, edge: edge, size: size),
                                       orientation: arrangement.orientation)
    }

    /// Drop the phone at a freely dragged position: it snaps to the nearest free display edge.
    func dropPhone(at dragged: CGRect) {
        guard let snap = ArrangementGeometry.snap(dragged, displays: displays.map(\.bounds)) else { return }
        arrangement = PhoneArrangement(displayID: displays[snap.displayIndex].id, edge: snap.edge,
                                       offset: snap.offset, orientation: arrangement.orientation)
    }

    func refreshDisplays() {
        displays = DisplayInfo.current()
    }

    private static let arrangementKey = "phoneArrangement"

    var isArrangementConfigured: Bool { UserDefaults.standard.data(forKey: Self.arrangementKey) != nil }

    private static func loadArrangement(displays: [DisplayInfo]) -> PhoneArrangement? {
        guard let data = UserDefaults.standard.data(forKey: arrangementKey) else { return nil }
        return try? JSONDecoder().decode(PhoneArrangement.self, from: data)
    }

    private static func saveArrangement(_ value: PhoneArrangement) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: arrangementKey) }
    }

    /// Default: right of the main display, vertically centred, portrait.
    private static func defaultArrangement(displays: [DisplayInfo], phonePoints: CGSize) -> PhoneArrangement {
        guard let main = displays.first(where: \.isMain) ?? displays.first else {
            return PhoneArrangement(displayID: "", edge: .right, offset: 0, orientation: .portrait)
        }
        let size = ArrangementGeometry.phoneSize(portraitPoints: phonePoints, orientation: .portrait, macPointsPerMM: main.pointsPerMM)
        return PhoneArrangement(displayID: main.id, edge: .right,
                                offset: ArrangementGeometry.centredOffset(display: main.bounds, edge: .right, size: size),
                                orientation: .portrait)
    }

    func start() {
        pool.onMessage = { [weak self] in self?.handle($0) }
        pool.onActiveChanged = { [weak self] active in
            if active != nil { self?.sendFullState() } else { self?.releasePointer() }
        }
        pool.onPeerHello = { [weak self] hello in
            guard let screen = hello.screen else { return }
            // UI points in portrait, whatever way the phone reported them.
            self?.phonePortraitPoints = CGSize(width: min(screen.width, screen.height), height: max(screen.width, screen.height))
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
        pool.onStatus = { [weak self] status in
            if status.active != self?.status.active || status.available != self?.status.available {
                Self.log.info("""
                    active=\(status.active?.label ?? "none", privacy: .public) \
                    available=\(status.available.map(\.label).joined(separator: ","), privacy: .public) \
                    rtt=\((status.rtt ?? -1) * 1000, format: .fixed(precision: 1), privacy: .public)ms \
                    peer=\(status.peerName ?? "-", privacy: .public)
                    """)
            }
            self?.status = status
        }

        let pool = self.pool
        bonjour = BonjourBrowser { pool.add($0) }
        usb = USBMuxClient { pool.add($0) }
        bonjour?.start()
        usb?.start()

        music.onChange = { [weak self] value in
            self?.nowPlaying = value
            self?.sendNowPlaying()
        }
        music.start()

        stats.onSample = { [weak self] sample in
            guard let self, self.pages[self.currentPage].kind == .monitor else { return }
            self.pool.send(.stats(sample))
        }
        stats.start()

        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .nextPage: self.show(page: (self.currentPage + 1) % self.pages.count)
            case .previousPage: self.show(page: (self.currentPage - 1 + self.pages.count) % self.pages.count)
            case .page(let i) where i < self.pages.count: self.show(page: i)
            case .page: break
            case .releasePointer: self.releasePointer()
            }
        }
        hotKeys.register()
        startPointer()
    }

    func show(page index: Int) {
        currentPage = index
        pool.send(.setPage(index: index))
    }

    func perform(_ action: MediaAction) {
        music.perform(action)
    }

    private func handle(_ message: Message) {
        switch message {
        case .pageChanged(let index) where pages.indices.contains(index):
            currentPage = index
        case .pointerExit(let along):
            pointerLeftPhone(along: along)
        case .mediaAction(let action):
            Self.log.info("mediaAction \(action.rawValue, privacy: .public)")
            music.perform(action)
        default:
            break
        }
    }

    /// Sent on every (re)connection and transport switch, so the phone never shows stale state.
    private func sendFullState() {
        pool.send(.layout(arrangement.layout))
        pool.send(.pages(list: pages, current: currentPage))
        sendNowPlaying()
    }

    private func sendNowPlaying() {
        var value = nowPlaying
        if pool.isLowBandwidth { value?.artwork = nil }
        pool.send(.nowPlaying(value))
    }
}
