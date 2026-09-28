import Foundation
import Network
import QwoviKit

/// Accepts connections from the Mac agent on one TCP port:
/// - USB: usbmuxd on the phone tunnels the Mac's `Connect` to this port on loopback;
/// - Wi-Fi LAN and peer-to-peer Wi-Fi (AWDL): discovered through the Bonjour advertisement.
final class Listener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qwovi.listener")
    private var listener: NWListener?
    private let name: String
    private let onChannel: @Sendable (ByteChannel) -> Void

    init(name: String, onChannel: @escaping @Sendable (ByteChannel) -> Void) {
        self.name = name
        self.onChannel = onChannel
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: .qwovi(peerToPeer: true),
                                              on: NWEndpoint.Port(rawValue: Protocol.tcpPort)!)
                listener.service = NWListener.Service(name: name, type: Protocol.bonjourType)
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed = state { self?.restart() }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                restart()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func restart() {
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                self.onChannel(NWByteChannel(connection: connection, transport: .detect(connection), queue: self.queue))
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
