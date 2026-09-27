import PhoneScreenKit
import SwiftUI

/// "Displays"-style editor: every Mac display plus the phone at true physical proportions.
/// Drag the phone to any free display edge (it snaps), rotate it in 90° steps.
struct ArrangementView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            ArrangementCanvas()
                .frame(minWidth: 560, minHeight: 340)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor)))
            controls
            Text("Перетащите iPhone к нужной стороне экрана — он прилипнет к краю. Зелёная линия — участок края, через который курсор будет переходить на телефон. Ориентацию телефон применит сам, даже лёжа на столе.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 600)
        .onAppear { model.refreshDisplays() }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ControlGroup {
                Button { model.rotatePhone(clockwise: false) } label: { Image(systemName: "rotate.left") }
                    .help("Повернуть против часовой (⇧R)")
                    .keyboardShortcut("r", modifiers: .shift)
                Button { model.rotatePhone(clockwise: true) } label: { Image(systemName: "rotate.right") }
                    .help("Повернуть по часовой (R)")
                    .keyboardShortcut("r", modifiers: [])
            }
            .fixedSize()

            Picker("Положение", selection: Binding(get: { model.arrangement.orientation }, set: { model.setOrientation($0) })) {
                ForEach(PhoneOrientation.allCases, id: \.self) { o in
                    Text(o.title).tag(o)
                }
            }
            .fixedSize()

            Picker("Край", selection: Binding(
                get: { model.arrangement.edge },
                set: { edge in model.arrangedDisplay.map { model.attach(to: $0, edge: edge) } }
            )) {
                ForEach(ScreenEdge.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()

            if model.displays.count > 1 {
                Picker("Экран", selection: Binding(
                    get: { model.arrangedDisplay?.id ?? "" },
                    set: { id in
                        if let d = model.displays.first(where: { $0.id == id }) { model.attach(to: d, edge: model.arrangement.edge) }
                    }
                )) {
                    ForEach(model.displays) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }

            Spacer()
            Button("По центру") {
                model.arrangedDisplay.map { model.attach(to: $0, edge: model.arrangement.edge) }
            }
        }
    }
}

private struct ArrangementCanvas: View {
    @EnvironmentObject private var model: AppModel
    /// Phone rect (world coordinates) while being dragged.
    @State private var dragRect: CGRect?

    var body: some View {
        GeometryReader { geo in
            if let phone = model.phoneRect, let display = model.arrangedDisplay {
                let map = WorldMap(world: worldBounds(phone: phone), in: geo.size)
                let shown = dragRect ?? phone
                ZStack(alignment: .topLeading) {
                    ForEach(model.displays) { d in
                        DisplayTile(display: d, attached: d.id == display.id)
                            .frame(width: map.length(d.bounds.width), height: map.length(d.bounds.height))
                            .position(map.point(CGPoint(x: d.bounds.midX, y: d.bounds.midY)))
                    }
                    if dragRect == nil, let portal = ArrangementGeometry.portal(
                        display: display.bounds, phone: phone, edge: model.arrangement.edge,
                        otherDisplays: model.displays.filter { $0.id != display.id }.map(\.bounds)) {
                        Path { p in
                            p.move(to: map.point(portal.start))
                            p.addLine(to: map.point(portal.end))
                        }
                        .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    PhoneTile(orientation: model.arrangement.orientation,
                              portrait: CGSize(width: map.length(model.phoneSize(for: .portrait, on: display).width),
                                               height: map.length(model.phoneSize(for: .portrait, on: display).height)),
                              dragging: dragRect != nil)
                        .frame(width: map.length(shown.width), height: map.length(shown.height))
                        .position(map.point(CGPoint(x: shown.midX, y: shown.midY)))
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    dragRect = phone.offsetBy(dx: value.translation.width / map.scale,
                                                              dy: value.translation.height / map.scale)
                                }
                                .onEnded { _ in
                                    if let dragRect {
                                        withAnimation(.snappy(duration: 0.25)) { model.dropPhone(at: dragRect) }
                                    }
                                    dragRect = nil
                                }
                        )
                }
                .animation(.snappy(duration: 0.25), value: model.arrangement)
            }
        }
        .padding(12)
    }

    /// Everything that has to fit on the canvas; frozen while dragging so the view doesn't rescale under the cursor.
    private func worldBounds(phone: CGRect) -> CGRect {
        let displays = model.displays.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
        // Room for the phone on any side, so it can be dragged around every display.
        let margin = max(phone.width, phone.height) * 1.15
        return displays.insetBy(dx: -margin, dy: -margin)
    }
}

/// World (Mac global points) → canvas coordinates, aspect-fit and centred.
private struct WorldMap {
    let world: CGRect
    let scale: CGFloat
    let origin: CGPoint

    init(world: CGRect, in size: CGSize) {
        self.world = world
        scale = min(size.width / world.width, size.height / world.height)
        origin = CGPoint(x: (size.width - world.width * scale) / 2, y: (size.height - world.height * scale) / 2)
    }

    func length(_ v: CGFloat) -> CGFloat { v * scale }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x - world.minX) * scale, y: origin.y + (p.y - world.minY) * scale)
    }
}

private struct DisplayTile: View {
    let display: DisplayInfo
    let attached: Bool

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.42, blue: 0.78), Color(red: 0.36, green: 0.24, blue: 0.62)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if display.isMain {
                Rectangle().fill(.white.opacity(0.85)).frame(height: 5)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
            }
            Text(display.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(attached ? Color.white : Color.white.opacity(0.25),
                                                          lineWidth: attached ? 2 : 1))
    }
}

private struct PhoneTile: View {
    let orientation: PhoneOrientation
    /// Portrait size on the canvas; the tile is drawn portrait and rotated into place.
    let portrait: CGSize
    let dragging: Bool

    var body: some View {
        let corner = portrait.width * 0.16
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: corner).stroke(Color(white: 0.55), lineWidth: 1.5))
            Capsule()
                .fill(.black)
                .frame(width: portrait.width * 0.32, height: max(3, portrait.width * 0.09))
                .padding(.top, portrait.width * 0.06)
            Image(systemName: "iphone")
                .font(.system(size: max(8, portrait.width * 0.28)))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxHeight: .infinity)
        }
        .frame(width: portrait.width, height: portrait.height)
        .rotationEffect(.degrees(orientation.degrees))
        .shadow(color: .black.opacity(dragging ? 0.45 : 0.25), radius: dragging ? 10 : 4, y: dragging ? 6 : 2)
        .scaleEffect(dragging ? 1.04 : 1)
        .contentShape(Rectangle())
        .help("Перетащите к нужному краю экрана")
    }
}

extension PhoneOrientation {
    var title: String {
        switch self {
        case .portrait: "Вертикально"
        case .landscapeIslandRight: "Горизонтально, верх справа"
        case .upsideDown: "Вверх ногами"
        case .landscapeIslandLeft: "Горизонтально, верх слева"
        }
    }
}

extension ScreenEdge {
    var title: String {
        switch self {
        case .left: "Слева"
        case .right: "Справа"
        case .top: "Сверху"
        case .bottom: "Снизу"
        }
    }
}
