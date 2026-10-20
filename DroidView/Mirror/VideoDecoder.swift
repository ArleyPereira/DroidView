import Foundation
import CoreMedia
import VideoToolbox

enum VideoCodec: String, CaseIterable, Identifiable, Codable, Sendable {
    case h265, h264
    var id: String { rawValue }
    var label: String { self == .h265 ? "H.265 (HEVC)" : "H.264 (AVC)" }

    init?(scrcpyCodecID: UInt32) {
        switch scrcpyCodecID {
        case 0x6832_3634: self = .h264
        case 0x6832_3635: self = .h265
        default: return nil
        }
    }
}

/// Utilitários de bitstream H.264/H.265.
enum NALUnits {
    /// Separa um bitstream Annex B (start codes 00 00 01 / 00 00 00 01) em NAL units.
    static func split(_ data: Data) -> [Data] {
        var units: [Data] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            let n = p.count
            var i = 0
            var start = -1
            while i + 2 < n {
                if p[i] == 0, p[i + 1] == 0, p[i + 2] == 1 {
                    if start >= 0 {
                        var end = i
                        if end > start, p[end - 1] == 0 { end -= 1 } // start code de 4 bytes
                        if end > start { units.append(Data(bytes: raw.baseAddress! + start, count: end - start)) }
                    }
                    i += 3
                    start = i
                } else {
                    i += 1
                }
            }
            if start >= 0, start < n {
                units.append(Data(bytes: raw.baseAddress! + start, count: n - start))
            } else if start < 0, n > 0 {
                units.append(Data(bytes: raw.baseAddress!, count: n)) // sem start code
            }
        }
        return units
    }

    static func type(of nal: Data, codec: VideoCodec) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return codec == .h264 ? first & 0x1F : (first >> 1) & 0x3F
    }

    static func isParameterSet(_ nal: Data, codec: VideoCodec) -> Bool {
        let t = type(of: nal, codec: codec)
        return codec == .h264 ? (t == 7 || t == 8) : (t >= 32 && t <= 34)
    }

    static func makeFormatDescription(from nals: [Data], codec: VideoCodec) -> CMVideoFormatDescription? {
        let sets: [Data]
        switch codec {
        case .h264:
            let sps = nals.first { type(of: $0, codec: codec) == 7 }
            let pps = nals.first { type(of: $0, codec: codec) == 8 }
            guard let sps, let pps else { return nil }
            sets = [sps, pps]
        case .h265:
            let vps = nals.first { type(of: $0, codec: codec) == 32 }
            let sps = nals.first { type(of: $0, codec: codec) == 33 }
            let pps = nals.first { type(of: $0, codec: codec) == 34 }
            guard let vps, let sps, let pps else { return nil }
            sets = [vps, sps, pps]
        }

        // Mantém os buffers vivos durante a chamada.
        let buffers = sets.map { [UInt8]($0) }
        var format: CMVideoFormatDescription?
        let status: OSStatus = buffers[0].withUnsafeBufferPointer { b0 in
            buffers[1].withUnsafeBufferPointer { b1 in
                if codec == .h264 {
                    let ptrs = [b0.baseAddress!, b1.baseAddress!]
                    let sizes = [b0.count, b1.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
                return buffers[2].withUnsafeBufferPointer { b2 in
                    let ptrs = [b0.baseAddress!, b1.baseAddress!, b2.baseAddress!]
                    let sizes = [b0.count, b1.count, b2.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }

    /// Converte NAL units para o formato AVCC/HVCC (prefixo de 4 bytes com o tamanho).
    static func lengthPrefixed(_ nals: [Data]) -> Data {
        var out = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for nal in nals {
            out.appendBE(UInt32(nal.count))
            out.append(nal)
        }
        return out
    }
}

struct EncodedFrame: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let isKeyFrame: Bool
    let pts: Int64
}

/// Decodificador por hardware (VideoToolbox). Recebe pacotes do scrcpy e entrega
/// CVPixelBuffers prontos para exibição.
final class VideoDecoder: @unchecked Sendable {
    let codec: VideoCodec
    private(set) var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    /// Pixel buffer decodificado + PTS (µs).
    var onFrame: ((CVPixelBuffer, Int64) -> Void)?
    /// Amostra comprimida (AVCC), usada pela gravação sem re-encode.
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    var onFormatChange: ((CMVideoFormatDescription) -> Void)?

    init(codec: VideoCodec) {
        self.codec = codec
    }

    deinit { invalidate() }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    func handle(packet: Data, isConfig: Bool, isKeyFrame: Bool, pts: Int64) {
        let nals = NALUnits.split(packet)
        let paramSets = nals.filter { NALUnits.isParameterSet($0, codec: codec) }
        if !paramSets.isEmpty {
            updateFormat(with: paramSets)
        }
        if isConfig { return }

        let frameNALs = nals.filter { !NALUnits.isParameterSet($0, codec: codec) }
        guard !frameNALs.isEmpty, let format = formatDescription else { return }
        guard let sample = makeSampleBuffer(NALUnits.lengthPrefixed(frameNALs), format: format, pts: pts, isKeyFrame: isKeyFrame) else { return }

        onEncodedFrame?(EncodedFrame(sampleBuffer: sample, isKeyFrame: isKeyFrame, pts: pts))
        decode(sample, pts: pts)
    }

    private func updateFormat(with paramSets: [Data]) {
        guard let newFormat = NALUnits.makeFormatDescription(from: paramSets, codec: codec) else { return }
        if let current = formatDescription, CMFormatDescriptionEqual(current, otherFormatDescription: newFormat) {
            return
        }
        formatDescription = newFormat
        invalidate()
        createSession(format: newFormat)
        onFormatChange?(newFormat)
    }

    private func createSession(format: CMVideoFormatDescription) {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            NSLog("DroidView: VTDecompressionSessionCreate falhou: \(status)")
            return
        }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
    }

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription, pts: Int64, isKeyFrame: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sizes = [length]
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        if !isKeyFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func decode(_ sample: CMSampleBuffer, pts: Int64) {
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._1xRealTimePlayback], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onFrame?(imageBuffer, pts)
        }
        if status == kVTInvalidSessionErr, let format = formatDescription {
            // Acontece após o Mac dormir: recria a sessão e segue.
            invalidate()
            createSession(format: format)
        }
    }
}
