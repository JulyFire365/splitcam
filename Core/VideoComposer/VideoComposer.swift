import AVFoundation
import CoreImage
import UIKit

// MARK: - Custom Video Compositing

/// 自定义合成指令 — 存储分屏目标区域和轨道 ID
class SplitScreenInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    nonisolated(unsafe) let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackIDA: CMPersistentTrackID
    let trackIDB: CMPersistentTrackID
    let rectA: CGRect
    let rectB: CGRect
    let outputSize: CGSize
    let isPip: Bool
    let pipShape: PipShape

    init(timeRange: CMTimeRange,
         trackIDA: CMPersistentTrackID,
         trackIDB: CMPersistentTrackID,
         rectA: CGRect,
         rectB: CGRect,
         outputSize: CGSize,
         isPip: Bool = false,
         pipShape: PipShape = .roundedRect) {
        self.timeRange = timeRange
        self.trackIDA = trackIDA
        self.trackIDB = trackIDB
        self.rectA = rectA
        self.rectB = rectB
        self.outputSize = outputSize
        self.isPip = isPip
        self.pipShape = pipShape
        self.requiredSourceTrackIDs = [
            NSNumber(value: trackIDA),
            NSNumber(value: trackIDB)
        ]
        super.init()
    }
}

/// 自定义视频合成器 — 使用 CIImage 逐帧渲染分屏画面（含裁切）
class SplitScreenCompositor: NSObject, @preconcurrency AVVideoCompositing, @unchecked Sendable {
    nonisolated var sourcePixelBufferAttributes: [String: Any]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: Any] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? SplitScreenInstruction else {
            request.finish(with: NSError(domain: "SplitScreen", code: -1))
            return
        }

        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "SplitScreen", code: -2))
            return
        }

        let outputSize = instruction.outputSize

        // Start with black background
        var composite = CIImage(color: .black)
            .cropped(to: CGRect(origin: .zero, size: outputSize))

        // Render video A into its target rect
        if let bufferA = request.sourceFrame(byTrackID: instruction.trackIDA) {
            let imageA = CIImage(cvPixelBuffer: bufferA)
            let fittedA = fitAndClip(imageA, into: instruction.rectA, outputHeight: outputSize.height)
            composite = fittedA.composited(over: composite)
        }

        // Render video B into its target rect
        if let bufferB = request.sourceFrame(byTrackID: instruction.trackIDB) {
            let imageB = CIImage(cvPixelBuffer: bufferB)
            let fittedB = fitAndClip(imageB, into: instruction.rectB, outputHeight: outputSize.height)

            if instruction.isPip {
                // PiP: 用圆角/圆形遮罩裁切小窗口
                let masked = applyPipMask(fittedB, rect: instruction.rectB,
                                          shape: instruction.pipShape, outputHeight: outputSize.height)
                composite = masked.composited(over: composite)
            } else {
                composite = fittedB.composited(over: composite)
            }
        }

        ciContext.render(composite, to: outputBuffer)
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    func cancelAllPendingVideoCompositionRequests() {}

    /// 将图像缩放填充目标区域并裁切（aspect fill + clip）
    /// targetRect 使用 UIKit 坐标系（左上角原点），内部转换为 CIImage 坐标系（左下角原点）
    private func fitAndClip(_ image: CIImage, into targetRect: CGRect, outputHeight: CGFloat) -> CIImage {
        let imageSize = image.extent.size

        // Aspect fill
        let scaleX = targetRect.width / imageSize.width
        let scaleY = targetRect.height / imageSize.height
        let scale = max(scaleX, scaleY)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Convert from UIKit coords (top-left origin) to CIImage coords (bottom-left origin)
        let ciTargetY = outputHeight - targetRect.origin.y - targetRect.height
        let ciTargetRect = CGRect(
            x: targetRect.origin.x,
            y: ciTargetY,
            width: targetRect.width,
            height: targetRect.height
        )

        // Center the scaled image within the CI target rect
        let offsetX = ciTargetRect.origin.x + (ciTargetRect.width - scaledWidth) / 2
        let offsetY = ciTargetRect.origin.y + (ciTargetRect.height - scaledHeight) / 2

        let result = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: ciTargetRect)

        return result
    }

    /// 为画中画小窗口应用圆角矩形或圆形遮罩
    /// 使用 CGContext（线程安全）创建遮罩，白色区域显示 PiP 内容
    private func applyPipMask(_ image: CIImage, rect: CGRect, shape: PipShape, outputHeight: CGFloat) -> CIImage {
        let ciY = outputHeight - rect.origin.y - rect.height
        let ciRect = CGRect(x: rect.origin.x, y: ciY, width: rect.width, height: rect.height)

        let maskWidth = Int(rect.width)
        let maskHeight = Int(rect.height)
        guard maskWidth > 0, maskHeight > 0 else { return image }

        // 用 CGContext 创建遮罩（线程安全，不依赖 UIGraphicsImageRenderer）
        guard let context = CGContext(
            data: nil,
            width: maskWidth,
            height: maskHeight,
            bitsPerComponent: 8,
            bytesPerRow: maskWidth * 4,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return image }

        // 背景黑色（透明区域）
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight))

        // 白色填充形状区域（CIBlendWithMask 中白色 = 显示前景）
        context.setFillColor(gray: 1, alpha: 1)
        if shape == .circle {
            let size = min(CGFloat(maskWidth), CGFloat(maskHeight))
            let circleRect = CGRect(
                x: (CGFloat(maskWidth) - size) / 2,
                y: (CGFloat(maskHeight) - size) / 2,
                width: size,
                height: size
            )
            context.fillEllipse(in: circleRect)
        } else {
            let cornerRadius: CGFloat = 12
            let maskRect = CGRect(x: 0, y: 0, width: maskWidth, height: maskHeight)
            let path = CGPath(roundedRect: maskRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(path)
            context.fillPath()
        }

        guard let maskCGImage = context.makeImage() else { return image }

        // CIImage 坐标系：原点左下角，CGContext 生成的图像原点也是左下角，无需翻转
        let maskCI = CIImage(cgImage: maskCGImage)
            .transformed(by: CGAffineTransform(translationX: ciRect.origin.x, y: ciRect.origin.y))

        // CIBlendWithMask: 白色=前景(PiP), 黑色=背景(透明)
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return image }
        let transparent = CIImage(color: .clear).cropped(to: image.extent)
        blendFilter.setValue(image, forKey: kCIInputImageKey)
        blendFilter.setValue(transparent, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)

        return blendFilter.outputImage ?? image
    }
}

