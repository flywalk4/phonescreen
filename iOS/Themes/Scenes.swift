import SwiftUI

/// Animated backgrounds, drawn natively (Canvas + TimelineView, ~30 fps). Used by themes
/// (`background.animation`) and by the `scene` widget node (live wallpapers).
/// With Reduce Motion the scene is drawn once, still.
struct SceneView: View {
    enum Kind: String, CaseIterable {
        case aurora, stars, matrix, waves, bokeh, lava, snow, rain, gradient
    }

    let kind: Kind
    /// Background: one colour or a gradient.
    let base: [Color]
    /// Colours of the moving parts (blobs, stars, glyphs, waves).
    let tints: [Color]
    var speed: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 12 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) * speed
            Canvas(rendersAsynchronously: true) { ctx, size in
                Self.fillBase(&ctx, size, base)
                let palette = tints.isEmpty ? [Color.purple, .teal, .blue, .pink] : tints
                switch kind {
                case .aurora: Self.aurora(&ctx, size, t, palette)
                case .stars: Self.stars(&ctx, size, t, palette)
                case .matrix: Self.matrix(&ctx, size, t, palette)
                case .waves: Self.waves(&ctx, size, t, palette)
                case .bokeh: Self.bokeh(&ctx, size, t, palette)
                case .lava: Self.lava(&ctx, size, t, palette)
                case .snow: Self.snow(&ctx, size, t, palette)
                case .rain: Self.rain(&ctx, size, t, palette)
                case .gradient: Self.gradient(&ctx, size, t, palette)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static func fillBase(_ ctx: inout GraphicsContext, _ size: CGSize, _ colors: [Color]) {
        let rect = CGRect(origin: .zero, size: size)
        if colors.count > 1 {
            ctx.fill(Path(rect), with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                                       endPoint: CGPoint(x: size.width, y: size.height)))
        } else {
            ctx.fill(Path(rect), with: .color(colors.first ?? .black))
        }
    }

    /// Deterministic pseudo-random 0…1 (stars and glyphs keep their place between frames).
    private static func rand(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }

    // MARK: Aurora — big soft colour blobs drifting on slow Lissajous paths.

    private static func aurora(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        var layer = ctx
        layer.addFilter(.blur(radius: min(size.width, size.height) * 0.18))
        let r = max(size.width, size.height) * 0.45
        for i in 0..<4 {
            let p = Double(i) * 1.7
            let x = size.width * (0.5 + 0.38 * sin(t * 0.11 + p))
            let y = size.height * (0.5 + 0.36 * cos(t * 0.083 + p * 1.3))
            let rr = r * (0.75 + 0.2 * sin(t * 0.2 + p))
            layer.opacity = 0.55
            layer.fill(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)),
                       with: .color(tints[i % tints.count]))
        }
    }

    // MARK: Stars — a slow drifting field with twinkling.

    private static func stars(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let count = Int(size.width * size.height / 2600)
        for i in 0..<max(40, count) {
            let depth = 0.3 + rand(i * 7) * 0.7
            let x = (rand(i) * size.width + t * 4 * depth).truncatingRemainder(dividingBy: size.width)
            let y = rand(i * 3) * size.height
            let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * sin(t * (0.6 + rand(i * 5) * 1.8) + Double(i)))
            let d = 0.8 + depth * 1.8
            ctx.opacity = twinkle * depth
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(tints[i % tints.count]))
        }
        ctx.opacity = 1
    }

    // MARK: Matrix — columns of glyphs raining down (made for the ASCII theme).

    private static func matrix(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let head = tints[0], trail = tints[tints.count > 1 ? 1 : 0]
        let cell: CGFloat = 14
        let glyphs = Array("01<>{}[]/=+*#$%&ｱｲｳｴｵｶｷｸｹｺ")
        let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
        for c in 0..<cols {
            let speed = 4 + rand(c) * 7
            let length = 8 + Int(rand(c * 13) * 14)
            let headRow = Int((t * speed + rand(c * 3) * Double(rows + length)).truncatingRemainder(dividingBy: Double(rows + length)))
            for k in 0..<length {
                let r = headRow - k
                guard r >= 0, r < rows else { continue }
                let glyph = glyphs[Int(rand(c * 31 + r + Int(t * 2) * (k == 0 ? 1 : 0)) * Double(glyphs.count)) % glyphs.count]
                var text = ctx.resolve(Text(String(glyph)).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(k == 0 ? head : trail))
                text.shading = .color(k == 0 ? head : trail)
                ctx.opacity = k == 0 ? 1 : max(0.05, 0.8 - Double(k) / Double(length))
                ctx.draw(text, at: CGPoint(x: CGFloat(c) * cell + cell / 2, y: CGFloat(r) * cell + cell / 2))
            }
        }
        ctx.opacity = 1
    }

    // MARK: Waves — layered translucent sine waves along the bottom.

    private static func waves(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        for layer in 0..<4 {
            let base = size.height * (0.55 + Double(layer) * 0.1)
            let amp = size.height * (0.05 - Double(layer) * 0.006)
            let k = 2 * Double.pi / (size.width * (1.1 + Double(layer) * 0.3))
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: 0, through: size.width, by: 6) {
                let y = base + amp * sin(x * k + t * (0.6 + Double(layer) * 0.25) + Double(layer))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.opacity = 0.35
            ctx.fill(path, with: .color(tints[layer % tints.count]))
        }
        ctx.opacity = 1
    }

    // MARK: Bokeh — soft out-of-focus lights floating up.

    private static func bokeh(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        var layer = ctx
        layer.addFilter(.blur(radius: 6))
        for i in 0..<18 {
            let r = 14 + rand(i * 5) * 46
            let x = rand(i) * size.width + 20 * sin(t * 0.3 + Double(i))
            let travel = size.height + r * 2
            let y = size.height + r - (t * (6 + rand(i * 9) * 14) + rand(i * 2) * travel).truncatingRemainder(dividingBy: travel)
            layer.opacity = 0.18 + rand(i * 11) * 0.25
            layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(tints[i % tints.count]))
        }
    }

    // MARK: Lava — slow metaball-like blobs (blur + alpha threshold).

    private static func lava(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let tint = tints[0]
        ctx.drawLayer { layer in
            layer.addFilter(.alphaThreshold(min: 0.5, color: tint))
            layer.addFilter(.blur(radius: 18))
            layer.drawLayer { inner in
                for i in 0..<7 {
                    let r = min(size.width, size.height) * (0.12 + rand(i * 3) * 0.1)
                    let x = size.width * (0.2 + 0.6 * rand(i)) + size.width * 0.12 * sin(t * 0.2 + Double(i))
                    let y = size.height * (0.5 + 0.42 * sin(t * (0.07 + rand(i * 7) * 0.08) + Double(i) * 2))
                    inner.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white))
                }
            }
        }
    }

    // MARK: Snow — flakes of three depths drifting down and sideways.

    private static func snow(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let count = max(60, Int(size.width * size.height / 3000))
        for i in 0..<count {
            let depth = 0.35 + rand(i * 7) * 0.65
            let fall = size.height + 20
            let y = (rand(i * 3) * fall + t * (10 + 26 * depth)).truncatingRemainder(dividingBy: fall) - 10
            let x = (rand(i) * size.width + 14 * sin(t * (0.4 + rand(i * 5)) + Double(i))).truncatingRemainder(dividingBy: size.width)
            let d = 1.2 + depth * 3.2
            ctx.opacity = 0.35 + depth * 0.6
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(tints[i % tints.count]))
        }
        ctx.opacity = 1
    }

    // MARK: Rain — slanted streaks and a few drops sliding down the glass.

    private static func rain(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let count = max(50, Int(size.width * size.height / 2600))
        let slant = 0.18
        for i in 0..<count {
            let depth = 0.3 + rand(i * 7) * 0.7
            let length = 10 + depth * 18
            let fall = size.height + length
            let y = (rand(i * 3) * fall + t * (220 + 380 * depth)).truncatingRemainder(dividingBy: fall) - length
            let x = (rand(i) * (size.width + 60) - y * slant).truncatingRemainder(dividingBy: size.width + 60)
            var streak = Path()
            streak.move(to: CGPoint(x: x, y: y))
            streak.addLine(to: CGPoint(x: x + length * slant, y: y + length))
            ctx.opacity = 0.15 + depth * 0.45
            ctx.stroke(streak, with: .color(tints[i % tints.count]), lineWidth: 0.6 + depth)
        }
        for i in 0..<14 { // drops on the glass: sit still, then slide
            let cycle = 6 + rand(i * 11) * 8
            let phase = (t + rand(i * 13) * cycle).truncatingRemainder(dividingBy: cycle) / cycle
            let slide = phase < 0.6 ? 0 : pow((phase - 0.6) / 0.4, 2) * size.height * 0.5
            let r = 2 + rand(i * 17) * 4
            let x = rand(i * 19) * size.width, y = rand(i * 23) * size.height * 0.8 + slide
            ctx.opacity = 0.5 * (1 - max(0, phase - 0.85) / 0.15)
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r * 1.2, width: r * 2, height: r * 2.4)),
                     with: .color(tints[i % tints.count]))
        }
        ctx.opacity = 1
    }

    // MARK: Gradient — the tints as a slowly turning gradient with a drifting glow.

    private static func gradient(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ tints: [Color]) {
        let angle = t * 0.04
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = hypot(size.width, size.height) / 2
        let start = CGPoint(x: c.x - cos(angle) * r, y: c.y - sin(angle) * r)
        let end = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
        ctx.opacity = 0.85
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: tints), startPoint: start, endPoint: end))
        let glow = CGPoint(x: size.width * (0.5 + 0.35 * sin(t * 0.09)), y: size.height * (0.5 + 0.3 * cos(t * 0.07)))
        ctx.opacity = 0.35
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .radialGradient(Gradient(colors: [tints[tints.count > 1 ? 1 : 0], .clear]), center: glow,
                                       startRadius: 0, endRadius: r * 0.8))
        ctx.opacity = 1
    }
}
