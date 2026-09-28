import QwoviKit
import SwiftUI
import UIKit

/// The Mac's welcome tour, on the phone itself: a hello when it connects, then "click here with the Mac's cursor",
/// "now tap with your finger" — each answered back to the Mac, which ticks the step off — and a finish.
struct TourOverlay: View {
    @EnvironmentObject private var model: PhoneModel
    let step: TourStep
    @State private var done: Set<TourStep> = []
    /// A gentle "not like that": a finger on the cursor's target, or the cursor on the finger's.
    @State private var hint: LocalizedStringKey?
    @State private var burst: Date?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.16), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            Glow(color: done.contains(step) || step == .finish ? .green : step == .touch ? .pink : .indigo)
            VStack(spacing: 22) {
                Spacer(minLength: 0)
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .multilineTextAlignment(.center)
            if let burst { Confetti(start: burst).allowsHitTesting(false) }
        }
        .foregroundStyle(.white)
        .onChange(of: step) { _, new in
            hint = nil
            if new == .finish { celebrate() }
        }
        .onAppear { if step == .finish { celebrate() } }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .hello:
            Waving()
            Title("Hi! I'm connected to your Mac")
            Subtitle("Carry on in the window on the Mac — the phone will join in.")
        case .cursor:
            if done.contains(.cursor) {
                Success()
                Title("The cursor is on the phone!")
                Subtitle("Click, scroll and type here. Esc brings the cursor back to the Mac.")
            } else {
                Title("Bring the Mac's cursor here")
                Subtitle("Push it past the edge of the Mac's screen, then click the circle.")
                Target(symbol: "cursorarrow.rays", tint: .indigo)
                    .pointerTarget { finish(.cursor, event: .clicked) }
                    .onTapGesture { nudge("With the Mac's cursor this time — your finger is next") }
                    .overlay(alignment: macSideAlignment) { Chevrons(pointing: model.layout.macSide.opposite) }
                HintLine(hint: hint)
            }
        case .touch:
            if done.contains(.touch) {
                Success()
                Title("Touch works too")
                Subtitle("Tap a card to open it, swipe to turn pages, hold a card to peek at it.")
            } else {
                Title("Now touch the screen")
                Subtitle("The same widgets answer your finger — tap the circle.")
                Target(symbol: "hand.tap.fill", tint: .pink)
                    .onTapGesture { finish(.touch, event: .touched) }
                    .pointerTarget { nudge("Now with your finger") }
                HintLine(hint: hint)
            }
        case .finish:
            Success()
            Title("All set!")
            Subtitle("Close the tour on the Mac and your pages come back.")
        }
    }

    /// Where the Mac is, relative to the phone's screen: the arrows come from there.
    private var macSideAlignment: Alignment {
        switch model.layout.macSide {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func finish(_ step: TourStep, event: TourEvent) {
        guard !done.contains(step) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        model.sendTour(event)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { _ = done.insert(step) }
        burst = .now
    }

    private func nudge(_ text: LocalizedStringKey) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { hint = text }
    }

    private func celebrate() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        burst = .now
    }
}

private struct Title: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.system(.title, design: .rounded).weight(.bold)).fixedSize(horizontal: false, vertical: true)
            .transition(.opacity.combined(with: .offset(y: 10)))
    }
}

private struct Subtitle: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }
}

private struct HintLine: View {
    let hint: LocalizedStringKey?
    var body: some View {
        Text(hint ?? " ").font(.footnote.weight(.medium)).foregroundStyle(.yellow)
            .opacity(hint == nil ? 0 : 1)
            .id(hint == nil)
            .transition(.opacity)
    }
}

/// A big pulsing circle to hit.
private struct Target: View {
    let symbol: String
    let tint: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 2 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Circle().strokeBorder(tint.opacity(0.7 * (1 - p)), lineWidth: 2)
                        .frame(width: 130 + 110 * p, height: 130 + 110 * p)
                }
                Circle().fill(tint.gradient).frame(width: 130, height: 130)
                    .shadow(color: tint.opacity(0.6), radius: 24)
                    .scaleEffect(1 + 0.04 * sin(t * 3))
                Image(systemName: symbol).font(.system(size: 46, weight: .semibold))
            }
            .frame(width: 240, height: 240)
            .contentShape(Circle().inset(by: 50))
        }
    }
}

/// Arrows marching in from the Mac's side.
private struct Chevrons: View {
    let pointing: ScreenEdge

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let stack = ForEach(0..<3, id: \.self) { i in
                Image(systemName: "chevron.\(direction)")
                    .font(.system(size: 18, weight: .heavy))
                    .opacity(0.25 + 0.75 * max(0, sin(t * 4 - Double(i) * 0.9)))
            }
            Group {
                if pointing.isVertical { HStack(spacing: 2) { stack } } else { VStack(spacing: 2) { stack } }
            }
            .foregroundStyle(.white.opacity(0.8))
        }
        .offset(x: pointing == .right ? -34 : pointing == .left ? 34 : 0, y: pointing == .bottom ? -34 : pointing == .top ? 34 : 0)
    }

    private var direction: String {
        switch pointing {
        case .left: "left"
        case .right: "right"
        case .top: "up"
        case .bottom: "down"
        }
    }
}

private struct Waving: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Text(verbatim: "👋")
                .font(.system(size: 84))
                .rotationEffect(.degrees(18 * sin(t * 7) * max(0, sin(t * 1.4))), anchor: .bottomTrailing)
        }
    }
}

private struct Success: View {
    @State private var shown = false
    var body: some View {
        ZStack {
            Circle().fill(Color.green.gradient).frame(width: 110, height: 110).shadow(color: .green.opacity(0.6), radius: 26)
            Image(systemName: "checkmark").font(.system(size: 48, weight: .heavy))
        }
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { shown = true } }
    }
}

private struct Glow: View {
    let color: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().fill(color.opacity(0.45)).frame(width: 420, height: 420)
                .offset(x: 60 * cos(t / 4), y: -120 + 50 * sin(t / 5))
                .blur(radius: 90)
        }
        .animation(.smooth(duration: 0.8), value: color)
    }
}

/// A one-shot burst of confetti from the middle of the screen.
private struct Confetti: View {
    let start: Date
    private static let colors: [Color] = [.pink, .yellow, .green, .cyan, .orange, .purple, .white]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { gc, size in
                guard t < 2.6 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.42)
                for i in 0..<60 {
                    let seed = Double(i) * 12.9898
                    let angle = (sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1) * .pi * 2
                    let speed = 180 + abs((cos(seed) * 24634.6345).truncatingRemainder(dividingBy: 1)) * 320
                    let x = origin.x + cos(angle) * speed * t
                    let y = origin.y + sin(angle) * speed * t + 420 * t * t
                    let spin = Angle.radians(t * (4 + Double(i % 5)))
                    var piece = gc
                    piece.opacity = max(0, 1 - t / 2.6)
                    piece.translateBy(x: x, y: y)
                    piece.rotate(by: spin)
                    piece.fill(Path(roundedRect: CGRect(x: -4, y: -2.5, width: 8, height: 5), cornerRadius: 1.5),
                               with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
    }
}
