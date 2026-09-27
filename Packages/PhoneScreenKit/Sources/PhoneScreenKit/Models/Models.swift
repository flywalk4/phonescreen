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

public enum PageKind: String, Codable, CaseIterable, Sendable {
    case music, monitor, notes, reminders, calendar, weather, launcher
}

public struct PageInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: PageKind
    public var title: String

    public init(id: String, kind: PageKind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
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
}
