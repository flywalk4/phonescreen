import QwoviKit
import SwiftUI

/// The welcome tour, shown once on first launch (and from the menu): why the iPhone lying by the Mac is worth
/// waking up, then connecting it and trying it for real. Once connected, the phone takes part: it says hi, asks
/// for a click with the Mac's cursor and a tap with a finger, and reports back (`AppModel.tourEvents`).
///
/// Every text here is a `Text` literal, looked up in the tour's own `\.locale`: the language switch in the corner
/// changes the tour at once (and the product's language, the phone's included, like the picker in Settings).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    let finish: () -> Void
    /// Plays itself through, for recording the README video (`--record-tour`); called at the end.
    var autoplayEnded: (() -> Void)?

    enum Step: Int, CaseIterable { case idle, connect, glance, cursor, touch, display, yours, ready }

    @State private var step: Step
    @State private var forward = true
    /// The first step: the phone has been woken up.
    @State private var awake: Bool
    @State private var language = AppLanguage.current
    @State private var arrangementDone = false

    init(step: Step = .idle, awake: Bool = false, autoplayEnded: (() -> Void)? = nil, finish: @escaping () -> Void) {
        _step = State(initialValue: step)
        _awake = State(initialValue: awake)
        self.autoplayEnded = autoplayEnded
        self.finish = finish
    }

    private var connected: Bool { model.tourLink != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .center, spacing: 30) {
                text
                    .frame(width: 350, alignment: .leading)
                    .frame(maxHeight: .infinity)
                ZStack { scene }
                    .frame(width: Stage.size.width, height: Stage.size.height)
            }
            .padding(.horizontal, 44)
            .frame(maxHeight: .infinity)
            bottomBar
        }
        .frame(width: 940, height: 600)
        .background(Aurora(tint: tint))
        .foregroundStyle(.white)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, .dark)
        .onAppear {
            arrangementDone = model.isArrangementConfigured
            model.setTour(Self.phoneStep(step))
        }
        .onChange(of: step) { _, new in model.setTour(Self.phoneStep(new)) }
        .onDisappear { model.setTour(nil) }
        .task { await autoplay() }
        // "At a glance": the Mac turns the real phone's pages, then puts it back where it was.
        .task(id: step == .glance && connected) {
            guard step == .glance, connected, model.pages.count > 1 else { return }
            let start = model.currentPage
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { break }
                model.show(page: (model.currentPage + 1) % model.pages.count)
            }
            model.show(page: start)
        }
    }

    /// The whole tour on a timer, the try-it steps ticking themselves off: a walkthrough to record.
    private func autoplay() async {
        guard let ended = autoplayEnded else { return }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await wait(3.5)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { awake = true }
        await wait(5.5)
        for (stay, ticks) in [(5.5, false), (7.0, false), (7.0, true), (7.0, true), (7.5, false), (7.0, false)] {
            go(1)
            if ticks {
                await wait(3.5)
                #if DEBUG
                model.demoTourEvent(step == .cursor ? .clicked : .touched)
                #endif
                await wait(stay - 3.5)
            } else {
                await wait(stay)
            }
        }
        go(1)
        await wait(5)
        ended()
    }

    /// What the phone shows for each step of the tour (nil: its own pages).
    private static func phoneStep(_ step: Step) -> TourStep? {
        switch step {
        case .connect: .hello
        case .cursor: .cursor
        case .touch: .touch
        case .ready: .finish
        default: nil
        }
    }

    private var tint: Color {
        switch step {
        case .idle: awake ? .indigo : Color(white: 0.3)
        case .connect: .cyan
        case .glance: .purple
        case .cursor: .blue
        case .touch: .pink
        case .display: .teal
        case .yours: .orange
        case .ready: .green
        }
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack {
            Spacer()
            LanguageSwitch(code: $language) { model.setLanguage($0) }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if step != .ready {
                Button { finish() } label: { Text("Skip") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            StepDots(count: Step.allCases.count, current: step.rawValue)
            Spacer()
            if step != .idle {
                Button { go(-1) } label: { Text("Back").frame(minWidth: 60) }
                    .buttonStyle(TourButtonStyle(primary: false))
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            primaryButton
        }
        .padding(.horizontal, 44)
        .padding(.bottom, 26)
        .frame(height: 76)
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .idle where !awake:
            Button {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { awake = true }
            } label: {
                Label { Text("Wake it up") } icon: { Image(systemName: "sparkles") }.frame(minWidth: 110)
            }
            .buttonStyle(TourButtonStyle(primary: true))
            .keyboardShortcut(.defaultAction)
        case .ready:
            Button { finish() } label: { Text("Get started").frame(minWidth: 110) }
                .buttonStyle(TourButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
        default:
            Button { go(1) } label: {
                HStack(spacing: 6) { Text("Continue"); Image(systemName: "arrow.right") }.frame(minWidth: 110)
            }
            .buttonStyle(TourButtonStyle(primary: true, beckons: stepDone))
            .keyboardShortcut(.defaultAction)
        }
    }

    /// The try-it steps are done: the Continue button glows.
    private var stepDone: Bool {
        switch step {
        case .connect: connected
        case .cursor: model.tourEvents.contains(.clicked)
        case .touch: model.tourEvents.contains(.touched)
        default: false
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        // The direction first, so the page on its way out already knows which side to leave by.
        forward = delta > 0
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = next }
        }
    }

    // MARK: - Text

    private var text: some View {
        ZStack(alignment: .leading) {
            stepText
                .id(step.rawValue * 10 + (awake ? 1 : 0))
                .transition(.asymmetric(insertion: .glide(forward ? 50 : -50), removal: .glide(forward ? -50 : 50)))
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: awake)
    }

    @ViewBuilder private var stepText: some View {
        switch step {
        case .idle:
            if awake {
                StepText(eyebrow: "Meet Qwovi", title: "Now it's a screen for your Mac.",
                         body: "Music, your calendar, the weather and the Mac's load at a glance. The cursor moves onto it, and so do windows. Nothing to buy — it's already on your desk.")
            } else {
                StepText(eyebrow: "Meet Qwovi", title: "Your iPhone is lying by the Mac. Doing nothing.",
                         body: "Face down on the desk or up on a stand, it lights up only for notifications. The rest of the day it's a black rectangle within arm's reach.")
            }
        case .connect:
            StepText(eyebrow: "Connect", title: "Open Qwovi on the iPhone",
                     body: "A cable is quickest. Wi-Fi and Bluetooth work too — nothing to set up. The rest of the tour happens on the phone as well.") {
                TryCard(done: connected) {
                    if let link = model.tourLink {
                        Text("Connected · \(link)")
                        Text("Look at your phone — it says hi 👋").opacity(0.7)
                    } else {
                        Text("Looking for the iPhone…")
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://github.com/flywalk4/qwovi#-install")!)
                        } label: {
                            HStack(spacing: 4) { Text("How to install it on the iPhone"); Image(systemName: "arrow.up.right") }
                                .foregroundStyle(.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .glance:
            StepText(eyebrow: "At a glance", title: "Everything you check a hundred times a day",
                     body: "What's playing, the next meeting, the weather, CPU and memory — on the phone, without covering your windows or switching apps.") {
                if connected {
                    FeatureRow(symbol: "iphone.gen3", text: "Look at the phone: the Mac is turning its pages right now")
                }
                FeatureRow(symbol: "rectangle.split.3x1", text: "Swipe between pages, or let them turn by themselves")
                FeatureRow(symbol: "cable.connector", text: "Over a cable, Wi-Fi or Bluetooth — whatever's at hand")
            }
        case .cursor:
            StepText(eyebrow: "Try it · the cursor", title: "The cursor walks onto the phone",
                     body: "Push it past the edge of the screen and it appears on the iPhone. Click, scroll, type — and Esc brings it back to the Mac.") {
                CursorTry()
            }
        case .touch:
            StepText(eyebrow: "Try it · touch", title: "And it's still a touchscreen",
                     body: "Every card answers your finger as well as the Mac's cursor: tap to open, swipe to turn pages, hold to peek. Use whichever hand is closer.") {
                TryCard(done: model.tourEvents.contains(.touched), needsPhone: !connected) {
                    if model.tourEvents.contains(.touched) {
                        Text("Tapped on the iPhone!")
                    } else {
                        Text("Tap the pink circle on the phone with your finger")
                    }
                }
            }
        case .display:
            StepText(eyebrow: "Second screen", title: "Drag a window onto it",
                     body: "The iPhone becomes a real display for macOS. Park a chat, a terminal or a player there and keep the big screen for work.") {
                FeatureRow(symbol: "hand.point.up.left", text: "Tap, drag and scroll right on the phone")
                FeatureRow(symbol: "macwindow.on.rectangle", text: "Windows stay normal Mac windows")
                FeatureRow(symbol: "rectangle.stack", text: "Turns on as a page, like any widget")
            }
        case .yours:
            StepText(eyebrow: "Make it yours", title: "Your desk, your look",
                     body: "Themes, layouts and pages are set up on the Mac and show up on the phone instantly. Missing a widget? Take one from the catalog or write your own.") {
                FeatureRow(symbol: "paintpalette", text: "Ready-made themes, or one of your own")
                FeatureRow(symbol: "rectangle.3.group", text: "Layouts for upright and sideways")
                FeatureRow(symbol: "curlybraces", text: "Widgets in JavaScript, reloaded as you save")
            }
        case .ready:
            StepText(eyebrow: "Ready", title: "That's it — the phone is working now", body: nil) {
                ReadyChecklist(arrangementDone: arrangementDone)
            }
        }
    }

    // MARK: - Scene

    @ViewBuilder private var scene: some View {
        Group {
            switch step {
            case .idle: IdleScene(awake: awake)
            case .connect: ConnectScene(connected: connected, link: model.tourLink)
            case .glance: GlanceScene()
            case .cursor: CursorScene()
            case .touch: TouchScene()
            case .display: DisplayScene()
            case .yours: ThemesScene()
            case .ready: ConnectScene(connected: connected, link: model.tourLink, finished: true)
            }
        }
        .id(step)
        .transition(.asymmetric(insertion: .glide(forward ? 90 : -90, scale: 0.92), removal: .glide(forward ? -90 : 90, scale: 0.92)))
    }
}

/// A "try it" box: a live status that turns green when the phone reports back.
private struct TryCard<Content: View>: View {
    let done: Bool
    var needsPhone = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : .white.opacity(0.1))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).transition(.scale.combined(with: .opacity))
                } else if needsPhone {
                    Image(systemName: "iphone.slash").font(.system(size: 11, weight: .semibold)).opacity(0.7)
                } else {
                    Spinner()
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                if needsPhone && !done {
                    Text("Connect the iPhone to try it for real")
                    Text("Until then, watch the animation on the right").opacity(0.6)
                } else {
                    content
                }
            }
            .font(.system(size: 13, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(done ? Color.green.opacity(0.14) : .white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(done ? Color.green.opacity(0.6) : .white.opacity(0.1), lineWidth: 1))
        .scaleEffect(done ? 1.02 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.55), value: done)
    }
}

/// The cursor step's try-it: permission, which side the phone is on, then the click on the phone.
private struct CursorTry: View {
    @EnvironmentObject private var model: AppModel
    private let edges: [(ScreenEdge, LocalizedStringKey)] = [(.left, "Left"), (.right, "Right"), (.top, "Top"), (.bottom, "Bottom")]

    var body: some View {
        let clicked = model.tourEvents.contains(.clicked)
        VStack(alignment: .leading, spacing: 10) {
            if !model.hasAccessibility {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("First, allow Accessibility — it lets the cursor leave the screen").font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.requestAccessibility() } label: { Text("Allow") }
                        .buttonStyle(TourButtonStyle(primary: false, small: true))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
            }
            HStack(spacing: 8) {
                Text("Where's the phone?").font(.system(size: 12.5)).opacity(0.7)
                HStack(spacing: 2) {
                    ForEach(edges, id: \.0) { edge, title in
                        let on = model.arrangement.edge == edge
                        Button {
                            model.arrangedDisplay.map { model.attach(to: $0, edge: edge) }
                        } label: {
                            Text(title).font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1).fixedSize()
                                .foregroundStyle(on ? .black : .white.opacity(0.75))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Color.white : .clear))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(.white.opacity(0.08)))
                .animation(.snappy(duration: 0.2), value: model.arrangement.edge)
            }
            TryCard(done: clicked, needsPhone: model.tourLink == nil) {
                if clicked {
                    Text("Clicked on the iPhone! Now press Esc")
                } else {
                    Text("Push the cursor past the edge (\(Text(edgeName))) and click the circle on the phone")
                }
            }
        }
    }

    private var edgeName: LocalizedStringKey {
        edges.first { $0.0 == model.arrangement.edge }?.1 ?? "Right"
    }
}

