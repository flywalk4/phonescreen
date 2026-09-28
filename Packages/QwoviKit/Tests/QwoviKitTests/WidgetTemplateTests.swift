import Foundation
import Testing
@testable import QwoviKit

@Suite struct WidgetTemplateTests {
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }

    @Test func bindingsKeepTypesOrInterpolate() throws {
        let data = json(#"{"rate": 92.5, "code": "USD", "ratio": 0.4}"#)
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "vstack", "children": [
                {"type": "text", "text": "1 {{code}} = {{rate}} ₽", "style": "title"},
                {"type": "gauge", "value": "{{ratio}}", "label": "{{code}}"}
            ]}
            """#), data: data)
        #expect(node == .vstack(spacing: nil, align: nil, children: [
            .text("1 USD = 92.5 ₽", style: "title", color: nil, lines: nil, align: nil),
            .gauge(value: 0.4, label: "USD", color: nil),
        ]))
    }

    @Test func listsRepeatTheTemplateWithItemAndIndex() throws {
        let data = json(#"{"rows": [{"n": "EUR", "v": 100}, {"n": "CNY", "v": 12.7}]}"#)
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "list", "items": "{{rows}}", "template":
                {"type": "text", "text": "{{index}}. {{item.n}}: {{item.v}}"}}
            """#), data: data)
        guard case .vstack(_, _, let rows) = node else { Issue.record("not a stack"); return }
        #expect(rows == [.text("0. EUR: 100", style: nil, color: nil, lines: nil, align: nil),
                         .text("1. CNY: 12.7", style: nil, color: nil, lines: nil, align: nil)])
    }

    @Test func ifDropsNodesWithFalsyValues() throws {
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "vstack", "children": [
                {"type": "text", "text": "shown", "if": "{{ok}}"},
                {"type": "text", "text": "hidden", "if": "{{missing}}"},
                {"type": "text", "text": "hidden too", "if": "{{empty}}"}
            ]}
            """#), data: json(#"{"ok": true, "empty": []}"#))
        #expect(node == .vstack(spacing: nil, align: nil, children: [.text("shown", style: nil, color: nil, lines: nil, align: nil)]))
    }

    @Test func pathsIntoArraysAndMissingValues() {
        let data = json(#"{"a": {"b": [10, {"c": "deep"}]}}"#)
        #expect(WidgetTemplate.lookup("a.b.1.c", ["$": data]) as? String == "deep")
        #expect(WidgetTemplate.lookup("a.x", ["$": data]) == nil)
        #expect(WidgetTemplate.value("x{{a.nope}}y", ["$": data]) as? String == "xy")
    }

    @Test func unknownTypesAreSkippedAndGaugesClamped() throws {
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "hstack", "children": [{"type": "hologram"}, {"type": "progress", "value": 7}]}
            """#), data: json("{}"))
        #expect(node == .hstack(spacing: nil, align: nil, children: [.progress(value: 1, color: nil)]))
    }

    @Test func runawayTemplatesAreStopped() {
        let many = (0..<600).map { _ in #"{"type": "spacer"}"# }.joined(separator: ",")
        #expect(throws: WidgetTemplate.Error.self) {
            try WidgetTemplate.resolve(json(#"{"type": "vstack", "children": [\#(many)]}"#), data: json("{}"))
        }
    }

    @Test func stateRoundTripsAndFallsBackBetweenSizes() throws {
        let state = CustomWidgetState(id: "a.b", name: "Курсы", symbol: "dollarsign",
                                      views: [.full: .text("big", style: nil, color: nil, lines: nil, align: nil)],
                                      error: nil, updated: Date(timeIntervalSince1970: 1_700_000_000))
        let m = Message.customWidget(state)
        #expect(try MessageCoder.decoder.decode(Message.self, from: MessageCoder.encoder.encode(m)) == m)
        #expect(state.view(for: .small) == state.views[.full])
    }
}

@Suite struct WidgetManifestTests {
    let base = WidgetManifest(id: "com.example.rates", name: "Курсы", version: "1.0.0", author: "me",
                              permissions: .init(network: ["open.er-api.com"]))

    @Test func validManifestPasses() throws { try base.validate() }

    @Test func badFieldsAreRejected() {
        var m = base; m.id = "Rates"
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
        m = base; m.version = "1.0"
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
        m = base; m.permissions = .init(network: ["https://open.er-api.com/v6"])
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
        m = base; m.permissions = .init(network: ["*.example.com"])
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
    }

    @Test func networkAllowListIsHTTPSAndHostBound() {
        #expect(base.allows(URL(string: "https://open.er-api.com/v6/latest/USD")!))
        #expect(base.allows(URL(string: "https://eu.open.er-api.com/x")!))       // subdomain
        #expect(!base.allows(URL(string: "http://open.er-api.com/v6")!))         // not HTTPS
        #expect(!base.allows(URL(string: "https://open.er-api.com.evil.io/")!))  // suffix trick
        #expect(!base.allows(URL(string: "https://evil-open.er-api.com.io/")!))
        #expect(!base.allows(URL(string: "https://example.org/")!))
    }

    @Test func refreshIntervalHasAFloor() {
        var m = base; m.refresh = 5
        #expect(m.refreshInterval == 30)
        m.refresh = nil
        #expect(m.refreshInterval == 300)
        m.permissions = .init(files: ["~/.claude/qwovi/"]); m.refresh = 1
        #expect(m.refreshInterval == 5) // local-only widgets may poll faster
    }

    @Test func typedSettingsDecode() throws {
        let json = #"""
        {"id": "com.example.w", "name": "W", "version": "1.0.0", "author": "me", "settings": [
          {"key": "style", "title": "Стиль", "type": "choice", "options": ["a", {"value": "b", "title": "Бэ"}], "default": "a"},
          {"key": "clock", "title": "Часы", "type": "toggle", "default": "true"},
          {"key": "speed", "title": "Скорость", "type": "number", "min": 0.2, "max": 3, "step": 0.1},
          {"key": "city", "title": "Город"}
        ]}
        """#
        let m = try JSONDecoder().decode(WidgetManifest.self, from: Data(json.utf8))
        try m.validate()
        let s = try #require(m.settings)
        #expect(s[0].options == [.init(value: "a"), .init(value: "b", title: "Бэ")])
        #expect(s[0].options?[1].label == "Бэ")
        #expect(s[1].kind == .toggle && s[2].max == 3 && s[3].kind == .text)
        #expect(WidgetManifest.Setting.isOn("yes") && WidgetManifest.Setting.isOn("true") && !WidgetManifest.Setting.isOn("no"))
        var bad = m; bad.settings = [.init(key: "x", title: "X", type: .choice)]
        #expect(throws: WidgetManifest.Invalid.self) { try bad.validate() }
    }

    @Test func stringsPickLanguageAndLocalizeManifest() throws {
        let all: [String: Any] = [
            "ru": ["manifest.name": "Курсы", "settings.target.title": "Валюта", "settings.target.options.RUB": "Рубль", "hello": "Привет"],
            "en": ["manifest.name": "Rates", "settings.target.title": "Currency", "hello": "Hello", "only.en": "x"],
        ]
        #expect(WidgetStrings.language("de", available: ["ru", "en"]) == "en")
        #expect(WidgetStrings.language("ru", available: ["ru", "en"]) == "ru")
        #expect(WidgetStrings.language("fr", available: ["ru"]) == "ru")
        #expect(WidgetStrings.language("fr", available: []) == "fr")
        let (lang, table) = WidgetStrings.table(all, wanted: "ru")
        #expect(lang == "ru")
        #expect(table["hello"] as? String == "Привет")
        #expect(table["only.en"] as? String == "x") // gaps fall back to English
        var m = base
        m.settings = [.init(key: "target", title: "Target", type: .choice, options: [.init(value: "RUB"), .init(value: "USD")])]
        let local = m.localized(table)
        #expect(local.name == "Курсы")
        #expect(local.settings?[0].title == "Валюта")
        #expect(local.settings?[0].options?.map(\.label) == ["Рубль", "USD"])
        #expect(WidgetStrings.code("en-GB") == "en" && WidgetStrings.code("zh_Hans_CN") == "zh")
    }

    @Test func fileAccessIsLimitedToDeclaredPaths() throws {
        var m = base
        m.permissions = .init(files: ["~/.claude/qwovi/", "~/notes.txt"])
        try m.validate()
        #expect(m.allowsFile("~/.claude/qwovi/status.json"))
        #expect(m.allowsFile("~/notes.txt"))
        #expect(!m.allowsFile("~/.claude/settings.json"))
        #expect(!m.allowsFile("~/.claude/qwovi/../settings.json"))
        #expect(!m.allowsFile("/etc/passwd"))
        #expect(!m.allowsFile("~/notes.txt.bak"))
        #expect(m.allowsResolved("/Users/v/.claude/qwovi/state.json", home: "/Users/v"))
        #expect(!m.allowsResolved("/Users/v/.ssh/id_ed25519", home: "/Users/v")) // a symlink pointing out is refused
        m.permissions = .init(files: ["/etc/"])
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
        m.permissions = .init(files: ["~/../x/"])
        #expect(throws: WidgetManifest.Invalid.self) { try m.validate() }
    }

    @Test func spriteFramesAndPalette() throws {
        let node = try WidgetTemplate.resolve(
            try JSONSerialization.jsonObject(with: Data(##"{"type": "sprite", "frames": "{{f}}", "palette": {"x": "#DA7756"}, "fps": 4}"##.utf8)),
            data: try JSONSerialization.jsonObject(with: Data(#"{"f": [[".x.", "xxx"], ["x.x", "xxx"]]}"#.utf8)))
        #expect(node == .sprite(frames: [[".x.", "xxx"], ["x.x", "xxx"]], palette: ["x": "#DA7756"], fps: 4))
    }
}

@Suite struct WidgetTemplateStylingTests {
    func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }

    @Test func textFontAndChartStyle() throws {
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "vstack", "children": [
                {"type": "text", "text": "{{n}}", "size": 48, "weight": "bold", "design": "rounded"},
                {"type": "text", "text": "plain"},
                {"type": "chart", "values": "{{v}}", "style": "area", "height": 80}
            ]}
            """#), data: json(#"{"n": 42, "v": [1, 2, 3]}"#))
        #expect(node == .vstack(spacing: nil, align: nil, children: [
            .text("42", style: nil, color: nil, lines: nil, align: nil, font: WidgetFont(size: 48, weight: "bold", design: "rounded")),
            .text("plain", style: nil, color: nil, lines: nil, align: nil),
            .chart(values: [1, 2, 3], color: nil, style: "area", height: 80),
        ]))
    }

    @Test func actionsTakeBindings() throws {
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "list", "items": "{{cells}}", "columns": 3, "template":
                {"type": "box", "action": "tap:{{index}}", "children": [{"type": "text", "text": "{{item}}"}]}}
            """#), data: json(#"{"cells": ["X", "O"]}"#))
        guard case .grid(3, _, let cells) = node, cells.count == 2,
              case .box(_, _, _, _, _, _, _, let action, _, _) = cells[1] else { Issue.record("not a grid of boxes"); return }
        #expect(action == "tap:1")
    }

    @Test func layersAndScene() throws {
        let node = try WidgetTemplate.resolve(json(##"""
            {"type": "layers", "align": "bottomLeading", "children": [
                {"type": "scene", "kind": "{{k}}", "tints": ["#FF0000", "{{c}}"], "speed": 9},
                {"type": "text", "text": "12:40"}
            ]}
            """##), data: json(##"{"k": "stars", "c": "#00FF00"}"##))
        let scene: WidgetNode = .scene(kind: "stars", colors: nil, tints: ["#FF0000", "#00FF00"], speed: 5)
        let text: WidgetNode = .text("12:40", style: nil, color: nil, lines: nil, align: nil)
        let expected: WidgetNode = .layers(align: "bottomLeading", children: [scene, text])
        #expect(node == expected)
    }

    @Test func gridUpToSixteenColumns() throws {
        let node = try WidgetTemplate.resolve(json(#"{"type": "grid", "columns": 8, "children": []}"#), data: json("{}"))
        #expect(node == .grid(columns: 8, spacing: nil, children: []))
        let capped = try WidgetTemplate.resolve(json(#"{"type": "grid", "columns": 40, "children": []}"#), data: json("{}"))
        #expect(capped == .grid(columns: 16, spacing: nil, children: []))
    }

    @Test func boxAndGrid() throws {
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "box", "padding": 10, "background": "green", "opacity": 0.2, "children": [
                {"type": "list", "items": "{{xs}}", "columns": 2, "template": {"type": "text", "text": "{{item}}"}}
            ]}
            """#), data: json(#"{"xs": ["a", "b", "c"]}"#))
        let cell = { (s: String) in WidgetNode.text(s, style: nil, color: nil, lines: nil, align: nil) }
        #expect(node == .box(spacing: nil, align: nil, padding: 10, background: "green", opacity: 0.2, radius: nil, fit: nil,
                             children: [.grid(columns: 2, spacing: nil, children: [cell("a"), cell("b"), cell("c")])]))
    }
}
