import Foundation

/// Decides what a Mac key press does while the pointer is on the phone and a phone text field has focus.
/// Pure, so the rules are testable; the Mac event tap feeds it and acts on the result.
public enum KeyMapping {
    public enum Action: Equatable, Sendable {
        /// Type this text on the phone.
        case text(String)
        /// An editing key on the phone.
        case special(SpecialKey)
        /// ⌘V: paste the Mac clipboard into the phone field.
        case pasteMacClipboard
        /// Not for the phone: let the Mac handle it (⌘Tab, ⌘Space, other shortcuts…).
        case passThrough
    }

    /// macOS virtual key codes (Carbon `kVK_*`).
    public enum Code {
        public static let returnKey: Int64 = 36, keypadEnter: Int64 = 76, tab: Int64 = 48, escape: Int64 = 53
        public static let delete: Int64 = 51, forwardDelete: Int64 = 117
        public static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
        public static let home: Int64 = 115, end: Int64 = 119
        public static let a: Int64 = 0, v: Int64 = 9
    }

    /// - Parameter text: what the key types with the current Mac layout and modifiers (may be empty).
    public static func action(keyCode: Int64, command: Bool, option: Bool, control: Bool, text: String) -> Action {
        if command {
            switch keyCode {
            case Code.v: return .pasteMacClipboard
            case Code.a: return .special(.selectAll)
            case Code.delete: return .special(.deleteLineBackward)
            case Code.left: return .special(.lineStart)
            case Code.right: return .special(.lineEnd)
            default: return .passThrough // keep Mac shortcuts working
            }
        }
        if control { return .passThrough }

        switch keyCode {
        case Code.returnKey, Code.keypadEnter: return .special(.enter)
        case Code.tab: return .special(.tab)
        case Code.escape: return .special(.escape)
        case Code.delete: return .special(option ? .deleteWordBackward : .backspace)
        case Code.forwardDelete: return .special(.forwardDelete)
        case Code.left: return .special(.left)
        case Code.right: return .special(.right)
        case Code.up: return .special(.up)
        case Code.down: return .special(.down)
        case Code.home: return .special(.lineStart)
        case Code.end: return .special(.lineEnd)
        default: break
        }
        // Printable text only; function keys and the like produce control / private-use characters.
        let printable = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
        return printable.isEmpty ? .passThrough : .text(String(String.UnicodeScalarView(printable)))
    }
}
