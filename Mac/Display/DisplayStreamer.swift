import CoreMedia
import QwoviKit
import ScreenCaptureKit
import VideoToolbox

/// Streams one display to the phone as low-latency H.264: ScreenCaptureKit hands over frames only when
/// something changed, the hardware encoder turns them into access units, and each goes out as a
/// `displayFrame`. Everything runs on its own queue; the main thread (and so the cursor) never waits for it.
final class DisplayStreamer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Sends a message to the phone. Must be thread-safe (`ChannelPool.send` is).
    var send: (@Sendable (Message) -> Void)?

    private let queue = DispatchQueue(label: "qwovi.display", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var forceKey = true
    /// Frames being encoded or sent: new ones are dropped while the link is behind.
    private var inFlight = 0
    private var displayID: CGDirectDisplayID?
    private var frames = 0
    private var bytes = 0
    private var statsStart = CFAbsoluteTimeGetCurrent()

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    var isRunning: Bool { lock.withLock { stream != nil } }

    /// Starts streaming `displayID` at `pixels` (the display's size in pixels).
    func start(displayID: CGDirectDisplayID, pixels: CGSize) {
        stop()
        guard Self.hasPermission else {
            DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
            AppModel.log.error("display: no Screen Recording permission")
            return
        }
        lock.withLock { self.displayID = displayID }
        Task.detached(priority: .userInitiated) { [self] in
            // A new virtual display takes a moment to show up in the shareable content.
            var target: SCDisplay?
            for _ in 0..<20 {
                if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                   let display = content.displays.first(where: { $0.displayID == displayID }) {
                    target = display
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let target, lock.withLock({ self.displayID == displayID }) else {
                AppModel.log.error("display: \(displayID) not found for capture")
                return
            }
            let width = Int(pixels.width) & ~1, height = Int(pixels.height) & ~1
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = true
            configuration.queueDepth = 4
            configuration.capturesAudio = false
            let filter = SCContentFilter(display: target, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                guard makeEncoder(width: width, height: height) else { return }
                try await stream.startCapture()
                lock.withLock { self.stream = stream; forceKey = true; statsStart = CFAbsoluteTimeGetCurrent() }
                send?(.displayStart(DisplayStreamInfo(width: width, height: height, scale: Double(PhoneDisplay.scale))))
                AppModel.log.info("display: streaming \(width)×\(height)")
            } catch {
                AppModel.log.error("display: capture failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        let (stream, session) = lock.withLock {
            defer { self.stream = nil; self.session = nil; displayID = nil; inFlight = 0 }
            return (self.stream, self.session)
        }
        if let stream { Task { try? await stream.stopCapture() } }
        if let session {
            queue.async {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
        }
        if stream != nil { send?(.displayStop) }
    }

    /// The phone's decoder asked for a fresh start.
    func requestKeyframe() {
        lock.withLock { forceKey = true }
    }

    // MARK: - Encoder

    private func makeEncoder(width: Int, height: Int) -> Bool {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            AppModel.log.error("display: encoder failed \(status)")
            return false
        }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
            kVTCompressionPropertyKey_AverageBitRate: 8_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
        ]
        for (key, value) in properties { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
        lock.withLock { self.session = session }
        return true
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer),
              let image = sampleBuffer.imageBuffer else { return }
        let (session, key, busy) = lock.withLock { () -> (VTCompressionSession?, Bool, Bool) in
            let busy = inFlight >= 2 && !forceKey
            if !busy { inFlight += 1 }
            let key = forceKey
            if !busy { forceKey = false }
            return (self.session, key, busy)
        }
        guard let session, !busy else { return }
        let options = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                                        duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard let self else { return }
            defer { lock.withLock { self.inFlight = max(0, self.inFlight - 1) } }
            guard status == noErr, let encoded, let (data, isKey) = Self.annexB(encoded) else { return }
            send?(.displayFrame(data: data, key: isKey))
            logRate(data.count)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppModel.log.error("display: stream stopped \(error.localizedDescription, privacy: .public)")
        lock.withLock { if self.stream === stream { self.stream = nil } }
    }

    private func logRate(_ size: Int) {
        let line: String? = lock.withLock {
            frames += 1
            bytes += size
            let elapsed = CFAbsoluteTimeGetCurrent() - statsStart
            guard elapsed >= 5 else { return nil }
            defer { frames = 0; bytes = 0; statsStart = CFAbsoluteTimeGetCurrent() }
            return String(format: "%.0f fps, %.1f Mbit/s", Double(frames) / elapsed, Double(bytes) * 8 / elapsed / 1_000_000)
        }
        if let line { AppModel.log.info("display: \(line, privacy: .public)") }
    }

    /// ScreenCaptureKit also delivers "idle" buffers when nothing changed; only complete frames carry a picture.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// AVCC sample → Annex B (start codes), with SPS and PPS in front of a key frame.
    private static func annexB(_ buffer: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = buffer.dataBuffer else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if isKey, let format = buffer.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        var offset = 0
        pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            while offset + 4 <= length {
                let nal = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
                offset += 4
                guard nal > 0, offset + nal <= length else { break }
                out.append(contentsOf: startCode)
                out.append(bytes + offset, count: nal)
                offset += nal
            }
        }
        return (out, isKey)
    }
}
