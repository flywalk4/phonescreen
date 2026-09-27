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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Тема меняет вид всего iPhone — фон, карточки, текст, шрифт — у встроенных виджетов и у виджетов из каталога. Тема — это только цвета и настройки, кода в ней нет.",
                      systemImage: "paintpalette")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                installedSection
                catalogSection

                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
        .task { if catalog.isEmpty { await loadCatalog() } }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Установленные").font(.headline)
                Spacer()
                Button("Установить из папки…") { choose(development: false) }
                Button("Папка разработки…") { choose(development: true) }
                    .help("Подключить папку с theme.json: сохраните файл — iPhone перекрасится сразу")
                Button { NSWorkspace.shared.open(ThemeStore.root) } label: { Image(systemName: "folder") }
                    .help("Папка установленных тем")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemePreview(theme: theme)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
                .contentShape(Rectangle())
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
