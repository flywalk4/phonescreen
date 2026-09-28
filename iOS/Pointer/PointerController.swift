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

/// Live scale of the current page during a pinch (1 = at rest), from touch or the Mac trackpad.
@MainActor
final class PinchState: ObservableObject {
    @Published var scale: CGFloat = 1
}

extension EnvironmentValues {
    /// False inside overview tiles: their controls are pictures, not targets for the pointer.
    @Entry var pointerInteractive = true
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
    let pinch = PinchState()
    /// Called on a click or the start of a scroll (restarts the pages' auto-advance).
    var onActivity: () -> Void = {}
    /// True while an action runs because of a Mac click (no haptic tick: nobody's finger is on the phone).
    private(set) static var clicking = false

    private func fromPointer(_ action: () -> Void) {
        Self.clicking = true
        defer { Self.clicking = false }
        action()
    }
    private var pinchTotal: Double = 0

    private(set) var isVisible = false
    private var model = PhonePointer(size: CGSize(width: 393, height: 852), macSide: .left)
    private var targets: [UUID: (frame: CGRect, action: () -> Void)] = [:]
    private var scrollers: [UUID: (frame: CGRect, scroll: (CGFloat) -> Void)] = [:]
    /// Controls that follow a pressed pointer (sliders): get the horizontal position 0…1 within their frame.
    private var draggers: [UUID: (frame: CGRect, drag: (Double) -> Void)] = [:]
    private var activeDrag: UUID?
    /// Targets that also answer a press held down (a card peeks at its full version).
    private var holders: [UUID: (PointerHold) -> Void] = [:]
    /// The press in progress on such a target; kept even if the target unregisters meanwhile.
    private var hold: (id: UUID, handler: (PointerHold) -> Void, timer: Task<Void, Never>?, held: Bool)?
    static let holdDelay: Duration = .milliseconds(300)
    private enum Axis { case horizontal, vertical }
    /// Locked on the first real movement of a trackpad gesture, kept for its momentum.
    private var gestureAxis: Axis?
    private var gestureScroller: UUID?
    fileprivate weak var layerView: PointerLayerView?
    private var swipeVelocity: CGFloat = 0
    private var lastWheelPage = Date.distantPast

    /// The pointer left through the Mac-facing side.
    var onExit: ((Double) -> Void)?
    /// A click that hit no control (ends text editing, like tapping away).
    var onEmptyClick: (() -> Void)?
    /// A swipe ended: move by this many pages (−1, 0, +1); the pager animates `swipe.offset` back to 0.
    var onSwipeEnd: ((Int) -> Void)?
    /// Pinch finished: `true` = pinched in (show all pages), `false` = spread out (open a page).
    var onPinch: ((Bool) -> Void)?
    /// Two-finger double tap on the trackpad.
    var onSmartZoom: (() -> Void)?

