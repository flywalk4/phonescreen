import AVFoundation
import QwoviKit
import SwiftUI
import UIKit

/// The phone as a second screen of the Mac: shows the Mac's virtual display that sits where the phone is in
/// the arrangement. Drag a window across the Mac's edge and it lands here. A finger works like a mouse:
/// a tap clicks, dragging drags, a long press right-clicks, two fingers scroll.
struct DisplayPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size

    var body: some View {
        Group {
            if size != .full {
                Placeholder(symbol: "display.2", text: L("Open it full screen"))
            } else if model.status.active == nil {
                Placeholder(symbol: "display.2", text: L("No connection to the Mac"))
            } else if model.status.active == .bluetooth {
                Placeholder(symbol: "cable.connector", text: L("Needs a cable or Wi-Fi"))
            } else {
                ZStack {
                    StreamView(decoder: model.displayDecoder, send: model.sendDisplay)
                        .aspectRatio(model.displayStream.map { CGFloat($0.width) / CGFloat($0.height) }, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if model.displayStream == nil {
                        if model.displayStopped {
                            // Disconnected on the Mac (Control Center, System Settings): only back on request.
                            VStack(spacing: 14) {
                                Placeholder(symbol: "display.2", text: L("The screen is off on the Mac")).fixedSize()
                                Button("Turn on again") {
                                    model.displayStopped = false
                                    model.sendDisplay(.displayVisible(true))
                                }
                                .buttonStyle(PillButtonStyle(fill: .accentColor))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                        } else {
                            Placeholder(symbol: "display.2", text: L("Connecting the screen…")).allowsHitTesting(false)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            model.displayStopped = false
            model.sendDisplay(.displayVisible(true))
        }
        .onDisappear { model.sendDisplay(.displayVisible(false)) }
    }
}

private struct Placeholder: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Glyph(symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StreamView: UIViewRepresentable {
    let decoder: DisplayDecoder
    let send: (Message) -> Void

    func makeUIView(context: Context) -> StreamUIView {
        let view = StreamUIView()
        view.send = send
        decoder.attach(view.displayLayer)
        return view
    }

    func updateUIView(_ view: StreamUIView, context: Context) {
        view.send = send
    }

    static func dismantleUIView(_ view: StreamUIView, coordinator: ()) {
        MainActor.assumeIsolated { view.detach() }
    }
}

/// Shows the stream and turns raw touches into mouse input. Raw touches, not gesture recognizers, so one
/// finger (mouse) and two fingers (scroll) are told apart exactly and nothing waits for a recognizer.
final class StreamUIView: UIView {
    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    var send: ((Message) -> Void)?

    /// Mouse button state for the one-finger gesture.
    private enum Mode { case pending(start: CGPoint), dragging, rightClicked, scrolling(last: CGPoint) }
    private var mode: Mode?
    private var longPress: Timer?
    /// Movement (points) before a finger counts as dragging rather than tapping.
    private let slop: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resize // the view already has the stream's aspect ratio
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    func detach() {
        longPress?.invalidate()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        if active.count >= 2 {
            // A second finger turns the gesture into a scroll; a button already down is let go first.
            if case .dragging = mode, let first = active.first { touch(.ended, at: first.location(in: self)) }
            longPress?.invalidate()
            mode = .scrolling(last: centroid(active))
            return
        }
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        mode = .pending(start: point)
        self.touch(.hover, at: point)
        longPress?.invalidate()
        longPress = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .pending(let start) = self.mode else { return }
                self.mode = .rightClicked
                self.touch(.rightClick, at: start)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        switch mode {
        case .scrolling(let last):
            let now = centroid(active)
            // Content follows the fingers, like a trackpad with natural scrolling. The virtual display is about the
            // phone's own size, so a phone point is roughly a display point.
            send?(.displayScroll(dx: Double(now.x - last.x), dy: Double(now.y - last.y)))
            mode = .scrolling(last: now)
        case .pending(let start):
            guard let point = active.first?.location(in: self), hypot(point.x - start.x, point.y - start.y) > slop else { return }
            longPress?.invalidate()
            touch(.began, at: start)
            touch(.moved, at: point)
            mode = .dragging
        case .dragging:
            if let point = active.first?.location(in: self) { touch(.moved, at: point) }
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? Set()
        guard remaining.isEmpty else {
            if case .scrolling = mode { mode = .scrolling(last: centroid(remaining)) }
            return
        }
        longPress?.invalidate()
        let point = touches.first?.location(in: self) ?? .zero
        switch mode {
        case .pending(let start):
            touch(.began, at: start)
            touch(.ended, at: start)
        case .dragging:
            touch(.ended, at: point)
        default:
            break
        }
        mode = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPress?.invalidate()
        if case .dragging = mode, let point = touches.first?.location(in: self) { touch(.ended, at: point) }
        mode = nil
    }

    private func touch(_ phase: DisplayTouchPhase, at point: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        send?(.displayTouch(phase: phase, x: Double(point.x / bounds.width), y: Double(point.y / bounds.height)))
    }

    private func centroid(_ touches: Set<UITouch>) -> CGPoint {
        let points = touches.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}