/// The last step: what's done and what's left.
private struct ReadyChecklist: View {
    @EnvironmentObject private var model: AppModel
    let arrangementDone: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SetupRow(number: 1, done: model.tourLink != nil, title: "The iPhone is connected",
                     detail: "Keep Qwovi open on it: the screen stays on while it's connected.") {
                if model.tourLink == nil { Text("Looking for the iPhone…").foregroundStyle(.white.opacity(0.55)) }
            }
            SetupRow(number: 2, done: model.hasAccessibility, title: "The cursor can cross",
                     detail: "Accessibility lets the cursor move onto the iPhone.") {
                if !model.hasAccessibility {
                    Button { model.requestAccessibility() } label: { Text("Allow") }
                        .buttonStyle(TourButtonStyle(primary: false, small: true))
                }
            }
            SetupRow(number: 3, done: arrangementDone, title: "Fine-tune where the phone lies",
                     detail: "Drag it to the exact spot along the edge — that's where the cursor will cross.") {
                if !arrangementDone { Text("Opens right after this window").foregroundStyle(.white.opacity(0.55)) }
            }
            Text("The tour is always in the menu bar: Qwovi → Welcome tour.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)
        }
    }
}


// MARK: - Pieces

private struct StepText<Extra: View>: View {
    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    @ViewBuilder var extra: Extra