    /// The upright content area (the pointer's coordinate space).
    var areaSize: CGSize { model.size }

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
        if let id = activeDrag { drag(id) } else { updateHover() }
    }

    private func drag(_ id: UUID) {
        guard let d = draggers[id], d.frame.width > 0 else { return }
        d.drag(min(max((model.position.x - d.frame.minX) / d.frame.width, 0), 1))
    }

    func button(_ button: PointerButton, down: Bool) {
        guard isVisible, button == .left else { return }
        if down {
            onActivity()
            if let id = draggers.filter({ $0.value.frame.contains(model.position) }).first?.key {
                activeDrag = id
                drag(id)
                layerView?.setPressed(true)
                return
            }
            pressed = hit(model.position)
            if let id = pressed, let handler = holders[id] { beginHold(id, handler) }
        } else {
            // A press held long enough is not a click: it only ends the peek.
            if endHold() {
                pressed = nil
                layerView?.setPressed(false)
                return
            }
            if activeDrag != nil {
                activeDrag = nil
                layerView?.setPressed(false)
                return
            }
            // Like a real button: fires when released over the same control it was pressed on.
            if let id = pressed, hit(model.position) == id { fromPointer { targets[id]?.action() } }
            if pressed == nil, hit(model.position) == nil { onEmptyClick?() }
            pressed = nil
        }
        layerView?.setPressed(down)
    }

    func scroll(dx: Double, dy: Double, phase: PhoneScreenKit.ScrollPhase) {
        guard isVisible else { return }
        if phase == .began {
            onActivity()
            gestureAxis = nil
            gestureScroller = nil
            swipeVelocity = 0
        }
        if gestureAxis == nil, dx != 0 || dy != 0, phase != .momentum {
            gestureAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
            gestureScroller = scroller(at: model.position)
        }

        // Vertical: scroll the list under the pointer, momentum included (feels like a real scroll view).
        if gestureAxis == .vertical || (phase == .wheel && abs(dy) >= abs(dx)) {
            let id = phase == .wheel ? scroller(at: model.position) : gestureScroller
            if let id { scrollers[id]?.scroll(dy) }
            if phase == .ended || phase == .wheel { gestureAxis = phase == .wheel ? nil : gestureAxis }
            return
        }

        // Horizontal: the pager follows the fingers.
        switch phase {
        case .began, .changed:
            // Content follows the fingers 1:1 (natural scrolling is already applied by macOS).
            swipe.offset += dx
            swipeVelocity = 0.6 * swipeVelocity + 0.4 * dx
        case .ended:
            guard gestureAxis == .horizontal else { return }
            let width = model.size.width
            let step = swipe.offset < -width * 0.18 || swipeVelocity < -8 ? 1
                : swipe.offset > width * 0.18 || swipeVelocity > 8 ? -1 : 0
            onSwipeEnd?(step)
        case .momentum:
            break // inertia after the fingers lift: the swipe has already been decided
        case .wheel:
            // Horizontal wheel steps (shift+wheel, tilt wheels): one page per notch burst.
            guard abs(dx) > 0, Date().timeIntervalSince(lastWheelPage) > 0.35 else { return }
            lastWheelPage = Date()
            onSwipeEnd?(dx < 0 ? 1 : -1)
        }
    }

    func pinch(magnification: Double, phase: PhoneScreenKit.ScrollPhase) {
        guard isVisible else { return }
        switch phase {
        case .began:
            pinchTotal = magnification
        case .changed, .wheel, .momentum:
            pinchTotal += magnification
        case .ended:
            pinchTotal += magnification
            let total = pinchTotal
            pinchTotal = 0
            withAnimation(.snappy) { pinch.scale = 1 }
            if total < -0.15 { onPinch?(true) } else if total > 0.15 { onPinch?(false) }
            return
        }
        pinch.scale = max(0.5, min(1.15, 1 + pinchTotal))
    }

    func smartZoom() {
        guard isVisible else { return }
        onSmartZoom?()
    }

    /// Run the control under the pointer (spreading fingers over an overview tile opens that page).
    @discardableResult
    func activateHovered() -> Bool {
        guard isVisible, let id = hit(model.position), let target = targets[id] else { return false }
        fromPointer { target.action() }
        return true
    }

    private func beginHold(_ id: UUID, _ handler: @escaping (PointerHold) -> Void) {
        endHold()
        handler(.pressed)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, self.hold?.id == id else { return }
            self.hold?.held = true
            handler(.held)
        }
        hold = (id, handler, timer, false)
    }

    /// Finishes a press on a hold target; true if it had been held (so the release is no click).
    @discardableResult
    private func endHold() -> Bool {
        guard let current = hold else { return false }
        hold = nil
        current.timer?.cancel()
        current.handler(.released)
        return current.held
    }

    /// The Mac took the cursor back (Esc, hotkey, disconnect).
    func hide() {
        endHold()
        model.deactivate()
        isVisible = false
        hovered = nil
        pressed = nil
        layerView?.hide()
        if swipe.offset != 0 { onSwipeEnd?(0) }
    }

    // MARK: - Targets

    func register(_ id: UUID, frame: CGRect, action: @escaping () -> Void, hold: ((PointerHold) -> Void)? = nil) {
        targets[id] = (frame, action)
        holders[id] = hold
    }

    func unregister(_ id: UUID) {
        targets[id] = nil
        holders[id] = nil
        scrollers[id] = nil
        draggers[id] = nil
        if activeDrag == id { activeDrag = nil }
        if hovered == id { hovered = nil }
    }

    func registerScroller(_ id: UUID, frame: CGRect, scroll: @escaping (CGFloat) -> Void) {
        scrollers[id] = (frame, scroll)
    }

    func registerDragger(_ id: UUID, frame: CGRect, drag: @escaping (Double) -> Void) {
        draggers[id] = (frame, drag)
    }

    private func scroller(at point: CGPoint) -> UUID? {
        scrollers.filter { $0.value.frame.contains(point) }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
            .key
    }

    private func hit(_ point: CGPoint) -> UUID? {
        // Smallest frame under the pointer wins (a button inside a larger tappable card).
        targets.filter { $0.value.frame.contains(point) }
            .min { $0.value.frame.width * $0.value.frame.height < $1.value.frame.width * $1.value.frame.height }?
            .key
    }

    private func updateHover() {
        let id = isVisible ? hit(model.position) : nil
        if id != hovered {
            hovered = id
            layerView?.setHovering(id != nil)
        }
    }

    fileprivate func attach(_ view: PointerLayerView) {
        layerView = view
        if isVisible { view.show(at: model.position) }
    }
}

/// A Mac click held down on a target: pressed, then (if still down after `holdDelay`) held, then released.
enum PointerHold {
    case pressed, held, released
}

