import PhoneScreenKit
import SwiftUI

struct MusicPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size

    var body: some View {
        if size == .full { full } else { compact }
    }

    /// Card version: cover + track + controls, side by side when there's width for it.
    private var compact: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height * 1.3
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            layout {
                Artwork(image: model.artwork)
                    .frame(maxWidth: wide ? geo.size.height : min(geo.size.width, geo.size.height * 0.5),
                           maxHeight: wide ? geo.size.height : geo.size.height * 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.nowPlaying?.title ?? "Ничего не играет")
                        .font(size == .small ? .subheadline.weight(.semibold) : .headline).lineLimit(2)
                    Text(model.nowPlaying?.artist ?? "Музыка / Spotify на Mac")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if size == .medium { ProgressRow(track: model.nowPlaying).padding(.top, 4) }
                    Spacer(minLength: 0)
                    Controls(playing: model.nowPlaying?.playing ?? false, compact: true) { model.perform($0) }
                        .disabled(model.nowPlaying == nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @State private var mode: Mode = {
        #if DEBUG
        // `--music-mode Звук` etc. for Simulator layout checks.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--music-mode"), i + 1 < args.count, let m = Mode(rawValue: args[i + 1]) { return m }
        #endif
        return .now
    }()

    enum Mode: String, CaseIterable {
        case now = "Сейчас", queue = "Далее", sound = "Звук"
    }

    private var full: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Text(m.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(m == mode ? Color.primary.opacity(0.18) : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.snappy) { mode = m } }
                        .pointerTarget { withAnimation(.snappy) { mode = m } }
                }
            }
            .padding(.top, 48) // below the connection badge
            switch mode {
            case .now: nowPlaying
            case .queue: QueueView()
            case .sound: SoundView()
            }
        }
    }

    private var nowPlaying: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let layout = landscape
                ? AnyLayout(HStackLayout(spacing: 32))
                : AnyLayout(VStackLayout(spacing: 24))
            layout {
                Artwork(image: model.artwork)
                    .frame(maxWidth: landscape ? geo.size.height * 0.7 : geo.size.width * 0.72)
                VStack(spacing: 18) {
                    TrackInfo(track: model.nowPlaying)
                    SeekBar(track: model.nowPlaying) { model.music(.seek($0)) }
                    Controls(playing: model.nowPlaying?.playing ?? false) { model.perform($0) }
                        .disabled(model.nowPlaying == nil)
                    ExtrasRow(track: model.nowPlaying) { model.music($0) }
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shuffle · like · repeat.
private struct ExtrasRow: View {
    let track: NowPlaying?
    let send: (MusicCommand) -> Void

    var body: some View {
        HStack(spacing: 36) {
            toggle("shuffle", on: track?.shuffle == true) { send(.toggleShuffle) }
            if let liked = track?.liked {
                toggle(liked ? "star.fill" : "star", on: liked) { send(.toggleLike) }
            }
            toggle(track?.repeatMode == "one" ? "repeat.1" : "repeat", on: (track?.repeatMode ?? "off") != "off") { send(.cycleRepeat) }
        }
        .disabled(track == nil)
    }

    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Glyph(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .frame(width: 44, height: 36)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .pointerTarget(action: action)
    }
}

/// Progress you can grab: drag with a finger, or press-and-drag / scroll with the Mac pointer.
private struct SeekBar: View {
    let track: NowPlaying?
    let seek: (Double) -> Void
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = track?.duration ?? 0
            let elapsed = dragging.map { $0 * duration } ?? min(currentElapsed(at: context.date), duration)
            let fraction = duration > 0 ? elapsed / duration : 0
            VStack(spacing: 6) {
                LevelBar(value: fraction, height: dragging == nil ? 5 : 9) { f in
                    dragging = f
                } onEnd: { f in
                    dragging = nil
                    seek(f * duration)
                }
                .pointerDraggable(value: fraction) { seek($0 * duration) }
                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text("-" + format(max(duration - elapsed, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .opacity(track?.duration == nil ? 0 : 1)
    }

    private func currentElapsed(at date: Date) -> Double {
        guard let track, let elapsed = track.elapsed else { return 0 }
        return track.playing ? elapsed + date.timeIntervalSince(track.timestamp) : elapsed
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A horizontal level (volume, progress) that follows a finger; `onEnd` gets the final value.
struct LevelBar: View {
    let value: Double
    var height: CGFloat = 8
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            ThemedBar(value: value, height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChange(min(max($0.location.x / geo.size.width, 0), 1)) }
                .onEnded { onEnd(min(max($0.location.x / geo.size.width, 0), 1)) })
        }
        .frame(height: 24)
        .animation(.snappy(duration: 0.15), value: height)
    }
}

/// What plays next (for Music: the rest of the current playlist/album). Tap a track to jump to it.
private struct QueueView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = model.musicQueue?.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((model.musicQueue?.tracks ?? []).enumerated()), id: \.offset) { i, track in
                        HStack(spacing: 12) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let d = track.duration {
                                Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                        .onTapGesture { model.music(.playQueueItem(i)) }
                        .pointerTarget { model.music(.playQueueItem(i)) }
                    }
                }
            }
            .pointerScrollable()
            if model.musicQueue == nil {
                ThemedSpinner().frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 36)
    }
}

