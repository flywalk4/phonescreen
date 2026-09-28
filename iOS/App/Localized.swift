import Foundation

/// The phone speaks the Mac's language, not necessarily the iPhone's. SwiftUI finds `Text("…")` literals by itself
/// (the pager sets `\.locale`); `L` is for texts built in code, and `Date.text` for dates.
enum Lang {
    /// "en", "ru"…: set by PhoneModel when the Mac says which language the product is in.
    static var code = "en" {
        didSet {
            bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
            locale = Locale(identifier: code)
        }
    }
    fileprivate static var bundle = Bundle.main
    static var locale = Locale(identifier: "en")
}

/// `key` (the English text, as in Localizable.xcstrings) in the phone's language; `%lld`/`%@` filled from `args`,
/// with plural forms where the catalog has them: `L("%lld apps", 3)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Lang.bundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Lang.locale, arguments: args)
}

extension Date {
    /// `formatted(date:time:)` in the phone's language.
    func text(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: Lang.locale))
    }

    /// `formatted(.dateTime…)` in the phone's language.
    func text(_ style: Date.FormatStyle) -> String {
        formatted(style.locale(Lang.locale))
    }

    /// "07", "19": the hour on a 24-hour clock, as the widgets show time (a desk clock, in any language).
    var hour24: String {
        String(format: "%02d", Calendar.current.component(.hour, from: self))
    }

    /// "5 minutes ago", "yesterday"… in the phone's language.
    var relativeText: String {
        formatted(Date.RelativeFormatStyle(presentation: .named, locale: Lang.locale))
    }
}
