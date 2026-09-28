import QwoviKit
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
            if !wide, size == .medium, geo.size.width > geo.size.height * 0.75 {
                squareCard(geo.size)
            } else {
                compactFlow(geo, wide: wide)
            }
        }
    }

    /// A roughly square half-page card: cover and title side by side, then the progress bar and big controls.
    private func squareCard(_ box: CGSize) -> some View {
        let cover = min(box.width * 0.42, box.height * 0.5)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Artwork(image: model.artwork, playing: model.nowPlaying?.playing ?? false, radius: 14)
                    .frame(width: cover, height: cover)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.nowPlaying?.title ?? L("Nothing playing")).font(.title3.weight(.semibold)).lineLimit(3)
                    Text(model.nowPlaying?.artist ?? L("Music / Spotify on the Mac"))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if let album = model.nowPlaying?.album, !album.isEmpty {
                        Text(album).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            ProgressRow(track: model.nowPlaying).padding(.top, 6)
            Controls(playing: model.nowPlaying?.playing ?? false, scale: 0.8) { model.perform($0) }
                .disabled(model.nowPlaying == nil)
        }
        // One tight group in the middle of the card, not cover at the top and buttons at the bottom.
        .frame(width: box.width, height: box.height)
    }

    private func compactFlow(_ geo: GeometryProxy, wide: Bool) -> some View {
        let w = geo.size.width, h = geo.size.height
        let progress = size == .medium || h > w * 1.5
        return Group {
            if wide {
                // Cover and column the same height: title level with the cover's top, buttons with its bottom.
                let cover = min(h, w * 0.4)
                HStack(spacing: 14) {
                    Artwork(image: model.artwork, playing: model.nowPlaying?.playing ?? false, radius: 12)
                        .frame(width: cover, height: cover)
                    VStack(alignment: .leading, spacing: 6) {
                        trackText
                        Spacer(minLength: 0)
                        if progress { ProgressRow(track: model.nowPlaying) }
                        Controls(playing: model.nowPlaying?.playing ?? false, scale: 0.6) { model.perform($0) }
                            .disabled(model.nowPlaying == nil)
                    }
                    .frame(height: cover)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Upright: one tight group — cover, title, bar, buttons — all the cover's width, centred in the tile.
                let info: CGFloat = progress ? 150 : 110
                let side = max(40, min(w, w * 0.9, h - info))
                VStack(alignment: .leading, spacing: 8) {
                    Artwork(image: model.artwork, playing: model.nowPlaying?.playing ?? false, radius: 12)
                        .frame(width: side, height: side)
                    trackText
                    if progress { ProgressRow(track: model.nowPlaying) }
                    Controls(playing: model.nowPlaying?.playing ?? false, scale: 0.6) { model.perform($0) }
                        .disabled(model.nowPlaying == nil)
                }
                .frame(width: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: w, height: h)
    }

    private var trackText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.nowPlaying?.title ?? L("Nothing playing"))
                .font(size == .small ? .subheadline.weight(.semibold) : .headline).lineLimit(2)
            Text(model.nowPlaying?.artist ?? L("Music / Spotify on the Mac"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var mode: Mode = {
        #if DEBUG
        // `--music-mode Sound` etc. for Simulator layout checks.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--music-mode"), i + 1 < args.count, let m = Mode(rawValue: args[i + 1]) { return m }
        #endif
        return .now
    }()

    enum Mode: String, CaseIterable {
        case now = "Now", queue = "Up next", sound = "Sound"
    }

    private var full: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Mode.allCases, id: \.self) { m in
                    Text(L(m.rawValue))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(m == mode ? Color.primary.opacity(0.18) : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { withAnimation(.snappy) { mode = m } }
                        .pointerTarget { withAnimation(.snappy) { mode = m } }
                }
            }
            .padding(.top, 4)
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
                : AnyLayout(VStackLayout(spacing: 32))
            // Upright: cover, title, bar and buttons share one column width, so their edges line up.
            let column = landscape ? 420 : max(160, min(geo.size.width - 56, 420, geo.size.height - 430))
            layout {
                Artwork(image: model.artwork, playing: model.nowPlaying?.playing ?? false)
                    .frame(width: landscape ? geo.size.height * 0.7 : column, height: landscape ? geo.size.height * 0.7 : column)
                VStack(spacing: 22) {
                    TrackInfo(track: model.nowPlaying)
                    SeekBar(track: model.nowPlaying) { model.music(.seek($0)) }
                    Controls(playing: model.nowPlaying?.playing ?? false) { model.perform($0) }
                        .disabled(model.nowPlaying == nil)
                    ExtrasRow(track: model.nowPlaying) { model.music($0) }
                }
                .frame(maxWidth: column)
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
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            toggle("shuffle", on: track?.shuffle == true, align: .leading) { send(.toggleShuffle) }
            Spacer(minLength: 0)
            if let liked = track?.liked {
                toggle(liked ? "star.fill" : "star", on: liked, align: .center) { send(.toggleLike) }
                Spacer(minLength: 0)
            }
            toggle(track?.repeatMode == "one" ? "repeat.1" : "repeat", on: (track?.repeatMode ?? "off") != "off",
                   align: .trailing) { send(.cycleRepeat) }
        }
        .disabled(track == nil)
    }

    private func toggle(_ symbol: String, on: Bool, align: Alignment, action: @escaping () -> Void) -> some View {
        Glyph(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(on ? theme.accent : .secondary)
            .frame(width: 44, height: 36, alignment: align)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .pointerTarget(action: action)
    }
}

/// Progress you can grab: drag with a finger, or press-and-drag / scroll with the Mac pointer.
/// The bar follows the finger, then glides on from where you let go (see `TrackProgress`).
private struct SeekBar: View {
    let track: NowPlaying?
    let seek: (Double) -> Void
    @State private var dragging: Double?
    @State private var pending: Double?

    var body: some View {
        TrackProgress(track: track, pending: $pending) { fraction, elapsed, duration in
            let shownFraction = dragging ?? fraction
            VStack(spacing: 6) {
                LevelBar(value: shownFraction, height: dragging == nil ? 5 : 9) { f in
                    dragging = f
                } onEnd: { f in
                    commit(f * duration)
                }
                .pointerDraggable(value: fraction) { commit($0 * duration) }
                PlaybackTimes(elapsed: dragging.map { $0 * duration } ?? elapsed, duration: duration)
            }
        }
        .opacity(track?.duration == nil ? 0 : 1)
    }

    private func commit(_ seconds: Double) {
        dragging = nil
        pending = seconds
        seek(seconds)
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
                    level(title: model.nowPlaying?.player ?? L("Player"), symbol: "music.note", value: volume) {
                        model.music(.setPlayerVolume($0))
                    }
                }
                if let audio = model.audio {
                    level(title: "Mac", symbol: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          value: audio.muted ? 0 : audio.systemVolume) { model.music(.setSystemVolume($0)) }
                    Button(audio.muted ? L("Unmute") : L("Mute")) { model.music(.toggleMute) }
                        .buttonStyle(PillButtonStyle())
                        .pointerTarget { model.music(.toggleMute) }
                    if !audio.airPlay.isEmpty {
                        Text("Play on").font(.headline).padding(.top, 6)
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
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Glyph(systemName: symbol).frame(width: 26)
            Text(device.name).lineLimit(1)
            Spacer()
            Glyph(systemName: device.selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(device.selected ? theme.accent : .secondary)
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

/// Cover art: a new cover fades and settles in; on pause the cover sinks back a little (like Music on iPhone).
private struct Artwork: View {
    let image: UIImage?
    var playing = true
    var radius: CGFloat = 18

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if image == nil, theme.style != .ascii {
                // No cover: a soft gradient in the theme's accent instead of a grey square.
                LinearGradient(colors: [theme.accent.opacity(0.55), theme.accent.opacity(0.15)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.08))
            }
            Group {
                if let image {
                    ThemedPicture(image: image)
                } else {
                    GeometryReader { geo in
                        Glyph(systemName: "music.note")
                            .font(.system(size: min(geo.size.width, geo.size.height) * 0.38, weight: .medium))
                            .foregroundStyle(.white.opacity(theme.style == .ascii ? 1 : 0.85))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .id(image)
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.08)), removal: .opacity))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(playing ? 0.5 : 0.25), radius: playing ? 20 : 10, y: playing ? 10 : 4)
        .scaleEffect(playing ? 1 : 0.88)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: playing)
        .animation(.easeInOut(duration: 0.45), value: image)
    }
}

private struct TrackInfo: View {
    let track: NowPlaying?

    var body: some View {
        ZStack {
            info
                .id(track?.title)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.spring(duration: 0.45, bounce: 0.2), value: track?.title)
    }

    private var info: some View {
        VStack(spacing: 6) {
            Text(track?.title ?? L("Nothing playing"))
                .font(.title2.weight(.bold))
            Text(track.map { [$0.artist, $0.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ") }
                 ?? L("Start Music or Spotify on the Mac"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
    }
}

private struct ProgressRow: View {
    let track: NowPlaying?
    @State private var pending: Double?

    var body: some View {
        TrackProgress(track: track, pending: $pending) { fraction, elapsed, duration in
            VStack(spacing: 6) {
                ThemedBar(value: fraction, height: 4)
                PlaybackTimes(elapsed: elapsed, duration: duration)
            }
        }
        .opacity(track?.duration == nil ? 0 : 1)
    }
}

/// Previous · play/pause · next spread across the column: the outer icons sit flush with its edges (under the
/// cover's and the progress bar's edges), play/pause in the middle. `scale` sizes everything (1 = whole page).
private struct Controls: View {
    let playing: Bool
    var scale: CGFloat = 1
    let action: (MediaAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("backward.fill", size: 30, align: .leading) { action(.previous) }
            Spacer(minLength: 4)
            button(playing ? "pause.fill" : "play.fill", size: 44, align: .center) { action(.togglePlayPause) }
            Spacer(minLength: 4)
            button("forward.fill", size: 30, align: .trailing) { action(.next) }
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.primary)
    }

    private func button(_ symbol: String, size: CGFloat, align: Alignment, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Glyph(systemName: symbol)
                .font(.system(size: size * scale))
                .contentTransition(.symbolEffect(.replace))
                .frame(minWidth: 44 * scale, minHeight: 56 * scale, alignment: align)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .pointerTarget(action: perform)
    }
}
