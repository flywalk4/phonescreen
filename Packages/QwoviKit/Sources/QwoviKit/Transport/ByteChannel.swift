import Foundation
import Network

/// A bidirectional byte pipe. USB (usbmuxd), LAN/AWDL (TCP) and BLE (L2CAP streams)
/// all end up as one of these, so the protocol above never cares about the transport.
public protocol ByteChannel: AnyObject, Sendable {
    var transport: TransportKind { get }
    /// Called on an internal queue with each chunk received; `nil` = channel closed.
    func start(onData: @escaping @Sendable (Data?) -> Void)
    func send(_ data: Data)
    func close()
}

public enum TransportKind: String, Codable, Sendable, Comparable {
    case usb, lan, peerToPeer, bluetooth

    /// Lower = preferred.
    public var priority: Int {
        switch self {
        case .usb: 0
        case .lan: 1
        case .peerToPeer: 2
        case .bluetooth: 3
        }
    }

    public static func < (a: TransportKind, b: TransportKind) -> Bool { a.priority < b.priority }

    public var label: String {
        switch self {
        case .usb: "USB"
        case .lan: "Wi-Fi"
        case .peerToPeer: "Wi-Fi P2P"
        case .bluetooth: "Bluetooth"
        }
    }
}

/// `ByteChannel` over an already-created `NWConnection` (TCP or Unix socket).
public final class NWByteChannel: ByteChannel, @unchecked Sendable {
    public let connection: NWConnection
    public let transport: TransportKind
    private let queue: DispatchQueue
    private var onData: (@Sendable (Data?) -> Void)?
    private var closed = false

    public init(connection: NWConnection, transport: TransportKind,
                queue: DispatchQueue = DispatchQueue(label: "qwovi.channel")) {
        self.connection = connection
        self.transport = transport
        self.queue = queue
    }

    public func start(onData: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            self.onData = onData
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
            if connection.state == .setup { connection.start(queue: queue) }
            receiveLoop()
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if isComplete || error != nil { self.finish() } else { self.receiveLoop() }
        }
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func close() {
        queue.async { [self] in
            connection.cancel()
            finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onData?(nil)
        onData = nil
    }
}

public extension NWParameters {
    /// TCP with Nagle disabled; `peerToPeer` also enables AWDL (direct Wi-Fi without a shared network).
    static func qwovi(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        return params
    }
}
