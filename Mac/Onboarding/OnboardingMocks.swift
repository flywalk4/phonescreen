import AppKit
import SwiftUI

// Drawings for the welcome tour: an iPhone, a Mac display and the phone's pages in miniature.
// The phone is drawn at a fixed design size (190 × 393 pt, screen 176 × 379) and scaled as a whole, so every scene
// can place things on its screen in the same coordinates.

enum PhoneDesign {
    static let size = CGSize(width: 190, height: 393)
    static let bezel: CGFloat = 7
    static let screen = CGSize(width: size.width - bezel * 2, height: size.height - bezel * 2)
    static let corner: CGFloat = 38
}

/// An iPhone 15-ish: titanium rim, black bezel, Dynamic Island; `screen` fills the display.
struct PhoneMock<Screen: View>: View {
    var scale: CGFloat = 1
    var glow: Color? = nil
    @ViewBuilder var screen: Screen

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: PhoneDesign.corner, style: .continuous)
                .fill(Color(white: 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: PhoneDesign.corner, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08), .white.opacity(0.3)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
                )
            screen
                .frame(width: PhoneDesign.screen.width, height: PhoneDesign.screen.height)
                .clipShape(RoundedRectangle(cornerRadius: PhoneDesign.corner - PhoneDesign.bezel, style: .continuous))
                .padding(PhoneDesign.bezel)
            Capsule().fill(.black).frame(width: 56, height: 16).padding(.top, 15)
        }
        .frame(width: PhoneDesign.size.width, height: PhoneDesign.size.height)
        .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.5 : 0.55), radius: glow == nil ? 18 : 34, y: glow == nil ? 12 : 0)
        .scaleEffect(scale)
        .frame(width: PhoneDesign.size.width * scale, height: PhoneDesign.size.height * scale)
    }
}

/// A Studio Display-like monitor on a stand. The screen is `width` × `width * 0.64`.
struct MacMock<Screen: View>: View {
    var width: CGFloat = 300
    @ViewBuilder var screen: Screen

    static func screenHeight(_ width: CGFloat) -> CGFloat { width * 0.64 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.09))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                screen
                    .frame(width: width - 12, height: Self.screenHeight(width) - 12)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(width: width, height: Self.screenHeight(width))
            LinearGradient(colors: [Color(white: 0.55), Color(white: 0.32)], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.16, height: 24)
            Capsule().fill(LinearGradient(colors: [Color(white: 0.6), Color(white: 0.35)], startPoint: .top, endPoint: .bottom))
                .frame(width: width * 0.36, height: 6)
        }
        .shadow(color: .black.opacity(0.45), radius: 20, y: 14)
    }
}

/// The Mac's desktop: a Sonoma-ish wallpaper, a menu bar and two windows.
struct MacDesktop: View {
    /// 0…1: the right edge lights up where the cursor crosses to the phone.
    var edgeGlow: Double = 0
    var showsWindows = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.16, blue: 0.45), Color(red: 0.55, green: 0.25, blue: 0.5),
                                    Color(red: 0.95, green: 0.55, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.28)).frame(height: 8)
                .overlay(alignment: .leading) {
                    HStack(spacing: 5) {
                        Image(systemName: "applelogo").font(.system(size: 5))
                        ForEach(0..<4, id: \.self) { i in Capsule().frame(width: CGFloat([10, 8, 12, 7][i]), height: 2.5) }
                    }
                    .foregroundStyle(.white.opacity(0.8)).padding(.leading, 6)
                }
            if showsWindows {
                MiniWindow(tint: .blue).frame(width: 118, height: 76).offset(x: 16, y: 22)
                MiniWindow(tint: .orange).frame(width: 96, height: 64).offset(x: 110, y: 64)
            }
        }
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.clear, .cyan.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
                .opacity(edgeGlow)
        }
    }
}

/// A window in miniature: traffic lights and a few lines of content.
struct MiniWindow: View {
    var tint: Color = .blue
    var scroll: CGFloat = 0
    var chat = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 5, height: 5)
                Circle().fill(.yellow).frame(width: 5, height: 5)
                Circle().fill(.green).frame(width: 5, height: 5)
                Spacer()
            }
            .padding(.horizontal, 6).frame(height: 12)
            .background(Color(white: 0.2))
            Group {
                if chat { ChatLines(scroll: scroll) } else { DocLines(tint: tint) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .background(Color(white: 0.13))
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
    }
}

