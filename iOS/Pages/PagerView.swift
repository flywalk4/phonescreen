import QwoviKit
import SwiftUI

private struct AutoPageKey: Equatable {
    let page: Int
    let touches: Int
    let every: Double?
}

struct PagerView: View {
    @EnvironmentObject private var model: PhoneModel
    private var autoPage: Double? { model.theme.layout?.autoPage.flatMap { $0 >= 10 ? $0 : nil } }
    private static let demo = ProcessInfo.processInfo.arguments.contains("--demo")

    var body: some View {
        ZStack {
            ThemeBackground()
            // A full-screen live wallpaper takes the whole screen, round corners and island included.
            Group {
                if let scene = model.screenBackdrop {
                    WidgetBackdrop(scene: scene)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: model.screenBackdrop)
            OrientedContainer(orientation: model.layout.orientation) { island in
                ZStack {
                    content(island: island)
                        // Keep content clear of the Dynamic Island and the rounded corners, whichever way the phone lies.
                        .padding(Edge.Set(island), PageMetrics.island)
                        .padding(PageMetrics(model.theme).edge)
                        // Under the tour, the pages stop answering the Mac pointer.
                        .environment(\.pointerInteractive, model.tour == nil)
                    // The band beside the Dynamic Island: time on one side, date on the other (upright or upside down).
                    if (island == .top || island == .bottom), model.theme.layout?.status ?? true, !model.overview {
                        IslandStatus(showsDate: !(island == .top && model.focused?.held == false))
                            .frame(height: PageMetrics.island)
                            .frame(maxHeight: .infinity, alignment: island == .top ? .top : .bottom)
                            .allowsHitTesting(false)
                    }
                    // An opened widget's close button, top right: beside the island when it is there, else in the corner.
                    if let focused = model.focused, !focused.held, !model.overview {
                        CloseFocusedButton { model.focus(nil) }
                            .padding(.top, island == .top ? (PageMetrics.island - CloseFocusedButton.side) / 2 + 3 : 14)
                            .padding(.trailing, island == .top ? 24 : 18)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                    // The Mac's welcome tour, over everything but the pointer.
                    if let step = model.tour {
                        TourOverlay(step: step)
                            .transition(.opacity.combined(with: .scale(scale: 1.06)))
                            .zIndex(2)
                    }
                    PointerOverlay().zIndex(3)
                }
                .coordinateSpace(.named(pointerSpace))
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { model.pointer.configure(size: geo.size, macSide: model.layout.macSide) }
                        .onChange(of: geo.size) { _, size in model.pointer.configure(size: size, macSide: model.layout.macSide) }
                        .onChange(of: model.layout) { _, layout in model.pointer.configure(size: geo.size, macSide: layout.macSide) }
                })
            }
        }
        .themed(model.theme)
        .dynamicTypeSize(Self.typeSize(model.theme.layout?.textSize))
        // Texts, dates and weekdays in the Mac's language.
        .environment(\.locale, Locale(identifier: model.language))
    }

    /// The theme's text size as Dynamic Type (scales every text style in built-in and catalog widgets).
    static func typeSize(_ name: String?) -> DynamicTypeSize {
        switch name {
        case "small": .small
        case "large": .xLarge
        case "xlarge": .xxxLarge
        default: .large
        }
    }

