import AppKit
import PhoneScreenKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Themes, laid out like Settings → Widgets: installed themes (pick one), the GitHub catalog (with
/// previews), and installing from a folder (copy, or link for development with live reload).
struct ThemesSettings: View {
    @ObservedObject private var themes: ThemeManager
    @AppStorage("widgetCatalogURL") private var catalogURL = WidgetsSettings.defaultCatalog
    @State private var catalog: [WidgetCatalog.Entry] = []
    /// Catalog themes downloaded (hash-checked) for their previews; installing writes the same bytes.
    @State private var downloaded: [String: (theme: Theme, data: Data)] = [:]
    @State private var catalogError: String?
    @State private var loadingCatalog = false
    @State private var message: String?

    init(themes: ThemeManager) {
        self.themes = themes
    }

    var body: some View {
        // A gallery (click a phone to apply) with the fine-tuning inspector beside it.
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Themes").font(.system(size: 26, weight: .bold))
                        Text("Click a phone to apply it. A theme changes the background, cards, text and font of every widget.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    installedSection
                    catalogSection
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(24)
            }
            Divider()
            ScrollView {
                ThemeTweaksPanel(themes: themes).padding(18).frame(width: 300)
            }
            .frame(width: 300)
            .clipped()
            .background(Color.black.opacity(0.12))
        }
        .task { if catalog.isEmpty { await loadCatalog() } }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installed").font(.headline)
                Spacer()
                Menu {
                    Button("Install from a folder…") { choose(development: false) }
                    Button("Connect a development folder…") { choose(development: true) }
                    Divider()
                    Button("Show the themes folder in Finder") { NSWorkspace.shared.open(ThemeStore.root) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Install a theme from a folder or connect a development folder")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], alignment: .leading, spacing: 24) {
                ForEach(themes.all) { theme in
                    ThemeTile(theme: theme, selected: theme.id == themes.selectedID,
                              development: themes.development.contains(theme.id), error: themes.errors[theme.id],
                              select: { themes.selectedID = theme.id },
                              remove: theme.id.hasPrefix("builtin.") ? nil : { themes.uninstall(theme.id) })
                }
            }
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Catalog").font(.headline)
                Spacer()
                Button { Task { await loadCatalog() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loadingCatalog)
            }
            TextField("index.json address", text: $catalogURL)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            if loadingCatalog { ProgressView().controlSize(.small) }
            if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.red) }
            if !loadingCatalog, catalogError == nil, catalog.isEmpty {
                Text("There are no themes in this catalog yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(catalog) { entry in
                let installed = themes.installed.first { $0.id == entry.id }
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let theme = downloaded[entry.id]?.theme {
                            ThemePreview(theme: theme).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15))
                                .overlay(Image(systemName: "paintpalette").foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 64, height: 110)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.text(in: AppLanguage.current).name)  ").font(.headline) + Text("v\(entry.version) · \(entry.author)").font(.caption).foregroundColor(.secondary)
                        if let d = entry.text(in: AppLanguage.current).description { Text(d).font(.callout).foregroundStyle(.secondary) }
                        if let theme = downloaded[entry.id]?.theme {
                            Text(summary(theme)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let installed, installed.version == entry.version {
                        if themes.selectedID == entry.id {
                            Text("On").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Turn on") { themes.selectedID = entry.id }
                        }
                    } else {
                        Button(installed == nil ? String(localized: "Install") : String(localized: "Update to \(entry.version)")) { Task { await install(entry) } }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private func summary(_ theme: Theme) -> String {
        let style: String
        switch theme.style {
        case .flat: style = String(localized: "flat")
        case .glass: style = String(localized: "glass")
        case .ascii: style = "ASCII"
        }
        let font: String
        switch theme.font {
        case .system: font = String(localized: "system font")
        case .rounded: font = String(localized: "rounded font")
        case .monospaced: font = String(localized: "monospaced font")
        case .serif: font = String(localized: "serif font")
        }
        let look = theme.appearance == .light ? String(localized: "light") : String(localized: "dark")
        return "\(look) · \(style) · \(font)"
    }

    // MARK: - Actions

    private func loadCatalog() async {
        guard let url = URL(string: catalogURL) else { catalogError = String(localized: "Invalid address"); return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await WidgetStore.loadCatalog(url).themes ?? []
            catalogError = nil
        } catch {
            catalog = []
            catalogError = String(localized: "The catalog is unavailable: \(error.localizedDescription)")
            return
        }
        // Previews: every theme.json is ~1 KB.
        downloaded = [:]
        await withTaskGroup(of: (String, (theme: Theme, data: Data)?).self) { group in
            for entry in catalog {
                group.addTask { (entry.id, try? await ThemeStore.download(entry, indexURL: url)) }
            }
            for await (id, result) in group { downloaded[id] = result }
        }
    }

    private func install(_ entry: WidgetCatalog.Entry) async {
        guard let url = URL(string: catalogURL) else { return }
        do {
            var data = downloaded[entry.id]?.data
            if data == nil { data = try await ThemeStore.download(entry, indexURL: url).data }
            guard let data else { return }
            let theme = try themes.install(data: data)
            themes.selectedID = theme.id
            message = String(localized: "The theme “\(theme.text(in: AppLanguage.current).name)” is installed and on.")
        } catch {
            message = String(localized: "Couldn't install “\(entry.text(in: AppLanguage.current).name)”: \(String(describing: error))")
        }
    }

    private func choose(development: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.prompt = development ? String(localized: "Connect") : String(localized: "Install")
        panel.message = String(localized: "A theme folder with theme.json (or the file itself)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try themes.install(from: url, development: development)
            themes.selectedID = theme.id
            let warnings = theme.contrastWarnings()
            let name = theme.text(in: AppLanguage.current).name
            message = (development ? String(localized: "“\(name)” is connected for development: save theme.json and the iPhone recolours itself.")
                                   : String(localized: "The theme “\(name)” is installed and on."))
                + (warnings.isEmpty ? "" : "\n" + String(localized: "Note: \(warnings.joined(separator: "; "))"))
        } catch {
            message = String(localized: "This isn't a theme: \(String(describing: error))")
        }
    }
}

/// An installed theme: its preview (click to switch the phone to it), name, badges, delete.
private struct ThemeTile: View {
    let theme: Theme
    let selected: Bool
    let development: Bool
    let error: String?
    let select: () -> Void
    let remove: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A gallery card: lifts under the pointer, the chosen one carries a check badge. One click applies.
            ThemePreview(theme: theme)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(hovering ? 0.25 : 0.08), lineWidth: selected ? 3 : 1))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 16 : 8, y: hovering ? 8 : 4)
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
                .animation(.spring(duration: 0.3), value: selected)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .onTapGesture(perform: select)
            HStack(spacing: 6) {
                Text(theme.text(in: AppLanguage.current).name).font(.headline).lineLimit(1)
                if development {
                    Text("development").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                }
                Spacer()
                if let remove {
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete the theme")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else {
                Text(theme.text(in: AppLanguage.current).description ?? "v\(theme.version) · \(theme.author)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// A theme as a tiny phone: background, cards in the theme's style, text and accent.
struct ThemePreview: View {
    let theme: Theme

    var body: some View {
        let text = Color(hex: theme.colors.text, fallback: .white)
        let secondary = Color(hex: theme.colors.secondary, fallback: .gray)
        let accent = Color(hex: theme.colors.accent, fallback: .blue)
        let design: Font.Design = switch theme.font {
        case .system: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        case .serif: .serif
        }
        GeometryReader { geo in
            let s = min(1, geo.size.width / 150) // scale type down in small previews
            ZStack {
                background
                VStack(spacing: 8 * s) {
                    card(s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("12:40").font(.system(size: 22 * s, weight: .semibold, design: design)).foregroundStyle(text)
                            Text("Wednesday 27").font(.system(size: 9 * s, design: design)).foregroundStyle(secondary)
                        }
                    }
                    HStack(spacing: 8 * s) {
                        card(s) {
                            VStack(alignment: .leading, spacing: 4 * s) {
                                Text("CPU").font(.system(size: 8 * s, design: design)).foregroundStyle(secondary)
                                if theme.style == .ascii {
                                    Text("[##..]").font(.system(size: 9 * s, design: .monospaced)).foregroundStyle(accent)
                                } else {
                                    Capsule().fill(accent).frame(width: 30 * s, height: 4 * s)
                                }
                            }
                        }
                        card(s) {
                            Image(systemName: "play.fill").font(.system(size: 14 * s)).foregroundStyle(accent)
                        }
                    }
                }
                .padding(10 * s)
            }
        }
        .environment(\.colorScheme, theme.appearance == .light ? .light : .dark)
    }

    @ViewBuilder private var background: some View {
        let colors = theme.background.colors.map { Color(hex: $0, fallback: .black) }
        if colors.count > 1 {
            let a = (theme.background.angle ?? 0) * .pi / 180
            LinearGradient(colors: colors, startPoint: UnitPoint(x: 0.5 - sin(a) / 2, y: 0.5 - cos(a) / 2),
                           endPoint: UnitPoint(x: 0.5 + sin(a) / 2, y: 0.5 + cos(a) / 2))
        } else {
            colors.first ?? .black
        }
    }

    @ViewBuilder private func card(_ s: CGFloat, @ViewBuilder _ content: () -> some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.radius / 2, 14) * s, style: .continuous)
        let fill = Color(hex: theme.colors.card, fallback: .clear)
        let border = Color(hex: theme.colors.border, fallback: .clear)
        let inner = content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(8 * s)
        switch theme.style {
        case .flat:
            inner.background(shape.fill(fill)).overlay(shape.strokeBorder(border, lineWidth: 1))
        case .glass:
            inner.background(.ultraThinMaterial, in: shape).background(shape.fill(fill)).overlay(shape.strokeBorder(border, lineWidth: 1))
        case .ascii:
            inner.background(fill).overlay(Rectangle().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
    }
}

extension Color {
    init(hex: String?, fallback: Color) {
        if let hex, let c = RGBA(hex: hex) {
            self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
        } else {
            self = fallback
        }
    }
}

/// Settings → Themes → Fine-tuning: accent, cards, font, background and page layout on top of the chosen theme.
private struct ThemeTweaksPanel: View {
    @ObservedObject var themes: ThemeManager

    var body: some View {
        let base = themes.selected
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fine-tuning").font(.headline)
                    Text("on top of “\(base.text(in: AppLanguage.current).name)”").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset") { themes.tweaks = ThemeTweaks() }.disabled(themes.tweaks.isEmpty)
                    .controlSize(.small)
            }
            .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 14) {
                row("Accent") {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: themes.tweaks.accent ?? base.colors.accent, fallback: .accentColor) },
                        set: { themes.tweaks.accent = $0.hex }), supportsOpacity: false)
                        .labelsHidden()
                }
                row("Cards") {
                    Picker("", selection: bind(\.style, base.style)) {
                        Text("Fill").tag(Theme.Style.flat)
                        Text("Glass").tag(Theme.Style.glass)
                        Text("ASCII").tag(Theme.Style.ascii)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                row("Font") {
                    Picker("", selection: bind(\.font, base.font)) {
                        Text("System").tag(Theme.FontDesign.system)
                        Text("Rounded").tag(Theme.FontDesign.rounded)
                        Text("Monospaced").tag(Theme.FontDesign.monospaced)
                        Text("Serif").tag(Theme.FontDesign.serif)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Corner radius") {
                    slider(bind(\.radius, base.radius), 0...40, step: 1, unit: "pt")
                }
                row("Live background") {
                    Picker("", selection: Binding(
                        get: { themes.tweaks.animation ?? base.background.animation ?? "none" },
                        set: { themes.tweaks.animation = $0 })) {
                        Text("None").tag("none")
                        ForEach(Theme.animations, id: \.self) { Text(LocalizedStringKey(Self.animationNames[$0] ?? $0)).tag($0) }
                        Divider()
                        Text("A photo from the iPhone (blurred)").tag(Theme.photoBackground)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Background speed") {
                    slider(bind(\.speed, base.background.speed ?? 1), 0.2...3, step: 0.1, unit: "×")
                }
                Divider()
                row("Between cards") {
                    slider(layout(\.gap, base.layout?.gap ?? 10), 0...24, step: 1, unit: "pt")
                }
                row("Screen margins") {
                    slider(layout(\.margin, base.layout?.margin ?? 10), 0...24, step: 1, unit: "pt")
                }
                row("Inside cards") {
                    slider(layout(\.padding, base.layout?.padding ?? 14), 6...24, step: 1, unit: "pt")
                }
                row("Card opacity") {
                    slider(layout(\.cardOpacity, base.layout?.cardOpacity ?? 1), 0...1, step: 0.05, unit: nil, percent: true)
                }
                row("Text size") {
                    Picker("", selection: Binding(get: { themes.tweaks.layout.textSize ?? base.layout?.textSize ?? "medium" },
                                                  set: { themes.tweaks.layout.textSize = $0 })) {
                        Text("Small").tag("small")
                        Text("Regular").tag("medium")
                        Text("Large").tag("large")
                        Text("Extra large").tag("xlarge")
                    }
                    .labelsHidden().fixedSize()
                }
                row("Shadow under cards") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.shadow ?? base.layout?.shadow ?? false },
                                             set: { themes.tweaks.layout.shadow = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Time by the notch") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.status ?? base.layout?.status ?? true },
                                             set: { themes.tweaks.layout.status = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Turn pages by themselves") {
                    Picker("", selection: Binding(get: { themes.tweaks.layout.autoPage ?? base.layout?.autoPage ?? 0 },
                                                  set: { themes.tweaks.layout.autoPage = $0 })) {
                        Text("Off").tag(0.0)
                        Text("every 15 s").tag(15.0)
                        Text("every 30 s").tag(30.0)
                        Text("every minute").tag(60.0)
                        Text("every 5 min").tag(300.0)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Vibrate on tap") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.haptics ?? base.layout?.haptics ?? true },
                                             set: { themes.tweaks.layout.haptics = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Loop pages") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.loop ?? base.layout?.loop ?? false },
                                             set: { themes.tweaks.layout.loop = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("On connecting, go to the first page") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.homeOnConnect ?? base.layout?.homeOnConnect ?? false },
                                             set: { themes.tweaks.layout.homeOnConnect = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Page dots") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.dots ?? base.layout?.dots ?? true },
                                             set: { themes.tweaks.layout.dots = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }

    }

    static let animationNames = ["aurora": "Northern lights", "stars": "Stars", "matrix": "Matrix", "waves": "Waves",
                                 "bokeh": "Bokeh", "lava": "Lava lamp", "snow": "Snow", "rain": "Rain", "gradient": "Gradient"]

    private func row(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bind<T>(_ key: WritableKeyPath<ThemeTweaks, T?>, _ fallback: T) -> Binding<T> {
        Binding(get: { themes.tweaks[keyPath: key] ?? fallback }, set: { themes.tweaks[keyPath: key] = $0 })
    }

    private func layout(_ key: WritableKeyPath<Theme.Layout, Double?>, _ fallback: Double) -> Binding<Double> {
        Binding(get: { themes.tweaks.layout[keyPath: key] ?? fallback }, set: { themes.tweaks.layout[keyPath: key] = $0 })
    }

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String?,
                        percent: Bool = false) -> some View {
        HStack(spacing: 10) {
            Slider(value: value, in: range, step: step)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%"
                         : String(format: step < 1 ? "%.1f" : "%.0f", value.wrappedValue) + (unit.map { " " + $0 } ?? ""))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 50, alignment: .leading)
        }
    }
}

private extension Color {
    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
