import QwoviKit
import SwiftUI
import UIKit

// Building blocks the built-in widgets use so they follow the theme: in the ASCII theme icons become characters,
// bars and rings become `[####....]`, spinners spin `|/-\` and pictures turn into ASCII art.

/// An SF Symbol, or its ASCII stand-in in the ASCII theme. Style it like an `Image` (`.font`, `.foregroundStyle`).
struct Glyph: View {
    let name: String
    var multicolor = false
    @Environment(\.theme) private var theme

    init(_ name: String, multicolor: Bool = false) { self.name = name; self.multicolor = multicolor }
    init(systemName: String) { name = systemName }

    var body: some View {
        if theme.style == .ascii {
            Text(AsciiGlyphs.text(for: name)).fontDesign(.monospaced).fontWeight(.bold).lineLimit(1).fixedSize()
        } else {
            // Multicolour clouds and moons are white: on a light theme they'd vanish, so draw those in layers of the text colour.
            Image(systemName: name)
                .symbolRenderingMode(multicolor ? (theme.appearance == .light && Self.whiteInMulticolor(name) ? .hierarchical : .multicolor) : nil)
        }
    }
}

extension Glyph {
    static func whiteInMulticolor(_ name: String) -> Bool {
        name.hasPrefix("cloud") || name.hasPrefix("moon") || name.hasPrefix("snowflake") || name == "wind" || name.hasPrefix("smoke")
    }
}

enum AsciiGlyphs {
    private static let table: [String: String] = [
        "play.fill": "[>]", "pause.fill": "[||]", "forward.fill": ">>|", "backward.fill": "|<<", "stop.fill": "[#]",
        "shuffle": "~x~", "repeat": "(R)", "repeat.1": "(1)", "star": "*", "star.fill": "(*)",
        "music.note": "d", "speaker.wave.2.fill": "<))", "speaker.fill": "<", "airplayaudio": "((o))",
        "checkmark.circle.fill": "[x]", "circle": "[ ]", "plus": "+", "plus.circle.fill": "(+)",
        "calendar": "[31]", "checklist": "[v]", "note.text": "[=]", "square.and.pencil": "[/]",
        "arrow.clockwise": "(@)", "location.fill": "@", "clock": "(:)", "lock.fill": "[L]",
        "sun.max.fill": "\\o/", "cloud.sun.fill": "~o~", "cloud.fill": "~~~", "cloud.rain.fill": "~,,",
        "cloud.snow.fill": "~**", "cloud.bolt.rain.fill": "~/,", "cloud.fog.fill": "===", "moon.fill": "(",
        "cloud.drizzle.fill": "~,.", "wind": ">>>", "drop.fill": "o", "thermometer.medium": "|*|",
        "square.grid.3x3.fill": "[#]", "gauge.with.dots.needle.33percent": "(/)", "cpu": "[cpu]",
        "headphones": "(n)", "hifispeaker.fill": "[o]", "tv": "[_]", "desktopcomputer": "[__]", "laptopcomputer": "/_/",
        "exclamationmark.triangle.fill": "/!\\", "questionmark": "?", "chevron.right": ">", "chevron.left": "<",
        "xmark": "x", "ellipsis": "...", "puzzlepiece.extension": "{}", "sparkles": "*.*",
        "mappin": "@", "arrow.down": "v", "arrow.up": "^", "arrow.left": "<", "arrow.right": ">", "circle.fill": "o", "folder": "[/]", "macbook": "[__]",
        "circle.lefthalf.filled": "(|", "square.stack.3d.up.fill": "[=]", "moon.zzz.fill": "z", "bell.fill": "(!)",
    ]

    static func text(for name: String) -> String {
        table[name] ?? table[name.replacingOccurrences(of: ".fill", with: "")] ?? "*"
    }
}

/// A 0…1 bar: `[#####.....]` in ASCII, a rounded bar otherwise.
struct ThemedBar: View {
    let value: Double
    var color: Color = .primary
    var height: CGFloat = 6
    /// Spring to a new value (levels, gauges); off for bars driven every frame (playback).
    var animated = false
    @Environment(\.theme) private var theme

    var body: some View {
        if theme.style == .ascii {
            AsciiBar(value: value, color: theme.text)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(color).frame(width: max(height, geo.size.width * min(max(value, 0), 1)))
                }
                .animation(animated ? .spring(duration: 0.45, bounce: 0.15) : nil, value: value)
            }
            .frame(height: height)
        }
    }
}

