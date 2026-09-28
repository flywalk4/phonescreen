import Foundation

/// Message-level connection on top of any `ByteChannel`.
public final class MessageChannel: @unchecked Sendable {
    public let bytes: ByteChannel
    public var transport: TransportKind { bytes.transport }
    private var parser = FrameParser()

    public init(_ bytes: ByteChannel) {
        self.bytes = bytes
    }

    /// `onMessage` gets each decoded message; `onClose` fires once when the channel ends
    /// (remote close, transport error or a malformed frame).
    public func start(onMessage: @escaping @Sendable (Message) -> Void,
                      onClose: @escaping @Sendable () -> Void) {
        bytes.start { [self] data in
            guard let data else { onClose(); return }
            do {
                for message in try parser.messages(from: data) { onMessage(message) }
            } catch {
                bytes.close()
            }
        }
    }

    public func send(_ message: Message) {
        guard let data = try? Framing.encode(message) else { return }
        bytes.send(data)
    }

    public func close() {
        bytes.close()
    }
}