private struct DocLines: View {
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(tint.opacity(0.9)).frame(width: 40, height: 4)
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(.white.opacity(0.22)).frame(width: CGFloat([70, 52, 64, 44, 58][i]), height: 3)
            }
        }
        .padding(8)
    }
}

/// A chat that scrolls: what someone might park on the phone.
private struct ChatLines: View {
    var scroll: CGFloat
    var body: some View {
        VStack(spacing: 7) {
            ForEach(0..<14, id: \.self) { i in
                let mine = i % 3 == 1
                HStack {
                    if mine { Spacer(minLength: 16) }
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(mine ? Color.blue.opacity(0.85) : Color.white.opacity(0.16))
                        .frame(height: CGFloat([16, 22, 16, 28, 16, 22][i % 6]))
                        .frame(maxWidth: CGFloat([60, 44, 70, 52, 38, 66][i % 6]))
                    if !mine { Spacer(minLength: 16) }
                }
            }
        }
        .padding(8)
        .offset(y: -scroll)
    }
}

/// The Mac's own arrow cursor, its hot spot at the view's centre.
struct MacArrow: View {
    private static let cursor = NSCursor.arrow

    var body: some View {
        let image = Self.cursor.image
        let hot = Self.cursor.hotSpot
        Image(nsImage: image)
            .frame(width: image.size.width, height: image.size.height)
            .offset(x: image.size.width / 2 - hot.x, y: image.size.height / 2 - hot.y)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

/// A spinner drawn in SwiftUI (the AppKit one doesn't show up in snapshots, and this one matches the tour).
struct Spinner: View {
    var size: CGFloat = 14
    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0.12, to: 0.82)
                .stroke(AngularGradient(colors: [.white.opacity(0), .white], center: .center),
                        style: StrokeStyle(lineWidth: size / 7, lineCap: .round))
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
        }
        .frame(width: size, height: size)
    }
}

/// The phone's own pointer: a soft round dot, as on an iPad.
struct PhonePointer: View {
    var pressed = false
    var body: some View {
        Circle().fill(Color(white: 0.75).opacity(0.75))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
            .frame(width: pressed ? 11 : 14, height: pressed ? 11 : 14)
            .shadow(color: .black.opacity(0.35), radius: 3)
    }
}

struct Keycap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.2))
                .shadow(color: .black.opacity(0.6), radius: 0, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Themes

/// A look for the miniature pages (the tour cycles through a few of the real themes).
struct MockTheme: Equatable {
    var background: [Color]
    var card: Color
    var accent: Color
    var text: Color = .white
    var name: LocalizedStringKey

    static func == (a: MockTheme, b: MockTheme) -> Bool { a.background == b.background && a.accent == b.accent }

    static let graphite = MockTheme(background: [Color(white: 0.13), Color(white: 0.05)], card: .white.opacity(0.08),
                                    accent: .orange, name: "Graphite")
    static let catppuccin = MockTheme(background: [Color(hex: 0x1E1E2E), Color(hex: 0x11111B)], card: Color(hex: 0x313244),
                                      accent: Color(hex: 0xCBA6F7), text: Color(hex: 0xCDD6F4), name: "Catppuccin")
    static let pastel = MockTheme(background: [Color(hex: 0xFDF2F8), Color(hex: 0xE0F2FE)], card: .white.opacity(0.75),
                                  accent: Color(hex: 0xEC4899), text: Color(hex: 0x1F2937), name: "Pastel")
    static let gruvbox = MockTheme(background: [Color(hex: 0x282828), Color(hex: 0x1D2021)], card: Color(hex: 0x3C3836),
                                   accent: Color(hex: 0xFABD2F), text: Color(hex: 0xEBDBB2), name: "Gruvbox")
    static let ocean = MockTheme(background: [Color(hex: 0x0B3D91), Color(hex: 0x041A3F)], card: .white.opacity(0.1),
                                 accent: .cyan, name: "Ocean")
    static let all = [graphite, catppuccin, pastel, gruvbox, ocean]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private struct MockThemeKey: EnvironmentKey { static let defaultValue = MockTheme.graphite }

extension EnvironmentValues {
    var mockTheme: MockTheme {
        get { self[MockThemeKey.self] }
        set { self[MockThemeKey.self] = newValue }
    }
}

// MARK: - Pages

/// The phone's first page: a 2 × 2 grid and reminders. Cards pop in one after another when `revealed` turns on.
struct HomePage: View {
    var revealed = true
    @Environment(\.mockTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            StatusRow().pop(revealed, 0)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                MusicCard().pop(revealed, 1)
                CalendarCard().pop(revealed, 2)
                GaugeCard().pop(revealed, 3)
                WeatherCard().pop(revealed, 4)
            }
            RemindersCard().pop(revealed, 5)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(width: PhoneDesign.screen.width, height: PhoneDesign.screen.height)
        .background(ThemeFill())
        .foregroundStyle(theme.text)
    }
}

struct ThemeFill: View {
    @Environment(\.mockTheme) private var theme
    var body: some View {
        LinearGradient(colors: theme.background, startPoint: .top, endPoint: .bottom)
    }
}

/// Time and date on either side of the island.
private struct StatusRow: View {
    var body: some View {
        HStack {
            Text("9:41")
            Spacer()
            Text(Date.tourDay, format: .dateTime.weekday(.abbreviated).day())
        }
        .font(.system(size: 9, weight: .semibold))
        .opacity(0.6)
        .padding(.horizontal, 10)
        .frame(height: 16)
    }
}

extension Date {
    /// A fixed Monday for the drawings, so screenshots don't change from day to day.
    static let tourDay = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9, minute: 41)) ?? .now
}

