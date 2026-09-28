import AppKit
import QwoviKit

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
        var volume: Double
        var shuffle: Bool
        var repeatMode: String
        var liked: Bool?
    }

    /// Called on the main thread.
    var onChange: (@MainActor (NowPlaying?) -> Void)?
    var onQueue: (@MainActor (MusicQueue) -> Void)?
    var onAudio: (@MainActor (AudioState) -> Void)?

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "qwovi.nowplaying", qos: .utility)
    private var current: NowPlaying?
    private var timer: DispatchSourceTimer?
    private var activePlayer: Player?
    private var artworkTrackID: String?
    private var artwork: Data?
    /// Compiled once: compiling is a good part of each run's cost.
    private var compiled: [String: NSAppleScript] = [:]
    private var queueTrackID: String?
    private var lastQueue: MusicQueue?
    private var lastAudio: AudioState?

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

    // MARK: - Extras: queue, system volume, AirPlay (polled only while a music widget is on screen)

    func refreshExtras() {
        queue.async { [self] in
            fetchAudio()
            if let current, "\(current.title)|\(current.artist)" != queueTrackID || Date().timeIntervalSince(lastQueueFetch) > 15 {
                queueTrackID = "\(current.title)|\(current.artist)"
                fetchQueue()
            }
        }
    }

    private var lastQueueFetch = Date.distantPast

    func perform(_ command: MusicCommand) {
        queue.async { [self] in
            let player = (activePlayer ?? runningPlayers().first)?.rawValue ?? "Music"
            switch command {
            case .setPlayerVolume(let v):
                run("-- nocache\ntell application \"\(player)\" to set sound volume to \(Int((v * 100).rounded()))")
            case .setSystemVolume(let v):
                run("-- nocache\nset volume output volume \(Int((v * 100).rounded()))")
            case .toggleMute:
                run("set volume output muted (not (output muted of (get volume settings)))")
            case .seek(let seconds):
                run("-- nocache\ntell application \"\(player)\" to set player position to \(seconds)")
            case .toggleShuffle:
                run(player == "Spotify" ? "tell application \"Spotify\" to set shuffling to not shuffling"
                                        : "tell application \"Music\" to set shuffle enabled to not shuffle enabled")
            case .cycleRepeat:
                if player == "Spotify" {
                    run("tell application \"Spotify\" to set repeating to not repeating")
                } else {
                    run("""
                        tell application "Music"
                            if song repeat is off then
                                set song repeat to all
                            else if song repeat is all then
                                set song repeat to one
                            else
                                set song repeat to off
                            end if
                        end tell
                        """)
                }
            case .toggleLike:
                run("""
                    tell application "Music"
                        try
                            set favorited of current track to not (favorited of current track)
                        on error
                            set loved of current track to not (loved of current track)
                        end try
                    end tell
                    """)
            case .playQueueItem(let n):
                guard player == "Music" else { break }
                run("-- nocache\ntell application \"Music\" to play track ((index of current track) + \(n + 1)) of current playlist")
                queueTrackID = nil
            case .setAirPlay(let names):
                let list = names.map(AppleScriptRunner.literal).joined(separator: ", ")
                run("""
                    -- nocache
                    tell application "Music"
                        set targets to {}
                        repeat with d in (every AirPlay device)
                            if name of d is in {\(list)} then set end of targets to contents of d
                        end repeat
                        if targets is not {} then set current AirPlay devices to targets
                    end tell
                    """)
            }
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.poll()
                self?.fetchAudio()
                if case .playQueueItem = command { self?.fetchQueue() }
            }
        }
    }

    private func fetchAudio() {
        let settings = run("return {output volume of (get volume settings), output muted of (get volume settings)}")
        var devices: [AirPlayDevice] = []
        if runningPlayers().contains(.music), let list = run("""
            tell application "Music"
                set out to {}
                repeat with d in (every AirPlay device)
                    set end of out to {name of d, (kind of d) as text, selected of d}
                end repeat
                return out
            end tell
            """) {
            devices = list.listItems.compactMap { item in
                guard item.numberOfItems >= 3, let name = item.atIndex(1)?.stringValue else { return nil }
                return AirPlayDevice(name: name, kind: item.atIndex(2)?.stringValue ?? "", selected: item.atIndex(3)?.booleanValue ?? false)
            }
        }
        let state = AudioState(systemVolume: (settings?.atIndex(1)?.doubleValue ?? 0) / 100,
                               muted: settings?.atIndex(2)?.booleanValue ?? false, airPlay: devices)
        guard state != lastAudio else { return }
        lastAudio = state
        DispatchQueue.main.async { [onAudio] in MainActor.assumeIsolated { onAudio?(state) } }
    }

    private func fetchQueue() {
        lastQueueFetch = Date()
        let result: MusicQueue
        if activePlayer == .spotify {
            result = MusicQueue(tracks: [], note: String(localized: "Spotify doesn't share its queue with scripts"))
        } else if let list = run("""
            tell application "Music"
                if player state is stopped then return {}
                set out to {}
                try
                    set pl to current playlist
                    set i to index of current track
                    set n to count of tracks of pl
                    set lastIndex to i + 20
                    if lastIndex > n then set lastIndex to n
                    repeat with k from (i + 1) to lastIndex
                        set t to track k of pl
                        set end of out to {name of t, artist of t, duration of t}
                    end repeat
                end try
                return out
            end tell
            """) {
            let tracks = list.listItems.compactMap { item -> QueueTrack? in
                guard item.numberOfItems >= 3 else { return nil }
                return QueueTrack(title: item.atIndex(1)?.stringValue ?? "", artist: item.atIndex(2)?.stringValue ?? "",
                                  duration: item.atIndex(3)?.doubleValue)
            }
            let shuffled = current?.shuffle == true
            result = MusicQueue(tracks: tracks, note: tracks.isEmpty ? String(localized: "Nothing up next")
                                : shuffled ? String(localized: "Up next in the playlist · shuffle may change the order") : String(localized: "Up next in the playlist"))
        } else {
            result = MusicQueue(tracks: [], note: nil)
        }
        guard result != lastQueue else { return }
        lastQueue = result
        DispatchQueue.main.async { [onQueue] in MainActor.assumeIsolated { onQueue?(result) } }
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
        var value = NowPlaying(title: s.title, artist: s.artist, album: s.album.isEmpty ? nil : s.album,
                               artwork: artwork, duration: s.duration > 0 ? s.duration : nil,
                               elapsed: s.position, playing: s.state == "playing")
        value.player = s.player.rawValue
        value.volume = s.volume / 100
        value.shuffle = s.shuffle
        value.repeatMode = s.repeatMode
        value.liked = s.liked
        publish(value)
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
                set fav to missing value
                try
                    set fav to favorited of t
                on error
                    try
                        set fav to loved of t
                    end try
                end try
                return {player state as text, name of t, artist of t, album of t, duration of t, player position, persistent ID of t, "", sound volume, shuffle enabled, song repeat as text, fav}
            end tell
            """
        case .spotify: """
            tell application "Spotify"
                if player state is stopped then return {"stopped"}
                set t to current track
                set rep to "off"
                if repeating then set rep to "all"
                return {player state as text, name of t, artist of t, album of t, (duration of t) / 1000, player position, id of t, artwork url of t, sound volume, shuffling, rep, missing value}
            end tell
            """
        }
        guard let list = run(script), list.numberOfItems >= 12 else { return nil }
        func string(_ i: Int) -> String { list.atIndex(i)?.stringValue ?? "" }
        func double(_ i: Int) -> Double { list.atIndex(i).map { Double($0.stringValue ?? "") ?? $0.doubleValue } ?? 0 }
        let fav = list.atIndex(12)
        return Snapshot(player: player, state: string(1), title: string(2), artist: string(3), album: string(4),
                        duration: double(5), position: double(6), trackID: string(7),
                        artworkURL: string(8).isEmpty ? nil : string(8),
                        volume: double(9), shuffle: list.atIndex(10)?.booleanValue ?? false,
                        repeatMode: string(11).isEmpty ? "off" : string(11),
                        liked: fav?.descriptorType == typeTrue || fav?.descriptorType == typeFalse
                            || fav?.descriptorType == typeBoolean ? fav?.booleanValue : nil)
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
            // i.scdn.co is unreachable on some networks; the same image lives on Spotify's other CDN hosts.
            var candidates = [url]
            if url.host == "i.scdn.co" {
                for host in ["image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com"] {
                    var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    c?.host = host
                    if let alt = c?.url { candidates.append(alt) }
                }
            }
            Self.firstImage(candidates) { [queue] data in queue.async { apply(data) } }
        }
    }

    /// Tries each URL in turn (6 s each) and hands back the first image data, or nil.
    private static func firstImage(_ urls: [URL], _ done: @escaping @Sendable (Data?) -> Void) {
        guard let url = urls.first else { return done(nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                done(data)
            } else {
                firstImage(Array(urls.dropFirst()), done)
            }
        }.resume()
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
            if !source.contains("-- nocache") { compiled[source] = script } // one-off scripts (volume values…)
            return script
        }()
        let result = script?.executeAndReturnError(&error)
        if let error {
            AppModel.log.error("AppleScript failed: \(error, privacy: .public) — \(source.prefix(80), privacy: .public)")
        }
        return error == nil ? result : nil
    }
}
