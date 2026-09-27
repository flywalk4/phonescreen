import Foundation

/// Every message exchanged between the Mac agent and the iPhone client.
/// JSON shape: `{"t": "<type>", ...fields}`.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case ping(t: Double)
    case pong(t: Double)

    // Pages (Mac → phone: pages/setPage, phone → Mac: pageChanged)
    case pages(list: [PageInfo], current: Int)
    case setPage(index: Int)
    case pageChanged(index: Int)
    /// Mac → phone: how the phone sits next to the Mac (orientation + which side faces it).
    case layout(PhoneLayout)

    // Widget data (Mac → phone)
    case nowPlaying(NowPlaying?)
    case stats(SystemStats)

    // Actions (phone → Mac)
    case mediaAction(MediaAction)
    case command(id: String)

    // Pointer. `along` = position along the phone side that faces the Mac, 0…1
    // (top→bottom for a left/right side, left→right for a top/bottom side, in the phone's upright UI).
    /// Mac → phone: the cursor crossed onto the phone.
    case pointerEnter(along: Double)
    /// Mac → phone: movement while captured, already in phone UI points.
    case pointerDelta(dx: Double, dy: Double)
    case pointerButton(button: PointerButton, down: Bool)
    /// Scroll / two-finger swipe, in phone points, with the trackpad gesture phase.
    case pointerScroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Phone → Mac: the pointer left through the Mac-facing side. Mac → phone: capture ended on the Mac's side.
    case pointerExit(along: Double)
}

extension Message: Codable {
    private enum Kind: String, Codable {
        case hello, ping, pong, pages, setPage, pageChanged, layout, nowPlaying, stats, mediaAction, command
        case pointerEnter, pointerDelta, pointerButton, pointerScroll, pointerExit
    }

    private enum Keys: String, CodingKey {
        case t, hello, list, current, index, value, id, along, dx, dy, button, down, phase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .t) {
        case .hello: self = .hello(try c.decode(Hello.self, forKey: .hello))
        case .ping: self = .ping(t: try c.decode(Double.self, forKey: .value))
        case .pong: self = .pong(t: try c.decode(Double.self, forKey: .value))
        case .pages: self = .pages(list: try c.decode([PageInfo].self, forKey: .list),
                                   current: try c.decode(Int.self, forKey: .current))
        case .setPage: self = .setPage(index: try c.decode(Int.self, forKey: .index))
        case .pageChanged: self = .pageChanged(index: try c.decode(Int.self, forKey: .index))
        case .layout: self = .layout(try c.decode(PhoneLayout.self, forKey: .value))
        case .nowPlaying: self = .nowPlaying(try c.decodeIfPresent(NowPlaying.self, forKey: .value))
        case .stats: self = .stats(try c.decode(SystemStats.self, forKey: .value))
        case .mediaAction: self = .mediaAction(try c.decode(MediaAction.self, forKey: .value))
        case .command: self = .command(id: try c.decode(String.self, forKey: .id))
        case .pointerEnter: self = .pointerEnter(along: try c.decode(Double.self, forKey: .along))
        case .pointerDelta: self = .pointerDelta(dx: try c.decode(Double.self, forKey: .dx),
                                                 dy: try c.decode(Double.self, forKey: .dy))
        case .pointerButton: self = .pointerButton(button: try c.decode(PointerButton.self, forKey: .button),
                                                   down: try c.decode(Bool.self, forKey: .down))
        case .pointerScroll: self = .pointerScroll(dx: try c.decode(Double.self, forKey: .dx),
                                                   dy: try c.decode(Double.self, forKey: .dy),
                                                   phase: try c.decode(ScrollPhase.self, forKey: .phase))
        case .pointerExit: self = .pointerExit(along: try c.decode(Double.self, forKey: .along))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let v): try c.encode(Kind.hello, forKey: .t); try c.encode(v, forKey: .hello)
        case .ping(let t): try c.encode(Kind.ping, forKey: .t); try c.encode(t, forKey: .value)
        case .pong(let t): try c.encode(Kind.pong, forKey: .t); try c.encode(t, forKey: .value)
        case .pages(let list, let current):
            try c.encode(Kind.pages, forKey: .t); try c.encode(list, forKey: .list); try c.encode(current, forKey: .current)
        case .setPage(let i): try c.encode(Kind.setPage, forKey: .t); try c.encode(i, forKey: .index)
        case .pageChanged(let i): try c.encode(Kind.pageChanged, forKey: .t); try c.encode(i, forKey: .index)
        case .layout(let v): try c.encode(Kind.layout, forKey: .t); try c.encode(v, forKey: .value)
        case .nowPlaying(let v): try c.encode(Kind.nowPlaying, forKey: .t); try c.encodeIfPresent(v, forKey: .value)
        case .stats(let v): try c.encode(Kind.stats, forKey: .t); try c.encode(v, forKey: .value)
        case .mediaAction(let v): try c.encode(Kind.mediaAction, forKey: .t); try c.encode(v, forKey: .value)
        case .command(let id): try c.encode(Kind.command, forKey: .t); try c.encode(id, forKey: .id)
        case .pointerEnter(let a): try c.encode(Kind.pointerEnter, forKey: .t); try c.encode(a, forKey: .along)
        case .pointerDelta(let dx, let dy):
            try c.encode(Kind.pointerDelta, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case .pointerButton(let b, let down):
            try c.encode(Kind.pointerButton, forKey: .t); try c.encode(b, forKey: .button); try c.encode(down, forKey: .down)
        case .pointerScroll(let dx, let dy, let phase):
            try c.encode(Kind.pointerScroll, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
            try c.encode(phase, forKey: .phase)
        case .pointerExit(let a): try c.encode(Kind.pointerExit, forKey: .t); try c.encode(a, forKey: .along)
        }
    }
}

public enum MessageCoder {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
