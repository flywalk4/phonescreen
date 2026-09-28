import SwiftUI

// The animated right half of each tour step. Every scene is drawn on a 480 × 340 stage in absolute coordinates, so
// the cursor and the dragged window can travel between the Mac and the phone. Loops run on the clock
// (TimelineView), which keeps them in step however long a page stays open.

enum Stage {
    static let size = CGSize(width: 480, height: 340)
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
/// 0 before `a`, 1 after `b`, eased in between.
private func span(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let p = clamp01((t - a) / (b - a))
    return p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
}
/// Rises over `a…b`, stays, falls over `c…d`.
private func bump(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
    t < c ? span(t, a, b) : 1 - span(t, c, d)
}
private func mix(_ a: CGPoint, _ b: CGPoint, _ p: Double) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
}
private func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * p }

// MARK: - 1. The phone asleep on the desk, then awake on a stand

struct IdleScene: View {
    let awake: Bool
    @State private var flash = 0.0

    var body: some View {
        ZStack {
            Ellipse().fill(RadialGradient(colors: [.white.opacity(0.08), .clear], center: .center, startRadius: 0, endRadius: 250))
                .frame(width: 540, height: 110)
                .position(x: 240, y: 292)
            MacMock(width: 270) {
                MacDesktop()
                    .overlay(alignment: .topTrailing) {
                        // The Mac notices the phone.
                        HStack(spacing: 4) {
                            Image(systemName: "iphone").font(.system(size: 7, weight: .bold))
                            Text("iPhone connected").font(.system(size: 7, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.top, 13).padding(.trailing, 6)
                        .offset(x: awake ? 0 : 120)
                        .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(awake ? 0.9 : 0), value: awake)
                    }
            }
            .position(x: 168, y: 166)

            // The stand appears under the phone as it gets up.
            StandShape()
                .fill(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                .frame(width: 84, height: 34)
                .position(x: 405, y: 276)
                .opacity(awake ? 1 : 0)
                .offset(y: awake ? 0 : 10)
                .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(awake ? 0.05 : 0), value: awake)

            PhoneMock(scale: 0.5, glow: awake ? .indigo : nil) {
                ZStack {
                    Color.black
                    Text("9:41").font(.system(size: 46, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.14))
                        .frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
                        .opacity(awake ? 0 : 1)
                    HomePage(revealed: awake)
                        .opacity(awake ? 1 : 0)
                        .animation(.easeOut(duration: 0.35), value: awake)
                    Color.white.opacity(flash).allowsHitTesting(false)
                }
            }
            // Lying flat on the desk, then standing up.
            .rotation3DEffect(.degrees(awake ? 6 : 72), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
            .position(x: 405, y: 176)
            .animation(.spring(response: 0.9, dampingFraction: 0.7), value: awake)

            if !awake { Snores().position(x: 440, y: 212).transition(.opacity) }
        }
        .frame(width: Stage.size.width, height: Stage.size.height)
        .onChange(of: awake) { _, on in
            guard on else { return }
            flash = 0.9
            withAnimation(.easeOut(duration: 0.8).delay(0.15)) { flash = 0 }
        }
    }
}

/// A wedge stand, seen from the front.
private struct StandShape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX + 10, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - 10, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// "z z z" drifting up from the sleeping phone.
private struct Snores: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                    Text("z")
                        .font(.system(size: 12 + 9 * p, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7 * sin(p * .pi)))
                        .offset(x: 16 * p + 5 * sin(p * 7), y: -70 * p)
                }
            }
        }
    }
}

// MARK: - 2. Pages at a glance

struct GlanceScene: View {
    @State private var page = 0
    @State private var appeared = false

    private let chips: [(LocalizedStringKey, String, Color, CGPoint)] = [
        ("Music", "music.note", .pink, CGPoint(x: -168, y: -118)),
        ("Calendar", "calendar", .red, CGPoint(x: 165, y: -126)),
        ("Weather", "cloud.sun.fill", .yellow, CGPoint(x: -182, y: -22)),
        ("Reminders", "checklist", .orange, CGPoint(x: 180, y: -34)),
        ("Notes", "note.text", .yellow, CGPoint(x: -168, y: 78)),
        ("Photos", "photo.on.rectangle.angled", .green, CGPoint(x: 172, y: 70)),
        ("Mac load", "gauge.with.dots.needle.67percent", .teal, CGPoint(x: -150, y: 150)),
        ("Mac apps", "square.grid.2x2.fill", .blue, CGPoint(x: 152, y: 150)),
    ]

