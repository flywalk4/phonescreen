import Foundation
import QwoviKit

/// Runs every installed JavaScript widget: refreshes it on its schedule and on button presses,
/// resolves its `view.json` with the data, and sends the result to the phone.
@MainActor
final class WidgetManager: ObservableObject {
    @Published private(set) var installed: [InstalledWidget] = []
    @Published private(set) var states: [String: CustomWidgetState] = [:]
    @Published private(set) var logs: [String: [String]] = [:]

    /// Sends to the phone (the pool).
    var send: ((Message) -> Void)?

    private var runtimes: [String: WidgetRuntime] = [:]
    private var timers: [String: Timer] = [:]
    private var devWatch: Timer?


    func start() {
        reloadAll()
        // Development installs are re-read when their files change (edit, save, see it on the phone).
        devWatch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDevChanges() }
        }
    }

    func reloadAll() {
        let found = WidgetStore.installed()
        let removed = Set(installed.map(\.id)).subtracting(found.map(\.id))
        for id in removed { stop(id); send?(.customWidgetRemoved(id: id)); states[id] = nil }
        installed = found
        for widget in found { start(widget) }
    }

    func reload(_ id: String) {
        guard let folder = installed.first(where: { $0.id == id }).map({ WidgetStore.root.appendingPathComponent($0.id) }),
              let widget = try? WidgetStore.load(installFolder: folder) else { return reloadAll() }
        installed = installed.map { $0.id == id ? widget : $0 }
        start(widget)
    }

    func uninstall(_ id: String) {
        stop(id)
        WidgetStore.uninstall(id)
        installed.removeAll { $0.id == id }
        states[id] = nil
        send?(.customWidgetRemoved(id: id))
    }

    /// Everything the phone needs after (re)connecting.
    func sendAll() {
        for state in states.values { send?(.customWidget(state)) }
    }

    func refresh(_ id: String) {
        guard let runtime = runtimes[id] else { return }
        runtime.refresh { [weak self] result in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(id, result) } }
        }
    }

    func action(_ id: String, _ name: String) {
        guard let runtime = runtimes[id] else { return }
        runtime.action(name) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .failure(let error) = result { self?.apply(id, .failure(error)) } else { self?.refresh(id) }
                }
            }
        }
    }

    // MARK: - Internals

    private func start(_ widget: InstalledWidget) {
        stop(widget.id)
        let id = widget.id
        let (language, table) = WidgetStrings.table(widget.strings, wanted: AppLanguage.current)
        var hooks = WidgetRuntime.Hooks(
            secret: { key in WidgetSecrets.get(widget: id, key: key) },
            settings: { Self.settings(for: widget.manifest) },
            loadStorage: {
                UserDefaults.standard.data(forKey: "widgetStorage.\(id)")
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            },
            saveStorage: { value in
                if let data = try? JSONSerialization.data(withJSONObject: value) {
                    UserDefaults.standard.set(data, forKey: "widgetStorage.\(id)")
                }
            },
            log: { [weak self] line in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendLog(id, line) } }
            })
        hooks.language = language
        hooks.strings = table
        runtimes[id] = WidgetRuntime(manifest: widget.manifest, source: widget.source, hooks: hooks)
        refresh(id)
        timers[id] = Timer.scheduledTimer(withTimeInterval: widget.manifest.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(id) }
        }
    }

    private func stop(_ id: String) {
        timers[id]?.invalidate()
        timers[id] = nil
        runtimes[id] = nil
    }

    private func apply(_ id: String, _ result: Result<Any, WidgetRuntime.Failure>) {
        guard let widget = installed.first(where: { $0.id == id }) else { return }
        let table = WidgetStrings.table(widget.strings, wanted: AppLanguage.current).table
        var state = CustomWidgetState(id: id, name: widget.manifest.localized(table).name, symbol: widget.manifest.symbol ?? "puzzlepiece.extension",
                                      views: states[id]?.views ?? [:], error: nil, updated: Date())
        switch result {
        case .success(let data):
            var views: [WidgetSize: WidgetNode] = [:]
            do {
                for size in [WidgetSize.full, .medium, .small] {
                    // `{{t.key}}` in view.json: the widget's strings next to the data.
                    var scope = data
                    if var dict = data as? [String: Any], !table.isEmpty { dict["t"] = table; scope = dict }
                    if let template = widget.view[size.rawValue] { views[size] = try WidgetTemplate.resolve(template, data: scope) }
                }
                state.views = views
            } catch {
                state.error = "view.json: \(error)"
            }
        case .failure(let error):
            state.error = error.description // keep the last good UI underneath
        }
        if let error = state.error { appendLog(id, "error: \(error)") }
        states[id] = state
        send?(.customWidget(state))
    }

    private func appendLog(_ id: String, _ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logs[id, default: []].append("\(stamp) \(line)")
        if logs[id]!.count > 100 { logs[id]!.removeFirst(logs[id]!.count - 100) }
    }

    private func checkDevChanges() {
        for widget in installed where widget.isDevelopment {
            guard let fresh = try? WidgetStore.read(package: widget.folder, development: true) else { continue }
            if fresh.modified > widget.modified {
                appendLog(widget.id, "files changed — reloading")
                reload(widget.id)
            }
        }
    }

    /// The manifest in the current language (name, description, setting titles…) — for Settings and the phone.
    func localized(_ widget: InstalledWidget) -> WidgetManifest {
        widget.manifest.localized(WidgetStrings.table(widget.strings, wanted: AppLanguage.current).table)
    }

    var names: [String: String] { Dictionary(uniqueKeysWithValues: installed.map { ($0.id, localized($0).name) }) }

    nonisolated static func settings(for manifest: WidgetManifest) -> [String: String] {
        let saved = UserDefaults.standard.dictionary(forKey: "widgetSettings.\(manifest.id)") as? [String: String] ?? [:]
        var result: [String: String] = [:]
        for setting in manifest.settings ?? [] { result[setting.key] = saved[setting.key] ?? setting.default ?? "" }
        return result
    }

    nonisolated static func setSetting(_ manifest: WidgetManifest, key: String, value: String) {
        var saved = UserDefaults.standard.dictionary(forKey: "widgetSettings.\(manifest.id)") as? [String: String] ?? [:]
        saved[key] = value
        UserDefaults.standard.set(saved, forKey: "widgetSettings.\(manifest.id)")
    }
}
