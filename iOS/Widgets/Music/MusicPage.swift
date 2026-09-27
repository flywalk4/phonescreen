import PhoneScreenKit
import SwiftUI

struct MusicPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let layout = landscape
                ? AnyLayout(HStackLayout(spacing: 32))
                : AnyLayout(VStackLayout(spacing: 28))
            layout {
                Artwork(image: model.artwork)
                    .frame(maxWidth: landscape ? geo.size.height * 0.7 : geo.size.width * 0.78)
                VStack(spacing: 22) {
                    TrackInfo(track: model.nowPlaying)
                    ProgressRow(track: model.nowPlaying)
                    Controls(playing: model.nowPlaying?.playing ?? false) { model.perform($0) }
                        .disabled(model.nowPlaying == nil)
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Artwork: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.08))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary)
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
                ProgressView(value: duration > 0 ? elapsed / duration : 0)
                    .tint(.white)
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
    let action: (MediaAction) -> Void

    var body: some View {
        HStack(spacing: 44) {
            button("backward.fill", size: 30) { action(.previous) }
            button(playing ? "pause.fill" : "play.fill", size: 44) { action(.togglePlayPause) }
            button("forward.fill", size: 30) { action(.next) }
        }
        .foregroundStyle(.white)
    }

    private func button(_ symbol: String, size: CGFloat, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerTarget(action: perform)
    }
}