struct Card<Content: View>: View {
    var height: CGFloat = 92
    @ViewBuilder var content: Content
    @Environment(\.mockTheme) private var theme

    var body: some View {
        content
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.card))
    }
}

struct Artwork: View {
    var side: CGFloat = 34
    var spin: Double = 0
    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .fill(AngularGradient(colors: [.pink, .orange, .purple, .indigo, .pink], center: .center, angle: .degrees(spin)))
            .overlay(Image(systemName: "music.note").font(.system(size: side * 0.36, weight: .bold)).foregroundStyle(.white.opacity(0.85)))
            .frame(width: side, height: side)
    }
}

/// Bars that bounce while `playing`.
struct Equalizer: View {
    var playing = true
    var count = 4
    var height: CGFloat = 12
    var color: Color = .white

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let level = playing ? 0.3 + 0.7 * abs(sin(t * (3 + Double(i) * 0.9) + Double(i) * 1.3)) : 0.2
                    Capsule().fill(color).frame(width: 2.5, height: height * level)
                }
            }
            .frame(height: height, alignment: .bottom)
        }
    }
}

private struct MusicCard: View {
    @Environment(\.mockTheme) private var theme
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Artwork()
                    Spacer()
                    Equalizer(color: theme.accent)
                }
                Spacer(minLength: 0)
                Text("Midnight City").font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                Text("M83").font(.system(size: 8.5)).opacity(0.6)
            }
        }
    }
}

private struct CalendarCard: View {
    @Environment(\.mockTheme) private var theme
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 1) {
                Text(Date.tourDay, format: .dateTime.weekday(.wide)).font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.red).textCase(.uppercase)
                Text("28").font(.system(size: 26, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Capsule().fill(theme.accent).frame(width: 2.5, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Standup").font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
                        Text("10:00").font(.system(size: 8)).opacity(0.6)
                    }
                }
            }
        }
    }
}

/// CPU load as a ring that breathes.
private struct GaugeCard: View {
    @Environment(\.mockTheme) private var theme
    var body: some View {
        Card {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let load = 0.42 + 0.18 * sin(t * 0.9) + 0.06 * sin(t * 3.1)
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU").font(.system(size: 8.5, weight: .bold)).opacity(0.6)
                    ZStack {
                        Circle().stroke(theme.text.opacity(0.12), lineWidth: 5)
                        Circle().trim(from: 0, to: load)
                            .stroke(theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(load * 100))%").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 50, height: 50)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct WeatherCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.animation) { context in
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.yellow)
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 36) * 10))
                }
                Spacer(minLength: 0)
                Text("21°").font(.system(size: 22, weight: .medium, design: .rounded))
                Text("Sunny").font(.system(size: 8.5)).opacity(0.6)
            }
        }
    }
}

private struct RemindersCard: View {
    @Environment(\.mockTheme) private var theme
    private let items: [LocalizedStringKey] = ["Call Anna", "Buy coffee beans", "Send the invoice"]

    var body: some View {
        Card(height: 104) {
            TimelineView(.periodic(from: .now, by: 1.6)) { context in
                // One reminder ticks itself off and back, so the card never looks frozen.
                let done = Int(context.date.timeIntervalSinceReferenceDate / 1.6) % 4
                VStack(alignment: .leading, spacing: 7) {
                    Text("Reminders").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.accent)
                    ForEach(items.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            Image(systemName: i < done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(i < done ? theme.accent : theme.text.opacity(0.4))
                                .contentTransition(.symbolEffect(.replace))
                            Text(items[i]).font(.system(size: 9.5)).strikethrough(i < done).opacity(i < done ? 0.5 : 1)
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: done)
                    }
                }
            }
        }
    }
}

