import CoreGraphics
import Foundation
import Testing
@testable import PhoneScreenKit

@Suite struct PhonePointerTests {
    func pointer(_ side: ScreenEdge) -> PhonePointer {
        var p = PhonePointer(size: CGSize(width: 400, height: 800), macSide: side)
        p.enter(along: 0.5)
        return p
    }

    @Test func entersOnTheMacFacingSide() {
        #expect(pointer(.left).position == CGPoint(x: 1, y: 400))
        #expect(pointer(.right).position == CGPoint(x: 399, y: 400))
        #expect(pointer(.top).position == CGPoint(x: 200, y: 1))
        #expect(pointer(.bottom).position == CGPoint(x: 200, y: 799))
    }

    @Test func movesAndClampsToTheScreen() {
        var p = pointer(.left)
        #expect(p.move(dx: 50, dy: -1000) == .none)
        #expect(p.position == CGPoint(x: 51, y: 0))
    }

    @Test func exitsBackThroughTheMacSide() {
        var p = pointer(.left)
        _ = p.move(dx: 30, dy: 200)
        #expect(p.move(dx: -40, dy: 0) == .exit(along: 0.75))
        #expect(!p.isActive)
        #expect(p.move(dx: 10, dy: 0) == .none) // ignored once inactive
    }

    @Test func exitThroughBottomSideReportsHorizontalPosition() {
        var p = pointer(.bottom)
        _ = p.move(dx: -100, dy: -10)
        #expect(p.move(dx: 0, dy: 20) == .exit(along: 0.25))
    }

    @Test func pushingTheFarSideOnlyStopsThePointer() {
        var p = pointer(.right) // phone left of the Mac: its far side is the left one
        var events: [PhonePointer.Event] = []
        for _ in 0..<100 { events.append(p.move(dx: -20, dy: 0)) }
        #expect(events.allSatisfy { $0 == .none })
        #expect(p.position.x == 0)
        #expect(p.isActive)
    }
}

@Suite struct PointerMappingTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let phone = CGRect(x: 1512, y: 700, width: 100, height: 400) // hangs 118 pt below the display

    @Test func alongOfPointOnRightEdge() {
        #expect(ArrangementGeometry.along(ofMacPoint: CGPoint(x: 1511, y: 800), phone: phone, edge: .right) == 0.25)
    }

    @Test func exitPointIsClampedToThePortal() throws {
        let portal = try #require(ArrangementGeometry.portal(display: display, phone: phone, edge: .right, otherDisplays: []))
        let inside = ArrangementGeometry.exitPoint(along: 0.25, phone: phone, display: display, edge: .right, portal: portal)
        #expect(inside == CGPoint(x: 1510, y: 800))
        // Leaving from the part of the phone below the display: cursor lands at the portal's end.
        let below = ArrangementGeometry.exitPoint(along: 0.9, phone: phone, display: display, edge: .right, portal: portal)
        #expect(below == CGPoint(x: 1510, y: 981))
    }

    @Test func portalDetection() throws {
        let portal = try #require(ArrangementGeometry.portal(display: display, phone: phone, edge: .right, otherDisplays: []))
        #expect(ArrangementGeometry.isOnPortal(CGPoint(x: 1511, y: 750), display: display, edge: .right, portal: portal))
        #expect(!ArrangementGeometry.isOnPortal(CGPoint(x: 1511, y: 300), display: display, edge: .right, portal: portal))
        #expect(!ArrangementGeometry.isOnPortal(CGPoint(x: 1400, y: 750), display: display, edge: .right, portal: portal))
    }

    @Test func outwardComponentPerEdge() {
        #expect(ArrangementGeometry.outwardComponent(dx: 3, dy: 0, edge: .right) == 3)
        #expect(ArrangementGeometry.outwardComponent(dx: 3, dy: 0, edge: .left) == -3)
        #expect(ArrangementGeometry.outwardComponent(dx: 0, dy: -4, edge: .top) == 4)
    }
}
