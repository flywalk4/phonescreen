import Foundation

public enum PeerRole: String, Codable, Sendable {
    case mac, phone
}

public struct ScreenInfo: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct Hello: Codable, Equatable, Sendable {
    public var role: PeerRole
    public var version: Int
    public var name: String
    /// Stable per-pairing session id; lets a session resume after switching transports.
    public var sessionId: UUID
    public var screen: ScreenInfo?
    /// Set on slow transports (BLE): the peer must skip heavy fields such as artwork.
    public var lowBandwidth: Bool

    public init(role: PeerRole, version: Int = Protocol.version, name: String, sessionId: UUID,
                screen: ScreenInfo? = nil, lowBandwidth: Bool = false) {
        self.role = role
        self.version = version
        self.name = name
        self.sessionId = sessionId
        self.screen = screen
        self.lowBandwidth = lowBandwidth
    }
}

public enum WidgetKind: String, Codable, CaseIterable, Sendable {
    case music, monitor, notes, reminders, calendar, weather, launcher, photos

    public var title: String {
        switch self {
        case .music: "Музыка"
        case .monitor: "Мониторинг"
        case .notes: "Заметки"
        case .reminders: "Напоминания"
        case .calendar: "Календарь"
        case .weather: "Погода"
        case .launcher: "Команды"
        case .photos: "Фото"
        }
    }

    public var symbol: String {
        switch self {
        case .music: "music.note"
        case .monitor: "gauge.with.dots.needle.33percent"
        case .notes: "note.text"
        case .reminders: "checklist"
        case .calendar: "calendar"
        case .weather: "cloud.sun.fill"
        case .launcher: "square.grid.3x3.fill"
        case .photos: "photo.on.rectangle.angled"
        }
    }
}

/// How many widgets a page holds and how they are arranged.
public enum PageLayout: String, Codable, CaseIterable, Sendable {
    /// One widget, full screen.
    case single
    /// Two widgets: stacked in portrait, side by side in landscape.
    case split
    /// One large widget and two small ones.
    case trio
    /// Four small widgets, 2×2.
    case grid

    public var slots: Int {
        switch self {
        case .single: 1
        case .split: 2
        case .trio: 3
        case .grid: 4
        }
    }

    public var title: String {
        switch self {
        case .single: "Один"
        case .split: "Два"
        case .trio: "Один + два"
        case .grid: "Сетка 2×2"
        }
    }
}

/// How much room a widget has: it shows less as it gets smaller.
public enum WidgetSize: String, Codable, Sendable {
    case full, medium, small

    /// Size of each slot of a layout, in slot order.
    public static func sizes(for layout: PageLayout) -> [WidgetSize] {
        switch layout {
        case .single: [.full]
        case .split: [.medium, .medium]
        case .trio: [.medium, .small, .small]
        case .grid: [.small, .small, .small, .small]
        }
    }
}

/// What sits in a page slot: a built-in widget, or an installed JavaScript widget (by its id).
/// Encoded as one string ("music", "custom:com.author.rates"), so pages saved before custom widgets still load.
public enum WidgetRef: Hashable, Codable, Sendable {
    case builtin(WidgetKind)
    case custom(String)

    private static let customPrefix = "custom:"

