import Foundation
import JavaScriptCore
import PhoneScreenKit

// Stops runaway scripts (`while (true) {}`): JavaScriptCore's execution time limit, exported by the framework
// though declared in a private header.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(_ group: JSContextGroupRef, _ limit: Double,
                                                 _ callback: UnsafeRawPointer?, _ context: UnsafeMutableRawPointer?)

/// One widget's `provider.js`, sandboxed in its own JavaScriptCore VM on its own queue.
///
/// The script sees only: `fetch` (HTTPS, hosts from the manifest — redirects included), `secrets.get`
/// (keys declared in the manifest, values from the Keychain), `settings`, `storage.get/set` (small, persisted),
/// `files` (read-only, paths from the manifest), `setTimeout`, `console`. No processes, no other network.
/// It defines `async function refresh(ctx)` returning data for `view.json`, and optionally
/// `async function action(name, ctx)` for buttons.
final class WidgetRuntime: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Hooks {
        var secret: @Sendable (String) -> String?
        var settings: @Sendable () -> [String: String]
        var loadStorage: @Sendable () -> [String: Any]
        var saveStorage: @Sendable ([String: Any]) -> Void
        var log: @Sendable (String) -> Void
        /// Home folder `~/` resolves to (the real one; overridable in `--widget-test`).
        var home: String = NSHomeDirectory()
        /// The widget's language ("ru", "en"…) and its strings table (`t()`, `format`), see WidgetStrings.
        var language: String = "ru"
        var strings: [String: Any] = [:]
    }

    enum Failure: Error, CustomStringConvertible {
        case script(String), timeout, noRefresh
        var description: String {
            switch self {
            case .script(let s): s
            case .timeout: "Скрипт не ответил за 20 с"
            case .noRefresh: "В provider.js нет функции refresh()"
            }
        }
    }

    let manifest: WidgetManifest
    private let source: String
    private let hooks: Hooks
    private let queue: DispatchQueue
    private var context: JSContext?
    private var storage: [String: Any] = [:]
    private lazy var session = URLSession(configuration: {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        return c
    }(), delegate: self, delegateQueue: nil)

    static let maxResponseBytes = 2 * 1024 * 1024
    static let maxFileBytes = 1024 * 1024
    static let maxStorageBytes = 64 * 1024

    init(manifest: WidgetManifest, source: String, hooks: Hooks) {
        self.manifest = manifest
        self.source = source
        self.hooks = hooks
        self.queue = DispatchQueue(label: "phonescreen.widget.\(manifest.id)", qos: .utility)
    }

    /// Runs `refresh(ctx)`; the completion gets the returned data (JSON-compatible) or an error.
    func refresh(_ done: @escaping @Sendable (Result<Any, Failure>) -> Void) {
        call("refresh", arguments: [], done)
    }

    func action(_ name: String, _ done: @escaping @Sendable (Result<Any, Failure>) -> Void) {
        call("action", arguments: [name], done)
    }

    // MARK: - Calling into JS (queue)

    private func call(_ function: String, arguments: [Any], _ done: @escaping @Sendable (Result<Any, Failure>) -> Void) {
        queue.async { [self] in
            guard let context = loadedContext() else { return done(.failure(.script(lastError ?? "Не удалось загрузить скрипт"))) }
            guard let fn = context.objectForKeyedSubscript(function), !fn.isUndefined, fn.isObject else {
                return done(function == "refresh" ? .failure(.noRefresh) : .success(NSNull()))
            }
            var finished = false
            let finish: (Result<Any, Failure>) -> Void = { result in
                guard !finished else { return }
                finished = true
                done(result)
            }
            // Overall deadline, network included.
            queue.asyncAfter(deadline: .now() + 20) { finish(.failure(.timeout)) }

            let ctx = JSValue(object: ["settings": hooks.settings(), "lang": hooks.language], in: context)!
            lastError = nil
            let result = fn.call(withArguments: arguments + [ctx])
            if let error = lastError { return finish(.failure(.script(error))) }
            guard let result else { return finish(.failure(.script("Нет результата"))) }

            // Async functions return a Promise; plain values are fine too.
            if result.isObject, let then = result.objectForKeyedSubscript("then"), then.isObject {
                let onValue: @convention(block) (JSValue) -> Void = { value in finish(.success(Self.plain(value))) }
                let onError: @convention(block) (JSValue) -> Void = { error in
                    let message = error.objectForKeyedSubscript("message")?.toString() ?? error.toString() ?? "Ошибка"
                    finish(.failure(.script(message)))
                }
                result.invokeMethod("then", withArguments: [JSValue(object: onValue, in: context)!,
                                                           JSValue(object: onError, in: context)!])
            } else {
                finish(.success(Self.plain(result)))
            }
        }
    }

    private var lastError: String?

    private func loadedContext() -> JSContext? {
        if let context { return context }
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        context.name = manifest.id
        context.exceptionHandler = { [weak self] _, exception in
            let message = exception?.toString() ?? "Ошибка"
            let line = exception?.objectForKeyedSubscript("line")?.toInt32() ?? 0
            self?.lastError = line > 0 ? "\(message) (строка \(line))" : message
            self?.hooks.log("error: \(self?.lastError ?? message)")
        }
        // Each synchronous run of script code may take at most 2 s; waiting on fetch doesn't count.
        JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(context.jsGlobalContextRef), 2, nil, nil)
        storage = hooks.loadStorage()
        install(into: context)
        context.setObject(hooks.language, forKeyedSubscript: "__lang" as NSString)
        context.setObject(hooks.strings, forKeyedSubscript: "__strings" as NSString)
        // `format` helpers shared with scripts/widget-dev.mjs (Mac/Widgets/prelude.js, bundled as a resource).
        if let url = Bundle.main.url(forResource: "prelude", withExtension: "js"),
           let prelude = try? String(contentsOf: url, encoding: .utf8) {
            context.evaluateScript(prelude, withSourceURL: URL(string: "prelude.js"))
        }
        lastError = nil
        context.evaluateScript(source, withSourceURL: URL(string: "provider.js"))
        if lastError != nil { return nil }
        self.context = context
        return context
    }

    // MARK: - The sandbox API

    private func install(into context: JSContext) {
        let log: @convention(block) (String) -> Void = { [hooks] line in hooks.log(line) }
        context.setObject(log, forKeyedSubscript: "__log" as NSString)

        let secret: @convention(block) (String) -> Any = { [manifest, hooks] key in
            guard manifest.permissions?.secrets?.contains(where: { $0.key == key }) == true else { return NSNull() }
            return hooks.secret(key) ?? NSNull()
        }
        context.setObject(secret, forKeyedSubscript: "__secret" as NSString)

        let storageGet: @convention(block) (String) -> Any = { [weak self] key in self?.storage[key] ?? NSNull() }
        let storageSet: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            let plain = Self.plain(value)
            self.storage[key] = plain is NSNull ? nil : plain
            if let data = try? JSONSerialization.data(withJSONObject: self.storage), data.count <= Self.maxStorageBytes {
                self.hooks.saveStorage(self.storage)
            } else {
                self.storage[key] = nil
                self.hooks.log("storage: превышен лимит \(Self.maxStorageBytes / 1024) КБ, значение не сохранено")
            }
        }
        context.setObject(storageGet, forKeyedSubscript: "__storageGet" as NSString)
        context.setObject(storageSet, forKeyedSubscript: "__storageSet" as NSString)

        // Read-only files, only inside `permissions.files` (checked on the path as written and after
        // resolving symlinks, so a link can't lead outside).
        let readFile: @convention(block) (String) -> Any = { [weak self] path in
            guard let self, let url = self.fileURL(path) else { return NSNull() }
            guard let data = try? Data(contentsOf: url) else { return NSNull() }
            guard data.count <= Self.maxFileBytes else {
                self.hooks.log("files.read: \(path) больше 1 МБ")
                return NSNull()
            }
            return String(data: data, encoding: .utf8) ?? NSNull()
        }
        let fileModified: @convention(block) (String) -> Any = { [weak self] path in
            guard let url = self?.fileURL(path),
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return NSNull() }
            return date.timeIntervalSince1970
        }
        // Complete lines from a byte offset — for logs bigger than 1 MB or read incrementally.
        let readLines: @convention(block) (String, Double, Double) -> Any = { [weak self] path, offset, length in
            guard let self, let url = self.fileURL(path) else { return NSNull() }
            return Self.lines(at: url, offset: offset, length: length) ?? NSNull()
        }
        let listDir: @convention(block) (String) -> Any = { [weak self] path in
            guard let self, let url = self.fileURL(path) else { return NSNull() }
            return Self.list(url) ?? NSNull()
        }
        context.setObject(readFile, forKeyedSubscript: "__readFile" as NSString)
        context.setObject(fileModified, forKeyedSubscript: "__fileModified" as NSString)
        context.setObject(readLines, forKeyedSubscript: "__readLines" as NSString)
        context.setObject(listDir, forKeyedSubscript: "__listDir" as NSString)

        let timeout: @convention(block) (JSValue, Double) -> Void = { [weak self] fn, ms in
            self?.queue.asyncAfter(deadline: .now() + max(0, min(ms, 60_000)) / 1000) { fn.call(withArguments: []) }
        }
        context.setObject(timeout, forKeyedSubscript: "__setTimeout" as NSString)

        let fetch: @convention(block) (String, String, String, JSValue, JSValue, JSValue) -> Void = {
            [weak self] url, method, headersJSON, body, resolve, reject in
            self?.fetch(url: url, method: method, headersJSON: headersJSON, body: body.isNull || body.isUndefined ? nil : body.toString(),
                        resolve: resolve, reject: reject)
        }
        context.setObject(fetch, forKeyedSubscript: "__fetch" as NSString)

        context.evaluateScript(#"""
            "use strict";
            globalThis.console = {
              log: (...a) => __log(a.map(String).join(" ")),
              warn: (...a) => __log("warn: " + a.map(String).join(" ")),
              error: (...a) => __log("error: " + a.map(String).join(" ")),
            };
            globalThis.secrets = Object.freeze({ get: (key) => __secret(String(key)) });
            globalThis.files = Object.freeze({
              read: (path) => __readFile(String(path)),
              modified: (path) => __fileModified(String(path)),
              lines: (path, opts = {}) => __readLines(String(path), Number(opts.offset) || 0,
                Number(opts.length) || 1048576),
              list: (path) => __listDir(String(path)),
            });
            globalThis.storage = Object.freeze({
              get: (key) => __storageGet(String(key)),
              set: (key, value) => __storageSet(String(key), value),
            });
            globalThis.setTimeout = (fn, ms) => __setTimeout(fn, Number(ms) || 0);
            globalThis.sleep = (ms) => new Promise((r) => setTimeout(r, ms));
            globalThis.fetch = (url, opts = {}) => new Promise((resolve, reject) => {
              __fetch(String(url), String(opts.method || "GET"), JSON.stringify(opts.headers || {}),
                opts.body == null ? null : String(opts.body),
                (status, headersJSON, text) => {
                  const headers = JSON.parse(headersJSON);
                  resolve({
                    status, ok: status >= 200 && status < 300,
                    headers: { get: (k) => headers[String(k).toLowerCase()] ?? null },
                    text: async () => text,
                    json: async () => JSON.parse(text),
                  });
                },
                (message) => reject(new Error(message)));
            });
            """#)
    }

    private func fileURL(_ path: String) -> URL? {
        guard manifest.allowsFile(path) else {
            hooks.log("files: \(path) не разрешён — добавьте путь в permissions.files")
            return nil
        }
        let absolute = URL(fileURLWithPath: hooks.home).appendingPathComponent(String(path.dropFirst(2)))
        let resolved = absolute.resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: hooks.home).resolvingSymlinksInPath().path
        guard manifest.allowsResolved(resolved.path, home: home) else {
            hooks.log("files: \(path) ведёт за пределы разрешённых путей")
            return nil
        }
        return resolved
    }

    /// `files.lines`: `{ lines, next, size }` — whole lines starting at `offset` (bytes), at most `length` bytes
    /// (≤ 1 MB). `next` is the offset after the last complete line: pass it back to continue. A line longer than
    /// the limit is skipped in pieces (they won't parse, so scripts ignore them).
    static func lines(at url: URL, offset: Double, length: Double) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = min(UInt64(max(0, offset)), size)
        let limit = Int(min(max(1, length), Double(maxFileBytes)))
        try? handle.seek(toOffset: start)
        let data = Data((try? handle.read(upToCount: limit)) ?? Data())
        var end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        if end == 0, data.count == limit { end = data.count } // one giant line: step over this piece
        let text = String(decoding: data.prefix(end), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if end == data.count, data.last != UInt8(ascii: "\n") { lines = [] }
        return ["lines": lines, "next": Double(start) + Double(end), "size": Double(size)]
    }

    /// `files.list`: the folder's entries (hidden ones skipped, at most 2000) as
    /// `{ name, dir, size, modified }`, or `nil` if it isn't a readable folder.
    static func list(_ url: URL) -> [[String: Any]]? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return nil }
        return items.prefix(2000).map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            return ["name": item.lastPathComponent,
                    "dir": values?.isDirectory ?? false,
                    "size": Double(values?.fileSize ?? 0),
                    "modified": values?.contentModificationDate?.timeIntervalSince1970 ?? 0]
        }
    }

    private func fetch(url: String, method: String, headersJSON: String, body: String?, resolve: JSValue, reject: JSValue) {
        func fail(_ message: String) { queue.async { reject.call(withArguments: [message]) } }
        guard let target = URL(string: url), manifest.allows(target) else {
            return fail("fetch: \(url) не разрешён — добавьте хост в permissions.network (только HTTPS)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method.uppercased()
        if let data = headersJSON.data(using: .utf8),
           let headers = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in headers { request.setValue("\(v)", forHTTPHeaderField: k) }
        }
        request.httpBody = body?.data(using: .utf8)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error { return fail("fetch: \(error.localizedDescription)") }
            guard let http = response as? HTTPURLResponse else { return fail("fetch: нет ответа") }
            guard (data?.count ?? 0) <= Self.maxResponseBytes else { return fail("fetch: ответ больше 2 МБ") }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
            let headersJSON = (try? JSONSerialization.data(withJSONObject: headers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            self.queue.async { resolve.call(withArguments: [http.statusCode, headersJSON, text]) }
        }.resume()
    }

    /// Redirects must stay inside the allow-list too.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(manifest.allows) == true ? request : nil)
    }

    /// JS value → JSON-compatible Foundation value (dropping functions, cycles, dates as ISO strings).
    static func plain(_ value: JSValue) -> Any {
        guard let object = value.toObject() else { return NSNull() }
        if JSONSerialization.isValidJSONObject(object) { return object }
        if let data = try? JSONSerialization.data(withJSONObject: [object]),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = arr.first { return first }
        if value.isString { return value.toString() ?? "" }
        if value.isNumber { return value.toNumber() ?? 0 }
        if value.isBoolean { return value.toBool() }
        return NSNull()
    }
}
