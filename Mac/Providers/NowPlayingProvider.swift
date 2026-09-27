import AppKit
import PhoneScreenKit

/// Current track from Music.app / Spotify via AppleScript.
///
/// The system-wide MediaRemote route is closed to third-party apps since macOS 15.4;
/// the planned upgrade is the `mediaremote-adapter` helper, with this as the fallback that always works.
/// Only apps that are already running are queried, so polling never launches a player.
///
/// Runs on its own background queue: an AppleScript round trip takes 15–30 ms and must never
/// block the main thread. Results are delivered on the main thread.
final class NowPlayingProvider: @unchecked Sendable {
    private enum Player: String, CaseIterable {
        case spotify = "Spotify", music = "Music"

        var bundleID: String {
            switch self {
            case .spotify: "com.spotify.client"
            case .music: "com.apple.Music"
            }
        }
    }

    private struct Snapshot {
        var player: Player
        var state: String
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var trackID: String
        var artworkURL: String?
    }

    /// Called on the main thread.
    var onChange: (@MainActor (NowPlaying?) -> Void)?

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "phonescreen.nowplaying", qos: .utility)
    private var current: NowPlaying?
    private var timer: DispatchSourceTimer?
    private var activePlayer: Player?
    private var artworkTrackID: String?
    private var artwork: Data?
    /// Compiled once: compiling is a good part of each run's cost.
    private var compiled: [String: NSAppleScript] = [:]

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func perform(_ action: MediaAction) {
        queue.async { [self] in performOnQueue(action) }
    }

    private func performOnQueue(_ action: MediaAction) {
        guard let player = activePlayer ?? runningPlayers().first else { return }
        let command = switch action {
        case .togglePlayPause: "playpause"
        case .play: "play"
        case .pause: "pause"
        case .next: "next track"
        case .previous: "previous track"
        }
        run("tell application \"\(player.rawValue)\" to \(command)")
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
    }

    // MARK: - Polling

    private func runningPlayers() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Player.allCases.filter { running.contains($0.bundleID) }
    }

    private func poll() {
        let snapshots = runningPlayers().compactMap(snapshot)
        // Prefer whatever is playing; otherwise keep showing the last used (paused) player.
        let chosen = snapshots.first { $0.state == "playing" }
            ?? snapshots.first { $0.player == activePlayer }
            ?? snapshots.first
        activePlayer = chosen?.player

        guard let s = chosen else { return publish(nil) }
        if s.trackID != artworkTrackID {
            artworkTrackID = s.trackID
            artwork = nil
            loadArtwork(for: s)
        }
        publish(NowPlaying(title: s.title, artist: s.artist, album: s.album.isEmpty ? nil : s.album,
                           artwork: artwork, duration: s.duration > 0 ? s.duration : nil,
                           elapsed: s.position, playing: s.state == "playing"))
    }

    private func publish(_ value: NowPlaying?) {
        // Timestamps change every poll; compare everything else to avoid spamming the phone.
        var a = value, b = current
        a?.timestamp = .distantPast
        b?.timestamp = .distantPast
        let positionJumped = abs((value?.elapsed ?? 0) - extrapolatedElapsed()) > 1.5
        guard a != b || positionJumped else { return }
        current = value
        DispatchQueue.main.async { [onChange] in MainActor.assumeIsolated { onChange?(value) } }
    }

    private func extrapolatedElapsed() -> Double {
        guard let current, let elapsed = current.elapsed else { return 0 }
        return current.playing ? elapsed + Date().timeIntervalSince(current.timestamp) : elapsed
    }

    private func snapshot(_ player: Player) -> Snapshot? {
        let script = switch player {
        case .music: """
            tell application "Music"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {player state as text, name of t, artist of t, album of t, duration of t, player position, persistent ID of t, ""}
            end tell
            """
        case .spotify: """
            tell application "Spotify"
                if player state is stopped then return {"stopped"}
                set t to current track
                return {player state as text, name of t, artist of t, album of t, (duration of t) / 1000, player position, id of t, artwork url of t}
            end tell
            """
        }
        guard let list = run(script), list.numberOfItems >= 8 else { return nil }
        func string(_ i: Int) -> String { list.atIndex(i)?.stringValue ?? "" }
        func double(_ i: Int) -> Double { list.atIndex(i).map { Double($0.stringValue ?? "") ?? $0.doubleValue } ?? 0 }
        return Snapshot(player: player, state: string(1), title: string(2), artist: string(3), album: string(4),
                        duration: double(5), position: double(6), trackID: string(7),
                        artworkURL: string(8).isEmpty ? nil : string(8))
    }

    private func loadArtwork(for s: Snapshot) {
        let trackID = s.trackID
        let apply: (Data?) -> Void = { [weak self] data in
            guard let self, self.artworkTrackID == trackID, let data, let jpeg = Self.thumbnail(data) else { return }
            self.artwork = jpeg
            self.current = nil // force re-publish with artwork
            self.poll()
        }
        switch s.player {
        case .music:
            apply(run("tell application \"Music\" to get data of artwork 1 of current track")?.data)
        case .spotify:
            guard let url = s.artworkURL.flatMap(URL.init(string:)) else { return }
            URLSession.shared.dataTask(with: url) { [queue] data, _, _ in
                queue.async { apply(data) }
            }.resume()
        }
    }

    static func thumbnail(_ data: Data, side: CGFloat = 300) -> Data? {
        guard let image = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = compiled[source] ?? {
            let script = NSAppleScript(source: source)
            script?.compileAndReturnError(nil)
            compiled[source] = script
            return script
        }()
        let result = script?.executeAndReturnError(&error)
        if let error {
            AppModel.log.error("AppleScript failed: \(error, privacy: .public) — \(source.prefix(80), privacy: .public)")
        }
        return error == nil ? result : nil
    }
}
