import Foundation
import Network
import QwoviKit

/// Finds the phone over Bonjour on the LAN and over peer-to-peer Wi-Fi (AWDL, no shared network needed)
/// and hands ready TCP channels to the pool.
final class BonjourBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "qwovi.bonjour")
    private var browser: NWBrowser?
    private var pending: [NWEndpoint: NWConnection] = [:]
    private var connected: Set<NWEndpoint> = []
    private let onChannel: @Sendable (ByteChannel) -> Void

    init(onChannel: @escaping @Sendable (ByteChannel) -> Void) {
        self.onChannel = onChannel
    }

    func start() {
        queue.async { [self] in
            let browser = NWBrowser(for: .bonjour(type: Protocol.bonjourType, domain: nil), using: .qwovi())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.update(results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.restart() }
            }
            browser.start(queue: queue)
            self.browser = browser
        }
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        for result in results where !connected.contains(result.endpoint) && pending[result.endpoint] == nil {
            connect(to: result.endpoint)
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .qwovi())
        pending[endpoint] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.pending[endpoint] = nil
                self.connected.insert(endpoint)
                // Bonjour is never USB; loopback here only happens with the iOS Simulator on this Mac.
                let kind = TransportKind.detect(connection)
                let channel = NWByteChannel(connection: connection, transport: kind == .usb ? .lan : kind, queue: self.queue)
                // Once the channel closes, allow reconnecting to the same service.
                connection.stateUpdateHandler = nil
                self.onChannel(ClosingObserver(channel) { [weak self] in
                    self?.queue.async { self?.connected.remove(endpoint) }
                    self?.queue.asyncAfter(deadline: .now() + 1) { self?.retry(endpoint) }
                })
            case .failed, .waiting:
                connection.cancel()
                self.pending[endpoint] = nil
                self.queue.asyncAfter(deadline: .now() + 2) { self.retry(endpoint) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Reconnect only if the service is still being advertised.
    private func retry(_ endpoint: NWEndpoint) {
        guard let browser, browser.browseResults.contains(where: { $0.endpoint == endpoint }),
              !connected.contains(endpoint), pending[endpoint] == nil else { return }
        connect(to: endpoint)
    }
}

/// Wraps a channel to get notified when it closes.
final class ClosingObserver: ByteChannel, @unchecked Sendable {
    private let inner: ByteChannel
    private let onClosed: @Sendable () -> Void
    var transport: TransportKind { inner.transport }

    init(_ inner: ByteChannel, onClosed: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onClosed = onClosed
    }

    func start(onData: @escaping @Sendable (Data?) -> Void) {
        inner.start { [onClosed] data in
            onData(data)
            if data == nil { onClosed() }
        }
    }

    func send(_ data: Data) { inner.send(data) }
    func close() { inner.close() }
}
