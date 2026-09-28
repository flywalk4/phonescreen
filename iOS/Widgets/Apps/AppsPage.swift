import QwoviKit
import SwiftUI
import UIKit

/// Apps running on the Mac as tiles, like Mission Control: a live snapshot of each app's front window with its
/// icon and window title, most recently used first like ⌘Tab. Tap a tile to switch to the app; ✕ quits it,
/// a long press also hides it. Without snapshots (Bluetooth, no Screen Recording) a tile shows the icon.
struct AppsPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size

    private var front: RunningApp? { model.runningApps.first(where: \.active) }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .full ? 14 : 10) {
            WidgetHeader(title: L("Apps"), symbol: "macwindow.on.rectangle",
                         subtitle: model.runningApps.isEmpty ? nil : Self.openCount(model.runningApps.count))
            if model.runningApps.isEmpty {
                EmptyApps()
            } else if size == .small {
                small
            } else {
                grid
            }
        }
        .animation(.snappy(duration: 0.35), value: model.runningApps.map(\.id))
        .widgetPadding()
    }

    private var grid: some View {
        let full = size == .full
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: full ? 150 : 120), spacing: full ? 14 : 10, alignment: .top)],
                      spacing: full ? 18 : 12) {
                ForEach(model.runningApps) { app in AppTile(app: app, compact: !full) }
            }
            .padding(.vertical, 4) // room for the front tile's ring and glow
        }
        .scrollIndicators(.hidden)
        .pointerScrollable()
    }

    /// The front app's window, and the recent ones below it to jump to.
    private var small: some View {
        GeometryReader { geo in
            let side: CGFloat = 30, gap: CGFloat = 8
            let fit = max(1, Int((geo.size.width + gap) / (side + gap)))
            let others = model.runningApps.filter { !$0.active }
            VStack(spacing: 10) {
                if let front { AppTile(app: front, compact: true) }
                HStack(spacing: gap) {
                    ForEach(others.prefix(min(fit, 4))) { app in IconButton(app: app, side: side) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    static func openCount(_ n: Int) -> String { L("%lld apps", n) }

    static func windowCount(_ n: Int) -> String { L("%lld windows", n) }
}

// MARK: - Tile

private struct AppTile: View {
    let app: RunningApp
    let compact: Bool
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.theme) private var theme

    var body: some View {
        let tint = model.tint(for: app)
        let shape = RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            WindowPreview(app: app, shape: shape)
                .overlay(shape.strokeBorder(app.active ? theme.accent : Color.primary.opacity(0.12), lineWidth: app.active ? 2.5 : 1))
                .shadow(color: theme.style == .ascii ? .clear : (app.active ? tint.opacity(0.6) : .black.opacity(0.25)),
                        radius: app.active ? 14 : 6, y: 3)
                .overlay(alignment: .topTrailing) {
                    if !compact { CloseButton { model.appAction(app, .quit) }.padding(6) }
                }
            HStack(spacing: 7) {
                AppIcon(app: app, side: compact ? 20 : 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font((compact ? Font.caption : .subheadline).weight(.semibold)).lineLimit(1)
                    if !compact, let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if app.active {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.appAction(app, .activate) }
        .pointerTarget { model.appAction(app, .activate) }
        .contextMenu { AppMenu(app: app) }
        .animation(.snappy(duration: 0.25), value: app.active)
    }

    private var subtitle: String? {
        if app.hidden { return L("Hidden") }
        if let title = app.window, title != app.name { return title }
        if app.windows == 0 { return L("No windows") }
        return app.windows.map(AppsPage.windowCount)
    }
}

/// The app's window snapshot, cropped from the top (title bar and toolbar are the recognisable part).
/// Without one: the icon on a wash of its colour.
private struct WindowPreview: View {
    let app: RunningApp
    let shape: RoundedRectangle
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.theme) private var theme

    var body: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    if theme.style == .ascii {
                        ZStack {
                            AsciiFrame(color: theme.secondaryText)
                            Text(app.name).font(.caption.monospaced()).foregroundStyle(theme.text)
                        }
                    } else if let image = model.appPreviews[app.id] {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .clipped()
                    } else {
                        let tint = model.tint(for: app)
                        ZStack {
                            LinearGradient(colors: [tint.opacity(0.55), tint.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            AppIcon(app: app, side: min(geo.size.height * 0.55, 64))
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                    }
                }
            }
            .saturation(app.hidden ? 0 : 1)
            .opacity(app.hidden ? 0.5 : 1)
            .overlay {
                if app.hidden { Glyph("eye.slash").font(.title3.weight(.semibold)).foregroundStyle(.white).shadow(radius: 4) }
            }
            .clipShape(shape)
            .background(shape.fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Pieces

/// An app as just its icon, for the small card.
private struct IconButton: View {
    let app: RunningApp
    let side: CGFloat
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Button { model.appAction(app, .activate) } label: {
            AppIcon(app: app, side: side).saturation(app.hidden ? 0 : 1).opacity(app.hidden ? 0.55 : 1)
        }
        .buttonStyle(PressScale())
        .pointerTarget { model.appAction(app, .activate) }
        .contextMenu { AppMenu(app: app) }
    }
}

/// The app's icon; without one (over Bluetooth) its initial on a tile of its colour, like a real icon.
struct AppIcon: View {
    let app: RunningApp
    let side: CGFloat
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let icon = model.appIcons[app.id] {
                Image(uiImage: icon).resizable().interpolation(.high).scaledToFit()
            } else if theme.style == .ascii {
                AsciiFrame(color: theme.secondaryText)
                Text(String(app.name.prefix(1))).font(.system(size: side * 0.4, weight: .bold)).foregroundStyle(theme.text)
            } else {
                let tint = model.tint(for: app)
                // macOS icons sit inside ~10% transparent padding; match it so fallbacks line up with real icons.
                RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                    .fill(LinearGradient(colors: [tint.mix(with: .white, by: 0.15), tint.mix(with: .black, by: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
                    .padding(side * 0.1)
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.system(size: side * 0.38, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: side, height: side)
    }
}

private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Glyph("xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(PressScale())
        .pointerTarget(action: action)
    }
}

private struct AppMenu: View {
    let app: RunningApp
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Button { model.appAction(app, .activate) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        Button { model.appAction(app, .hide) } label: { Label("Hide", systemImage: "eye.slash") }
        Button(role: .destructive) { model.appAction(app, .quit) } label: { Label("Quit", systemImage: "xmark.circle") }
    }
}

private struct EmptyApps: View {
    var body: some View {
        VStack(spacing: 10) {
            Glyph("macwindow.on.rectangle").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("No connection to the Mac").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Colour

extension PhoneModel {
    /// The app's colour: from its icon, or a steady hue from its id when there's no icon yet.
    func tint(for app: RunningApp) -> Color {
        if let color = appTints[app.id] { return Color(color) }
        let hash = app.id.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.8)
    }
}

extension UIImage {
    /// The icon's most telling colour: the average of its colourful pixels (greys and transparency ignored),
    /// kept bright enough to glow.
    var dominantColor: UIColor? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let cg = cgImage,
              let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var (r, g, b, weight) = (0.0, 0.0, 0.0, 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let saturation = max(pr, pg, pb) - min(pr, pg, pb)
            let w = 0.05 + saturation * saturation
            r += pr * w; g += pg * w; b += pb * w; weight += w
        }
        guard weight > 0 else { return nil }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: r / weight, green: g / weight, blue: b / weight, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return UIColor(hue: hue, saturation: min(sat * 1.2, 0.85), brightness: max(bri, 0.7), alpha: 1)
    }
}

/// Stand-ins for `--demo` (no Mac to send real ones).
enum DemoIcons {
    /// An SF Symbol on a gradient tile.
    static func make(_ specs: [String: (String, UIColor)]) -> [String: UIImage] {
        let side: CGFloat = 96
        return specs.mapValues { symbol, color in
            UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                let tile = UIBezierPath(roundedRect: CGRect(x: 10, y: 10, width: side - 20, height: side - 20), cornerRadius: 18)
                color.setFill()
                tile.fill()
                let config = UIImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
                if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
                }
            }
        }
    }

    /// A made-up Mac window: title bar with the three buttons, a sidebar and some lines of content.
    static func windows(_ specs: [String: UIColor]) -> [String: UIImage] {
        let size = CGSize(width: 480, height: 300)
        return specs.mapValues { color in
            UIGraphicsImageRenderer(size: size).image { context in
                let dark = color == .black
                (dark ? UIColor(white: 0.12, alpha: 1) : UIColor(white: 0.97, alpha: 1)).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                color.withAlphaComponent(dark ? 1 : 0.12).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 130, height: size.height))
                UIColor(white: dark ? 0.2 : 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: size.width, height: 34))
                for (i, c) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                    c.setFill()
                    UIBezierPath(ovalIn: CGRect(x: 14 + CGFloat(i) * 20, y: 11, width: 12, height: 12)).fill()
                }
                let line = dark ? UIColor.systemGreen.withAlphaComponent(0.7) : UIColor(white: 0.75, alpha: 1)
                let widths: [CGFloat] = [260, 300, 220, 280, 180, 310, 240, 200, 270]
                for (i, width) in widths.enumerated() {
                    (i == 0 ? color : line).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 150, y: 56 + CGFloat(i) * 25, width: width * 0.95, height: i == 0 ? 14 : 9),
                                 cornerRadius: 4).fill()
                }
                color.withAlphaComponent(0.5).setFill()
                for i in 0..<5 { UIBezierPath(roundedRect: CGRect(x: 16, y: 56 + CGFloat(i) * 28, width: 96, height: 10), cornerRadius: 4).fill() }
            }
        }
    }
}
