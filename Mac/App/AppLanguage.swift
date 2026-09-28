import Foundation
import QwoviKit

/// The language of the whole product: the Mac app, the phone and every widget that has strings for it.
/// English by default; "system" follows macOS's preferred languages.
enum AppLanguage {
    /// Languages the apps are translated into (widgets may have more or fewer; they fall back to English).
    static let supported: [(code: String, name: String)] = [("en", "English"), ("ru", "Русский")]

    private static let key = "language"

    /// "system", or a code from `supported`.
    static var choice: String {
        get { UserDefaults.standard.string(forKey: key) ?? "en" }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            // The Mac app's own UI: macOS reads AppleLanguages at launch.
            if newValue == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Before anything is shown: on first launch pin the Mac's own UI to English (macOS reads AppleLanguages when the
    /// app first looks up a text), and let QwoviKit's texts go through this app's Localizable.xcstrings.
    static func bootstrap() {
        if UserDefaults.standard.string(forKey: key) == nil { choice = "en" }
        Localization.translate = { String(localized: String.LocalizationValue($0)) }
    }

    /// The code in effect: the chosen one, or the first preferred system language (English when unsupported by the app;
    /// widgets still get the system language and fall back on their own).
    static var current: String {
        let chosen = choice
        if chosen != "system" { return chosen }
        return WidgetStrings.code(Locale.preferredLanguages.first ?? "en")
    }
}
