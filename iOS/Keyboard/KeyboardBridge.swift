import PhoneScreenKit
import UIKit

/// Types Mac keystrokes into whatever text field or text view has focus on the phone, through UIKit's
/// `UITextInput` — so it works for any SwiftUI `TextField` / `TextEditor` and keeps the caret and selection.
///
/// While the Mac is typing, the on-screen keyboard is hidden (an empty input view), like with a hardware keyboard.
@MainActor
final class KeyboardBridge {
    /// Focus changed: the Mac needs to know whether keystrokes should come here.
    var onFocusChange: ((Bool) -> Void)?
    /// Whether the Mac pointer is on the phone (then the software keyboard stays hidden).
    var macInputActive = false {
        didSet { if macInputActive != oldValue { updateSoftwareKeyboard() } }
    }

    private(set) var hasFocus = false
    private weak var suppressed: UIResponder?

    init() {
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged(true) }
            }
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged(false) }
            }
        }
    }

    func insert(_ text: String) {
        guard let input = Self.firstResponder() as? (UIResponder & UITextInput) else { return }
        input.insertText(text)
    }

    func press(_ key: SpecialKey) {
        guard let input = Self.firstResponder() as? (UIResponder & UITextInput) else { return }
        switch key {
        case .enter:
            input.insertText("\n") // a UITextField turns this into "return" (SwiftUI onSubmit)
        case .tab:
            if input is UITextView { input.insertText("\t") }
        case .escape:
            input.resignFirstResponder()
        case .backspace:
            input.deleteBackward()
        case .forwardDelete:
            if let range = input.selectedTextRange, range.isEmpty,
               let next = input.position(from: range.start, offset: 1),
               let r = input.textRange(from: range.start, to: next) {
                input.replace(r, withText: "")
            } else {
                input.deleteBackward()
            }
        case .deleteWordBackward:
            deleteBackward(in: input, to: .word)
        case .deleteLineBackward:
            deleteBackward(in: input, to: .line)
        case .left, .right:
            moveCaret(in: input, direction: key == .left ? .left : .right)
        case .up, .down:
            moveCaret(in: input, direction: key == .up ? .up : .down)
        case .lineStart, .lineEnd:
            guard let caret = input.selectedTextRange?.start,
                  let target = input.tokenizer.position(from: caret, toBoundary: .line,
                                                        inDirection: .storage(key == .lineStart ? .backward : .forward))
            else { return }
            input.selectedTextRange = input.textRange(from: target, to: target)
        case .selectAll:
            input.selectAll(nil)
        }
    }

    /// Clicking outside any field with the Mac pointer ends editing, like tapping away.
    func endEditing() {
        Self.firstResponder()?.resignFirstResponder()
    }

    // MARK: - Internals

    private func focusChanged(_: Bool) {
        // End-then-begin fires when moving between fields; report the settled state on the next turn.
        DispatchQueue.main.async { [self] in
            let now = Self.firstResponder() is UITextInput
            if now != hasFocus {
                hasFocus = now
                onFocusChange?(now)
            }
            updateSoftwareKeyboard()
        }
    }

    private func updateSoftwareKeyboard() {
        let responder = Self.firstResponder()
        if macInputActive, let responder, responder !== suppressed {
            // An empty input view hides the on-screen keyboard while the Mac keyboard types.
            setInputView(UIView(frame: .zero), on: responder)
            suppressed = responder
        } else if !macInputActive, let suppressed {
            setInputView(nil, on: suppressed)
            self.suppressed = nil
        }
    }

    private func setInputView(_ view: UIView?, on responder: UIResponder) {
        if let field = responder as? UITextField { field.inputView = view; field.inputAccessoryView = view == nil ? nil : UIView() }
        if let text = responder as? UITextView { text.inputView = view; text.inputAccessoryView = view == nil ? nil : UIView() }
        responder.reloadInputViews()
    }

    private func moveCaret(in input: UITextInput, direction: UITextLayoutDirection) {
        guard let range = input.selectedTextRange else { return }
        // With a selection, left/right collapse it to its edge (like on the Mac).
        if !range.isEmpty, direction == .left || direction == .right {
            let edge = direction == .left ? range.start : range.end
            input.selectedTextRange = input.textRange(from: edge, to: edge)
            return
        }
        guard let target = input.position(from: range.start, in: direction, offset: 1) else { return }
        input.selectedTextRange = input.textRange(from: target, to: target)
    }

    private func deleteBackward(in input: UITextInput, to granularity: UITextGranularity) {
        guard let range = input.selectedTextRange else { return }
        guard range.isEmpty else { return input.replace(range, withText: "") }
        // Skip whitespace first, then to the start of the word / line — the Mac's ⌥⌫ / ⌘⌫.
        var start = range.start
        while let prev = input.position(from: start, offset: -1),
              let r = input.textRange(from: prev, to: start),
              let ch = input.text(in: r), ch.trimmingCharacters(in: .whitespaces).isEmpty, !ch.isEmpty, ch != "\n" {
            start = prev
        }
        let boundary = input.tokenizer.position(from: start, toBoundary: granularity, inDirection: .storage(.backward)) ?? input.beginningOfDocument
        if let r = input.textRange(from: boundary, to: range.start) { input.replace(r, withText: "") }
    }

    // MARK: - First responder lookup

    private static weak var found: UIResponder?

    static func firstResponder() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.psCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc fileprivate func psCaptureFirstResponder() {
        MainActor.assumeIsolated { KeyboardBridge.capture(self) }
    }
}
