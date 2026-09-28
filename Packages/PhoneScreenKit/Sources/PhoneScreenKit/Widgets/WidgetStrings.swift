import Foundation

/// A widget's `strings.json`: `{"en": {"key": "text", …}, "ru": {…}}`. A value is a string, or plural forms
/// `{"one": "{n} day", "other": "{n} days"}` (CLDR categories: zero, one, two, few, many, other).
///
/// Keys the app itself reads (all optional): `manifest.name`, `manifest.description`, `settings.<key>.title`,
/// `settings.<key>.hint`, `settings.<key>.options.<value>`, `secrets.<key>.title`. Everything else is the widget's
/// own: `t("key")` in provider.js, `{{t.key}}` in view.json.
public enum WidgetStrings {
    /// The language a widget shows for `wanted`: that one if it has it, else English, else its first language.
    /// A widget without strings.json just gets `wanted` (its texts are whatever the author wrote).
    public static func language(_ wanted: String, available: [String]) -> String {
        if available.isEmpty || available.contains(wanted) { return wanted }
        if available.contains("en") { return "en" }
        return available.sorted().first ?? wanted
    }

    /// The table for `wanted`: its language's strings over the fallback language's (English, else the first),
    /// so a half-translated widget still shows every text.
    public static func table(_ all: [String: Any], wanted: String) -> (language: String, table: [String: Any]) {
        let langs = all.keys.sorted()
        let lang = language(wanted, available: langs)
        let fallback = langs.contains("en") ? "en" : langs.first
        var table = fallback.flatMap { all[$0] as? [String: Any] } ?? [:]
        for (key, value) in all[lang] as? [String: Any] ?? [:] { table[key] = value }
        return (lang, table)
    }

    /// Two-letter code of the first preferred language ("ru", "en", "zh"…).
    public static func code(_ identifier: String) -> String {
        String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en").lowercased()
    }
}

extension WidgetManifest {
    /// The manifest as shown to the user in a language: name, description, setting titles, hints, choice option
    /// titles and secret titles from the strings table where it has them.
    public func localized(_ table: [String: Any]) -> WidgetManifest {
        func text(_ key: String) -> String? {
            (table[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var m = self
        m.name = text("manifest.name") ?? name
        m.description = text("manifest.description") ?? description
        m.settings = settings?.map { s in
            var s = s
            s.title = text("settings.\(s.key).title") ?? s.title
            s.hint = text("settings.\(s.key).hint") ?? s.hint
            s.options = s.options?.map { o in
                WidgetManifest.Setting.Option(value: o.value, title: text("settings.\(s.key).options.\(o.value)") ?? o.title)
            }
            return s
        }
        m.permissions?.secrets = permissions?.secrets?.map { secret in
            WidgetManifest.Secret(key: secret.key, title: text("secrets.\(secret.key).title") ?? secret.title)
        }
        return m
    }
}