    @ViewBuilder private func content(island: Edge) -> some View {
        if model.status.active == nil && model.pages.isEmpty {
            WaitingView()
        } else {
            ZStack {
                if model.overview {
                    OverviewGrid(pages: model.pages, current: model.currentPage) { model.openFromOverview($0) }
                        .padding(.top, 34)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.15)),
                                                removal: .opacity.combined(with: .scale(scale: 1.15))))
                        // Spread two fingers anywhere in the overview to go back to the current page.
                        .simultaneousGesture(MagnifyGesture().onEnded { value in
                            if value.magnification > 1.2 { model.setOverview(false) }
                        })
                } else {
                    PinchablePager()
                        // Under an opened widget the page fades away; its cards stop answering the Mac pointer.
                        // A blurred hint of it stays, so the opened widget reads as lying over the page it came from.
                        .blur(radius: model.focused == nil ? 0 : 24)
                        .opacity(model.focused == nil ? 1 : 0.18)
                        .scaleEffect(model.focused == nil ? 1 : 0.94)
                        .environment(\.pointerInteractive, model.focused == nil && model.tour == nil)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.4)),
                                                removal: .opacity.combined(with: .scale(scale: 0.4))))
                    if let focused = model.focused {
                        FocusedWidgetView(focused: focused)
                            // Room for the close button when there is no island band beside it.
                            .padding(.top, focused.held || island == .top ? 0 : CloseFocusedButton.side + 4)
                            .padding(.bottom, PageMetrics(model.theme).dots)
                            // Grows out of the card it came from and shrinks back into it.
                            .transition(.scale(scale: 0.3, anchor: focused.anchor).combined(with: .opacity))
                            .zIndex(1)
                            // Pinch in to put it back.
                            .simultaneousGesture(MagnifyGesture().onEnded { value in
                                if value.magnification < 0.8 { model.focus(nil) }
                            })
                    }
                }

            }
            // An overlay, not a ZStack sibling: the badge and the dots must never make the pager wider than the screen
            // (20 pages of 22-pt dots are 440 pt — wider than an iPhone — and pushed every page off both edges).
            .overlay {
                VStack {
                    // Only when something is wrong: a connected phone shows nothing but the widgets.
                    if !Self.demo, model.status.active == nil { ConnectionBadge(status: model.status) }
                    Spacer()
                    if model.focused == nil, !model.overview, PageMetrics(model.theme).showsDots {
                        PageDots(count: model.pages.count, current: model.currentPage) { index in
                            withAnimation(.snappy) { model.currentPage = index }
                        }
                    }
                }
                .padding(.bottom, -PageMetrics(model.theme).edge + 2)
            }
            .onChange(of: model.currentPage) { _, index in model.userChangedPage(to: index) }
            // Auto-advance: restarts on every page change (a swipe, the Mac, or itself) and on every touch.
            .task(id: AutoPageKey(page: model.currentPage, touches: model.interactions, every: autoPage)) {
                guard let every = autoPage, model.pages.count > 1, !model.overview else { return }
                try? await Task.sleep(for: .seconds(every))
                guard !Task.isCancelled else { return }
                // Past the last page: round to the first with "loop", otherwise stay there.
                let next = model.currentPage + 1
                guard next < model.pages.count || model.loopsPages else { return }
                withAnimation(.smooth(duration: 0.6)) { model.currentPage = next % model.pages.count }
            }
            .simultaneousGesture(TapGesture().onEnded { model.interactions += 1 })
            .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in model.interactions += 1 })
        }
    }
}

/// The pager, shrinking live under a pinch (touch or trackpad); pinching in far enough opens the overview.
private struct PinchablePager: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        PinchablePagerContent(pinch: model.pointer.pinch)
    }
}

private struct PinchablePagerContent: View {
    @EnvironmentObject private var model: PhoneModel
    @ObservedObject var pinch: PinchState
    @GestureState private var touchScale: CGFloat = 1

    var body: some View {
        Pager(count: model.pages.count, current: $model.currentPage, swipe: model.pointer.swipe, loops: model.loopsPages,
              locked: model.isOnSecondScreen) { index in
            PageView(page: model.pages[index])
        }
        .scaleEffect(min(pinch.scale, touchScale))
        .opacity(0.4 + 0.6 * min(1, min(pinch.scale, touchScale) * 1.2 - 0.2))
        .simultaneousGesture(
            MagnifyGesture()
                .updating($touchScale) { value, state, _ in state = max(0.5, min(1, value.magnification)) }
                .onEnded { value in if value.magnification < 0.8 { model.setOverview(true) } }
        )
    }
}