/// Player and Mac volume, mute, and (with Music) the AirPlay speakers to play to.
private struct SoundView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let volume = model.nowPlaying?.volume {
                    level(title: model.nowPlaying?.player ?? "Плеер", symbol: "music.note", value: volume) {
                        model.music(.setPlayerVolume($0))
                    }
                }
                if let audio = model.audio {
                    level(title: "Mac", symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          value: audio.muted ? 0 : audio.systemVolume) { model.music(.setSystemVolume($0)) }
                    Button(audio.muted ? "Включить звук" : "Выключить звук") { model.music(.toggleMute) }
                        .buttonStyle(.bordered)
                        .pointerTarget { model.music(.toggleMute) }
                    if !audio.airPlay.isEmpty {
                        Text("Воспроизводить на").font(.headline).padding(.top, 6)
                        ForEach(audio.airPlay) { device in
                            AirPlayRow(device: device) { toggle(device, in: audio.airPlay) }
                        }
                    }
                } else {
                    ThemedSpinner().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 36)
        }
        .pointerScrollable()
    }

    private func level(title: String, symbol: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label { Text(title) } icon: { Glyph(symbol) }.font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            LevelBar(value: value, onChange: set)
                .pointerDraggable(value: value, onChange: set)
        }
    }

    /// Several speakers can play at once (like the AirPlay menu); the last one can't be switched off.
    private func toggle(_ device: AirPlayDevice, in all: [AirPlayDevice]) {
        var selected = Set(all.filter(\.selected).map(\.name))
        if selected.contains(device.name) {
            guard selected.count > 1 else { return }
            selected.remove(device.name)
        } else {
            selected.insert(device.name)
        }
        model.audio?.airPlay = all.map { AirPlayDevice(name: $0.name, kind: $0.kind, selected: selected.contains($0.name)) }
        model.music(.setAirPlay(Array(selected)))
    }
}

private struct AirPlayRow: View {
    let device: AirPlayDevice
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Glyph(systemName: symbol).frame(width: 26)
            Text(device.name).lineLimit(1)
            Spacer()
            Glyph(systemName: device.selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(device.selected ? Color.accentColor : .secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(device.selected ? 0.1 : 0.05)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .pointerTarget(action: toggle)
    }

    private var symbol: String {
        let k = device.kind.lowercased()
        if k.contains("homepod") { return "homepod.fill" }
        if k.contains("tv") { return "appletv.fill" }
        if k.contains("computer") { return "laptopcomputer" }
        if k.contains("bluetooth") { return "headphones" }
        return "hifispeaker.fill"
    }
}

private struct Artwork: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.08))
            if let image {
                ThemedPicture(image: image)
            } else {
                Glyph(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}

private struct TrackInfo: View {
    let track: NowPlaying?

    var body: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? "Ничего не играет")
                .font(.title2.weight(.bold))
            Text(track.map { [$0.artist, $0.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") }
                 ?? "Запустите Музыку или Spotify на Mac")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
    }
}

private struct ProgressRow: View {
    let track: NowPlaying?

    var body: some View {
        // Extrapolate locally between updates so the bar moves smoothly without extra traffic.
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = track?.duration ?? 0
            let elapsed = min(currentElapsed(at: context.date), duration)
            VStack(spacing: 6) {
                ThemedBar(value: duration > 0 ? elapsed / duration : 0, height: 4)
                HStack {
                    Text(format(elapsed))
                    Spacer()
                    Text("-" + format(max(duration - elapsed, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .opacity(track?.duration == nil ? 0 : 1)
    }

    private func currentElapsed(at date: Date) -> Double {
        guard let track, let elapsed = track.elapsed else { return 0 }
        return track.playing ? elapsed + date.timeIntervalSince(track.timestamp) : elapsed
    }

    private func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Controls: View {
    let playing: Bool
    var compact = false
    let action: (MediaAction) -> Void

    var body: some View {
        HStack(spacing: compact ? 6 : 44) {
            button("backward.fill", size: compact ? 16 : 30) { action(.previous) }
            button(playing ? "pause.fill" : "play.fill", size: compact ? 24 : 44) { action(.togglePlayPause) }
            button("forward.fill", size: compact ? 16 : 30) { action(.next) }
        }
        .foregroundStyle(.primary)
    }

    private func button(_ symbol: String, size: CGFloat, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Glyph(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: compact ? 38 : 64, height: compact ? 38 : 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerTarget(action: perform)
    }
}
