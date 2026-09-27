import Foundation
import Testing
@testable import PhoneScreenKit

@Suite struct ThemeTests {
    @Test func builtinThemesAreValid() throws {
        for theme in Theme.builtin { try theme.validate() }
        #expect(Set(Theme.builtin.map(\.id)).count == Theme.builtin.count)
    }

    @Test func hexColours() {
        #expect(RGBA(hex: "#FF8000") == RGBA(r: 1, g: 128.0 / 255, b: 0, a: 1))
        #expect(RGBA(hex: "#00000080")?.a == 128.0 / 255)
        #expect(RGBA(hex: "#FFF") == nil)
        #expect(RGBA(hex: "red") == nil)
        #expect(RGBA(hex: "#GG0000") == nil)
    }

    @Test func invalidThemeIsRejected() {
        var theme = Theme.glass
        theme.id = "com.me.glass"
        theme.colors.accent = "blue"
        #expect(throws: Theme.Invalid.self) { try theme.validate() }
        theme.colors.accent = "#0000FF"
        theme.radius = 100
        #expect(throws: Theme.Invalid.self) { try theme.validate() }
        theme.radius = 20
        theme.background.colors = []
        #expect(throws: Theme.Invalid.self) { try theme.validate() }
    }

    @Test func contrast() {
        let white = RGBA(r: 1, g: 1, b: 1), black = RGBA(r: 0, g: 0, b: 0)
        #expect(abs(white.contrast(with: black) - 21) < 0.01)
        #expect(abs(white.contrast(with: white) - 1) < 0.01)
        for theme in Theme.builtin { #expect(theme.contrastWarnings().isEmpty, "\(theme.name)") }
        var unreadable = Theme.light
        unreadable.colors.text = "#DDDDDD"
        #expect(unreadable.contrastWarnings().count == 1)
    }

    @Test func themeMessageRoundTrip() throws {
        let messages = try FrameParser().messagesFrom(Framing.encode(.theme(.ascii)))
        #expect(messages == [.theme(.ascii)])
    }

    @Test func catalogWithoutThemesStillDecodes() throws {
        let json = #"{"widgets": []}"#
        let catalog = try JSONDecoder().decode(WidgetCatalog.self, from: Data(json.utf8))
        #expect(catalog.themes == nil)
    }

    @Test func themeFileDecodes() throws {
        let json = #"""
        {"id": "com.author.paper", "name": "Бумага", "version": "1.0.0", "author": "author",
         "style": "flat", "appearance": "light", "font": "serif", "radius": 12,
         "background": {"colors": ["#FAF7F0"]},
         "colors": {"text": "#222222", "secondary": "#777777", "accent": "#C0392B"}}
        """#
        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
        try theme.validate()
        #expect(theme.colors.palette == nil)
    }
}

private extension FrameParser {
    func messagesFrom(_ data: Data) throws -> [Message] {
        var parser = self
        return try parser.messages(from: data)
    }
}
