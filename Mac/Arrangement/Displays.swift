import AppKit
import CoreGraphics

/// A connected Mac display in CoreGraphics global coordinates (origin top-left of the main display, y down).
struct DisplayInfo: Identifiable, Equatable {
    /// Stable across reboots and rearrangement.
    let id: String
    let cgID: CGDirectDisplayID
    let bounds: CGRect
    let name: String
    let isMain: Bool
    /// Display points per millimetre, for drawing the phone at true physical size.
    let pointsPerMM: Double

    static func current() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }, uniquingKeysWith: { a, _ in a })

        return ids.prefix(Int(count))
            // Mirrored displays show the same content; only the mirror source is a real surface.
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            // The phone's own virtual display (second screen) is the phone, not a display to attach it to.
            .filter { CGDisplayVendorNumber($0) != PhoneDisplay.vendorID }
            .map { id in
                let bounds = CGDisplayBounds(id)
                let mm = CGDisplayScreenSize(id)
                let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
                return DisplayInfo(
                    id: uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "display-\(id)",
                    cgID: id,
                    bounds: bounds,
                    name: names[id] ?? String(localized: "Display"),
                    isMain: CGDisplayIsMain(id) != 0,
                    // Some displays report 0 mm; assume a typical ~110 pt/inch then.
                    pointsPerMM: mm.width > 0 ? bounds.width / mm.width : 110 / 25.4
                )
            }
    }
}