/// Makes a control reachable with the Mac pointer: hover highlight, press feedback, click = `action`.
struct PointerTarget: ViewModifier {
    @EnvironmentObject private var pointer: PointerController
    @Environment(\.pointerInteractive) private var interactive
    @State private var id = UUID()
    var highlight = true
    var hold: ((PointerHold) -> Void)?
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .named(pointerSpace))
                Color.clear
                    .onAppear { if interactive { pointer.register(id, frame: frame, action: action, hold: hold) } }
                    .onChange(of: frame) { _, new in if interactive { pointer.register(id, frame: new, action: action, hold: hold) } }
                    .onChange(of: interactive) { _, on in
                        if on { pointer.register(id, frame: frame, action: action, hold: hold) } else { pointer.unregister(id) }
                    }
            })
            .onDisappear { pointer.unregister(id) }
            .scaleEffect(!highlight ? 1 : pointer.pressed == id ? 0.92 : pointer.hovered == id ? 1.08 : 1)
            .brightness(highlight && pointer.hovered == id ? 0.15 : 0)
            .animation(.snappy(duration: 0.15), value: pointer.hovered == id)
            .animation(.snappy(duration: 0.1), value: pointer.pressed == id)
    }
}

/// Lets the Mac pointer scroll a vertical `ScrollView` (trackpad / wheel over it). Apply to the ScrollView.
struct PointerScrollable: ViewModifier {
    @EnvironmentObject private var pointer: PointerController
    @Environment(\.pointerInteractive) private var interactive
    @State private var id = UUID()
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: [CGFloat].self) { geo in
                [geo.contentOffset.y, max(0, geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom - geo.containerSize.height)]
            } action: { _, v in
                offset = v[0]
                maxOffset = v[1]
            }
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .named(pointerSpace))
                Color.clear
                    .onAppear { register(frame) }
                    .onChange(of: frame) { _, new in register(new) }
                    .onChange(of: interactive) { _, on in if on { register(frame) } else { pointer.unregister(id) } }
            })
            .onDisappear { pointer.unregister(id) }
    }

    private func register(_ frame: CGRect) {
        guard interactive else { return }
        pointer.registerScroller(id, frame: frame) { dy in
            // Positive dy = content moves down (natural scrolling already applied by macOS).
            let target = min(max(offset - dy, 0), maxOffset)
            offset = target
            position.scrollTo(y: target)
        }
    }
}

/// A slider the Mac pointer can press-and-drag, and scroll over (two fingers / wheel) to nudge.
struct PointerDraggable: ViewModifier {
    @EnvironmentObject private var pointer: PointerController
    @Environment(\.pointerInteractive) private var interactive
    @State private var id = UUID()
    let value: Double
    let onChange: (Double) -> Void

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                let frame = geo.frame(in: .named(pointerSpace))
                Color.clear
                    .onAppear { register(frame) }
                    .onChange(of: frame) { _, new in register(new) }
                    .onChange(of: interactive) { _, on in if on { register(frame) } else { pointer.unregister(id) } }
                    .onChange(of: value) { register(frame) }
            })
            .onDisappear { pointer.unregister(id) }
    }

    private func register(_ frame: CGRect) {
        guard interactive else { return }
        pointer.registerDragger(id, frame: frame, drag: onChange)
        // Scrolling up over the slider turns it up (natural scrolling: fingers up = negative dy).
        pointer.registerScroller(id, frame: frame) { [value] dy in onChange(min(max(value - dy / 300, 0), 1)) }
    }
}

extension View {
    func pointerDraggable(value: Double, onChange: @escaping (Double) -> Void) -> some View {
        modifier(PointerDraggable(value: value, onChange: onChange))
    }

    func pointerTarget(highlight: Bool = true, hold: ((PointerHold) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(PointerTarget(highlight: highlight, hold: hold, action: action))
    }

    func pointerScrollable() -> some View {
        modifier(PointerScrollable())
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

/// iPad-style pointer: a translucent circle. Over a control it shrinks and fades (the control lights up
/// instead); a press squeezes it.
final class PointerLayerView: UIView {
    private let dot = CALayer()
    private static let size: CGFloat = 20
    private var hovering = false
    private var pressed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        dot.bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        dot.cornerRadius = Self.size / 2
        dot.backgroundColor = UIColor.white.withAlphaComponent(0.35).cgColor
        dot.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        dot.borderWidth = 1
        dot.shadowColor = UIColor.black.cgColor
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.shadowPath = UIBezierPath(ovalIn: dot.bounds).cgPath
        dot.opacity = 0
        layer.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    func move(to point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animation: follow the mouse exactly
        dot.position = point
        CATransaction.commit()
    }

    func show(at point: CGPoint) {
        move(to: point)
        dot.opacity = hovering ? 0.35 : 1
    }

    func hide() {
        dot.opacity = 0
    }

    func setHovering(_ value: Bool) {
        guard value != hovering else { return }
        hovering = value
        applyState()
    }

    func setPressed(_ value: Bool) {
        pressed = value
        applyState()
    }

    private func applyState() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        let scale: CGFloat = pressed ? 0.7 : hovering ? 0.6 : 1
        dot.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        if dot.opacity > 0 { dot.opacity = hovering ? 0.35 : 1 }
        CATransaction.commit()
    }
}
