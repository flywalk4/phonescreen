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
                        Text("Темы").font(.system(size: 26, weight: .bold))
                        Text("Нажмите на телефон, чтобы применить. Тема меняет фон, карточки, текст и шрифт всех виджетов.")
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
                Text("Установленные").font(.headline)
                Spacer()
                Menu {
                    Button("Установить из папки…") { choose(development: false) }
                    Button("Подключить папку разработки…") { choose(development: true) }
                    Divider()
                    Button("Показать папку тем в Finder") { NSWorkspace.shared.open(ThemeStore.root) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Установить тему из папки или подключить папку разработки")
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
                Text("Каталог").font(.headline)
                Spacer()
                Button { Task { await loadCatalog() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                    .disabled(loadingCatalog)
            }
            TextField("Адрес index.json", text: $catalogURL)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            if loadingCatalog { ProgressView().controlSize(.small) }
            if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.red) }
            if !loadingCatalog, catalogError == nil, catalog.isEmpty {
                Text("В этом каталоге пока нет тем.").font(.callout).foregroundStyle(.secondary)
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
                        Text("\(entry.name)  ").font(.headline) + Text("v\(entry.version) · \(entry.author)").font(.caption).foregroundColor(.secondary)
                        if let d = entry.description { Text(d).font(.callout).foregroundStyle(.secondary) }
                        if let theme = downloaded[entry.id]?.theme {
                            Text(summary(theme)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let installed, installed.version == entry.version {
                        if themes.selectedID == entry.id {
                            Text("Включена").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Включить") { themes.selectedID = entry.id }
                        }
                    } else {
                        Button(installed == nil ? "Установить" : "Обновить до \(entry.version)") { Task { await install(entry) } }
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
        case .flat: style = "плоская"
        case .glass: style = "стекло"
        case .ascii: style = "ASCII"
        }
        let font: String
        switch theme.font {
        case .system: font = "системный шрифт"
        case .rounded: font = "скруглённый шрифт"
        case .monospaced: font = "моноширинный шрифт"
        case .serif: font = "шрифт с засечками"
        }
        let look = theme.appearance == .light ? "светлая" : "тёмная"
        return "\(look) · \(style) · \(font)"
    }

    // MARK: - Actions

    private func loadCatalog() async {
        guard let url = URL(string: catalogURL) else { catalogError = "Неверный адрес"; return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await WidgetStore.loadCatalog(url).themes ?? []
            catalogError = nil
        } catch {
            catalog = []
            catalogError = "Каталог недоступен: \(error.localizedDescription)"
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
            message = "Тема «\(theme.name)» установлена и включена."
        } catch {
            message = "Не удалось установить «\(entry.name)»: \(error)"
        }
    }

    private func choose(development: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .folder]
        panel.prompt = development ? "Подключить" : "Установить"
        panel.message = "Папка темы с theme.json (или сам файл)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try themes.install(from: url, development: development)
            themes.selectedID = theme.id
            let warnings = theme.contrastWarnings()
            message = (development ? "«\(theme.name)» подключена для разработки: сохраняйте theme.json — iPhone перекрасится сам."
                                   : "Тема «\(theme.name)» установлена и включена.")
                + (warnings.isEmpty ? "" : "\nВнимание: " + warnings.joined(separator: "; "))
        } catch {
            message = "Это не тема: \(error)"
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
                Text(theme.name).font(.headline).lineLimit(1)
                if development {
                    Text("разработка").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                }
                Spacer()
                if let remove {
                    Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Удалить тему")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else {
                Text(theme.description ?? "v\(theme.version) · \(theme.author)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                            Text("Среда, 27").font(.system(size: 9 * s, design: design)).foregroundStyle(secondary)
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
                    Text("Тонкая настройка").font(.headline)
                    Text("поверх «\(base.name)»").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Сбросить") { themes.tweaks = ThemeTweaks() }.disabled(themes.tweaks.isEmpty)
                    .controlSize(.small)
            }
            .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 14) {
                row("Акцент") {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: themes.tweaks.accent ?? base.colors.accent, fallback: .accentColor) },
                        set: { themes.tweaks.accent = $0.hex }), supportsOpacity: false)
                        .labelsHidden()
                }
                row("Карточки") {
                    Picker("", selection: bind(\.style, base.style)) {
                        Text("Заливка").tag(Theme.Style.flat)
                        Text("Стекло").tag(Theme.Style.glass)
                        Text("ASCII").tag(Theme.Style.ascii)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                row("Шрифт") {
                    Picker("", selection: bind(\.font, base.font)) {
                        Text("Системный").tag(Theme.FontDesign.system)
                        Text("Скруглённый").tag(Theme.FontDesign.rounded)
                        Text("Моноширинный").tag(Theme.FontDesign.monospaced)
                        Text("С засечками").tag(Theme.FontDesign.serif)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Скругление") {
                    slider(bind(\.radius, base.radius), 0...40, step: 1, unit: "pt")
                }
                row("Живой фон") {
                    Picker("", selection: Binding(
                        get: { themes.tweaks.animation ?? base.background.animation ?? "none" },
                        set: { themes.tweaks.animation = $0 })) {
                        Text("Нет").tag("none")
                        ForEach(Theme.animations, id: \.self) { Text(Self.animationNames[$0] ?? $0).tag($0) }
                        Divider()
                        Text("Фото с iPhone (размытое)").tag(Theme.photoBackground)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Скорость фона") {
                    slider(bind(\.speed, base.background.speed ?? 1), 0.2...3, step: 0.1, unit: "×")
                }
                Divider()
                row("Между карточками") {
                    slider(layout(\.gap, base.layout?.gap ?? 10), 0...24, step: 1, unit: "pt")
                }
                row("Поля экрана") {
                    slider(layout(\.margin, base.layout?.margin ?? 10), 0...24, step: 1, unit: "pt")
                }
                row("Внутри карточек") {
                    slider(layout(\.padding, base.layout?.padding ?? 14), 6...24, step: 1, unit: "pt")
                }
                row("Непрозрачность карточек") {
                    slider(layout(\.cardOpacity, base.layout?.cardOpacity ?? 1), 0...1, step: 0.05, unit: nil, percent: true)
                }
                row("Размер текста") {
                    Picker("", selection: Binding(get: { themes.tweaks.layout.textSize ?? base.layout?.textSize ?? "medium" },
                                                  set: { themes.tweaks.layout.textSize = $0 })) {
                        Text("Мелкий").tag("small")
                        Text("Обычный").tag("medium")
                        Text("Крупный").tag("large")
                        Text("Очень крупный").tag("xlarge")
                    }
                    .labelsHidden().fixedSize()
                }
                row("Тень под карточками") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.shadow ?? base.layout?.shadow ?? false },
                                             set: { themes.tweaks.layout.shadow = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Время у выреза") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.status ?? base.layout?.status ?? true },
                                             set: { themes.tweaks.layout.status = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Листать страницы сами") {
                    Picker("", selection: Binding(get: { themes.tweaks.layout.autoPage ?? base.layout?.autoPage ?? 0 },
                                                  set: { themes.tweaks.layout.autoPage = $0 })) {
                        Text("Нет").tag(0.0)
                        Text("каждые 15 с").tag(15.0)
                        Text("каждые 30 с").tag(30.0)
                        Text("каждую минуту").tag(60.0)
                        Text("каждые 5 мин").tag(300.0)
                    }
                    .labelsHidden().fixedSize()
                }
                row("Вибрация при нажатии") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.haptics ?? base.layout?.haptics ?? true },
                                             set: { themes.tweaks.layout.haptics = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                row("Точки страниц") {
                    Toggle("", isOn: Binding(get: { themes.tweaks.layout.dots ?? base.layout?.dots ?? true },
                                             set: { themes.tweaks.layout.dots = $0 }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }

    }

    static let animationNames = ["aurora": "Северное сияние", "stars": "Звёзды", "matrix": "Матрица", "waves": "Волны",
                                 "bokeh": "Огоньки", "lava": "Лавовая лампа", "snow": "Снег", "rain": "Дождь", "gradient": "Градиент"]

    private func row(_ title: String, @ViewBuilder _ control: () -> some View) -> some View {
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
