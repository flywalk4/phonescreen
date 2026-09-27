import Foundation
import Network
import PhoneScreenKit

/// Talks to macOS's built-in `usbmuxd` to reach a TCP port on a USB-attached iPhone.
///
/// Protocol (plist flavour): every packet = 16-byte little-endian header
/// `{length incl. header, version = 1, message = 8 (plist), tag}` + XML plist.
/// 1. A "Listen" connection receives `Attached` / `Detached` notifications.
/// 2. For each USB device, a fresh connection sends `Connect{DeviceID, PortNumber (network byte order)}`;
///    on `Result{Number: 0}` that socket becomes a transparent byte pipe to the phone.
final class USBMuxClient: @unchecked Sendable {
    static let socketPath = "/var/run/usbmuxd"

    private let queue = DispatchQueue(label: "phonescreen.usbmux")
    private let port: UInt16
    private let onChannel: @Sendable (ByteChannel) -> Void
    private var listenConnection: NWConnection?
    private var devices: Set<Int> = []
    private var connected: Set<Int> = []
    private var connecting: Set<Int> = []

    init(port: UInt16 = Protocol.tcpPort, onChannel: @escaping @Sendable (ByteChannel) -> Void) {
        self.port = port
        self.onChannel = onChannel
    }

    func start() {
        queue.async { [self] in startListening() }
    }

    // MARK: - Device notifications

    private func startListening() {
        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        listenConnection = connection
        var reader = PacketReader()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(content: Self.packet(["MessageType": "Listen"], tag: 1), completion: .idempotent)
            case .failed, .cancelled:
                self.devices.removeAll()
                self.queue.asyncAfter(deadline: .now() + 3) { self.startListening() }
            default: break
            }
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data {
                    for plist in reader.append(data) { self.handleNotification(plist) }
                }
                if done || error != nil { connection.cancel() } else { receive() }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func handleNotification(_ plist: [String: Any]) {
        switch plist["MessageType"] as? String {
        case "Attached":
            let props = plist["Properties"] as? [String: Any]
            guard props?["ConnectionType"] as? String == "USB",
                  let id = plist["DeviceID"] as? Int else { return }
            devices.insert(id)
            connect(device: id)
        case "Detached":
            if let id = plist["DeviceID"] as? Int { devices.remove(id) }
        default:
            break
        }
    }

    // MARK: - Tunnels

    private func connect(device id: Int) {
        guard devices.contains(id), !connected.contains(id), !connecting.contains(id) else { return }
        connecting.insert(id)
        let connection = NWConnection(to: .unix(path: Self.socketPath), using: .tcp)
        var reader = PacketReader()
        let request: [String: Any] = [
            "MessageType": "Connect",
            "DeviceID": id,
            "PortNumber": Int(port.bigEndian),
        ]
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                connection.send(content: Self.packet(request, tag: 2), completion: .idempotent)
                // Read exactly one packet: the phone may start talking right after the Result,
                // and those bytes belong to the tunnel, not to usbmuxd.
                Self.receiveExactly(16, on: connection) { header in
                    guard let header, header.count == 16 else { return self.connectFailed(id, connection) }
                    let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
                    Self.receiveExactly(max(length - 16, 0), on: connection) { body in
                        let result = body.flatMap { reader.append(header + $0).first }?["Number"] as? Int
                        self.finishConnect(id, connection, result: result)
                    }
                }
            case .failed:
                self.connectFailed(id, connection)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private static func receiveExactly(_ count: Int, on connection: NWConnection, _ done: @escaping (Data?) -> Void) {
        guard count > 0 else { return done(Data()) }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, _ in done(data) }
    }

    private func connectFailed(_ id: Int, _ connection: NWConnection) {
        connecting.remove(id)
        connection.stateUpdateHandler = nil
        connection.cancel()
        retry(id)
    }

    private func finishConnect(_ id: Int, _ connection: NWConnection, result: Int?) {
        // 3 = connection refused: the app on the phone is not running yet.
        guard result == 0 else { return connectFailed(id, connection) }
        connecting.remove(id)
        connected.insert(id)
        connection.stateUpdateHandler = nil
        let channel = NWByteChannel(connection: connection, transport: .usb, queue: queue)
        onChannel(ClosingObserver(channel) { [weak self] in
            self?.queue.async {
                self?.connected.remove(id)
                self?.retry(id)
            }
        })
    }

    private func retry(_ id: Int) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect(device: id) }
    }

    // MARK: - Wire format

    static func packet(_ body: [String: Any], tag: UInt32) -> Data {
        var plist = body
        plist["ClientVersionString"] = "phonescreen"
        plist["ProgName"] = "PhoneScreen"
        let payload = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        var data = Data()
        for value in [UInt32(16 + payload.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    struct PacketReader {
        private var buffer = Data()

        mutating func append(_ chunk: Data) -> [[String: Any]] {
            buffer.append(chunk)
            var out: [[String: Any]] = []
            while buffer.count >= 16 {
                let s = buffer.startIndex
                let length = Int(buffer[s..<s + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
                guard length >= 16, buffer.count >= length else { break }
                let payload = buffer[s + 16..<s + length]
                if let plist = try? PropertyListSerialization.propertyList(from: Data(payload), format: nil) as? [String: Any] {
                    out.append(plist)
                }
                buffer.removeSubrange(s..<s + length)
            }
            return out
        }
    }
}
