import Foundation
import Testing
@testable import PhoneScreenKit

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
        m.permissions = .init(files: ["~/.claude/phonescreen/"]); m.refresh = 1
        #expect(m.refreshInterval == 5) // local-only widgets may poll faster
    }

    @Test func fileAccessIsLimitedToDeclaredPaths() throws {
        var m = base
        m.permissions = .init(files: ["~/.claude/phonescreen/", "~/notes.txt"])
        try m.validate()
        #expect(m.allowsFile("~/.claude/phonescreen/status.json"))
        #expect(m.allowsFile("~/notes.txt"))
        #expect(!m.allowsFile("~/.claude/settings.json"))
        #expect(!m.allowsFile("~/.claude/phonescreen/../settings.json"))
        #expect(!m.allowsFile("/etc/passwd"))
        #expect(!m.allowsFile("~/notes.txt.bak"))
        #expect(m.allowsResolved("/Users/v/.claude/phonescreen/state.json", home: "/Users/v"))
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
        let node = try WidgetTemplate.resolve(json(#"""
            {"type": "layers", "align": "bottomLeading", "children": [
                {"type": "scene", "kind": "{{k}}", "tints": ["#FF0000", "{{c}}"], "speed": 9},
                {"type": "text", "text": "12:40"}
            ]}
            """#), data: json(#"{"k": "stars", "c": "#00FF00"}"#))
        #expect(node == .layers(align: "bottomLeading", children: [
            .scene(kind: "stars", colors: nil, tints: ["#FF0000", "#00FF00"], speed: 5),
            .text("12:40", style: nil, color: nil, lines: nil, align: nil),
        ]))
    }

    @Test func gridUpToTwelveColumns() throws {
        let node = try WidgetTemplate.resolve(json(#"{"type": "grid", "columns": 8, "children": []}"#), data: json("{}"))
        #expect(node == .grid(columns: 8, spacing: nil, children: []))
        let capped = try WidgetTemplate.resolve(json(#"{"type": "grid", "columns": 40, "children": []}"#), data: json("{}"))
        #expect(capped == .grid(columns: 12, spacing: nil, children: []))
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
