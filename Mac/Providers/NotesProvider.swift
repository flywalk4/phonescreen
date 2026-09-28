import AppKit
import QwoviKit

/// Apple Notes through AppleScript: iOS has no API for Notes, the Mac does, and iCloud keeps both in sync —
/// so the Mac is the phone's window into Notes. Runs on its own queue; talking to Notes can take a while.
final class NotesProvider: @unchecked Sendable {
    /// Called on the main thread.
    var onNotes: (@MainActor ([NoteSummary]) -> Void)?
    var onBody: (@MainActor (String, String) -> Void)?

    private let queue = DispatchQueue(label: "qwovi.notes", qos: .utility)
    private let script = AppleScriptRunner()
    private var lastRefresh = Date.distantPast
    static let limit = 40

    /// `force` bypasses the 5 s throttle (e.g. right after creating a note).
    func refresh(force: Bool = false) {
        queue.async { [self] in
            guard force || Date().timeIntervalSince(lastRefresh) > 5 else { return }
            lastRefresh = Date()
            guard let notes = fetch() else { return }
            DispatchQueue.main.async { [onNotes] in MainActor.assumeIsolated { onNotes?(notes) } }
        }
    }

    func body(id: String) {
        queue.async { [self] in
            let text = script.run("""
                -- nocache
                tell application "Notes" to get plaintext of note id \(AppleScriptRunner.literal(id))
                """)?.stringValue ?? ""
            DispatchQueue.main.async { [onBody] in MainActor.assumeIsolated { onBody?(id, String(text.prefix(20_000))) } }
        }
    }

    /// Creates a note in the default folder; the first line becomes its title.
    func create(text: String) {
        queue.async { [self] in
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let title = Self.html(lines.first ?? "")
            let rest = lines.dropFirst().map { "<div>\(Self.html($0).isEmpty ? "<br>" : Self.html($0))</div>" }.joined()
            script.run("""
                -- nocache
                tell application "Notes"
                    make new note at default folder of default account with properties {body:\(AppleScriptRunner.literal("<div><h1>\(title)</h1></div>\(rest)"))}
                end tell
                """)
            lastRefresh = .distantPast
        }
        refresh(force: true)
    }

    func showOnMac(id: String) {
        queue.async { [self] in
            script.run("""
                -- nocache
                tell application "Notes"
                    show note id \(AppleScriptRunner.literal(id))
                    activate
                end tell
                """)
        }
    }

    // MARK: - Fetching (queue)

    private func fetch() -> [NoteSummary]? {
        // Bulk property reads are one Apple Event each — far faster than walking notes one by one.
        // (Properties must be read off `every note` itself, not off a list variable holding the notes.)
        guard let result = script.run("""
            tell application "Notes"
                return {id of every note, name of every note, modification date of every note}
            end tell
            """), result.numberOfItems >= 3 else { return nil }
        let ids = result.atIndex(1)?.listItems.map { $0.stringValue ?? "" } ?? []
        let names = result.atIndex(2)?.listItems.map { $0.stringValue ?? "" } ?? []
        let dates = result.atIndex(3)?.listItems.map { $0.dateValue ?? .distantPast } ?? []
        // Folder names are a nicety; if Notes refuses them, the list still works.
        let folders = script.run("""
            tell application "Notes" to get name of container of every note
            """)?.listItems.map { $0.stringValue } ?? []
        guard ids.count == names.count, ids.count == dates.count else { return nil }

        let deleted: Set<String> = ["Recently Deleted", "Недавно удаленные", "Недавно удалённые"]
        var rows = ids.indices
            .filter { i in !(folders.indices.contains(i) && folders[i].map(deleted.contains) == true) }
            .map { i in (id: ids[i], title: names[i], date: dates[i], folder: folders.indices.contains(i) ? folders[i] : nil) }
        rows.sort { $0.date > $1.date }
        rows = Array(rows.prefix(Self.limit))

        // Snippets only for the notes we show.
        let snippets = script.run("""
            -- nocache
            tell application "Notes"
                set out to {}
                repeat with theID in {\(rows.map { AppleScriptRunner.literal($0.id) }.joined(separator: ", "))}
                    set end of out to plaintext of note id (contents of theID)
                end repeat
                return out
            end tell
            """)?.listItems.map { $0.stringValue ?? "" } ?? []

        return rows.enumerated().map { i, row in
            let text = snippets.indices.contains(i) ? snippets[i] : ""
            // Plain text starts with the title line; the snippet is what follows it.
            let body = text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst().joined(separator: " ")
            return NoteSummary(id: row.id, title: row.title, snippet: String(body.prefix(160)),
                               folder: row.folder, modified: row.date)
        }
    }

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
