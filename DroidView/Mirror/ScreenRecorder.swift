import AVFoundation
import CoreMedia

/// Gravação de tela sem re-encode: o próprio stream H.265/H.264 vindo do
/// dispositivo é gravado em .mp4 (qualidade idêntica à exibida, custo de CPU ~zero).
final class ScreenRecorder: @unchecked Sendable {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let queue = DispatchQueue(label: "droidview.recorder")
    private var startPTS: Int64?
    private var lastVideoTime: CMTime = .zero
    private var finished = false

    init(url: URL, format: CMVideoFormatDescription) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)
    }

    var hasStarted: Bool { queue.sync { startPTS != nil } }

    /// Só começa a gravar em um keyframe.
    func append(video frame: EncodedFrame) {
        queue.async { [self] in
            guard !finished else { return }
            if startPTS == nil {
                guard frame.isKeyFrame else { return }
                guard writer.startWriting() else {
                    NSLog("DroidView: gravação falhou: \(String(describing: writer.error))")
                    finished = true
                    return
                }
                writer.startSession(atSourceTime: .zero)
                startPTS = frame.pts
            }
            guard let start = startPTS, videoInput.isReadyForMoreMediaData else { return }
            let time = CMTime(value: frame.pts - start, timescale: 1_000_000)
            guard time > lastVideoTime || lastVideoTime == .zero else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
            var retimed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: frame.sampleBuffer,
                                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                  sampleBufferOut: &retimed)
            if let retimed, videoInput.append(retimed) { lastVideoTime = time }
        }
    }

    func finish() async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                guard !finished, startPTS != nil, writer.status == .writing else {
                    finished = true
                    writer.cancelWriting()
                    cont.resume(returning: nil)
                    return
                }
                finished = true
                videoInput.markAsFinished()
                writer.endSession(atSourceTime: lastVideoTime)
                writer.finishWriting { [writer, url] in
                    cont.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }
}
