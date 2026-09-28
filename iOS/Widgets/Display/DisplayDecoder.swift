import AVFoundation
import CoreMedia
import QwoviKit

/// The Mac's virtual display arrives as H.264 access units (Annex B). They go straight to an
/// `AVSampleBufferDisplayLayer`, which decodes in hardware and shows each frame at once — no SwiftUI state
/// changes per frame. Until a key frame (with SPS and PPS) arrives nothing can be shown, so the decoder asks for one.
@MainActor
final class DisplayDecoder {
    /// Asks the Mac for a key frame.
    var requestKeyframe: (() -> Void)?

    private(set) var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private var lastAsk = Date.distantPast

    /// The view showing the stream (or nil when it went away).
    func attach(_ layer: AVSampleBufferDisplayLayer?) {
        self.layer = layer
        reset()
    }

    /// A new stream: forget the old parameter sets.
    func reset() {
        format = nil
        waitingForKey = true
        layer?.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        askForKey()
    }

    func decode(_ data: Data, key: Bool) {
        guard let layer else { return }
        if layer.sampleBufferRenderer.status == .failed {
            layer.sampleBufferRenderer.flush()
            waitingForKey = true
        }
        if waitingForKey && !key { askForKey(); return }

        var nalUnits: [Data] = []
        for nal in Self.split(data) {
            guard let header = nal.first else { continue }
            switch header & 0x1F {
            case 7, 8: continue // parameter sets, read below
            default: nalUnits.append(nal)
            }
        }
        if key {
            let sets = Self.split(data).filter { [7, 8].contains(($0.first ?? 0) & 0x1F) }
            if let sps = sets.first(where: { $0.first! & 0x1F == 7 }), let pps = sets.first(where: { $0.first! & 0x1F == 8 }) {
                format = Self.formatDescription(sps: sps, pps: pps) ?? format
            }
        }
        guard let format, !nalUnits.isEmpty, let sample = Self.sample(nalUnits, format: format) else { return }
        waitingForKey = false
        layer.sampleBufferRenderer.enqueue(sample)
    }

    private func askForKey() {
        guard Date().timeIntervalSince(lastAsk) > 0.5 else { return }
        lastAsk = Date()
        requestKeyframe?()
    }

    /// Splits Annex B data at its 3- or 4-byte start codes.
    private static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count { units.append(Data(bytes[s...])) }
        return units
    }

    private static func formatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBuffer in
            pps.withUnsafeBytes { ppsBuffer in
                let pointers = [spsBuffer.bindMemory(to: UInt8.self).baseAddress!, ppsBuffer.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// NAL units → one AVCC (length-prefixed) sample, shown as soon as it is decoded.
    private static func sample(_ units: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        for unit in units {
            var length = UInt32(unit.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