    var body: some View {
        ZStack {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(chips.indices, id: \.self) { i in
                        let chip = chips[i]
                        FeatureChip(title: chip.0, symbol: chip.1, tint: chip.2)
                            .offset(x: chip.3.x, y: chip.3.y + 5 * sin(t * 1.3 + Double(i) * 0.9))
                            .scaleEffect(appeared ? 1 : 0.3)
                            .opacity(appeared ? 1 : 0)
                            .animation(.spring(response: 0.6, dampingFraction: 0.65).delay(0.15 + Double(i) * 0.06), value: appeared)
                    }
                }
            }
            PhoneMock(scale: 0.78, glow: .purple) {
                HStack(spacing: 0) {
                    HomePage()
                    MusicPage()
                    MonitorPage()
                }
                .frame(width: PhoneDesign.screen.width, alignment: .leading)
                .offset(x: -CGFloat(page) * PhoneDesign.screen.width)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(.white.opacity(i == page ? 0.9 : 0.3)).frame(width: i == page ? 14 : 5, height: 5)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: Stage.size.width, height: Stage.size.height)
        .onAppear { appeared = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.8))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { page = (page + 1) % 3 }
            }
        }
    }
}

struct FeatureChip: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .fixedSize()
    }
}

// MARK: - 3. The cursor crosses onto the phone

struct CursorScene: View {
    private static let period = 6.4
    // Stage coordinates (see the layout below).
    private let macScreenRight: CGFloat = 318
    private let start = CGPoint(x: 150, y: 196)
    private let edge = CGPoint(x: 316, y: 150)
    private let entry = CGPoint(x: 354, y: 150)
    /// The play button: phone origin (346.8, 65) + (bezel + its point on the screen, 88 × 260) × 0.56.
    private let play = CGPoint(x: 400, y: 214)

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            let onPhone = t >= 1.75 && t < 4.1
            let point: CGPoint = if t < 1.75 {
                mix(start, edge, span(t, 0.4, 1.5))
            } else if onPhone {
                mix(entry, play, span(t, 1.8, 2.8))
            } else {
                mix(edge, start, span(t, 4.2, 5.4))
            }
            let pressed = t > 2.9 && t < 3.05
            let playing = t >= 2.95
            let ripple = clamp01((t - 2.95) / 0.6)

            ZStack {
                MacMock(width: 300) { MacDesktop(edgeGlow: bump(t, 1.2, 1.55, 1.7, 2.2)) }
                    .position(x: 170, y: 190)
                PhoneMock(scale: 0.56, glow: onPhone ? .blue : nil) {
                    MusicPage(playing: playing)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(0.8 * (1 - ripple)), lineWidth: 2)
                                .frame(width: 42 + 50 * ripple, height: 42 + 50 * ripple)
                                .position(x: 88, y: 260)
                                .opacity(ripple > 0 && ripple < 1 ? 1 : 0)
                        }
                }
                .position(x: 400, y: 175)
                .animation(.easeOut(duration: 0.3), value: onPhone)

                Keycap(label: "esc")
                    .scaleEffect(0.7 + 0.3 * bump(t, 3.6, 3.8, 4.25, 4.5))
                    .opacity(bump(t, 3.6, 3.8, 4.25, 4.5))
                    .offset(y: t > 3.9 && t < 4.05 ? 2 : 0)
                    .position(x: 250, y: 312)

                if onPhone {
                    PhonePointer(pressed: pressed).position(point)
                } else {
                    MacArrow().position(point)
                }
            }
            .frame(width: Stage.size.width, height: Stage.size.height)
        }
    }
}

// MARK: - 4. A window dragged onto the phone as a second display