/// Horizontal pager in pure SwiftUI: works inside the rotated container (UIKit's page TabView does not).
/// Follows finger drags on the phone and two-finger swipes on the Mac trackpad (`swipe`).
struct Pager<Page: View>: View {
    let count: Int
    @Binding var current: Int
    @ObservedObject var swipe: PagerSwipe
    /// Swiping past either end goes round to the other.
    var loops = false
    /// Finger swipes don't turn pages (the second screen uses them as a mouse); dots, the Mac and pinch still do.
    var locked = false
    @ViewBuilder var page: (Int) -> Page
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    // Only the current page and its neighbours exist: widgets far away don't run timers,
                    // animations or permission prompts (the photo frame asks for Photos when it appears).
                    Group {
                        if abs(index - current) <= 1 {
                            page(index).environment(\.isCurrentPage, index == current)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: width, height: geo.size.height)
                }
            }
            .offset(x: -CGFloat(current) * width + rubberBand(drag + swipe.offset, width: width))
            .animation(.snappy(duration: 0.3), value: current)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in state = value.translation.width }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.width
                        if predicted < -width / 3 { if current < count - 1 { current += 1 } else if loops { current = 0 } }
                        if predicted > width / 3 { if current > 0 { current -= 1 } else if loops { current = count - 1 } }
                    },
                including: locked ? .subviews : .all
            )
            .animation(.interactiveSpring, value: drag)
        }
        .clipped()
    }

    /// Resist dragging past the first/last page.
    private func rubberBand(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let atStart = current == 0 && x > 0
        let atEnd = current == count - 1 && x < 0
        return (atStart || atEnd) && !loops ? x / 3 : x
    }
}

/// The page indicator: the current page a short capsule, the rest dots. Many pages show a sliding window of
/// `window` dots whose outer ones shrink (more pages that way), as on the iPhone home screen, instead of a row of
/// tiny dots across the whole screen.
struct PageDots: View {
    let count: Int
    let current: Int
    var select: (Int) -> Void = { _ in }
    private let window = 9
    private let cell: CGFloat = 16

    var body: some View {
        let first = count <= window ? 0 : min(max(current - window / 2, 0), count - window)
        let last = min(count, first + window) - 1
        HStack(spacing: 0) {
            ForEach(Array(first...max(first, last)), id: \.self) { i in
                let active = i == current
                Capsule()
                    .fill(active ? Color.primary : Color.primary.opacity(0.3))
                    .frame(width: active ? 16 : 6, height: 6)
                    .scaleEffect(scale(i, first: first, last: last))
                    .frame(width: active ? 24 : cell, height: 22)
                    .contentShape(Rectangle())
                    .pointerTarget { select(i) }
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(Color.primary.opacity(count > 1 ? 0.06 : 0)).frame(height: 18))
        .opacity(count > 1 ? 1 : 0)
        .animation(.snappy, value: current)
    }

    /// The window's outer dots are smaller when there are more pages beyond them.
    private func scale(_ i: Int, first: Int, last: Int) -> CGFloat {
        let fromEdge = min(first > 0 ? i - first : .max, last < count - 1 ? last - i : .max)
        switch fromEdge {
        case 0: return 0.5
        case 1: return 0.75
        default: return 1
        }
    }
}

struct ConnectionBadge: View {
    let status: ChannelPool.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.active == nil ? Color.orange : Color.green).frame(width: 6, height: 6)
            if let active = status.active {
                Text(active.label)
                if let rtt = status.rtt {
                    Text(L("%lld ms", Int((rtt * 1000).rounded()))).monospacedDigit()
                }
            } else {
                Text("No connection to the Mac")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct WaitingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ThemedSpinner().controlSize(.large)
            Text("Waiting for the Mac").font(.title2.weight(.semibold))
            Text("Connect the cable or open Qwovi on the Mac.\nA Wi-Fi network isn't required — a direct connection works too.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// Time and date either side of the Dynamic Island, like a status bar for the Mac's side screen.
private struct IslandStatus: View {
    /// Off while an opened widget's close button takes the date's place.
    var showsDate = true

    var body: some View {
        TimelineView(.everyMinute) { context in
            // Two equal halves around a gap the island's width, so nothing slides under it whatever the font.
            HStack(spacing: 0) {
                Text(context.date.text(date: .omitted, time: .shortened))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: 150) // the island
                Text(context.date.text(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(showsDate ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: showsDate)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .padding(.horizontal, 30)
            .padding(.top, 6)
        }
    }
}
