import AppKit
import PhoneScreenKit
import SwiftUI

/// Settings → Themes: pick the phone's look, install themes from a file or the catalog, link one for development.
struct ThemesSettings: View {
    @ObservedObject private var themes: ThemeManager
    @AppStorage("widgetCatalogURL") private var catalogURL = WidgetsSettings.defaultCatalog
    @State private var catalog: [WidgetCatalog.Entry] = []
    @State private var catalogError: String?
    @State private var message: String?

    init(themes: ThemeManager) {
        self.themes = themes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Тема iPhone").font(.headline)
                    Spacer()
                    Button("Установить файл…") { chooseFile(link: false) }
                    Button("Файл разработки…") { chooseFile(link: true) }
                        .help("Подключить theme.json: сохраните файл — iPhone перекрасится сразу")
                    Button { NSWorkspace.shared.open(ThemeManager.root) } label: { Image(systemName: "folder") }
                        .help("Папка установленных тем")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(themes.all) { theme in
                        ThemeTile(theme: theme, selected: theme.id == themes.selectedID,
                                  linked: themes.linked.contains(theme.id),
                                  select: { themes.selectedID = theme.id },
                                  remove: theme.id.hasPrefix("builtin.") ? nil : { themes.uninstall(theme.id) })
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                catalogSection
                Text("Свою тему легко написать: это один theme.json — цвета, фон, шрифт, стиль карточек (flat, glass, ascii). Формат — catalog/README.md, раздел «Темы».")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .task { await loadCatalog() }
    }

    @ViewBuilder private var catalogSection: some View {
        if !catalog.isEmpty || catalogError != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Каталог").font(.headline)
                if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.red) }
                ForEach(catalog) { entry in
                    let installed = themes.installed.first { $0.id == entry.id }
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "paintpalette").font(.title2).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.name)  ").font(.headline) + Text("v\(entry.version) · \(entry.author)").font(.caption).foregroundColor(.secondary)
                            if let d = entry.description { Text(d).font(.callout).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let installed, installed.version == entry.version {
                            Text("Установлена").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(installed == nil ? "Установить" : "Обновить до \(entry.version)") { Task { await install(entry) } }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                }
            }
        }
    }

    private func loadCatalog() async {
        guard let url = URL(string: catalogURL) else { return }
        do {
            catalog = try await WidgetStore.loadCatalog(url).themes ?? []
            catalogError = nil
        } catch {
            catalogError = "Каталог недоступен: \(error.localizedDescription)"
        }
    }

    private func install(_ entry: WidgetCatalog.Entry) async {
        guard let url = URL(string: catalogURL) else { return }
        do {
            let theme = try await themes.install(entry, indexURL: url)
            themes.selectedID = theme.id
            message = "Тема «\(theme.name)» установлена и включена."
        } catch {
            message = "Не удалось установить «\(entry.name)»: \(error)"
        }
    }

    private func chooseFile(link: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = link ? "Подключить" : "Установить"
        panel.message = "Файл темы theme.json"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let theme = try themes.install(file: file, link: link)
            themes.selectedID = theme.id
            message = link ? "«\(theme.name)» подключена: сохраняйте файл — iPhone перекрасится сам."
                           : "Тема «\(theme.name)» установлена и включена."
        } catch {
            message = "Это не тема: \(error)"
        }
    }
}

/// A theme as a tiny phone: background, two cards in the theme's style, text and accent.
private struct ThemeTile: View {
    let theme: Theme
    let selected: Bool
    let linked: Bool
    let select: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
                .onTapGesture(perform: select)
            HStack(spacing: 4) {
                Text(theme.name).font(.headline).lineLimit(1)
                if linked { Image(systemName: "link").font(.caption).help("Файл разработки") }
                Spacer()
                if let remove {
                    Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Удалить тему")
                }
            }
            Text(theme.description ?? theme.author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var preview: some View {
        let text = Color(hex: theme.colors.text, fallback: .white)
        let secondary = Color(hex: theme.colors.secondary, fallback: .gray)
        let accent = Color(hex: theme.colors.accent, fallback: .blue)
        let design: Font.Design = switch theme.font {
        case .system: .default
        case .rounded: .rounded
        case .monospaced: .monospaced
        case .serif: .serif
        }
        return ZStack {
            background
            VStack(spacing: 8) {
                card {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("12:40").font(.system(size: 22, weight: .semibold, design: design)).foregroundStyle(text)
                        Text("Среда, 27").font(.system(size: 9, design: design)).foregroundStyle(secondary)
                    }
                }
                HStack(spacing: 8) {
                    card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("CPU").font(.system(size: 8, design: design)).foregroundStyle(secondary)
                            if theme.style == .ascii {
                                Text("[###..]").font(.system(size: 9, design: .monospaced)).foregroundStyle(accent)
                            } else {
                                Capsule().fill(accent).frame(width: 34, height: 4)
                            }
                        }
                    }
                    card {
                        Image(systemName: "play.fill").font(.system(size: 14)).foregroundStyle(accent)
                    }
                }
            }
            .padding(10)
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

    @ViewBuilder private func card(@ViewBuilder _ content: () -> some View) -> some View {
        let radius = min(theme.radius / 2, 14)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let fill = Color(hex: theme.colors.card, fallback: .clear)
        let border = Color(hex: theme.colors.border, fallback: .clear)
        let body = content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(8)
        switch theme.style {
        case .flat: body.background(shape.fill(fill)).overlay(shape.strokeBorder(border, lineWidth: 1))
        case .glass: body.background(.ultraThinMaterial, in: shape).background(shape.fill(fill)).overlay(shape.strokeBorder(border, lineWidth: 1))
        case .ascii: body.background(fill).overlay(Rectangle().strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
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
