import Foundation

/// Holds every live channel to the peer (USB, LAN, P2P Wi-Fi, BLE at once) and always sends
/// through the best one. Losing a channel just moves traffic to the next; the session survives.
///
/// Both sides use the same pool, so both agree on the active transport without negotiation.
/// All callbacks are delivered on the main queue.
public final class ChannelPool: @unchecked Sendable {
    public struct Status: Equatable, Sendable {
        public var active: TransportKind?
        public var available: [TransportKind]
        /// Round-trip time of the active channel, seconds.
        public var rtt: Double?
        public var peerName: String?

        public init(active: TransportKind? = nil, available: [TransportKind] = [], rtt: Double? = nil, peerName: String? = nil) {
            self.active = active
            self.available = available
            self.rtt = rtt
            self.peerName = peerName
        }
    }

    private final class Entry: @unchecked Sendable {
        let id = UUID()
        let channel: MessageChannel
        var rtt: Double?
        var helloReceived = false
        init(_ channel: MessageChannel) { self.channel = channel }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var pingTimer: DispatchSourceTimer?
    private var lastActive: TransportKind?
    private var peerName: String?

    private let makeHello: @Sendable (TransportKind) -> Hello

    /// Every message from the peer except handshake/ping plumbing.
    public var onMessage: (@MainActor (Message) -> Void)?
    /// Fires when a new channel becomes the active one (connect, failover, upgrade back to USB).
    /// The owner should re-send its state here so the peer is in sync on the new path.
    public var onActiveChanged: (@MainActor (TransportKind?) -> Void)?
    public var onPeerHello: (@MainActor (Hello) -> Void)?
    public var onStatus: (@MainActor (Status) -> Void)?

    public init(makeHello: @escaping @Sendable (TransportKind) -> Hello) {
        self.makeHello = makeHello
    }

    public var hasChannel: Bool { lock.withLock { !entries.isEmpty } }

    public func has(_ transport: TransportKind) -> Bool {
        lock.withLock { entries.contains { $0.channel.transport == transport } }
    }

    public func add(_ bytes: ByteChannel) {
        let channel = MessageChannel(bytes)
        let entry = Entry(channel)
        lock.withLock { entries.append(entry) }
        channel.start(
            onMessage: { [weak self] message in self?.handle(message, from: entry) },
            onClose: { [weak self] in self?.remove(entry) }
        )
        channel.send(.hello(makeHello(channel.transport)))
        channel.send(.ping(t: Self.now))
        startPinging()
    }

    public func send(_ message: Message) {
        best()?.channel.send(message)
    }

    public var activeTransport: TransportKind? { best()?.channel.transport }

    public var isLowBandwidth: Bool { activeTransport == .bluetooth }

    public func closeAll() {
        let all = lock.withLock { entries }
        all.forEach { $0.channel.close() }
    }

    // MARK: - Internals

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Best = lowest transport priority among channels that completed the hello handshake.
    private func best() -> Entry? {
        lock.withLock {
            entries.filter(\.helloReceived).min { $0.channel.transport < $1.channel.transport }
        }
    }

    private func handle(_ message: Message, from entry: Entry) {
        switch message {
        case .ping(let t):
            entry.channel.send(.pong(t: t))
        case .pong(let t):
            lock.withLock { entry.rtt = Self.now - t }
            publishStatus()
        case .hello(let hello):
            lock.withLock {
                entry.helloReceived = true
                peerName = hello.name
            }
            DispatchQueue.main.async { self.onPeerHello?(hello) }
            activeMaybeChanged()
        default:
            DispatchQueue.main.async { self.onMessage?(message) }
        }
    }

    private func remove(_ entry: Entry) {
        lock.withLock { entries.removeAll { $0.id == entry.id } }
        activeMaybeChanged()
    }

    private func activeMaybeChanged() {
        let active = activeTransport
        let changed = lock.withLock { () -> Bool in
            defer { lastActive = active }
            return lastActive != active
        }
        if changed {
            DispatchQueue.main.async { self.onActiveChanged?(active) }
        }
        publishStatus()
    }

    private func publishStatus() {
        let status = lock.withLock { () -> Status in
            let ready = entries.filter(\.helloReceived)
            let best = ready.min { $0.channel.transport < $1.channel.transport }
            return Status(active: best?.channel.transport,
                          available: ready.map(\.channel.transport).sorted(),
                          rtt: best?.rtt,
                          peerName: best == nil ? nil : peerName)
        }
        DispatchQueue.main.async { self.onStatus?(status) }
    }

    private func startPinging() {
        lock.withLock {
            guard pingTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let all = self.lock.withLock { self.entries }
                all.forEach { $0.channel.send(.ping(t: Self.now)) }
            }
            timer.resume()
            pingTimer = timer
        }
    }
}