/// The music widget opened full screen.
struct MusicPage: View {
    var playing = true
    @Environment(\.mockTheme) private var theme

    var body: some View {
        TimelineView(.animation(paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 10) {
                Spacer().frame(height: 34)
                Artwork(side: 124, spin: playing ? t * 30 : 0)
                    .shadow(color: .pink.opacity(0.45), radius: 20, y: 8)
                    .scaleEffect(playing ? 1 : 0.9)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: playing)
                VStack(spacing: 2) {
                    Text("Midnight City").font(.system(size: 13, weight: .bold))
                    Text("M83").font(.system(size: 10)).opacity(0.6)
                }
                .padding(.top, 8)
                ProgressLine(value: playing ? 0.3 + (t.truncatingRemainder(dividingBy: 20)) / 40 : 0.3)
                    .padding(.horizontal, 22)
                HStack(spacing: 26) {
                    Image(systemName: "backward.fill")
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(theme.text))
                        .foregroundStyle(theme.background.last ?? .black)
                    Image(systemName: "forward.fill")
                }
                .font(.system(size: 13))
                Equalizer(playing: playing, count: 9, height: 18, color: theme.accent).padding(.top, 6)
                Spacer()
            }
        }
        .frame(width: PhoneDesign.screen.width, height: PhoneDesign.screen.height)
        .background(ThemeFill())
        .foregroundStyle(theme.text)
    }
}

private struct ProgressLine: View {
    let value: Double
    @Environment(\.mockTheme) private var theme
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.text.opacity(0.15))
                Capsule().fill(theme.text.opacity(0.8)).frame(width: geo.size.width * min(1, value))
            }
        }
        .frame(height: 3)
    }
}

/// The system monitor page: two rings and a scrolling load graph.
struct MonitorPage: View {
    @Environment(\.mockTheme) private var theme

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 12) {
                Spacer().frame(height: 30)
                HStack(spacing: 14) {
                    Ring(value: 0.46 + 0.2 * sin(t * 0.8), label: "CPU", tint: theme.accent)
                    Ring(value: 0.63 + 0.04 * sin(t * 0.3), label: "Memory", tint: .teal)
                }
                Card(height: 104) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Load").font(.system(size: 9, weight: .bold)).opacity(0.6)
                        Sparkline(t: t).stroke(theme.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .background(Sparkline(t: t, closed: true).fill(LinearGradient(colors: [theme.accent.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)))
                    }
                }
                HStack(spacing: 8) {
                    Card(height: 58) { Stat(title: "Network", value: "↓ 4.2 MB/s") }
                    Card(height: 58) { Stat(title: "Battery", value: "86%") }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .frame(width: PhoneDesign.screen.width, height: PhoneDesign.screen.height)
        .background(ThemeFill())
        .foregroundStyle(theme.text)
    }

    private struct Stat: View {
        let title: LocalizedStringKey
        let value: String
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 8.5, weight: .bold)).opacity(0.6)
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }
}

private struct Ring: View {
    let value: Double
    let label: LocalizedStringKey
    let tint: Color
    @Environment(\.mockTheme) private var theme
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(theme.text.opacity(0.12), lineWidth: 7)
                Circle().trim(from: 0, to: value).stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int(value * 100))%").font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 66, height: 66)
            Text(label).font(.system(size: 9, weight: .semibold)).opacity(0.7)
        }
    }
}

private struct Sparkline: Shape {
    let t: Double
    var closed = false
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = 30
        for i in 0...n {
            let x = rect.width * CGFloat(i) / CGFloat(n)
            let s = Double(i) * 0.45 + t * 2
            let v = 0.5 + 0.28 * sin(s) + 0.14 * sin(s * 2.7 + 1) + 0.06 * sin(s * 6.1)
            let point = CGPoint(x: x, y: rect.height * (1 - v))
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        if closed {
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.closeSubpath()
        }
        return p
    }
}

extension View {
    /// Springs in with a small delay per `index` once `on` is true.
    func pop(_ on: Bool, _ index: Int) -> some View {
        scaleEffect(on ? 1 : 0.6)
            .opacity(on ? 1 : 0)
            .blur(radius: on ? 0 : 6)
            .animation(.spring(response: 0.55, dampingFraction: 0.68).delay(on ? 0.25 + Double(index) * 0.08 : 0), value: on)
    }
}
