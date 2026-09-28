import PhoneScreenKit
import SwiftUI

/// Where playback is, drawn smoothly: the position is extrapolated every frame while playing, a seek shows up at once
/// (before the Mac confirms it), and any jump — a seek here, from the Mac, or a new track — glides to the new spot
/// instead of snapping. `content` gets (fraction 0…1, elapsed s, duration s).
struct TrackProgress<Content: View>: View {
    let track: NowPlaying?
    /// A position the user just picked, shown until the Mac's next update arrives.
    @Binding var pending: Double?
    @ViewBuilder var content: (_ fraction: Double, _ elapsed: Double, _ duration: Double) -> Content

    @State private var glide: Glide?
    @State private var pendingAt = Date()

    private struct Glide {
        let from: Double
        let start: Date
        static var length: Double { 0.45 }
    }

    var body: some View {
        let playing = track?.playing == true
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing && glide == nil)) { context in
            let now = context.date
            let duration = track?.duration ?? 0
            let target = min(elapsed(at: now), duration)
            let shown = glide.map { g -> Double in
                let t = min(1, now.timeIntervalSince(g.start) / Glide.length)
                return g.from + (target - g.from) * Self.ease(t)
            } ?? target
            content(duration > 0 ? shown / duration : 0, shown, duration)
        }
        .task(id: glide?.start) {
            // End the glide after it has run, so the timeline can pause again when playback is paused.
            guard glide != nil else { return }
            try? await Task.sleep(for: .seconds(Glide.length))
            glide = nil
        }
        .onChange(of: pending) { old, new in
            let from = elapsed(at: Date(), pending: old)
            if new != nil { pendingAt = Date() }
            startGlide(from: from)
        }
        .onChange(of: track) { old, new in
            // The Mac answered: its value replaces the optimistic one (which glides via `pending`).
            if pending != nil { pending = nil; return }
            // A seek from the Mac or a new track: glide when the position jumped.
            guard let old, let new, let e0 = old.elapsed, let e1 = new.elapsed else { return }
            let before = old.playing ? e0 + Date().timeIntervalSince(old.timestamp) : e0
            let after = new.playing ? e1 + Date().timeIntervalSince(new.timestamp) : e1
            if abs(before - after) > 1.5 { startGlide(from: min(before, new.duration ?? before)) }
        }
    }

    private func startGlide(from value: Double) {
        glide = Glide(from: value, start: Date())
    }

    private func elapsed(at date: Date) -> Double { elapsed(at: date, pending: pending) }

    private func elapsed(at date: Date, pending: Double?) -> Double {
        guard let track else { return 0 }
        if let pending { return pending + (track.playing ? date.timeIntervalSince(pendingAt) : 0) }
        guard let elapsed = track.elapsed else { return 0 }
        return track.playing ? elapsed + date.timeIntervalSince(track.timestamp) : elapsed
    }

    /// Ease-out with a touch of overshoot, like a soft spring.
    private static func ease(_ t: Double) -> Double {
        let c1 = 1.2, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}

/// "1:10" / "-2:50", with digits that roll when they change.
struct PlaybackTimes: View {
    let elapsed: Double
    let duration: Double

    var body: some View {
        HStack {
            Text(Self.format(elapsed))
            Spacer()
            Text("-" + Self.format(max(duration - elapsed, 0)))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
        .animation(.snappy, value: Int(elapsed))
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