    public var rawValue: String {
        switch self {
        case .builtin(let kind): kind.rawValue
        case .custom(let id): Self.customPrefix + id
        }
    }

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.customPrefix) {
            self = .custom(String(rawValue.dropFirst(Self.customPrefix.count)))
        } else if let kind = WidgetKind(rawValue: rawValue) {
            self = .builtin(kind)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = WidgetRef(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown widget \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var builtin: WidgetKind? { if case .builtin(let k) = self { k } else { nil } }
    public var customID: String? { if case .custom(let id) = self { id } else { nil } }

    /// Display name; custom widgets are named by whoever knows the installed ones.
    public func title(customNames: [String: String] = [:]) -> String {
        switch self {
        case .builtin(let kind): kind.title
        case .custom(let id): customNames[id] ?? id.split(separator: ".").last.map(String.init) ?? id
        }
    }
}

public struct PageInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var layout: PageLayout
    /// One per slot of `layout` (extra ones are ignored, missing ones are empty slots).
    public var widgets: [WidgetRef]

    public init(id: String = UUID().uuidString, layout: PageLayout, widgets: [WidgetRef]) {
        self.id = id
        self.layout = layout
        self.widgets = widgets
    }

    public init(id: String = UUID().uuidString, layout: PageLayout, builtins: [WidgetKind]) {
        self.init(id: id, layout: layout, widgets: builtins.map(WidgetRef.builtin))
    }

    public init(_ widget: WidgetKind) {
        self.init(id: widget.rawValue, layout: .single, widgets: [.builtin(widget)])
    }

    /// A copy with another id and widgets (same layout).
    public func with(id: String, widgets: [WidgetRef]) -> PageInfo {
        PageInfo(id: id, layout: layout, widgets: widgets)
    }

    /// The widgets actually shown (as many as the layout has slots).
    public var visibleWidgets: [WidgetRef] { Array(widgets.prefix(layout.slots)) }

    public func contains(_ kind: WidgetKind) -> Bool { visibleWidgets.contains(.builtin(kind)) }

    public var title: String { title(customNames: [:]) }

    public func title(customNames: [String: String]) -> String {
        visibleWidgets.map { $0.title(customNames: customNames) }.joined(separator: " + ")
    }

    /// Change the layout, keeping the widgets that still fit and filling new slots with unused built-ins.
    public mutating func setLayout(_ new: PageLayout) {
        layout = new
        var result = Array(widgets.prefix(new.slots))
        for kind in WidgetKind.allCases where result.count < new.slots && !result.contains(.builtin(kind)) {
            result.append(.builtin(kind))
        }
        widgets = result
    }

    /// Out-of-the-box pages: a dashboard first, then every widget on its own.
    public static let defaults: [PageInfo] = [
        PageInfo(id: "dashboard", layout: .grid, builtins: [.music, .weather, .calendar, .monitor]),
        PageInfo(.music), PageInfo(.calendar), PageInfo(.reminders), PageInfo(.notes),
        PageInfo(.launcher), PageInfo(.monitor), PageInfo(.weather),
    ]
}

public struct NowPlaying: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    /// JPEG, already downscaled by the sender.
    public var artwork: Data?
    public var duration: Double?
    public var elapsed: Double?
    public var playing: Bool
    /// When `elapsed` was sampled, so the receiver can extrapolate the progress bar.
    public var timestamp: Date
    /// "Music" or "Spotify".
    public var player: String?
    /// Player volume 0…1.
    public var volume: Double?
    public var shuffle: Bool?
    /// "off", "one" or "all" (Spotify only knows off/all).
    public var repeatMode: String?
    /// Favourited in Music (nil when the player can't tell).
    public var liked: Bool?

    public init(title: String, artist: String, album: String? = nil, artwork: Data? = nil,
                duration: Double? = nil, elapsed: Double? = nil, playing: Bool, timestamp: Date = Date()) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artwork = artwork
        self.duration = duration
        self.elapsed = elapsed
        self.playing = playing
        self.timestamp = timestamp
    }
}

public enum MediaAction: String, Codable, Sendable {
    case togglePlayPause, play, pause, next, previous
}

/// A track coming up after the current one.
public struct QueueTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var duration: Double?

    public init(title: String, artist: String, duration: Double?) {
        self.title = title
        self.artist = artist
        self.duration = duration
    }
}

/// What's coming up. Neither Music nor Spotify exposes their real "Up Next" to scripts, so for Music this is
/// the rest of the playlist/album being played; `note` explains what the list is (or why it's empty).
public struct MusicQueue: Codable, Equatable, Sendable {
    public var tracks: [QueueTrack]
    public var note: String?

    public init(tracks: [QueueTrack], note: String?) {
        self.tracks = tracks
        self.note = note
    }
}

