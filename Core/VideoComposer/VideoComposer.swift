import AVFoundation
import CoreImage
import UIKit

/// 视频合成引擎 — 将两路视频合成为分屏视频并导出
@MainActor
final class VideoComposer: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false
    @Published var error: ComposerError?

    private var exportSession: AVAssetExportSession?

    // MARK: - Public API

    /// 合成两个视频为分屏视频
    func compose(
        videoA: URL,
        videoB: URL,
        splitMode: SplitMode,
        splitRatio: CGFloat,
        borderStyle: BorderStyleConfig,
        outputSize: CGSize,
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
                    outputSize: outputSize
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
        outputSize: CGSize
    ) async throws -> URL {
        let assetA = AVURLAsset(url: videoA)
        let assetB = AVURLAsset(url: videoB)

        // Load tracks
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

        // Add audio from first video
        let audioTracksA = try await assetA.loadTracks(withMediaType: .audio)
        if let audioTrackA = audioTracksA.first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudioTrack.insertTimeRange(timeRange, of: audioTrackA, at: .zero)
        }

        // Calculate frames for each video
        let frames = calculateFrames(
            splitMode: splitMode,
            splitRatio: splitRatio,
            outputSize: outputSize,
            borderWidth: borderStyle.width
        )

        // Build video composition
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = outputSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.backgroundColor = UIColor(borderStyle.color).cgColor

        // Layer instruction A
        let layerInstructionA = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrackA)
        let transformA = try await makeTransform(
            for: videoTrackA,
            targetRect: frames.first,
            outputSize: outputSize
        )
        layerInstructionA.setTransform(transformA, at: .zero)

        // Layer instruction B
        let layerInstructionB = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrackB)
        let transformB = try await makeTransform(
            for: videoTrackB,
            targetRect: frames.second,
            outputSize: outputSize
        )
        layerInstructionB.setTransform(transformB, at: .zero)

        instruction.layerInstructions = [layerInstructionA, layerInstructionB]
        videoComposition.instructions = [instruction]

        // Add border overlay layer if needed
        if borderStyle.style != .none {
            addBorderOverlay(
                to: videoComposition,
                splitMode: splitMode,
                splitRatio: splitRatio,
                borderStyle: borderStyle,
                outputSize: outputSize,
                duration: duration,
                composition: composition
            )
        }

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

        // Monitor progress in a separate task
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
        }
    }

    // MARK: - Transform

    private func makeTransform(
        for track: AVAssetTrack,
        targetRect: CGRect,
        outputSize: CGSize
    ) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)

        // Apply the track's preferred transform to get actual dimensions
        let transformedSize = naturalSize.applying(preferredTransform)
        let actualWidth = abs(transformedSize.width)
        let actualHeight = abs(transformedSize.height)

        // Scale to fill the target rect (aspect fill)
        let scaleX = targetRect.width / actualWidth
        let scaleY = targetRect.height / actualHeight
        let scale = max(scaleX, scaleY)

        // Center in target rect
        let scaledWidth = actualWidth * scale
        let scaledHeight = actualHeight * scale
        let offsetX = targetRect.origin.x + (targetRect.width - scaledWidth) / 2
        let offsetY = targetRect.origin.y + (targetRect.height - scaledHeight) / 2

        let transform = preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))

        return transform
    }

    // MARK: - Border Overlay

    private func addBorderOverlay(
        to videoComposition: AVMutableVideoComposition,
        splitMode: SplitMode,
        splitRatio: CGFloat,
        borderStyle: BorderStyleConfig,
        outputSize: CGSize,
        duration: CMTime,
        composition: AVMutableComposition
    ) {
        let overlayLayer = CALayer()
        overlayLayer.frame = CGRect(origin: .zero, size: outputSize)

        let borderLayer = CAShapeLayer()
        borderLayer.frame = overlayLayer.bounds

        let path = UIBezierPath()
        let borderColor = UIColor(borderStyle.color)

        switch splitMode {
        case .leftRight:
            let x = outputSize.width * splitRatio
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: outputSize.height))
        case .topBottom:
            let y = outputSize.height * splitRatio
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: outputSize.width, y: y))
        }

        borderLayer.path = path.cgPath
        borderLayer.strokeColor = borderColor.cgColor
        borderLayer.lineWidth = borderStyle.width
        borderLayer.fillColor = nil
        overlayLayer.addSublayer(borderLayer)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: outputSize)

        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
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