// MARK: - Video Composer

/// 视频合成引擎 — 将两路视频合成为分屏视频并导出
@MainActor
final class VideoComposer: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false
    @Published var error: ComposerError?

    private var exportSession: AVAssetExportSession?

    // MARK: - Public API

    func compose(
        videoA: URL,
        videoB: URL,
        splitMode: SplitMode,
        splitRatio: CGFloat,
        borderStyle: BorderStyleConfig,
        outputSize: CGSize,
        pipRect: CGRect? = nil,
        pipShape: PipShape = .roundedRect,
        completion: @escaping (Result<URL, ComposerError>) -> Void
    ) {
        Task {
            await MainActor.run {
                self.isExporting = true
                self.progress = 0
            }

            do {
                let outputURL = try await performComposition(
                    videoA: videoA,
                    videoB: videoB,
                    splitMode: splitMode,
                    splitRatio: splitRatio,
                    borderStyle: borderStyle,
                    outputSize: outputSize,
                    pipRect: pipRect,
                    pipShape: pipShape
                )
                await MainActor.run {
                    self.isExporting = false
                    self.progress = 1.0
                }
                completion(.success(outputURL))
            } catch let error as ComposerError {
                await MainActor.run {
                    self.isExporting = false
                    self.error = error
                }
                completion(.failure(error))
            } catch {
                let composerError = ComposerError.exportFailed(error.localizedDescription)
                await MainActor.run {
                    self.isExporting = false
                    self.error = composerError
                }
                completion(.failure(composerError))
            }
        }
    }

    func cancelExport() {
        exportSession?.cancelExport()
        isExporting = false
    }

    // MARK: - Composition Logic

    private func performComposition(
        videoA: URL,
        videoB: URL,
        splitMode: SplitMode,
        splitRatio: CGFloat,
        borderStyle: BorderStyleConfig,
        outputSize: CGSize,
        pipRect: CGRect? = nil,
        pipShape: PipShape = .roundedRect
    ) async throws -> URL {
        let assetA = AVURLAsset(url: videoA)
        let assetB = AVURLAsset(url: videoB)

        let tracksA = try await assetA.loadTracks(withMediaType: .video)
        let tracksB = try await assetB.loadTracks(withMediaType: .video)

        guard let videoTrackA = tracksA.first, let videoTrackB = tracksB.first else {
            throw ComposerError.invalidInput("无法读取视频轨道")
        }

        let durationA = try await assetA.load(.duration)
        let durationB = try await assetB.load(.duration)
        let duration = min(durationA, durationB)

        // Create composition
        let composition = AVMutableComposition()

        guard let compTrackA = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compTrackB = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ComposerError.compositionFailed
        }

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compTrackA.insertTimeRange(timeRange, of: videoTrackA, at: .zero)
        try compTrackB.insertTimeRange(timeRange, of: videoTrackB, at: .zero)

        // Add audio
        let audioTracksA = try await assetA.loadTracks(withMediaType: .audio)
        if let audioTrackA = audioTracksA.first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudioTrack.insertTimeRange(timeRange, of: audioTrackA, at: .zero)
        }

        // Calculate target rects
        let isPip = splitMode == .pip
        let rectA: CGRect
        let rectB: CGRect

        if isPip, let pipRect = pipRect {
            rectA = CGRect(origin: .zero, size: outputSize)
            rectB = pipRect
        } else {
            let frames = calculateFrames(
                splitMode: splitMode,
                splitRatio: splitRatio,
                outputSize: outputSize,
                borderWidth: borderStyle.style != .none ? borderStyle.width : 0
            )
            rectA = frames.first
            rectB = frames.second
        }

        // Build video composition with custom compositor
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.customVideoCompositorClass = SplitScreenCompositor.self

        let instruction = SplitScreenInstruction(
            timeRange: timeRange,
            trackIDA: compTrackA.trackID,
            trackIDB: compTrackB.trackID,
            rectA: rectA,
            rectB: rectB,
            outputSize: outputSize,
            isPip: isPip,
            pipShape: pipShape
        )
        videoComposition.instructions = [instruction]

        // Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitcam_output_\(UUID().uuidString).mp4")

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ComposerError.exportFailed("无法创建导出会话")
        }

        session.videoComposition = videoComposition
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        self.exportSession = session

        let progressTask = Task {
            while !Task.isCancelled {
                let currentProgress = session.progress
                await MainActor.run { self.progress = Double(currentProgress) }
                if currentProgress >= 1.0 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await session.export()
        progressTask.cancel()

        if let error = session.error {
            throw ComposerError.exportFailed(error.localizedDescription)
        }

        guard session.status == .completed else {
            throw ComposerError.exportFailed("导出状态异常: \(session.status.rawValue)")
        }

        return outputURL
    }

    // MARK: - Frame Calculation

    private func calculateFrames(
        splitMode: SplitMode,
        splitRatio: CGFloat,
        outputSize: CGSize,
        borderWidth: CGFloat
    ) -> (first: CGRect, second: CGRect) {
        switch splitMode {
        case .leftRight:
            let firstWidth = outputSize.width * splitRatio - borderWidth / 2
            let secondX = outputSize.width * splitRatio + borderWidth / 2
            let secondWidth = outputSize.width - secondX
            return (
                CGRect(x: 0, y: 0, width: firstWidth, height: outputSize.height),
                CGRect(x: secondX, y: 0, width: secondWidth, height: outputSize.height)
            )
        case .topBottom:
            let firstHeight = outputSize.height * splitRatio - borderWidth / 2
            let secondY = outputSize.height * splitRatio + borderWidth / 2
            let secondHeight = outputSize.height - secondY
            return (
                CGRect(x: 0, y: 0, width: outputSize.width, height: firstHeight),
                CGRect(x: 0, y: secondY, width: outputSize.width, height: secondHeight)
            )
        case .pip:
            return (CGRect(origin: .zero, size: outputSize), .zero)
        }
    }
}

// MARK: - Supporting Types

enum ExportResolution: String, CaseIterable, Identifiable {
    case hd720p = "720p"
    case hd1080p = "1080p"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .hd720p: return CGSize(width: 1280, height: 720)
        case .hd1080p: return CGSize(width: 1920, height: 1080)
        }
    }

    var exportPreset: String {
        switch self {
        case .hd720p: return AVAssetExportPreset1280x720
        case .hd1080p: return AVAssetExportPreset1920x1080
        }
    }
}

enum ComposerError: Error, LocalizedError {
    case invalidInput(String)
    case compositionFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "输入无效：\(msg)"
        case .compositionFailed: return "视频合成失败"
        case .exportFailed(let msg): return "导出失败：\(msg)"
        }
    }
}