public struct AirPlayDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// "computer", "AirPort Express", "Apple TV", "HomePod", "Bluetooth device"…
    public var kind: String
    public var selected: Bool

    public init(name: String, kind: String, selected: Bool) {
        self.name = name
        self.kind = kind
        self.selected = selected
    }
}

/// The Mac's sound: system output volume and, when Music is the player, its AirPlay speakers.
public struct AudioState: Codable, Equatable, Sendable {
    public var systemVolume: Double
    public var muted: Bool
    public var airPlay: [AirPlayDevice]

    public init(systemVolume: Double, muted: Bool, airPlay: [AirPlayDevice]) {
        self.systemVolume = systemVolume
        self.muted = muted
        self.airPlay = airPlay
    }
}

/// Phone → Mac music controls beyond play/pause/skip.
public enum MusicCommand: Codable, Equatable, Sendable {
    case setPlayerVolume(Double)
    case setSystemVolume(Double)
    case toggleMute
    case seek(Double)
    case toggleShuffle
    case cycleRepeat
    case toggleLike
    /// Play the n-th track of `MusicQueue.tracks`.
    case playQueueItem(Int)
    /// Play to exactly these AirPlay devices (by name).
    case setAirPlay([String])
}

public struct SystemStats: Codable, Equatable, Sendable {
    public var cpu: Double
    public var cpuPerCore: [Double]
    public var gpu: Double?
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var netInBytesPerSec: Double
    public var netOutBytesPerSec: Double

    public init(cpu: Double, cpuPerCore: [Double], gpu: Double?, memoryUsed: UInt64, memoryTotal: UInt64,
                netInBytesPerSec: Double, netOutBytesPerSec: Double) {
        self.cpu = cpu
        self.cpuPerCore = cpuPerCore
        self.gpu = gpu
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.netInBytesPerSec = netInBytesPerSec
        self.netOutBytesPerSec = netOutBytesPerSec
    }
}

public enum PointerButton: String, Codable, Sendable {
    case left, right
}

/// Where a scroll event sits in a trackpad gesture. Momentum (the inertia after the fingers lift)
/// is reported separately so a swipe doesn't keep flipping pages after it ended.
public enum ScrollPhase: String, Codable, Sendable {
    case began, changed, ended, momentum
    /// A discrete mouse-wheel step (no gesture).
    case wheel
}

/// Non-text keys typed on the Mac keyboard while the pointer is on the phone.
public enum SpecialKey: String, Codable, Sendable {
    case enter, tab, escape
    case backspace, forwardDelete, deleteWordBackward, deleteLineBackward
    case left, right, up, down, lineStart, lineEnd
    case selectAll
}

/// An Apple Notes note, as listed on the phone.
public struct NoteSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var snippet: String
    public var folder: String?
    public var modified: Date

    public init(id: String, title: String, snippet: String, folder: String?, modified: Date) {
        self.id = id
        self.title = title
        self.snippet = snippet
        self.folder = folder
        self.modified = modified
    }
}

/// Something the phone can launch on the Mac. The Mac only runs ids it has itself offered.
public struct LauncherItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case app, shortcut, system
    }

    public var id: String
    public var title: String
    public var kind: Kind
    /// SF Symbol for shortcuts and system actions.
    public var symbol: String?
    /// PNG app icon.
    public var icon: Data?

    public init(id: String, title: String, kind: Kind, symbol: String? = nil, icon: Data? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.symbol = symbol
        self.icon = icon
    }
}

public enum Protocol {
    public static let version = 1
    public static let bonjourType = "_phonescreen._tcp"
    public static let tcpPort: UInt16 = 47800
    /// Bluetooth LE service the phone advertises; its one characteristic holds the L2CAP PSM (UInt16, little endian).
    public static let bleService = "6E2B0001-7F3A-4C8E-9B51-5C1D0A7E3F10"
    public static let blePSMCharacteristic = "6E2B0002-7F3A-4C8E-9B51-5C1D0A7E3F10"
}
