import PhoneScreenKit
import SwiftUI
import UIKit

/// Name of the coordinate space pointer positions and target frames are measured in:
/// the phone's upright content (inside `OrientedContainer`).
let pointerSpace = "pointer"

/// Horizontal offset of the pager while a two-finger swipe is in progress (phone points).
@MainActor
final class PagerSwipe: ObservableObject {
    @Published var offset: CGFloat = 0
}

/// The Mac cursor while it is on the phone.
///
/// Movement is drawn by a Core Animation layer updated directly — no SwiftUI invalidation per move.
/// SwiftUI only hears about hover/press changes, which are rare.
@MainActor
final class PointerController: ObservableObject {
    @Published private(set) var hovered: UUID?
    @Published private(set) var pressed: UUID?
    let swipe = PagerSwipe()

    private(set) var isVisible = false
    private var model = PhonePointer(size: CGSize(width: 393, height: 852), macSide: .left)
    private var targets: [UUID: (frame: CGRect, action: () -> Void)] = [:]
    fileprivate weak var layerView: PointerLayerView?
    private var swipeVelocity: CGFloat = 0
    private var lastWheelPage = Date.distantPast

    /// The pointer left through the Mac-facing side.
    var onExit: ((Double) -> Void)?
    /// A swipe ended: move by this many pages (−1, 0, +1); the pager animates `swipe.offset` back to 0.
    var onSwipeEnd: ((Int) -> Void)?

    func configure(size: CGSize, macSide: ScreenEdge) {
        guard size != model.size || macSide != model.macSide else { return }
        model.size = size
        model.macSide = macSide
    }

    // MARK: - Messages from the Mac

    func enter(along: Double) {
        model.enter(along: along)
        isVisible = true
        layerView?.show(at: model.position)
        updateHover()
    }

    func move(dx: Double, dy: Double) {
        if case .exit(let along) = model.move(dx: dx, dy: dy) {
            hide()
            onExit?(along)
            return
        }
        layerView?.move(to: model.position)
        updateHover()
    }

    func button(_ button: PointerButton, down: Bool) {
        guard isVisible, button == .left else { return }
        if down {
            pressed = hit(model.position)
        } else {
            // Like a real button: fires when released over the same control it was pressed on.
            if let id = pressed, hit(model.position) == id { targets[id]?.action() }
            pressed = nil
        }
        layerView?.setPressed(down)
    }

    func scroll(dx: Double, dy: Double, phase: PhoneScreenKit.ScrollPhase) {
        guard isVisible else { return }
        switch phase {
        case .began:
            swipeVelocity = 0
            swipe.offset = dx
        case .changed:
            // Content follows the fingers 1:1 (natural scrolling is already applied by macOS).
            swipe.offset += dx
            swipeVelocity = 0.6 * swipeVelocity + 0.4 * dx
        case .ended:
            let width = model.size.width
            let step = swipe.offset < -width * 0.18 || swipeVelocity < -8 ? 1
                : swipe.offset > width * 0.18 || swipeVelocity > 8 ? -1 : 0
            onSwipeEnd?(step)
        case .momentum:
            break // inertia after the fingers lift: the swipe has already been decided
        case .wheel:
            // Horizontal wheel steps (shift+wheel, tilt wheels): one page per notch burst.
            guard abs(dx) > abs(dy), abs(dx) > 0, Date().timeIntervalSince(lastWheelPage) > 0.35 else { return }
            lastWheelPage = Date()
            onSwipeEnd?(dx < 0 ? 1 : -1)
        }
    }

    /// The Mac took the cursor back (Esc, hotkey, disconnect).
    func hide() {
        model.deactivate()
        isVisible = false
        hovered = nil
        pressed = nil
        layerView?.hide()
        if swipe.offset != 0 { onSwipeEnd?(0) }
    }

    // MARK: - Targets

    func register(_ id: UUID, frame: CGRect, action: @escaping () -> Void) {
        targets[id] = (frame, action)
    }

    func unregister(_ id: UUID) {
        targets[id] = nil
        if hovered == id { hovered = nil }
    }

    private func hit(_ point: CGPoint) -> UUID? {
        // Smallest frame under the pointer wins (a button inside a larger tappable card).
        targets.filter { $0.value.frame.contains(point) }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
            .key
    }

    private func updateHover() {
        let id = isVisible ? hit(model.position) : nil
        if id != hovered { hovered = id }
    }

    fileprivate func attach(_ view: PointerLayerView) {
        layerView = view
        if isVisible { view.show(at: model.position) }
    }
}

/// Makes a control reachable with the Mac pointer: hover highlight, press feedback, click = `action`.
struct PointerTarget: ViewModifier {
    @EnvironmentObject private var pointer: PointerController
    @State private var id = UUID()
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .named(pointerSpace))
                Color.clear
                    .onAppear { pointer.register(id, frame: frame, action: action) }
                    .onChange(of: frame) { _, new in pointer.register(id, frame: new, action: action) }
            })
            .onDisappear { pointer.unregister(id) }
            .scaleEffect(pointer.pressed == id ? 0.92 : pointer.hovered == id ? 1.08 : 1)
            .brightness(pointer.hovered == id ? 0.15 : 0)
            .animation(.snappy(duration: 0.15), value: pointer.hovered == id)
            .animation(.snappy(duration: 0.1), value: pointer.pressed == id)
    }
}

extension View {
    func pointerTarget(action: @escaping () -> Void) -> some View {
        modifier(PointerTarget(action: action))
    }
}

/// Hosts the arrow layer; sits over the content in the pointer coordinate space.
struct PointerOverlay: UIViewRepresentable {
    @EnvironmentObject private var pointer: PointerController

    func makeUIView(context: Context) -> PointerLayerView {
        let view = PointerLayerView()
        pointer.attach(view)
        return view
    }

    func updateUIView(_ view: PointerLayerView, context: Context) {}
}

final class PointerLayerView: UIView {
    private let arrow = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        arrow.path = Self.arrowPath()
        arrow.fillColor = UIColor.white.cgColor
        arrow.strokeColor = UIColor.black.cgColor
        arrow.lineWidth = 1.3
        arrow.bounds = CGRect(x: 0, y: 0, width: 14, height: 22)
        arrow.anchorPoint = .zero // the tip is the layer's origin
        arrow.shadowColor = UIColor.black.cgColor
        arrow.shadowOpacity = 0.4
        arrow.shadowRadius = 2
        arrow.shadowOffset = CGSize(width: 0, height: 1)
        arrow.shadowPath = arrow.path
        arrow.opacity = 0
        layer.addSublayer(arrow)
    }

    required init?(coder: NSCoder) { fatalError() }

    func move(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit 0.25 s animation: follow the mouse exactly
        arrow.position = point
        CATransaction.commit()
    }

    func show(at point: CGPoint) {
        move(to: point)
        arrow.opacity = 1
    }

    func hide() {
        arrow.opacity = 0
    }

    func setPressed(_ pressed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        arrow.setAffineTransform(pressed ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity)
        CATransaction.commit()
    }

    /// Classic macOS arrow; the tip is at (0, 0).
    private static func arrowPath() -> CGPath {
        let p = CGMutablePath()
        let points: [CGPoint] = [.init(x: 0, y: 0), .init(x: 0, y: 18), .init(x: 4.3, y: 14), .init(x: 7.2, y: 21),
                                 .init(x: 10, y: 19.8), .init(x: 7.2, y: 13.2), .init(x: 13, y: 13)]
        p.addLines(between: points)
        p.closeSubpath()
        return p
    }
}
