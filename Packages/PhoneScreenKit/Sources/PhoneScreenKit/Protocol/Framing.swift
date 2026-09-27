import Foundation

/// Wire format: `[UInt32 big-endian payload length][payload]`, payload = JSON-encoded `Message`.
public enum Framing {
    /// Frames larger than this are treated as a protocol error (protects against garbage on the pipe).
    public static let maxFrameLength = 4 * 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    public static func encode(_ message: Message) throws -> Data {
        try frame(MessageCoder.encoder.encode(message))
    }
}

public enum FramingError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Incremental parser: feed arbitrary chunks from the byte stream, get complete payloads out.
public struct FrameParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard length <= Framing.maxFrameLength else { throw FramingError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer.removeSubrange(start..<start + 4 + length)
        }
        return frames
    }

    public mutating func messages(from chunk: Data) throws -> [Message] {
        try append(chunk).map { try MessageCoder.decoder.decode(Message.self, from: $0) }
    }
}
