import CoreGraphics
import Foundation
import Testing
@testable import QwoviKit

@Suite struct ArrangementTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let phone = CGSize(width: 100, height: 200)

    @Test func rectOnEachEdge() {
        typealias G = ArrangementGeometry
        #expect(G.phoneRect(display: laptop, edge: .right, offset: 300, size: phone) == CGRect(x: 1512, y: 300, width: 100, height: 200))
        #expect(G.phoneRect(display: laptop, edge: .left, offset: 0, size: phone) == CGRect(x: -100, y: 0, width: 100, height: 200))
        #expect(G.phoneRect(display: laptop, edge: .bottom, offset: 10, size: phone) == CGRect(x: 10, y: 982, width: 100, height: 200))
        #expect(G.phoneRect(display: laptop, edge: .top, offset: 10, size: phone) == CGRect(x: 10, y: -200, width: 100, height: 200))
    }

    @Test func offsetKeepsMinimumOverlap() {
        let r = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: 5000, size: phone)
        #expect(Double(r.minY) == Double(laptop.maxY) - ArrangementGeometry.minOverlap)
        let l = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: -5000, size: phone)
        #expect(Double(l.maxY) == ArrangementGeometry.minOverlap)
    }

    @Test func snapsToNearestEdge() throws {
        let dragged = CGRect(x: 1530, y: 400, width: 100, height: 200)
        let snap = try #require(ArrangementGeometry.snap(dragged, displays: [laptop]))
        #expect(snap.edge == .right)
        #expect(snap.offset == 400)
        #expect(snap.rect.minX == laptop.maxX)
    }

    @Test func snapSkipsEdgesBlockedByAnotherDisplay() throws {
        let monitor = CGRect(x: 1512, y: -500, width: 2560, height: 1440)
        // Dragged right next to the laptop's right side, which is fully covered by the monitor.
        let dragged = CGRect(x: 1500, y: 700, width: 100, height: 200)
        let snap = try #require(ArrangementGeometry.snap(dragged, displays: [laptop, monitor]))
        for display in [laptop, monitor] {
            #expect(!display.insetBy(dx: 1, dy: 1).intersects(snap.rect))
        }
    }

    @Test func portalIsTheSharedSegment() throws {
        let rect = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: 900, size: phone)
        let portal = try #require(ArrangementGeometry.portal(display: laptop, phone: rect, edge: .right, otherDisplays: []))
        #expect(portal.start == CGPoint(x: 1512, y: 900))
        #expect(portal.end == CGPoint(x: 1512, y: 982)) // phone hangs below the display; only the overlap counts
    }

    @Test func portalExcludesAdjacentDisplay() throws {
        let monitor = CGRect(x: 1512, y: 0, width: 1920, height: 500)
        let rect = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: 400, size: CGSize(width: 100, height: 400))
        let portal = try #require(ArrangementGeometry.portal(display: laptop, phone: rect, edge: .right, otherDisplays: [monitor]))
        #expect(portal.start.y == 500)
        #expect(portal.end.y == 800)
    }

    @Test func rotationCyclesAndResizes() {
        #expect(PhoneOrientation.portrait.rotatedClockwise == .landscapeIslandRight)
        #expect(PhoneOrientation.landscapeIslandLeft.rotatedClockwise == .portrait)
        #expect(PhoneOrientation.portrait.rotatedCounterClockwise == .landscapeIslandLeft)
        let p = ArrangementGeometry.phoneSize(portraitPoints: CGSize(width: 393, height: 852), orientation: .landscapeIslandRight,
                                              macPointsPerMM: ArrangementGeometry.phonePointsPerMM)
        #expect(p == CGSize(width: 852, height: 393))
    }

    @Test func recentringKeepsTheCentre() {
        let portrait = CGSize(width: 100, height: 200), landscape = CGSize(width: 200, height: 100)
        let a = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: 300, size: portrait)
        let newOffset = ArrangementGeometry.recentredOffset(300, edge: .right, from: portrait, to: landscape)
        let b = ArrangementGeometry.phoneRect(display: laptop, edge: .right, offset: newOffset, size: landscape)
        #expect(a.midY == b.midY)
    }

    @Test func normalizedMappingRoundTrips() {
        let rect = CGRect(x: 1512, y: 300, width: 100, height: 200)
        let n = ArrangementGeometry.normalizedInPhone(CGPoint(x: 1512, y: 350), phone: rect)
        #expect(n == CGPoint(x: 0, y: 0.25))
        #expect(ArrangementGeometry.macPoint(fromNormalized: n, phone: rect) == CGPoint(x: 1512, y: 350))
    }

    @Test func layoutMessageRoundTrips() throws {
        let m = Message.layout(PhoneLayout(orientation: .landscapeIslandLeft, macSide: .left))
        #expect(try MessageCoder.decoder.decode(Message.self, from: MessageCoder.encoder.encode(m)) == m)
        let o = Message.orientation(.upsideDown)
        #expect(try MessageCoder.decoder.decode(Message.self, from: MessageCoder.encoder.encode(o)) == o)
    }
}

@Suite struct PageModelTests {
    @Test func layoutChangeKeepsWidgetsAndFillsNewSlots() {
        var page = PageInfo(.music)
        page.setLayout(.grid)
        #expect(page.widgets.count == 4)
        #expect(page.widgets.first == .builtin(.music))
        #expect(Set(page.widgets).count == 4) // filled with distinct, unused widgets
        page.setLayout(.split)
        #expect(page.widgets == Array(page.widgets.prefix(2)))
        #expect(page.widgets.first == .builtin(.music))
    }

    @Test func sizesMatchSlots() {
        for layout in PageLayout.allCases {
            #expect(WidgetSize.sizes(for: layout).count == layout.slots)
        }
    }

    @Test func titleListsVisibleWidgets() {
        let page = PageInfo(layout: .split, builtins: [.music, .weather, .notes])
        #expect(page.title == "Music + Weather")
        let custom = PageInfo(layout: .split, widgets: [.custom("com.example.rates"), .builtin(.music)])
        #expect(custom.title(customNames: ["com.example.rates": "Курсы валют"]) == "Курсы валют + Music")
        #expect(custom.title == "rates + Music")
    }

    @Test func widgetRefIsAStringOnTheWire() throws {
        // Pages saved before custom widgets existed are plain arrays of built-in names.
        let old = Data(#"{"id":"p","layout":"split","widgets":["music","weather"]}"#.utf8)
        let page = try JSONDecoder().decode(PageInfo.self, from: old)
        #expect(page.widgets == [.builtin(.music), .builtin(.weather)])
        let mixed = PageInfo(id: "q", layout: .split, widgets: [.custom("a.b"), .builtin(.notes)])
        let json = String(decoding: try JSONEncoder().encode(mixed.widgets), as: UTF8.self)
        #expect(json == #"["custom:a.b","notes"]"#)
        #expect(try JSONDecoder().decode(PageInfo.self, from: JSONEncoder().encode(mixed)) == mixed)
    }
}
