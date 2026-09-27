import Foundation

/// Runs AppleScript with compiled scripts cached by source.
/// Not thread-safe: each provider owns one and uses it only on its own serial queue.
final class AppleScriptRunner {
    private var compiled: [String: NSAppleScript] = [:]

    @discardableResult
    func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let script = compiled[source] ?? {
            let script = NSAppleScript(source: source)
            script?.compileAndReturnError(nil)
            // Scripts with user text baked in are one-offs; only cache the fixed ones.
            if source.count < 4000 && !source.contains("-- nocache") { compiled[source] = script }
            return script
        }()
        let result = script?.executeAndReturnError(&error)
        if let error {
            AppModel.log.error("AppleScript failed: \(error, privacy: .public) — \(source.prefix(80), privacy: .public)")
        }
        return error == nil ? result : nil
    }

    /// A string literal safe to splice into AppleScript source.
    static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension NSAppleEventDescriptor {
    /// Items of an AppleScript list (1-based under the hood).
    var listItems: [NSAppleEventDescriptor] {
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { atIndex($0) }
    }
}
