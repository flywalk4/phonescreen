import PhoneScreenKit
import SwiftUI

struct PagerView: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            OrientedContainer(orientation: model.layout.orientation) { island in
                ZStack {
                    content
                        // Keep content clear of the Dynamic Island and the rounded corners, whichever way the phone lies.
                        .padding(Edge.Set(island), 44)
                        .padding(18)
                    PointerOverlay()
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
    }

    @ViewBuilder private var content: some View {
        if model.status.active == nil && model.pages.isEmpty {
            WaitingView()
        } else {
            ZStack {
                Pager(count: model.pages.count, current: $model.currentPage, swipe: model.pointer.swipe) { index in
                    PageContent(page: model.pages[index])
                }
                .onChange(of: model.currentPage) { _, index in model.userChangedPage(to: index) }

                VStack {
                    ConnectionBadge(status: model.status)
                    Spacer()
                    PageDots(count: model.pages.count, current: model.currentPage) { index in
                        withAnimation(.snappy) { model.currentPage = index }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

/// Horizontal pager in pure SwiftUI: works inside the rotated container (UIKit's page TabView does not).
/// Follows finger drags on the phone and two-finger swipes on the Mac trackpad (`swipe`).
struct Pager<Page: View>: View {
    let count: Int
    @Binding var current: Int
    @ObservedObject var swipe: PagerSwipe
    @ViewBuilder var page: (Int) -> Page
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    page(index).frame(width: width, height: geo.size.height)
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
                        if predicted < -width / 3, current < count - 1 { current += 1 }
                        if predicted > width / 3, current > 0 { current -= 1 }
                    }
            )
            .animation(.interactiveSpring, value: drag)
        }
        .clipped()
    }

    /// Resist dragging past the first/last page.
    private func rubberBand(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let atStart = current == 0 && x > 0
        let atEnd = current == count - 1 && x < 0
        return atStart || atEnd ? x / 3 : x
    }
}

private struct PageContent: View {
    let page: PageInfo

    var body: some View {
        switch page.kind {
        case .music: MusicPage()
        case .monitor: MonitorPage()
        default: Text(page.title).font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

struct PageDots: View {
    let count: Int
    let current: Int
    var select: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == current ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .frame(width: 22, height: 22) // comfortable target for the Mac pointer
                    .contentShape(Rectangle())
                    .pointerTarget { select(i) }
            }
        }
        .animation(.snappy, value: current)
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
                    Text(String(format: "%.0f мс", rtt * 1000)).monospacedDigit()
                }
            } else {
                Text("Нет связи с Mac")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: Capsule())
    }
}

private struct WaitingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Жду Mac").font(.title2.weight(.semibold))
            Text("Подключите кабель или откройте PhoneScreen на Mac.\nWi-Fi сеть не обязательна — сработает прямое соединение.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}
