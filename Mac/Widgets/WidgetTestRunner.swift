import Foundation
import PhoneScreenKit

/// `PhoneScreen --widget-test <folder>`: validates a package, runs `refresh()` once in the real sandbox and
/// prints the data and the resolved UI for every size as JSON (exit 0), or the error (exit 1).
/// For widget authors and AI agents: the same code path the app uses, without a phone.
enum WidgetTestRunner {
    static func run(folder: URL) {
        let widget: InstalledWidget
        do {
            widget = try WidgetStore.read(package: folder)
        } catch {
            fail("пакет: \(error)")
        }
        let manifest = widget.manifest
        // WIDGET_LANG=en: the widget in that language (default: the app's).
        let (language, table) = WidgetStrings.table(widget.strings,
                                                    wanted: ProcessInfo.processInfo.environment["WIDGET_LANG"] ?? AppLanguage.current)
        var hooks = WidgetRuntime.Hooks(
            secret: { key in ProcessInfo.processInfo.environment["WIDGET_SECRET_\(key.uppercased())"] },
            settings: {
                var s = WidgetManager.settings(for: manifest)
                for setting in manifest.settings ?? [] {
                    if let v = ProcessInfo.processInfo.environment["WIDGET_SETTING_\(setting.key.uppercased())"] { s[setting.key] = v }
                }
                return s
            },
            loadStorage: { [:] }, saveStorage: { _ in },
            log: { line in FileHandle.standardError.write(Data("log: \(line)\n".utf8)) },
            home: ProcessInfo.processInfo.environment["WIDGET_HOME"] ?? NSHomeDirectory())
        hooks.language = language
        hooks.strings = table
        let runtime = WidgetRuntime(manifest: manifest, source: widget.source, hooks: hooks)
        runtime.refresh { result in
            switch result {
            case .failure(let error):
                fail("refresh(): \(error)")
            case .success(let data):
                var out: [String: Any] = ["id": manifest.id, "data": data]
                var views: [String: Any] = [:]
                for size in [WidgetSize.full, .medium, .small] {
                    guard let template = widget.view[size.rawValue] else { continue }
                    do {
                        var scope = data
                        if var dict = data as? [String: Any], !table.isEmpty { dict["t"] = table; scope = dict }
                        let node = try WidgetTemplate.resolve(template, data: scope)
                        views[size.rawValue] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node))
                    } catch {
                        fail("view.json (\(size.rawValue)): \(error)")
                    }
                }
                out["views"] = views
                let json = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(json)
                FileHandle.standardOutput.write(Data("\nOK\n".utf8))
                exit(0)
            }
        }
    }

    /// `PhoneScreen --catalog-test <index.json URL or path>`: downloads every widget and theme the way the app
    /// installs it (SHA-256 checked) and validates it. Exit 0 if all install.
    static func runCatalog(_ location: String) {
        let url = location.contains("://") ? URL(string: location)! : URL(fileURLWithPath: location)
        Task {
            do {
                let catalog = try await WidgetStore.loadCatalog(url)
                for entry in catalog.widgets {
                    let folder = try await WidgetStore.download(entry, indexURL: url)
                    let widget = try WidgetStore.read(package: folder)
                    print("✓ \(entry.id) \(widget.manifest.version)")
                    try? FileManager.default.removeItem(at: folder)
                }
                for entry in catalog.themes ?? [] {
                    let theme = try await ThemeStore.download(entry, indexURL: url).theme
                    print("✓ тема \(entry.id) \(theme.version)")
                }
                print("OK")
                exit(0)
            } catch {
                fail("каталог: \(error)")
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL \(message)\n".utf8))
        exit(1)
    }
}
