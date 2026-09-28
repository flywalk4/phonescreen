import Foundation
import Testing
@testable import QwoviKit

@Suite struct StreamChannelTests {
    /// Two channels joined by bound stream pairs (like the two ends of an L2CAP channel) exchange framed messages.
    @Test func framedMessagesCrossAStreamPair() async throws {
        var aIn: InputStream?, bOut: OutputStream?, bIn: InputStream?, aOut: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &aIn, outputStream: &bOut)
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &bIn, outputStream: &aOut)
        let a = MessageChannel(StreamByteChannel(input: aIn!, output: aOut!, transport: .bluetooth))
        let b = MessageChannel(StreamByteChannel(input: bIn!, output: bOut!, transport: .bluetooth))

        let received = await withCheckedContinuation { (done: CheckedContinuation<[Message], Never>) in
            let box = Box()
            b.start(onMessage: { message in
                let all = box.append(message)
                if all.count == 3 { done.resume(returning: all) }
            }, onClose: {})
            a.start(onMessage: { _ in }, onClose: {})
            a.send(.ping(t: 1))
            // Bigger than the 4 KB stream buffer: must be written in pieces as space frees up.
            a.send(.keyText(String(repeating: "я", count: 6000)))
            a.send(.setPage(index: 3))
        }
        #expect(received.count == 3)
        #expect(received[0] == .ping(t: 1))
        #expect(received[1] == .keyText(String(repeating: "я", count: 6000)))
        #expect(received[2] == .setPage(index: 3))
        a.close()
        b.close()
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Message] = []
    func append(_ m: Message) -> [Message] { lock.withLock { items.append(m); return items } }
}
