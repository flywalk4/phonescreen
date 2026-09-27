import Foundation

/// `ByteChannel` over a Foundation stream pair — what a Bluetooth L2CAP channel (`CBL2CAPChannel`) provides.
/// The streams run on a dedicated run-loop thread; writes are buffered until the stream has space.
public final class StreamByteChannel: NSObject, ByteChannel, StreamDelegate, @unchecked Sendable {
    public let transport: TransportKind
    private let input: InputStream
    private let output: OutputStream
    /// Keeps the owner of the streams alive (e.g. the `CBL2CAPChannel`: its streams close when it's released).
    private let owner: AnyObject?

    private var thread: Thread?
    private var runLoop: RunLoop?
    private var onData: (@Sendable (Data?) -> Void)?
    private var pending = Data()
    private var closed = false
    private let lock = NSLock()

    public init(input: InputStream, output: OutputStream, transport: TransportKind, owner: AnyObject? = nil) {
        self.input = input
        self.output = output
        self.transport = transport
        self.owner = owner
    }

    public func start(onData: @escaping @Sendable (Data?) -> Void) {
        self.onData = onData
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = RunLoop.current
            runLoop = loop
            for stream in [input, output] as [Stream] {
                stream.delegate = self
                stream.schedule(in: loop, forMode: .default)
                stream.open()
            }
            ready.signal()
            // Keeps running until both streams are removed on close.
            while !isClosed, loop.run(mode: .default, before: .distantFuture) {}
        }
        thread.name = "PhoneScreen.stream.\(transport.rawValue)"
        thread.qualityOfService = .userInitiated
        thread.start()
        self.thread = thread
        ready.wait()
    }

    public func send(_ data: Data) {
        perform { [self] in
            pending.append(data)
            flush()
        }
    }

    public func close() {
        perform { [self] in finish() }
    }

    // MARK: - Stream thread

    private var isClosed: Bool { lock.withLock { closed } }

    /// Runs on the stream thread.
    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        runLoop.perform(inModes: [.default], block: block)
        // Wake the loop so the block runs promptly.
        CFRunLoopWakeUp(runLoop.getCFRunLoop())
    }

    public func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            read()
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            finish()
        default:
            break
        }
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while input.hasBytesAvailable {
            let n = input.read(&buffer, maxLength: buffer.count)
            if n > 0 {
                onData?(Data(buffer[0..<n]))
            } else {
                if n < 0 { finish() }
                return
            }
        }
    }

    private func flush() {
        while !pending.isEmpty, output.hasSpaceAvailable {
            let written = pending.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: pending.count)
            }
            if written <= 0 {
                if written < 0 { finish() }
                return
            }
            pending.removeFirst(written)
        }
    }

    private func finish() {
        let wasClosed = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        for stream in [input, output] as [Stream] {
            stream.delegate = nil
            stream.close()
            if let runLoop { stream.remove(from: runLoop, forMode: .default) }
        }
        pending.removeAll()
        onData?(nil)
        onData = nil
    }
}
