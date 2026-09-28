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
    @Published var isTypingOnPhone = false
    @Published var hasAccessibility = PointerCapture.hasAccessibility
    let pointerCapture = PointerCapture()
    let edgeWatcher = EdgeWatcher()
    /// Where the cursor left the Mac; it comes back here if the capture is cancelled.
    var captureEntry: CGPoint?
    var accessibilityPoll: Timer?

    /// The phone's pages, edited in Settings → Pages. Saved, and pushed to the phone on every change.
    @Published var pages: [PageInfo] = AppModel.loadPages() {
        didSet {
            guard pages != oldValue else { return }
            if pages.isEmpty { pages = [PageInfo(.music)]; return }
            Self.savePages(pages)
            if currentPage >= pages.count { currentPage = pages.count - 1 }
            pool.send(.pages(list: pages, current: currentPage))
            pageBecameVisible()
        }
    }
    /// Which Settings tab to show.
    @Published var settingsTab = SettingsTab.pages
    /// "system" or a language code (see AppLanguage).
    @Published private(set) var languageChoice = AppLanguage.choice

    enum SettingsTab: Hashable { case pages, widgets, themes, arrangement }

    private static let pagesKey = "phonePages"

    private static func loadPages() -> [PageInfo] {
        UserDefaults.standard.data(forKey: pagesKey).flatMap { try? JSONDecoder().decode([PageInfo].self, from: $0) }
            ?? PageInfo.defaults
    }

    private static func savePages(_ pages: [PageInfo]) {
        if let data = try? JSONEncoder().encode(pages) { UserDefaults.standard.set(data, forKey: pagesKey) }
    }

    /// Built-in widgets on the current page.
    var currentWidgets: [WidgetKind] {
        pages.indices.contains(currentPage) ? pages[currentPage].visibleWidgets.compactMap(\.builtin) : []
    }

    /// Installed JavaScript widgets.
    let widgets = WidgetManager()
    /// The phone's look (built-in and installed themes).
    let themes = ThemeManager()

    private let sessionId = UUID()
    let pool: ChannelPool
    private var bonjour: BonjourBrowser?
    private var usb: USBMuxClient?
    private var bluetooth: BLECentral?
    private let music = NowPlayingProvider()
    private let stats = SystemStatsProvider()
    private let hotKeys = HotKeys()
    private let notes = NotesProvider()
    private let launcher = LauncherProvider()
    private var launcherItems: [LauncherItem] = []
    private let runningApps = RunningAppsProvider()
    private var apps: [RunningApp] = []
    private let previews = AppPreviewProvider()
    /// Window snapshots by app id, kept to send again on a new connection.
    private var appPreviews: [String: Data] = [:]
    /// Apps whose icon the phone already has on this connection.
    private var appIconsSent: Set<String> = []
    private var notesTimer: Timer?
    private var appsTimer: Timer?
    private var musicExtrasTimer: Timer?

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
        bluetooth = BLECentral { pool.add($0) }
        bonjour?.start()
        usb?.start()
        bluetooth?.start()

        music.onChange = { [weak self] value in
            self?.nowPlaying = value
            self?.sendNowPlaying()
        }
        music.start()
        music.onQueue = { [weak self] q in self?.pool.send(.musicQueue(q)) }
        music.onAudio = { [weak self] a in self?.pool.send(.audio(a)) }
        // Queue, system volume and AirPlay are polled only while a music widget is on screen.
        musicExtrasTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentWidgets.contains(.music), self.status.active != nil else { return }
                self.music.refreshExtras()
            }
        }

        stats.onSample = { [weak self] sample in
            // Always sent (tiny, 1 Hz), so the phone's charts already hold the last minute when shown.
            self?.pool.send(.stats(sample))
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

        notes.onNotes = { [weak self] list in
            Self.log.info("notes: \(list.count) fetched")
            self?.pool.send(.notes(list))
        }
        #if DEBUG
        if CommandLine.arguments.contains("--notes-selftest") { notes.refresh(force: true) }
        #endif
        notes.onBody = { [weak self] id, text in self?.pool.send(.noteBody(id: id, text: text)) }
        launcher.onItems = { [weak self] items in
            self?.launcherItems = items
            self?.sendLauncher()
        }
        launcher.refresh()
        runningApps.onApps = { [weak self] list in
            self?.apps = list
            self?.sendApps()
        }
        runningApps.start()
        previews.onPreview = { [weak self] id, image in
            guard let self else { return }
            appPreviews[id] = image.isEmpty ? nil : image
            if !pool.isLowBandwidth { pool.send(.appPreview(id: id, image: image)) }
        }
        widgets.send = { [weak self] in self?.pool.send($0) }
        widgets.start()
        themes.send = { [weak self] in self?.pool.send($0) }
        themes.start()
        // Notes change on other devices too; poll only while their page is on screen.
        notesTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentWidgets.contains(.notes) else { return }
                self.notes.refresh()
            }
        }
        // Window titles change without any app event (a new tab, another document): re-read them while
        // the apps page is on screen. The list only goes out when something actually changed.
        appsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentWidgets.contains(.apps) else { return }
                self.runningApps.refresh()
                self.capturePreviews()
            }
        }
    }

    func pageBecameVisible() {
        if currentWidgets.contains(.notes) { notes.refresh() }
        if currentWidgets.contains(.launcher) { launcher.refresh() }
        if currentWidgets.contains(.apps) { capturePreviews() }
    }

    /// Window snapshots are big: never over Bluetooth, and only while the apps page is on screen.
    private func capturePreviews() {
        guard !pool.isLowBandwidth, currentWidgets.contains(.apps) else { return }
        previews.capture(ids: Set(apps.map(\.id)))
    }

    private func sendLauncher() {
        // Icons are the heavy part; a Bluetooth link gets symbols and titles only.
        let items = pool.isLowBandwidth ? launcherItems.map { var i = $0; i.icon = nil; return i } : launcherItems
        pool.send(.launcher(items))
    }

    /// Always sent (small, and only on app launch/quit/switch), so the list is current the moment its page is shown.
    private func sendApps() {
        let list = apps.map { app in
            var app = app
            if pool.isLowBandwidth || appIconsSent.contains(app.id) { app.icon = nil }
            return app
        }
        if !pool.isLowBandwidth { appIconsSent.formUnion(apps.map(\.id)) }
        pool.send(.runningApps(list))
    }

    func show(page index: Int) {
        currentPage = index
        pool.send(.setPage(index: index))
        pageBecameVisible()
    }

    func perform(_ action: MediaAction) {
        music.perform(action)
    }

    private func handle(_ message: Message) {
        switch message {
        case .pageChanged(let index) where pages.indices.contains(index):
            currentPage = index
            pageBecameVisible()
        case .refresh(let kind):
            if kind == .notes { notes.refresh(force: true) }
            if kind == .launcher { launcher.refresh() }
            if kind == .apps { runningApps.resend(); capturePreviews() }
        case .appAction(let id, let action):
            runningApps.perform(action, id: id)
            // Switching to an app means working in it: the cursor goes back to the Mac.
            if action == .activate { releasePointer() }
        case .noteRequest(let id):
            notes.body(id: id)
        case .noteCreate(let text):
            notes.create(text: text)
        case .noteShowOnMac(let id):
            notes.showOnMac(id: id)
        case .command(let id):
            launcher.run(id)
        case .customAction(let id, let action):
            widgets.action(id, action)
        case .pointerExit(let along):
            pointerLeftPhone(along: along)
        case .textFocus(let focused):
            pointerCapture.phoneTextFocus = focused
            isTypingOnPhone = focused
        case .music(let command):
            music.perform(command)
        case .mediaAction(let action):
            Self.log.info("mediaAction \(action.rawValue, privacy: .public)")
            music.perform(action)
        default:
            break
        }
    }

    /// Sent on every (re)connection and transport switch, so the phone never shows stale state.
    /// A new language for the whole product: widgets restart in it, the phone switches, the Mac UI after relaunch.
    func setLanguage(_ choice: String) {
        AppLanguage.choice = choice
        languageChoice = choice
        widgets.reloadAll()
        pool.send(.language(AppLanguage.current))
    }

    private func sendFullState() {
        pool.send(.layout(arrangement.layout))
        pool.send(.language(AppLanguage.current))
        themes.sendCurrent()
        pool.send(.pages(list: pages, current: currentPage))
        sendNowPlaying()
        sendLauncher()
        appIconsSent = [] // a new connection may be a phone that has never seen them
        sendApps()
        if !pool.isLowBandwidth { for (id, image) in appPreviews { pool.send(.appPreview(id: id, image: image)) } }
        widgets.sendAll()
        // Notes are fetched only when their page is shown: asking Notes launches the app.
        if currentWidgets.contains(.notes) { notes.refresh(force: true) }
    }

    private func sendNowPlaying() {
        var value = nowPlaying
        if pool.isLowBandwidth { value?.artwork = nil }
        pool.send(.nowPlaying(value))
    }
}