struct DisplayScene: View {
    private static let period = 7.0
    private let windowStart = CGPoint(x: 150, y: 150)
    private let windowSize = CGSize(width: 136, height: 88)
    private let phoneCenter = CGPoint(x: 400, y: 175)
    /// The phone's screen at scale 0.56.
    private let phoneScreen = CGSize(width: PhoneDesign.screen.width * 0.56, height: PhoneDesign.screen.height * 0.56)

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            let drag = span(t, 1.3, 3.0)
            // The window keeps its size until it's over the phone, then takes the phone's shape.
            let fit = span(t, 2.2, 3.1)
            let center = mix(windowStart, phoneCenter, drag)
            let size = CGSize(width: mix(windowSize.width, phoneScreen.width, fit), height: mix(windowSize.height, phoneScreen.height, fit))
            let lifted = t > 1.1 && t < 3.0
            let grab = CGPoint(x: center.x, y: center.y - size.height / 2 + 6)
            let resting = CGPoint(x: 250, y: 236)
            let scrollSpot = CGPoint(x: phoneCenter.x + 10, y: phoneCenter.y + 30)
            let cursor: CGPoint = if t < 1.1 {
                mix(resting, CGPoint(x: windowStart.x, y: windowStart.y - windowSize.height / 2 + 6), span(t, 0.2, 1.0))
            } else if t < 3.1 {
                grab
            } else if t < 5.2 {
                mix(grab, scrollSpot, span(t, 3.1, 3.7))
            } else {
                mix(scrollSpot, resting, span(t, 5.4, 6.6))
            }
            let scroll = 90 * span(t, 3.8, 4.6) + 80 * span(t, 4.7, 5.3)
            let fade = t > 5.3 ? 1 - bump(t, 5.3, 5.7, 6.4, 6.9) : 1
            let window: (center: CGPoint, size: CGSize)? = t > 5.7 && t < 6.4 ? nil : (center, size)

            ZStack {
                MacMock(width: 300) { MacDesktop(showsWindows: false).overlay(alignment: .bottomLeading) {
                    MiniWindow(tint: .green).frame(width: 90, height: 56).padding(10)
                } }
                .position(x: 170, y: 190)
                PhoneMock(scale: 0.56, glow: fit > 0.9 ? .teal : nil) {
                    ZStack {
                        Color.black
                        Image(systemName: "display").font(.system(size: 34)).foregroundStyle(.white.opacity(0.18))
                    }
                }
                .position(phoneCenter)
                .animation(.easeOut(duration: 0.4), value: fit > 0.9)

                if let window {
                    MiniWindow(scroll: scroll, chat: true)
                        .frame(width: window.size.width, height: window.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: mix(6, 17, fit), style: .continuous))
                        .shadow(color: .black.opacity(lifted ? 0.55 : 0.25), radius: lifted ? 18 : 6, y: lifted ? 12 : 3)
                        .scaleEffect(lifted ? 1.04 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
                        .opacity(fade)
                        .position(window.center)
                }
                MacArrow().position(cursor)
            }
            .frame(width: Stage.size.width, height: Stage.size.height)
        }
    }
}

// MARK: - 5. Themes

struct ThemesScene: View {
    @State private var index = 0

    var body: some View {
        let theme = MockTheme.all[index]
        ZStack {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                PhoneMock(scale: 0.7, glow: theme.accent) {
                    HomePage()
                }
                .rotation3DEffect(.degrees(12 * sin(t * 0.6)), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(4 * sin(t * 0.43)), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            }
            .position(x: 240, y: 148)

            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(MockTheme.all.indices, id: \.self) { i in
                        let swatch = MockTheme.all[i]
                        Circle()
                            .fill(LinearGradient(colors: swatch.background, startPoint: .top, endPoint: .bottom))
                            .overlay(Circle().fill(swatch.accent).frame(width: 9, height: 9))
                            .overlay(Circle().strokeBorder(.white.opacity(i == index ? 0.95 : 0.2), lineWidth: i == index ? 2 : 1))
                            .frame(width: 28, height: 28)
                            .scaleEffect(i == index ? 1.18 : 1)
                    }
                }
                Text(theme.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.opacity)
                    .id(index)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            .position(x: 240, y: 312)
        }
        .environment(\.mockTheme, theme)
        .frame(width: Stage.size.width, height: Stage.size.height)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.smooth(duration: 0.7)) { index = (index + 1) % MockTheme.all.count }
            }
        }
    }
}

// MARK: - 6. Waiting for the phone / connected

struct ConnectScene: View {
    let connected: Bool
    let link: String?
    /// The tour's last step: the phone celebrates.
    var finished = false

