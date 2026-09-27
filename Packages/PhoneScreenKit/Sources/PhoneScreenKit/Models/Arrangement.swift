import CoreGraphics
import Foundation

/// Which side of a Mac display the phone is attached to.
public enum ScreenEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom

    public var opposite: ScreenEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    public var isVertical: Bool { self == .left || self == .right }
}

/// How the phone physically lies next to the Mac, named by where its Dynamic Island / top edge points.
/// The phone renders its UI in this orientation itself — lying flat on a desk, the accelerometer can't tell.
public enum PhoneOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, landscapeIslandRight, upsideDown, landscapeIslandLeft

    /// Clockwise rotation of the device from portrait, degrees.
    public var degrees: Double {
        switch self {
        case .portrait: 0
        case .landscapeIslandRight: 90
        case .upsideDown: 180
        case .landscapeIslandLeft: 270
        }
    }

    public var isLandscape: Bool { self == .landscapeIslandLeft || self == .landscapeIslandRight }

    public var rotatedClockwise: PhoneOrientation {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var rotatedCounterClockwise: PhoneOrientation {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

/// What the phone needs to know about the arrangement.
public struct PhoneLayout: Codable, Equatable, Sendable {
    public var orientation: PhoneOrientation
    /// The side of the phone's (upright) UI that faces the Mac: the pointer enters and leaves here.
    public var macSide: ScreenEdge

    public init(orientation: PhoneOrientation, macSide: ScreenEdge) {
        self.orientation = orientation
        self.macSide = macSide
    }
}

/// The user's placement of the phone relative to one Mac display. Stored relative to that display,
/// so it survives rearranging monitors in System Settings.
public struct PhoneArrangement: Codable, Equatable, Sendable {
    /// Stable display UUID (`CGDisplayCreateUUIDFromDisplayID`).
    public var displayID: String
    public var edge: ScreenEdge
    /// Position along the edge, display points: the phone's top (left/right edges)
    /// or left side (top/bottom edges) relative to the display's top/left.
    public var offset: Double
    public var orientation: PhoneOrientation

    public init(displayID: String, edge: ScreenEdge, offset: Double, orientation: PhoneOrientation) {
        self.displayID = displayID
        self.edge = edge
        self.offset = offset
        self.orientation = orientation
    }

    public var layout: PhoneLayout {
        PhoneLayout(orientation: orientation, macSide: edge.opposite)
    }
}

/// Geometry in Mac global display coordinates (CoreGraphics: origin top-left of the main display, y down).
public enum ArrangementGeometry {
    /// Points per millimetre of iPhone UI (3x devices ≈ 460 ppi / 3 ≈ 153 pt per inch).
    public static let phonePointsPerMM = 153.0 / 25.4
    /// The phone must share at least this much of its side with the display edge.
    public static let minOverlap = 40.0

    /// Phone footprint in Mac points, at true physical size relative to the display.
    public static func phoneSize(portraitPoints: CGSize, orientation: PhoneOrientation, macPointsPerMM: Double) -> CGSize {
        let k = macPointsPerMM / phonePointsPerMM
        let size = CGSize(width: portraitPoints.width * k, height: portraitPoints.height * k)
        return orientation.isLandscape ? CGSize(width: size.height, height: size.width) : size
    }

    public static func phoneRect(display: CGRect, edge: ScreenEdge, offset: Double, size: CGSize) -> CGRect {
        let offset = clampedOffset(offset, display: display, edge: edge, size: size)
        switch edge {
        case .right: return CGRect(x: display.maxX, y: display.minY + offset, width: size.width, height: size.height)
        case .left: return CGRect(x: display.minX - size.width, y: display.minY + offset, width: size.width, height: size.height)
        case .bottom: return CGRect(x: display.minX + offset, y: display.maxY, width: size.width, height: size.height)
        case .top: return CGRect(x: display.minX + offset, y: display.minY - size.height, width: size.width, height: size.height)
        }
    }

    public static func clampedOffset(_ offset: Double, display: CGRect, edge: ScreenEdge, size: CGSize) -> Double {
        let edgeLength = edge.isVertical ? display.height : display.width
        let phoneLength = edge.isVertical ? size.height : size.width
        let overlap = min(minOverlap, phoneLength / 2, edgeLength / 2)
        return min(max(offset, -phoneLength + overlap), edgeLength - overlap)
    }

    /// Offset that keeps the phone centred on the same point when its size changes (rotation).
    public static func recentredOffset(_ offset: Double, edge: ScreenEdge, from old: CGSize, to new: CGSize) -> Double {
        edge.isVertical ? offset + (old.height - new.height) / 2 : offset + (old.width - new.width) / 2
    }

    public static func centredOffset(display: CGRect, edge: ScreenEdge, size: CGSize) -> Double {
        edge.isVertical ? (display.height - size.height) / 2 : (display.width - size.width) / 2
    }

    public struct Snap: Equatable, Sendable {
        public var displayIndex: Int
        public var edge: ScreenEdge
        public var offset: Double
        public var rect: CGRect
    }

    /// Attach a freely dragged phone rect to the nearest free display edge (like arranging displays in macOS).
    /// Edges where the phone would overlap any display are skipped.
    public static func snap(_ dragged: CGRect, displays: [CGRect]) -> Snap? {
        var best: (snap: Snap, distance: CGFloat)?
        for (index, display) in displays.enumerated() {
            for edge in ScreenEdge.allCases {
                let raw = edge.isVertical ? dragged.minY - display.minY : dragged.minX - display.minX
                let offset = clampedOffset(raw, display: display, edge: edge, size: dragged.size)
                let rect = phoneRect(display: display, edge: edge, offset: offset, size: dragged.size)
                if displays.contains(where: { $0.insetBy(dx: 1, dy: 1).intersects(rect) }) { continue }
                let d = hypot(rect.midX - dragged.midX, rect.midY - dragged.midY)
                if best == nil || d < best!.distance {
                    best = (Snap(displayIndex: index, edge: edge, offset: offset, rect: rect), d)
                }
            }
        }
        return best?.snap
    }

    /// The segment of the display edge that the pointer crosses to reach the phone:
    /// where the phone touches the edge, minus parts already leading onto another display.
    public static func portal(display: CGRect, phone: CGRect, edge: ScreenEdge, otherDisplays: [CGRect]) -> (start: CGPoint, end: CGPoint)? {
        let vertical = edge.isVertical
        var lo = vertical ? max(display.minY, phone.minY) : max(display.minX, phone.minX)
        var hi = vertical ? min(display.maxY, phone.maxY) : min(display.maxX, phone.maxX)
        let line: Double = switch edge {
        case .left: display.minX
        case .right: display.maxX
        case .top: display.minY
        case .bottom: display.maxY
        }
        // Clip away ranges where another display continues past this edge.
        for other in otherDisplays {
            let touches = switch edge {
            case .left: abs(other.maxX - line) < 1
            case .right: abs(other.minX - line) < 1
            case .top: abs(other.maxY - line) < 1
            case .bottom: abs(other.minY - line) < 1
            }
            guard touches else { continue }
            let oLo = vertical ? other.minY : other.minX
            let oHi = vertical ? other.maxY : other.maxX
            guard oHi > lo, oLo < hi else { continue }
            // Keep the larger remaining piece.
            if oLo - lo >= hi - oHi { hi = min(hi, oLo) } else { lo = max(lo, oHi) }
        }
        guard hi - lo >= 1 else { return nil }
        return vertical
            ? (CGPoint(x: line, y: lo), CGPoint(x: line, y: hi))
            : (CGPoint(x: lo, y: line), CGPoint(x: hi, y: line))
    }

    /// Mac point → normalized point in the phone's upright UI (0…1 on both axes).
    /// Because the phone renders in the arranged orientation, its UI axes match the Mac's.
    public static func normalizedInPhone(_ point: CGPoint, phone: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - phone.minX) / phone.width, 0), 1),
                y: min(max((point.y - phone.minY) / phone.height, 0), 1))
    }

    /// Normalized phone UI point → Mac point.
    public static func macPoint(fromNormalized p: CGPoint, phone: CGRect) -> CGPoint {
        CGPoint(x: phone.minX + p.x * phone.width, y: phone.minY + p.y * phone.height)
    }
}