/// A ring gauge with its percentage; in ASCII, the percentage over a `[####..]` bar.
struct ThemedRing: View {
    let value: Double?
    let color: Color
    var diameter: CGFloat = 88
    @Environment(\.theme) private var theme

    var body: some View {
        let text = value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        if theme.style == .ascii {
            VStack(spacing: 2) {
                Text(text).font(.system(size: diameter * 0.26, weight: .bold, design: .monospaced))
                AsciiBar(value: value ?? 0, color: color)
            }
            .frame(width: diameter)
        } else {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: diameter * 0.09)
                Circle()
                    .trim(from: 0, to: value ?? 0)
                    .stroke(color, style: StrokeStyle(lineWidth: diameter * 0.09, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(text).font(.system(size: diameter * 0.22, weight: .semibold).monospacedDigit())
            }
            .frame(width: diameter, height: diameter)
        }
    }
}

/// Buttons that dip under the finger and spring back (with a soft highlight behind them).
/// Buttons as in the welcome tour: a flat glass pill with a hairline edge (a circle when it's just an icon); with a
/// `fill`, a solid pill — the main action. Text turns dark on a light fill. No gradients or glows: flat reads cleaner.
struct PillButtonStyle: ButtonStyle {
    var fill: Color?
    var round = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule()
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(fill.map { $0.isLight ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(Color.white) }
                             ?? AnyShapeStyle(.primary))
            .padding(.horizontal, round ? 9 : 16)
            .padding(.vertical, 8)
            .frame(minWidth: round ? 34 : nil, minHeight: 34)
            .background {
                if let fill {
                    shape.fill(fill.opacity(configuration.isPressed ? 0.8 : 1))
                } else {
                    shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.1))
                }
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(fill == nil ? 0.12 : 0), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(shape)
    }
}

extension Color {
    /// Bright enough that white text on it would be hard to read (yellow, mint, light blue).
    var isLight: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62
    }
}

struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.84

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0)).padding(-4))
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}

/// Activity indicator: `|/-\` in ASCII.
struct ThemedSpinner: View {
    @Environment(\.theme) private var theme

    var body: some View {
        if theme.style == .ascii {
            TimelineView(.periodic(from: .now, by: 0.15)) { context in
                let frames = ["|", "/", "-", "\\"]
                Text("[\(frames[Int(context.date.timeIntervalSinceReferenceDate / 0.15) % frames.count])]")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
            }
        } else {
            ProgressView()
        }
    }
}

/// A picture (album art, photo): as is, or rendered as ASCII art in the theme's text colour.
struct ThemedPicture: View {
    let image: UIImage
    var contentMode: ContentMode = .fill
    @Environment(\.theme) private var theme

    var body: some View {
        if theme.style == .ascii {
            AsciiArtwork(image: image, color: theme.text)
        } else {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        }
    }
}

/// Luminance → `" .:-=+*#%@"` on a character grid that fills the space.
struct AsciiArtwork: View {
    let image: UIImage
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            let cell = CGSize(width: ("#" as NSString).size(withAttributes: [.font: font]).width, height: font.lineHeight * 0.9)
            let cols = max(8, Int(geo.size.width / cell.width)), rows = max(4, Int(geo.size.height / cell.height))
            Text(Self.art(image, cols: cols, rows: rows))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineSpacing(-font.lineHeight * 0.1)
                .foregroundStyle(color)
                .frame(width: geo.size.width, height: geo.size.height)
                .fixedSize()
        }
        .clipped()
    }

    private static let ramp = Array(" .:-=+*#%@")

    /// The picture scaled to cols × rows grey pixels (aspect-filled), one character per pixel.
    static func art(_ image: UIImage, cols: Int, rows: Int) -> String {
        guard let cg = image.cgImage,
              let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return "" }
        let scale = max(CGFloat(cols) / CGFloat(cg.width), CGFloat(rows) * 2 / CGFloat(cg.height)) // cells are ~2× taller
        let w = CGFloat(cg.width) * scale, h = CGFloat(cg.height) * scale / 2
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: (CGFloat(cols) - w) / 2, y: (CGFloat(rows) - h) / 2, width: w, height: h))
        guard let data = ctx.data else { return "" }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cols * rows)
        var lines: [String] = []
        for y in 0..<rows {
            var line = ""
            for x in 0..<cols {
                let lum = Double(pixels[y * cols + x]) / 255
                line.append(ramp[min(ramp.count - 1, Int(lum * Double(ramp.count)))])
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    /// "понедельник, 28 сентября" → "Понедельник, 28 сентября" (`capitalized` would make it "28 Сентября", "2026 Г.").
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
