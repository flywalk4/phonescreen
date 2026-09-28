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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Widgets").font(.system(size: 26, weight: .bold))
                    Label("They run on the Mac in a sandbox: only the sites and (read-only) files they declare, which you see before installing.",
                          systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                installedSection
                catalogSection

                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(24)
        }
        .sheet(item: $pending) { p in PermissionsSheet(widget: p.widget, install: { confirm(p) }, cancel: { pending = nil }) }
        .task { if catalog == nil { await loadCatalog() } }
    }

    // MARK: - Installed

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installed").font(.headline)
                Spacer()
                Menu {
                    Button("Install from a folder…") { chooseFolder(development: false) }
                    Button("Connect a development folder…") { chooseFolder(development: true) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Install a widget from a folder or connect a development folder (live reload)")
            }
            if widgets.installed.isEmpty {
                Text("Nothing yet. Pick a widget from the catalog below or install one from a folder.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(widgets.installed) { widget in
                InstalledRow(widget: widget, manifest: widgets.localized(widget), state: widgets.states[widget.id],
                             log: widgets.logs[widget.id] ?? [],
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
                Text("Catalog").font(.headline)
                Spacer()
                Button { Task { await loadCatalog() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(loadingCatalog)
            }
            TextField("index.json address", text: $catalogURL)
                .textFieldStyle(.roundedBorder).font(.caption.monospaced())
            if loadingCatalog { ProgressView().controlSize(.small) }
            if let catalogError { Text(catalogError).font(.caption).foregroundStyle(.red) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(catalog?.widgets ?? []) { entry in
                    let installed = widgets.installed.first { $0.id == entry.id }
                    CatalogCard(entry: entry, installedVersion: installed?.manifest.version) {
                        Task { await download(entry) }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func loadCatalog() async {
        guard let url = URL(string: catalogURL) else { catalogError = String(localized: "Invalid address"); return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await WidgetStore.loadCatalog(url)
            catalogError = nil
        } catch {
            catalog = nil
            catalogError = String(localized: "The catalog is unavailable: \(error.localizedDescription)")
        }
    }

    private func download(_ entry: WidgetCatalog.Entry) async {
        guard let url = URL(string: catalogURL) else { return }
        do {
            let folder = try await WidgetStore.download(entry, indexURL: url)
            pending = Pending(folder: folder, widget: try WidgetStore.read(package: folder))
        } catch {
            message = String(localized: "Couldn't download “\(entry.text(in: AppLanguage.current).name)”: \(String(describing: error))")
        }
    }

    private func confirm(_ p: Pending) {
        pending = nil
        do {
            try WidgetStore.install(folder: p.folder, development: false)
            try? FileManager.default.removeItem(at: p.folder)
            widgets.reloadAll()
            message = String(localized: "“\(p.widget.manifest.localized(WidgetStrings.table(p.widget.strings, wanted: AppLanguage.current).table).name)” is installed. Add it to a page on the Pages tab.")
        } catch {
            message = String(localized: "Couldn't install: \(String(describing: error))")
        }
    }

    private func chooseFolder(development: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = development ? String(localized: "Connect") : String(localized: "Install")
        panel.message = String(localized: "A widget folder: manifest.json, view.json, provider.js")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let widget = try WidgetStore.read(package: folder)
            if development {
                try WidgetStore.install(folder: folder, development: true)
                widgets.reloadAll()
                message = String(localized: "“\(widget.manifest.localized(WidgetStrings.table(widget.strings, wanted: AppLanguage.current).table).name)” is connected for development: save the files and the widget reloads itself.")
            } else {
                pending = Pending(folder: folder, widget: widget)
            }
        } catch {
            message = String(localized: "This isn't a widget: \(String(describing: error))")
        }
    }
}

private struct InstalledRow: View {
    let widget: InstalledWidget
    /// In the current language (titles, hints, option names); keys and defaults are the widget's own.
    let manifest: WidgetManifest
    let state: CustomWidgetState?
    let log: [String]
    let refresh: () -> Void
    let reloadSettings: () -> Void
    let remove: () -> Void
    @State private var showLog = false
    @State private var secrets: [String: String] = [:]
    @State private var confirmRemove = false

    var body: some View {
        let m = manifest
        VStack(alignment: .leading, spacing: 14) {
            header(m)
            if !(m.settings ?? []).isEmpty || !(m.permissions?.secrets ?? []).isEmpty {
                Divider()
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                    ForEach(m.permissions?.secrets ?? [], id: \.key) { secret in
                        GridRow {
                            label(secret.title)
                            HStack {
                                SecureField(WidgetSecrets.get(widget: m.id, key: secret.key) == nil ? String(localized: "not set") : String(localized: "saved in the Keychain"),
                                            text: Binding(get: { secrets[secret.key] ?? "" }, set: { secrets[secret.key] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    WidgetSecrets.set(widget: m.id, key: secret.key, value: secrets[secret.key])
                                    secrets[secret.key] = ""
                                    reloadSettings()
                                }
                                .disabled((secrets[secret.key] ?? "").isEmpty)
                            }
                        }
                    }
                    ForEach(m.settings ?? [], id: \.key) { setting in
                        GridRow {
                            label(setting.title)
                            SettingControl(manifest: m, setting: setting, changed: reloadSettings)
                        }
                    }
                }
            }
            DisclosureGroup(isExpanded: $showLog) {
                ScrollView {
                    Text(log.isEmpty ? String(localized: "empty") : log.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.15)))
            } label: {
                Text("Log").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.12)))
        .confirmationDialog("Delete “\(m.name)”?", isPresented: $confirmRemove) {
            Button("Delete", role: .destructive, action: remove)
        } message: {
            Text("The widget disappears from the iPhone's pages.")
        }
    }

    private func header(_ m: WidgetManifest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: m.symbol ?? "puzzlepiece.extension")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)], startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(m.name).font(.headline)
                    Text("\(m.version) · \(m.author)").font(.caption).foregroundStyle(.tertiary)
                    if widget.isDevelopment {
                        Text("development").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                    }
                }
                if let d = m.description {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    status
                    Text(permissionsLine(m)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 22) }
                    .help("Refresh now")
                Button { confirmRemove = true } label: { Image(systemName: "trash").frame(width: 24, height: 22) }
                    .help("Delete")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if let error = state?.error {
            Label { Text(error).lineLimit(2) } icon: { Circle().fill(.red).frame(width: 7, height: 7) }
                .font(.caption).foregroundStyle(.red)
        } else if let updated = state?.updated {
            Label { Text("updated \(updated.formatted(date: .omitted, time: .shortened))") } icon: {
                Circle().fill(.green).frame(width: 7, height: 7)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.callout)
            .frame(width: 190, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionsLine(_ m: WidgetManifest) -> String {
        let hosts = m.permissions?.network ?? []
        let secrets = m.permissions?.secrets?.map(\.title) ?? []
        var parts = [hosts.isEmpty ? String(localized: "no network") : String(localized: "network: \(hosts.joined(separator: ", "))")]
        if !secrets.isEmpty { parts.append(String(localized: "secrets: \(secrets.joined(separator: ", "))")) }
        if let files = m.permissions?.files, !files.isEmpty { parts.append(String(localized: "files: \(files.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }
}

/// The control for one manifest setting; writes the value as a string and asks the widget to refresh.
private struct SettingControl: View {
    let manifest: WidgetManifest
    let setting: WidgetManifest.Setting
    let changed: () -> Void
    @State private var text = ""
    @State private var number = 0.0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let hint = setting.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            text = WidgetManager.settings(for: manifest)[setting.key] ?? ""
            number = Double(text.replacingOccurrences(of: ",", with: ".")) ?? setting.min ?? 0
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .choice:
            let options = setting.options ?? []
            let picker = Picker("", selection: Binding(get: { text }, set: { save($0) })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
                if !options.contains(where: { $0.value == text }) { Text(text.isEmpty ? "—" : text).tag(text) }
            }
            .labelsHidden()
            if options.count <= 3, options.allSatisfy({ $0.label.count <= 12 }) {
                picker.pickerStyle(.segmented).fixedSize()
            } else {
                picker.pickerStyle(.menu).fixedSize()
            }
        case .toggle:
            Toggle("", isOn: Binding(get: { WidgetManifest.Setting.isOn(text) }, set: { save($0 ? "true" : "false") }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        case .number:
            if let min = setting.min, let max = setting.max {
                HStack(spacing: 10) {
                    Slider(value: $number, in: min...max, step: setting.step ?? 1) { editing in
                        if !editing { save(format(number)) }
                    }
                    .frame(maxWidth: 260)
                    Text(format(number) + (setting.unit.map { " " + $0 } ?? ""))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .leading)
                }
            } else {
                HStack(spacing: 6) {
                    TextField(setting.default ?? "", text: $text)
                        .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                        .focused($focused).onSubmit { save(text) }
                    Stepper("", value: Binding(get: { number }, set: { number = $0; save(format($0)) }),
                            in: (setting.min ?? -Double.infinity)...(setting.max ?? Double.infinity), step: setting.step ?? 1)
                        .labelsHidden()
                    if let unit = setting.unit { Text(unit).font(.callout).foregroundStyle(.secondary) }
                }
                .onChange(of: focused) { _, now in if !now { save(text) } }
            }
        case .text:
            TextField(setting.default ?? "", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save(text) }
                .onChange(of: focused) { _, now in if !now { save(text) } }
        }
    }

    private func save(_ value: String) {
        text = value
        if let n = Double(value.replacingOccurrences(of: ",", with: ".")) { number = n }
        guard value != WidgetManager.settings(for: manifest)[setting.key] else { return }
        WidgetManager.setSetting(manifest, key: setting.key, value: value)
        changed()
    }

    private func format(_ value: Double) -> String {
        let step = setting.step ?? 1
        let decimals = step >= 1 ? 0 : min(3, Int((-log10(step)).rounded(.up)))
        return String(format: "%.\(decimals)f", value)
    }
}

/// A catalog widget as a gallery card: icon, name, what it does, one button.
private struct CatalogCard: View {
    let entry: WidgetCatalog.Entry
    let installedVersion: String?
    let install: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: entry.symbol ?? "puzzlepiece.extension")
                    .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)], startPoint: .top, endPoint: .bottom)))
                Spacer()
                if let installedVersion, installedVersion == entry.version {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium)).foregroundStyle(.green)
                } else {
                    Button(installedVersion == nil ? String(localized: "Install") : String(localized: "Update"), action: install)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            let text = entry.text(in: AppLanguage.current)
            Text(text.name).font(.headline)
            Text(text.description ?? "").font(.caption).foregroundStyle(.secondary)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text("v\(entry.version) · \(entry.author)").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovering ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Shown before installing: what the widget will be allowed to do.
private struct PermissionsSheet: View {
    let widget: InstalledWidget
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        let m = widget.manifest.localized(WidgetStrings.table(widget.strings, wanted: AppLanguage.current).table)
        VStack(alignment: .leading, spacing: 14) {
            Label("Install “\(m.name)”?", systemImage: m.symbol ?? "puzzlepiece.extension").font(.title3.weight(.semibold))
            Text("\(m.author) · version \(m.version)").foregroundStyle(.secondary)
            if let d = m.description { Text(d) }
            Divider()
            Text("The widget will be allowed to:").font(.headline)
            if let hosts = m.permissions?.network, !hosts.isEmpty {
                Label("Reach over HTTPS: \(hosts.joined(separator: ", "))", systemImage: "network")
            } else {
                Label("Load nothing from the network", systemImage: "network.slash")
            }
            ForEach(m.permissions?.secrets ?? [], id: \.key) { s in
                Label("Read the secret “\(s.title)” that you enter in the settings", systemImage: "key")
            }
            if let files = m.permissions?.files, !files.isEmpty {
                Label("Read files: \(files.joined(separator: ", "))", systemImage: "doc.text.magnifyingglass")
            }
            Label(m.permissions?.files?.isEmpty == false ? String(localized: "Other files, apps and sites are off limits")
                                                          : String(localized: "Files, apps and other sites are off limits"), systemImage: "lock")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Install", action: install).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