    init(eyebrow: LocalizedStringKey, title: LocalizedStringKey, body: LocalizedStringKey?, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.message = body
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow)
                .font(.system(size: 12, weight: .bold))
                .textCase(.uppercase)
                .kerning(1.2)
                .foregroundStyle(LinearGradient(colors: [.cyan, .purple, .pink], startPoint: .leading, endPoint: .trailing))
            Text(title)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 11) { extra }.padding(.top, 6)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.09)))
            Text(text).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupRow<Status: View>: View {
    let number: Int
    let done: Bool
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder var status: Status

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : .white.opacity(0.1))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).transition(.scale.combined(with: .opacity))
                } else {
                    Text(verbatim: "\(number)").font(.system(size: 12, weight: .bold, design: .rounded)).transition(.opacity)
                }
            }
            .frame(width: 24, height: 24)
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: done)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                status.font(.system(size: 12, weight: .medium)).padding(.top, 3)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(done ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(done ? Color.green.opacity(0.35) : .white.opacity(0.07), lineWidth: 1))
        .animation(.easeOut(duration: 0.3), value: done)
    }
}

/// EN | RU in the top corner: the tour switches at once.
private struct LanguageSwitch: View {
    @Binding var code: String
    let changed: (String) -> Void
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.horizontal, 6)
            ForEach(AppLanguage.supported, id: \.code) { language in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { code = language.code }
                    changed(language.code)
                } label: {
                    Text(verbatim: language.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(code == language.code ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background {
                            if code == language.code {
                                Capsule().fill(.white).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.08)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.white : .white.opacity(i < current ? 0.45 : 0.18))
                    .frame(width: i == current ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: current)
    }
}

struct TourButtonStyle: ButtonStyle {
    var primary: Bool
    var small = false
    /// Something just got done: a green ring keeps pulsing out of the button.
    var beckons = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13.5, weight: .semibold))
            .foregroundStyle(primary ? Color.black : .white)
            .padding(.horizontal, small ? 12 : 18)
            .padding(.vertical, small ? 5 : 10)
            .background(Capsule().fill(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1))))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.15), lineWidth: 1))
            .shadow(color: beckons ? .green.opacity(0.7) : primary ? .white.opacity(0.25) : .clear, radius: beckons ? 16 : 12)
            .overlay {
                if beckons {
                    Capsule().stroke(Color.green, lineWidth: 2)
                        .phaseAnimator([0.0, 1.0]) { ring, p in ring.scaleEffect(1 + 0.25 * p).opacity(1 - p) }
                            animation: { p in p == 1 ? .easeOut(duration: 1.3) : .linear(duration: 0.01) }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A dark backdrop with slow drifting glows in the step's colour.
private struct Aurora: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.075)
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Glow(color: tint.opacity(0.55), size: 900)
                        .offset(x: 260 + 90 * cos(t / 6), y: -40 + 60 * sin(t / 7))
                    Glow(color: Color.indigo.opacity(0.45), size: 760)
                        .offset(x: -300 + 70 * sin(t / 8), y: 200 + 50 * cos(t / 5))
                    Glow(color: tint.opacity(0.28), size: 640)
                        .offset(x: -120 + 110 * cos(t / 9), y: -240 + 40 * sin(t / 6))
                }
            }
            .animation(.smooth(duration: 1.2), value: tint)
            // A faint dot grid, like a desk mat.
            Canvas { context, size in
                for x in stride(from: 12.0, to: size.width, by: 24) {
                    for y in stride(from: 12.0, to: size.height, by: 24) {
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.white.opacity(0.06)))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A soft round light: a radial gradient, smooth where a blurred circle would band.
private struct Glow: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

// MARK: - Transition

private struct Glide: ViewModifier {
    let x: CGFloat
    let scale: CGFloat
    let active: Bool

    func body(content: Content) -> some View {
        content
            .offset(x: active ? x : 0)
            .scaleEffect(active ? scale : 1)
            .blur(radius: active ? 10 : 0)
            .opacity(active ? 0 : 1)
    }
}

extension AnyTransition {
    /// Slides in from `x`, blurred and faded.
    static func glide(_ x: CGFloat, scale: CGFloat = 1) -> AnyTransition {
        .modifier(active: Glide(x: x, scale: scale, active: true), identity: Glide(x: x, scale: scale, active: false))
    }
}
