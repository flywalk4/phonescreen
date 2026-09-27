import Testing
@testable import PhoneScreenKit

@Suite struct KeyMappingTests {
    typealias K = KeyMapping
    func map(_ code: Int64, cmd: Bool = false, opt: Bool = false, ctrl: Bool = false, _ text: String = "") -> K.Action {
        K.action(keyCode: code, command: cmd, option: opt, control: ctrl, text: text)
    }

    @Test func lettersFollowTheMacLayout() {
        #expect(map(0, "ф") == .text("ф"))       // Russian layout: the A key types «ф»
        #expect(map(1, "Ы") == .text("Ы"))       // shift is already applied by the layout
        #expect(map(49, " ") == .text(" "))
    }

    @Test func editingKeys() {
        #expect(map(K.Code.returnKey) == .special(.enter))
        #expect(map(K.Code.delete) == .special(.backspace))
        #expect(map(K.Code.delete, opt: true) == .special(.deleteWordBackward))
        #expect(map(K.Code.delete, cmd: true) == .special(.deleteLineBackward))
        #expect(map(K.Code.left) == .special(.left))
        #expect(map(K.Code.left, cmd: true) == .special(.lineStart))
        #expect(map(K.Code.escape) == .special(.escape))
    }

    @Test func commandShortcuts() {
        #expect(map(K.Code.v, cmd: true, "v") == .pasteMacClipboard)
        #expect(map(K.Code.a, cmd: true, "a") == .special(.selectAll))
        #expect(map(48, cmd: true) == .passThrough)   // ⌘Tab stays with the Mac
        #expect(map(49, cmd: true, " ") == .passThrough) // ⌘Space (Spotlight)
        #expect(map(8, ctrl: true, "c") == .passThrough)
    }

    @Test func nonPrintableGoesToTheMac() {
        #expect(map(122, "\u{F704}") == .passThrough) // F1
        #expect(map(999, "") == .passThrough)
    }
}
