#if DEBUG
import AVFoundation
import ScreenCaptureKit

/// Records one window of this app to a movie (the README's tour video): ScreenCaptureKit captures the window's own
/// pixels, so it can sit behind other windows, and AVAssetWriter encodes H.264.
final class TourRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private let queue = DispatchQueue(label: "tour-recorder")

    func start(windowNumber: Int, size: CGSize, to url: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == CGWindowID(windowNumber) }) else {
            throw CocoaError(.featureUnsupported)
        }
        let config = SCStreamConfiguration()
        config.width = Int(size.width * 2)
        config.height = Int(size.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 8
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        self.writer = writer
        self.input = input
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let writer, let input,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete
        else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }

    func stop() async {
        try? await stream?.stopCapture()
        queue.sync {}
        input?.markAsFinished()
        await writer?.finishWriting()
    }
}
#endif
