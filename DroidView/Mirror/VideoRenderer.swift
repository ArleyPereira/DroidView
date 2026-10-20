import AVFoundation
import CoreImage
import QuartzCore

/// Exibe os frames decodificados num AVSampleBufferDisplayLayer (composição
/// direta pelo WindowServer, sem cópias e sem passar por WebGL como no Vysor).
final class VideoRenderer: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        return l
    }()

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var cachedFormat: CMVideoFormatDescription?
    private var cachedSize: (Int, Int) = (0, 0)

    var frameSize: CGSize {
        lock.lock(); defer { lock.unlock() }
        return CGSize(width: cachedSize.0, height: cachedSize.1)
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        latest = pixelBuffer
        if cachedFormat == nil || cachedSize != (w, h) {
            var fmt: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
            cachedFormat = fmt
            cachedSize = (w, h)
        }
        let format = cachedFormat
        lock.unlock()

        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        lock.lock(); latest = nil; lock.unlock()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// Frame atual como CGImage (fallback de screenshot quando o screencap não está disponível).
    func snapshot() -> CGImage? {
        lock.lock(); let pb = latest; lock.unlock()
        guard let pb else { return nil }
        let image = CIImage(cvPixelBuffer: pb)
        return CIContext().createCGImage(image, from: image.extent)
    }
}
