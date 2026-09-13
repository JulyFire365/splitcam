import AVFoundation
import CoreImage
import Metal
import OSLog

/// The queue is the sole owner of every writer/input and its lifecycle. Capture
/// callbacks use synchronous submissions, so slow rendering cannot build up an
/// unbounded queue of camera buffers. No work on this queue waits for the UI.
final class VideoRecordingSession: @unchecked Sendable {
    enum Failure: Error {
        case busy
        case noVideoFrames
        case encoding(stage: String, underlying: Error?)
    }

    private final class Context: @unchecked Sendable {
        let id = UUID()
        let url: URL
        let size: CGSize
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let onFailure: (UUID) -> Void
        var finishing = false
        var startTime: CMTime?
        var lastVideoTime: CMTime?
        var lastAudioTime: CMTime?
        var videoFrames = 0
        var failure: Failure?

        init(url: URL, size: CGSize, settings: [String: Any], onFailure: @escaping (UUID) -> Void) throws {
            self.url = url
            self.size = size
            self.onFailure = onFailure
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            video.expectsMediaDataInRealTime = true
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ])
            audio.expectsMediaDataInRealTime = true
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
            guard writer.canAdd(video), writer.canAdd(audio) else {
                throw Failure.encoding(stage: "configure-inputs", underlying: writer.error)
            }
            writer.add(video)
            writer.add(audio)
            guard writer.startWriting() else {
                throw Failure.encoding(stage: "start-writing", underlying: writer.error)
            }
        }
    }

    private let queue = DispatchQueue(label: "com.splitcam.recording.writer", qos: .userInitiated)
    private var context: Context?
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.priorityRequestLow: false])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    func start(url: URL, fullSize: CGSize, quality: ResolutionQuality,
               onFailure: @escaping (UUID) -> Void) throws -> UUID {
        try queue.sync {
            guard context == nil else { throw Failure.busy }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.encoding(stage: "output-already-exists", underlying: CocoaError(.fileWriteFileExists))
            }
            do {
                let next = try Context(url: url, size: quality.outputSize(for: fullSize),
                                       settings: quality.videoOutputSettings(for: fullSize), onFailure: onFailure)
                context = next
                return next.id
            } catch {
                VideoSaveDiagnostics.record("writer-start", error: error)
                // This unique output belongs to this failed start, never an older recording.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    @discardableResult
    func appendVideo(at timestamp: CMTime, render: (CGSize) -> CIImage?) -> Bool {
        queue.sync {
            guard let current = context, !current.finishing, current.failure == nil else { return false }
            guard current.writer.status == .writing else {
                fail(current, stage: "video-writer-state", error: current.writer.error)
                return false
            }
            guard timestamp.isNumeric, timestamp >= .zero,
                  current.lastVideoTime.map({ timestamp > $0 }) ?? true,
                  current.video.isReadyForMoreMediaData,
                  let image = render(current.size) else { return false }

            if current.startTime == nil {
                current.writer.startSession(atSourceTime: timestamp)
                current.startTime = timestamp
            }
            guard let pool = current.adaptor.pixelBufferPool else {
                fail(current, stage: "pixel-buffer-pool", error: current.writer.error)
                return false
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard status == kCVReturnSuccess, let buffer else {
                fail(current, stage: "pixel-buffer-allocation", error: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
                return false
            }
            ciContext.render(image, to: buffer)
            guard current.adaptor.append(buffer, withPresentationTime: timestamp) else {
                fail(current, stage: "append-video", error: current.writer.error)
                return false
            }
            current.videoFrames += 1
            current.lastVideoTime = timestamp
            return true
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.sync {
            guard let current = context, !current.finishing, current.failure == nil,
                  current.videoFrames > 0, let start = current.startTime else { return }
            guard current.writer.status == .writing else {
                fail(current, stage: "audio-writer-state", error: current.writer.error)
                return
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            // Buffered audio can precede the first accepted video frame on cold start.
            guard timestamp.isNumeric, timestamp >= start,
                  current.lastAudioTime.map({ timestamp > $0 }) ?? true,
                  CMSampleBufferDataIsReady(sample), current.audio.isReadyForMoreMediaData else { return }
            guard current.audio.append(sample) else {
                fail(current, stage: "append-audio", error: current.writer.error)
                return
            }
            current.lastAudioTime = timestamp
        }
    }

    /// Serializes after every in-flight append, then closes the gate before
    /// markAsFinished/finishWriting. Late callbacks cannot append to this writer.
    func finish(id: UUID, completion: @escaping (Result<URL, Failure>) -> Void) {
        queue.async {
            guard let current = self.context, current.id == id, !current.finishing else {
                completion(.failure(.busy))
                return
            }
            current.finishing = true
            if let error = current.failure {
                self.cancelFailed(current, error: error, completion: completion)
                return
            }
            guard current.videoFrames > 0, let last = current.lastVideoTime else {
                self.cancelFailed(current, error: .noVideoFrames, completion: completion)
                return
            }
            guard current.writer.status == .writing else {
                self.cancelFailed(current, error: .encoding(stage: "finish-state", underlying: current.writer.error), completion: completion)
                return
            }
            // Even a single accepted frame needs a positive duration for Photos.
            current.writer.endSession(atSourceTime: last + CMTime(value: 1, timescale: 30))
            current.video.markAsFinished()
            current.audio.markAsFinished()
            current.writer.finishWriting {
                self.queue.async {
                    // Inspect the captured writer, never whichever one is current later.
                    let result: Result<URL, Failure>
                    if current.writer.status == .completed {
                        result = .success(current.url)
                    } else {
                        let error = Failure.encoding(stage: "finish-writing", underlying: current.writer.error)
                        VideoSaveDiagnostics.record("finish-writing", error: current.writer.error, frames: current.videoFrames)
                        try? FileManager.default.removeItem(at: current.url)
                        result = .failure(error)
                    }
                    if self.context === current { self.context = nil }
                    completion(result)
                }
            }
        }
    }

    private func fail(_ current: Context, stage: String, error: Error?) {
        guard current.failure == nil else { return }
        current.failure = .encoding(stage: stage, underlying: error)
        VideoSaveDiagnostics.record(stage, error: error, frames: current.videoFrames)
        // Notification only; the owner stops through the same serialized finish API.
        current.onFailure(current.id)
    }

    private func cancelFailed(_ current: Context, error: Failure,
                              completion: (Result<URL, Failure>) -> Void) {
        if current.writer.status == .writing { current.writer.cancelWriting() }
        VideoSaveDiagnostics.record("recording-cancelled", error: error, frames: current.videoFrames)
        try? FileManager.default.removeItem(at: current.url)
        if context === current { context = nil }
        completion(.failure(error))
    }
}

enum VideoSaveDiagnostics {
    private static let logger = Logger(subsystem: "com.flinter.splitcam", category: "VideoSave")

    /// No media, filenames, URLs or NSError userInfo are logged.
    static func record(_ stage: String, error: Error? = nil, frames: Int = 0) {
        var codes: [String] = []
        var underlying = error as NSError?
        for _ in 0..<4 {
            guard let current = underlying else { break }
            codes.append("\(current.domain):\(current.code)")
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        logger.error("stage=\(stage, privacy: .public) frames=\(frames) errors=\(codes.joined(separator: "/"), privacy: .public)")
    }
}
