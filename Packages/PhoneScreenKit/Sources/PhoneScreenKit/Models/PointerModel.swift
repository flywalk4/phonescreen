import CoreGraphics
import Foundation

/// Phone-side pointer: integrates Mac mouse deltas inside the phone's upright UI
/// and leaves through the Mac-facing side. Every other side just stops it.
public struct PhonePointer: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case none
        /// Pointer went back onto the Mac; `along` is where on the Mac-facing side (0…1).
        case exit(along: Double)
    }
    /// How far past the Mac-facing side counts as leaving (small, so an accidental 1 pt jitter doesn't).
    public static let exitOvershoot: Double = 2

    public var size: CGSize
    public var macSide: ScreenEdge
    public private(set) var position: CGPoint = .zero
    public private(set) var isActive = false

    public init(size: CGSize, macSide: ScreenEdge) {
        self.size = size
        self.macSide = macSide
    }

    /// Place the pointer just inside the Mac-facing side.
    public mutating func enter(along: Double) {
        let a = min(max(along, 0), 1)
        let inset = 1.0
        switch macSide {
        case .left: position = CGPoint(x: inset, y: a * size.height)
        case .right: position = CGPoint(x: size.width - inset, y: a * size.height)
        case .top: position = CGPoint(x: a * size.width, y: inset)
        case .bottom: position = CGPoint(x: a * size.width, y: size.height - inset)
        }
        isActive = true
    }

    public mutating func deactivate() {
        isActive = false
    }

    public mutating func move(dx: Double, dy: Double) -> Event {
        guard isActive else { return .none }
        var x = position.x + dx
        var y = position.y + dy

        // Leaving through the Mac-facing side.
        let exitAlong: Double? = switch macSide {
        case .left where x < -Self.exitOvershoot: y / size.height
        case .right where x > size.width + Self.exitOvershoot: y / size.height
        case .top where y < -Self.exitOvershoot: x / size.width
        case .bottom where y > size.height + Self.exitOvershoot: x / size.width
        default: nil
        }
        if let exitAlong {
            deactivate()
            return .exit(along: min(max(exitAlong, 0), 1))
        }

        x = min(max(x, 0), size.width)
        y = min(max(y, 0), size.height)
        position = CGPoint(x: x, y: y)
        return .none
    }
}

public extension ArrangementGeometry {
    /// Mac mouse delta → phone UI points, so the pointer keeps its physical speed across the gap.
    static func deltaScale(macPointsPerMM: Double) -> Double {
        phonePointsPerMM / macPointsPerMM
    }

    /// Where a Mac point on the display edge lands along the phone's Mac-facing side (0…1).
    static func along(ofMacPoint point: CGPoint, phone: CGRect, edge: ScreenEdge) -> Double {
        let n = normalizedInPhone(point, phone: phone)
        return edge.isVertical ? n.y : n.x
    }

    /// Where the cursor reappears on the Mac for a pointer leaving the phone at `along`:
    /// on the display edge (clamped to the portal), `inset` points inside the display.
    static func exitPoint(along: Double, phone: CGRect, display: CGRect, edge: ScreenEdge,
                          portal: (start: CGPoint, end: CGPoint)?, inset: Double = 2) -> CGPoint {
        let a = min(max(along, 0), 1)
        let lo = portal.map { edge.isVertical ? $0.start.y : $0.start.x }
        let hi = portal.map { edge.isVertical ? $0.end.y : $0.end.x }
        func clamp(_ v: Double, _ minV: Double, _ maxV: Double) -> Double { min(max(v, minV), maxV) }
        switch edge {
        case .right, .left:
            let y = clamp(phone.minY + a * phone.height, lo ?? display.minY, (hi ?? display.maxY) - 1)
            return CGPoint(x: edge == .right ? display.maxX - inset : display.minX + inset, y: y)
        case .top, .bottom:
            let x = clamp(phone.minX + a * phone.width, lo ?? display.minX, (hi ?? display.maxX) - 1)
            return CGPoint(x: x, y: edge == .bottom ? display.maxY - inset : display.minY + inset)
        }
    }

    /// Is a Mac cursor position resting on the portal (the part of the edge that leads to the phone)?
    static func isOnPortal(_ point: CGPoint, display: CGRect, edge: ScreenEdge,
                           portal: (start: CGPoint, end: CGPoint), tolerance: Double = 1.5) -> Bool {
        switch edge {
        case .right:
            return point.x >= display.maxX - tolerance && point.y >= portal.start.y && point.y <= portal.end.y
        case .left:
            return point.x <= display.minX + tolerance - 1 && point.y >= portal.start.y && point.y <= portal.end.y
        case .bottom:
            return point.y >= display.maxY - tolerance && point.x >= portal.start.x && point.x <= portal.end.x
        case .top:
            return point.y <= display.minY + tolerance - 1 && point.x >= portal.start.x && point.x <= portal.end.x
        }
    }

    /// Mouse movement pointing out of the display through `edge` (positive = pushing towards the phone).
    static func outwardComponent(dx: Double, dy: Double, edge: ScreenEdge) -> Double {
        switch edge {
        case .right: dx
        case .left: -dx
        case .bottom: dy
        case .top: -dy
        }
    }
}
