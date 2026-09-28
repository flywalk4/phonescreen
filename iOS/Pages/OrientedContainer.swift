import QwoviKit
import SwiftUI

/// Renders content upright for the orientation the phone lies in next to the Mac.
/// The app itself is locked to portrait; this rotates the whole UI instead, so it works lying flat,
/// supports upside-down on Face ID iPhones and never fights the system rotation (see MotionOrientation).
struct OrientedContainer<Content: View>: View {
    let orientation: PhoneOrientation
    @ViewBuilder var content: (_ islandEdge: Edge) -> Content

    var body: some View {
        GeometryReader { geo in
            let size = orientation.isLandscape ? CGSize(width: geo.size.height, height: geo.size.width) : geo.size
            content(islandEdge)
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(-orientation.degrees))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }

    /// Where the Dynamic Island ends up in the upright content.
    private var islandEdge: Edge {
        switch orientation {
        case .portrait: .top
        case .landscapeIslandRight: .trailing
        case .upsideDown: .bottom
        case .landscapeIslandLeft: .leading
        }
    }
}