    var body: some View {
        ZStack {
            if !connected {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            let p = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                            RoundedRectangle(cornerRadius: 40 + 60 * p, style: .continuous)
                                .strokeBorder(Color.cyan.opacity(0.55 * (1 - p)), lineWidth: 1.5)
                                .frame(width: 140 + 230 * p, height: 290 + 150 * p)
                        }
                    }
                }
                .position(x: 240, y: 158)
                .transition(.opacity)
            }
            PhoneMock(scale: 0.72, glow: connected ? .green : .cyan.opacity(0.6)) {
                ZStack {
                    if connected {
                        HomePage().transition(.opacity.combined(with: .scale(scale: 1.1)))
                    } else {
                        VStack(spacing: 12) {
                            Spinner(size: 18)
                            Text("Waiting for the Mac").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(ThemeFill())
                        .transition(.opacity)
                    }
                }
            }
            .position(x: 240, y: 158)

            if connected {
                HStack(spacing: 6) {
                    Image(systemName: finished ? "party.popper.fill" : "checkmark.circle.fill").foregroundStyle(finished ? .yellow : .green)
                    if finished { Text("All set") } else { Text("Connected") }
                    if let link, !finished { Text(verbatim: "· \(link)").foregroundStyle(.white.opacity(0.6)) }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.1)))
                .overlay(Capsule().strokeBorder(.green.opacity(0.5), lineWidth: 1))
                .position(x: 240, y: 318)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: Stage.size.width, height: Stage.size.height)
        .animation(.spring(response: 0.6, dampingFraction: 0.72), value: connected)
    }
}

// MARK: - Touch: a finger opens a card and swipes the pages

struct TouchScene: View {
    private static let period = 6.4
    private static let scale: CGFloat = 0.78
    /// The phone's top-left corner on the stage (centred at 240, 170).
    private let origin = CGPoint(x: 240 - PhoneDesign.size.width * scale / 2, y: 170 - PhoneDesign.size.height * scale / 2)

    /// A point on the phone's screen, in stage coordinates.
    private func onScreen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + (PhoneDesign.bezel + x) * Self.scale, y: origin.y + (PhoneDesign.bezel + y) * Self.scale)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            // Tap the music card: it opens over the page, then closes.
            let open = t < 2.7 ? span(t, 0.8, 1.25) : 1 - span(t, 2.7, 3.1)
            // Then a swipe to the next page and back.
            let swipe = t < 4.8 ? span(t, 3.5, 4.1) : 1 - span(t, 4.9, 5.5)
            let card = onScreen(48, 78)
            let finger: CGPoint = t < 3.2 ? card
                : t < 4.8 ? mix(onScreen(150, 200), onScreen(40, 200), span(t, 3.5, 4.1))
                : mix(onScreen(40, 200), onScreen(150, 200), span(t, 4.9, 5.5))
            let visible = t < 3.2 ? bump(t, 0.3, 0.6, 1.0, 1.3) : t < 4.8 ? bump(t, 3.25, 3.45, 4.1, 4.35) : bump(t, 4.75, 4.9, 5.5, 5.75)
            let ripple = clamp01((t - 0.75) / 0.5)
            let width = PhoneDesign.screen.width

            ZStack {
                PhoneMock(scale: Self.scale, glow: .pink) {
                    ZStack {
                        HStack(spacing: 0) {
                            HomePage()
                            MonitorPage()
                        }
                        .frame(width: width, alignment: .leading)
                        .offset(x: -width * swipe)
                        .scaleEffect(1 - 0.06 * open)
                        .opacity(1 - 0.7 * open)
                        MusicPage()
                            .scaleEffect(0.3 + 0.7 * open, anchor: UnitPoint(x: 48 / width, y: 78 / PhoneDesign.screen.height))
                            .opacity(open)
                    }
                }
                .position(x: 240, y: 170)

                // The finger: a soft touch mark with a ring on tap.
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.9 * (1 - ripple)), lineWidth: 2)
                        .frame(width: 30 + 40 * ripple, height: 30 + 40 * ripple)
                        .opacity(ripple > 0 && ripple < 1 && t < 2 ? 1 : 0)
                    Circle().fill(.white.opacity(0.45)).frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 4)
                }
                .opacity(visible)
                .position(finger)

                HStack(spacing: 18) {
                    Label { Text("Tap to open") } icon: { Image(systemName: "hand.tap.fill") }
                        .opacity(t < 3.2 ? 1 : 0.35)
                    Label { Text("Swipe to turn") } icon: { Image(systemName: "hand.draw.fill") }
                        .opacity(t >= 3.2 ? 1 : 0.35)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .animation(.easeOut(duration: 0.3), value: t < 3.2)
                .position(x: 240, y: 330)
            }
            .frame(width: Stage.size.width, height: Stage.size.height)
        }
    }
}
