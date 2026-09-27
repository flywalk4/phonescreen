import AppKit
import PhoneScreenKit
import SwiftUI

/// Settings → Widgets: installed JavaScript widgets (permissions, secrets, settings, log), the GitHub catalog,
/// and installing from a folder (copy, or link for development with live reload).
struct WidgetsSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var widgets: WidgetManager
    @AppStorage("widgetCatalogURL") private var catalogURL = WidgetsSettings.defaultCatalog
    @State private var catalog: WidgetCatalog?
    @State private var catalogError: String?
    @State private var loadingCatalog = false
    @State private var pending: Pending?
    @State private var message: String?

    static let defaultCatalog = "https://raw.githubusercontent.com/flywalk4/phonescreen/main/catalog/index.json"

    /// A downloaded package waiting for the user to accept its permissions.
    struct Pending: Identifiable {
        let id = UUID()
        let folder: URL
        let widget: InstalledWidget
    }

    init(widgets: WidgetManager) {
        self.widgets = widgets
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Виджеты выполняются на Mac в песочнице: только разрешённые сайты, без доступа к файлам. Канал до iPhone пока не зашифрован — ставьте виджеты, которым доверяете.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                installedSection
                catalogSection

                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
        .sheet(item: $pending) { p in PermissionsSheet(widget: p.widget, install: { confirm(p) }, cancel: { pending = nil }) }
        .task { if catalog == nil { await loadCatalog() } }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Установленные").font(.headline)
                Spacer()
                Button("Установить из папки…") { chooseFolder(development: false) }
                Button("Папка разработки…") { chooseFolder(development: true) }
                    .help("Подключить папку с виджетом: изменения в файлах сразу появляются на iPhone")
            }
            if widgets.installed.isEmpty {
                Text("Пока ничего. Возьмите виджет из каталога ниже или установите из папки.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(widgets.installed) { widget in
                InstalledRow(widget: widget, state: widgets.states[widget.id], log: widgets.logs[widget.id] ?? [],
                             refresh: { widgets.refresh(widget.id) },
                             reloadSettings: { widgets.refresh(widget.id) },
                             remove: { widgets.uninstall(widget.id) })
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
            ForEach(catalog?.widgets ?? []) { entry in
                let installed = widgets.installed.first { $0.id == entry.id }
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.symbol ?? "puzzlepiece.extension").font(.title2).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.name)  ").font(.headline) + Text("v\(entry.version) · \(entry.author)").font(.caption).foregroundColor(.secondary)
                        if let d = entry.description { Text(d).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let installed, installed.manifest.version == entry.version {
                        Text("Установлен").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(installed == nil ? "Установить" : "Обновить до \(entry.version)") { Task { await download(entry) } }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    // MARK: - Actions

    private func loadCatalog() async {
        guard let url = URL(string: catalogURL) else { catalogError = "Неверный адрес"; return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await WidgetStore.loadCatalog(url)
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = "Каталог недоступен: \(error.localizedDescription)"
        }
    }

    private func download(_ entry: WidgetCatalog.Entry) async {
        guard let url = URL(string: catalogURL) else { return }
        do {
            let folder = try await WidgetStore.download(entry, indexURL: url)
            pending = Pending(folder: folder, widget: try WidgetStore.read(package: folder))
        } catch {
            message = "Не удалось скачать «\(entry.name)»: \(error)"
        }
    }

    private func confirm(_ p: Pending) {
        pending = nil
        do {
            try WidgetStore.install(folder: p.folder, development: false)
            try? FileManager.default.removeItem(at: p.folder)
            widgets.reloadAll()
            message = "«\(p.widget.manifest.name)» установлен. Добавьте его на страницу во вкладке «Страницы»."
        } catch {
            message = "Не удалось установить: \(error)"
        }
    }

    private func chooseFolder(development: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = development ? "Подключить" : "Установить"
        panel.message = "Папка виджета: manifest.json, view.json, provider.js"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let widget = try WidgetStore.read(package: folder)
            if development {
                try WidgetStore.install(folder: folder, development: true)
                widgets.reloadAll()
                message = "«\(widget.manifest.name)» подключён для разработки: сохраняйте файлы — виджет перезагрузится сам."
            } else {
                pending = Pending(folder: folder, widget: widget)
            }
        } catch {
            message = "Это не виджет: \(error)"
        }
    }
}

private struct InstalledRow: View {
    let widget: InstalledWidget
    let state: CustomWidgetState?
    let log: [String]
    let refresh: () -> Void
    let reloadSettings: () -> Void
    let remove: () -> Void
    @State private var showLog = false
    @State private var secrets: [String: String] = [:]

    var body: some View {
        let m = widget.manifest
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: m.symbol ?? "puzzlepiece.extension").font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.name).font(.headline)
                        Text("v\(m.version) · \(m.author)").font(.caption).foregroundStyle(.secondary)
                        if widget.isDevelopment {
                            Text("разработка").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.25)))
                        }
                    }
                    Text(permissionsLine(m)).font(.caption).foregroundStyle(.secondary)
                    if let error = state?.error {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                    } else if let updated = state?.updated {
                        Text("Обновлён \(updated.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Обновить сейчас")
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }.help("Удалить")
            }
            ForEach(m.permissions?.secrets ?? [], id: \.key) { secret in
                HStack {
                    Text(secret.title).font(.callout).frame(width: 180, alignment: .leading)
                    SecureField(WidgetSecrets.get(widget: m.id, key: secret.key) == nil ? "не задан" : "сохранён в Связке ключей",
                                text: Binding(get: { secrets[secret.key] ?? "" }, set: { secrets[secret.key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    Button("Сохранить") {
                        WidgetSecrets.set(widget: m.id, key: secret.key, value: secrets[secret.key])
                        secrets[secret.key] = ""
                        reloadSettings()
                    }
                }
            }
            ForEach(m.settings ?? [], id: \.key) { setting in
                HStack {
                    Text(setting.title).font(.callout).frame(width: 180, alignment: .leading)
                    TextField(setting.default ?? "", text: Binding(
                        get: { WidgetManager.settings(for: m)[setting.key] ?? "" },
                        set: { WidgetManager.setSetting(m, key: setting.key, value: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(reloadSettings)
                }
            }
            DisclosureGroup("Журнал", isExpanded: $showLog) {
                ScrollView {
                    Text(log.isEmpty ? "пусто" : log.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            .font(.caption)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func permissionsLine(_ m: WidgetManifest) -> String {
        let hosts = m.permissions?.network ?? []
        let secrets = m.permissions?.secrets?.map(\.title) ?? []
        var parts = [hosts.isEmpty ? "без сети" : "сеть: " + hosts.joined(separator: ", ")]
        if !secrets.isEmpty { parts.append("секреты: " + secrets.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Shown before installing: what the widget will be allowed to do.
private struct PermissionsSheet: View {
    let widget: InstalledWidget
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        let m = widget.manifest
        VStack(alignment: .leading, spacing: 14) {
            Label("Установить «\(m.name)»?", systemImage: m.symbol ?? "puzzlepiece.extension").font(.title3.weight(.semibold))
            Text("\(m.author) · версия \(m.version)").foregroundStyle(.secondary)
            if let d = m.description { Text(d) }
            Divider()
            Text("Виджету будет разрешено:").font(.headline)
            if let hosts = m.permissions?.network, !hosts.isEmpty {
                Label("Обращаться по HTTPS к: \(hosts.joined(separator: ", "))", systemImage: "network")
            } else {
                Label("Ничего не загружать из сети", systemImage: "network.slash")
            }
            ForEach(m.permissions?.secrets ?? [], id: \.key) { s in
                Label("Читать секрет «\(s.title)», который вы введёте в настройках", systemImage: "key")
            }
            Label("Файлы, программы и другие сайты — недоступны", systemImage: "lock")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Установить", action: install).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
