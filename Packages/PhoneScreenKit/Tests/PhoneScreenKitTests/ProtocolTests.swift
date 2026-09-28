import Foundation
import Testing
@testable import PhoneScreenKit

@Suite struct FramingTests {
    @Test func roundTripSingleFrame() throws {
        var parser = FrameParser()
        let messages = try parser.messages(from: Framing.encode(.setPage(index: 3)))
        #expect(messages == [.setPage(index: 3)])
    }

    @Test func splitAcrossChunks() throws {
        let data = try Framing.encode(.command(id: "open-safari"))
        var parser = FrameParser()
        var out: [Message] = []
        for byte in data { out += try parser.messages(from: Data([byte])) }
        #expect(out == [.command(id: "open-safari")])
    }

    @Test func coalescedFrames() throws {
        let data = try Framing.encode(.ping(t: 1)) + Framing.encode(.pong(t: 1)) + Framing.encode(.pageChanged(index: 0))
        var parser = FrameParser()
        #expect(try parser.messages(from: data) == [.ping(t: 1), .pong(t: 1), .pageChanged(index: 0)])
    }

    @Test func partialTrailingFrameIsKept() throws {
        let a = try Framing.encode(.setPage(index: 1))
        let b = try Framing.encode(.setPage(index: 2))
        var parser = FrameParser()
        #expect(try parser.messages(from: a + b.prefix(5)) == [.setPage(index: 1)])
        #expect(try parser.messages(from: b.dropFirst(5)) == [.setPage(index: 2)])
    }

    @Test func rejectsOversizedFrame() {
        var parser = FrameParser()
        #expect(throws: FramingError.self) { try parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF])) }
    }
}

@Suite struct MessageCodingTests {
    static let all: [Message] = [
        .hello(Hello(role: .phone, name: "iPhone", sessionId: UUID(),
                     screen: ScreenInfo(width: 393, height: 852, scale: 3), lowBandwidth: true)),
        .ping(t: 12.5), .pong(t: 12.5),
        .pages(list: [PageInfo(.music), PageInfo(id: "d", layout: .trio, builtins: [.calendar, .weather, .music])], current: 0),
        .setPage(index: 2), .pageChanged(index: 1),
        .nowPlaying(NowPlaying(title: "Song", artist: "Artist", artwork: Data([1, 2, 3]), duration: 200,
                               elapsed: 10, playing: true, timestamp: Date(timeIntervalSince1970: 1_700_000_000))),
        .nowPlaying(nil),
        .stats(SystemStats(cpu: 0.4, cpuPerCore: [0.1, 0.7], gpu: nil, memoryUsed: 8, memoryTotal: 16,
                           netInBytesPerSec: 100, netOutBytesPerSec: 50)),
        .mediaAction(.next), .command(id: "lock"),
        .pointerEnter(along: 0.5), .pointerDelta(dx: 1.5, dy: -2), .pointerButton(button: .left, down: true),
        .pointerScroll(dx: 0, dy: 3, phase: .changed), .pointerExit(along: 0.25),
        .notes([NoteSummary(id: "x-coredata://1", title: "Покупки", snippet: "молоко", folder: "Заметки",
                            modified: Date(timeIntervalSince1970: 1_700_000_000))]),
        .noteRequest(id: "n1"), .noteBody(id: "n1", text: "Текст\nвторая строка"), .noteCreate(text: "Идея"),
        .noteShowOnMac(id: "n1"),
        .launcher([LauncherItem(id: "app:/Applications/Safari.app", title: "Safari", kind: .app, icon: Data([9])),
                   LauncherItem(id: "sys:lock", title: "Блокировка", kind: .system, symbol: "lock")]),
        .refresh(.notes),
        .runningApps([RunningApp(id: "com.apple.Safari", name: "Safari", active: true, window: "GitHub", windows: 3, icon: Data([7])),
                      RunningApp(id: "pid:123", name: "Без бандла", hidden: true)]),
        .appAction(id: "com.apple.Safari", action: .activate), .appPreview(id: "com.apple.Safari", image: Data([0xFF, 0xD8])),
        .appPreview(id: "pid:123", image: Data()), .refresh(.apps),
        .textFocus(true), .keyText("Привет, мир"), .key(.deleteWordBackward),
        .pointerPinch(magnification: -0.12, phase: .changed), .pointerSmartZoom,
        .musicQueue(MusicQueue(tracks: [QueueTrack(title: "Звезда по имени Солнце", artist: "Кино", duration: 225)],
                               note: "Далее в плейлисте")),
        .audio(AudioState(systemVolume: 0.4, muted: false,
                          airPlay: [AirPlayDevice(name: "Колонки MacBook Pro", kind: "computer", selected: true)])),
        .music(.setPlayerVolume(0.7)), .music(.seek(61.5)), .music(.cycleRepeat), .music(.playQueueItem(2)),
        .music(.setAirPlay(["HomePod", "Колонки MacBook Pro"])),
        .displayStart(DisplayStreamInfo(width: 1179, height: 2556, scale: 2)),
        .displayFrame(data: Data([0, 0, 0, 1, 0x67]), key: true), .displayStop, .displayVisible(true), .displayKeyframe,
        .displayTouch(phase: .moved, x: 0.25, y: 0.75), .displayScroll(dx: 0, dy: -12), .refresh(.display),
    ]

    @Test(arguments: all) func roundTrip(_ message: Message) throws {
        let data = try MessageCoder.encoder.encode(message)
        #expect(try MessageCoder.decoder.decode(Message.self, from: data) == message)
    }

    @Test func wireShapeIsFlatJSON() throws {
        let json = try JSONSerialization.jsonObject(with: MessageCoder.encoder.encode(Message.pointerDelta(dx: 1, dy: 2)))
        let dict = try #require(json as? [String: Any])
        #expect(dict["t"] as? String == "pointerDelta")
        #expect(dict["dx"] as? Double == 1)
    }
}
