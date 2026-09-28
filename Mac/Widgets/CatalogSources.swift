import Foundation
import QwoviKit

/// Where widgets and themes come from: the official catalog plus any number the user adds (each an `index.json`
/// address; a GitHub repository address is turned into its `catalog/index.json`). Shared by Settings → Widgets
/// and Settings → Themes, so both show the same catalogs and load them once.
@MainActor
final class CatalogSources: ObservableObject {
    static let shared = CatalogSources()
    static let official = "https://raw.githubusercontent.com/flywalk4/qwovi/main/catalog/index.json"
    private static let key = "widgetCatalogURLs"

    /// The official catalog first, then the user's in the order they were added.
    @Published private(set) var urls: [String]
    @Published private(set) var results: [String: Load] = [:]
    @Published private(set) var loading = false

    enum Load {
        case loaded(WidgetCatalog)
        case failed(String)
    }

    /// A catalog entry and the catalog it comes from (its files are relative to that index).
    struct Item: Identifiable {
        let entry: WidgetCatalog.Entry
        let source: URL
        var id: String { entry.id }
    }

    private init() {
        var added = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        // Before there could be several: one editable address. Keep it if it was changed to someone else's.
        if UserDefaults.standard.object(forKey: Self.key) == nil,
           let old = UserDefaults.standard.string(forKey: "widgetCatalogURL"), !Self.isOfficial(old) {
            added = [old]
        }
        urls = [Self.official] + added.filter { !Self.isOfficial($0) }
    }

    /// The official address, also as it was before the project was renamed.
    static func isOfficial(_ url: String) -> Bool {
        url == official || url.hasPrefix("https://raw.githubusercontent.com/flywalk4/phonescreen/")
    }

    // MARK: - Editing

    /// Adds a catalog and loads it; returns why it can't be added.
    func add(_ text: String) async -> String? {
        guard let url = Self.normalize(text) else {
            return String(localized: "Enter an https:// address of an index.json or a GitHub repository")
        }
        guard !urls.contains(url) else { return String(localized: "This catalog is already added") }
        urls.append(url)
        save()
        await load(url)
        return nil
    }

    func remove(_ url: String) {
        guard !Self.isOfficial(url) else { return }
        urls.removeAll { $0 == url }
        results[url] = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(urls.filter { !Self.isOfficial($0) }, forKey: Self.key)
    }

    /// `https://github.com/user/repo` (or `…/tree/branch`) → that repository's `catalog/index.json`;
    /// any other https (or file) address is taken as the index itself.
    static func normalize(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, scheme == "https" || scheme == "file" else { return nil }
        if url.host == "github.com" {
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            let branch = parts.count >= 4 && parts[2] == "tree" ? parts[3] : "main"
            return "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/\(branch)/catalog/index.json"
        }
        return text
    }

    // MARK: - Loading

    func reloadAll() async {
        loading = true
        defer { loading = false }
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { await self.load(url) } }
        }
    }

    func loadIfNeeded() async {
        if results.isEmpty, !loading { await reloadAll() }
    }

    private func load(_ address: String) async {
        guard let url = URL(string: address) else { results[address] = .failed(String(localized: "Invalid address")); return }
        do {
            results[address] = .loaded(try await WidgetStore.loadCatalog(url))
        } catch {
            results[address] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Contents

    var widgets: [Item] { merged(\.widgets) }
    var themes: [Item] { merged { $0.themes ?? [] } }

    /// Every catalog's entries in catalog order; an id in several catalogs appears once, in its newest version
    /// (the earlier catalog wins a tie, so the official one does).
    private func merged(_ entries: (WidgetCatalog) -> [WidgetCatalog.Entry]) -> [Item] {
        var items: [Item] = []
        var index: [String: Int] = [:]
        for address in urls {
            guard case .loaded(let catalog) = results[address], let source = URL(string: address) else { continue }
            for entry in entries(catalog) {
                let item = Item(entry: entry, source: source)
                if let i = index[entry.id] {
                    if entry.version.compare(items[i].entry.version, options: .numeric) == .orderedDescending { items[i] = item }
                } else {
                    index[entry.id] = items.count
                    items.append(item)
                }
            }
        }
        return items
    }

    /// The catalog's own name, else its host (the official one is "Qwovi").
    func name(of address: String) -> String {
        if case .loaded(let catalog) = results[address], let name = catalog.name, !name.isEmpty { return name }
        if Self.isOfficial(address) { return "Qwovi" }
        return URL(string: address).map { url in
            // raw.githubusercontent.com/user/repo/… reads better as user/repo.
            let parts = url.path.split(separator: "/")
            return url.host == "raw.githubusercontent.com" && parts.count >= 2 ? "\(parts[0])/\(parts[1])" : url.host ?? address
        } ?? address
    }
}
