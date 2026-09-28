import CoreMotion
import PhoneScreenKit

/// Reads how the phone is held from the accelerometer. Reports an orientation only when the phone is
/// tilted up enough to tell (on a stand, in a hand); lying flat on the desk it stays silent, so the
/// Mac arrangement keeps deciding. Hysteresis and a short hold stop it flapping near 45°.
final class MotionOrientation {
    var onChange: ((PhoneOrientation) -> Void)?

    private let motion = CMMotionManager()
    private var gravity = (x: 0.0, y: 0.0, z: -1.0)
    private var candidate: PhoneOrientation?
    private var candidateSince = Date.distantPast
    private(set) var current: PhoneOrientation?

    /// Screen plane must be at least this far from horizontal (sin of the tilt: 0.5 ≈ 30°).
    private static let minTilt = 0.5
    /// How far past the 45° boundary the phone has to turn before switching, degrees.
    private static let deadZone = 15.0
    private static let hold: TimeInterval = 0.4

    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 1 / 15
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let a = data?.acceleration else { return }
            self.update(x: a.x, y: a.y, z: a.z)
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        candidate = nil
    }

    private func update(x: Double, y: Double, z: Double) {
        // Low-pass: keep gravity, drop taps and hand shake.
        let k = 0.2
        gravity = (gravity.x + (x - gravity.x) * k, gravity.y + (y - gravity.y) * k, gravity.z + (z - gravity.z) * k)
        let g = gravity
        // Flat: nothing to tell; forget the last answer so the next tilt is reported even if it is the same.
        guard (g.x * g.x + g.y * g.y).squareRoot() >= Self.minTilt else { candidate = nil; current = nil; return }

        // 0° = upright portrait, 90° = top turned right (island right), ±180° = upside down, −90° = island left.
        let angle = atan2(g.x, -g.y) * 180 / .pi
        let nearest = Self.orientation(for: angle)
        if let current, nearest != current, Self.distance(angle, to: nearest) > 45 - Self.deadZone { candidate = nil; return }
        guard nearest != current else { candidate = nil; return }

        if candidate != nearest { candidate = nearest; candidateSince = Date(); return }
        guard Date().timeIntervalSince(candidateSince) >= Self.hold else { return }
        current = nearest
        candidate = nil
        onChange?(nearest)
    }

    private static func orientation(for angle: Double) -> PhoneOrientation {
        switch angle {
        case -45..<45: .portrait
        case 45..<135: .landscapeIslandRight
        case -135 ..< -45: .landscapeIslandLeft
        default: .upsideDown
        }
    }

    private static func distance(_ angle: Double, to orientation: PhoneOrientation) -> Double {
        let centre = orientation.degrees > 180 ? orientation.degrees - 360 : orientation.degrees
        let d = abs(angle - centre).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
