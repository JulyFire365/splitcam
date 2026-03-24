import PhotosUI
import SwiftUI
import AVFoundation
import Combine

/// 媒体导入模块 — 从相册选择视频并同步播放
final class MediaImporter: ObservableObject {
    @Published var importedVideoURL: URL?
    @Published var isImporting = false
    @Published var error: ImporterError?
    @Published var thumbnailImage: UIImage?

    private var player: AVPlayer?
    private var playerLooper: AVPlayerLooper?
    private var queuePlayer: AVQueuePlayer?

    // MARK: - Public API

    /// 从 PHPickerResult 导入视频
    func importVideo(from result: PHPickerResult) async throws -> URL {
        await MainActor.run { isImporting = true }

        guard result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else {
            await MainActor.run { isImporting = false }
            throw ImporterError.invalidFormat
        }

        let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: ImporterError.loadFailed(error.localizedDescription))
                    return
                }
                guard let url else {
                    continuation.resume(throwing: ImporterError.loadFailed("URL 为空"))
                    return
                }

                // Copy to temp directory (source file is temporary)
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("splitcam_import_\(UUID().uuidString).mp4")
                do {
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: ImporterError.loadFailed(error.localizedDescription))
                }
            }
        }

        // Generate thumbnail
        let thumbnail = try await generateThumbnail(for: url)

        await MainActor.run {
            self.importedVideoURL = url
            self.thumbnailImage = thumbnail
            self.isImporting = false
        }

        return url
    }

    /// 创建用于同步播放的 AVPlayer
    func createPlayer(for url: URL) -> AVPlayer {
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        return player
    }

    /// 开始播放（与录制同步）
    func startPlayback() {
        player?.seek(to: .zero)
        player?.play()
    }

    /// 暂停播放
    func pausePlayback() {
        player?.pause()
    }

    /// 停止并重置
    func stopPlayback() {
        player?.pause()
        player?.seek(to: .zero)
    }

    /// 获取导入视频的时长
    func videoDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// 清理导入的临时文件
    func cleanup() {
        if let url = importedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        importedVideoURL = nil
        thumbnailImage = nil
        player = nil
    }

    // MARK: - Private

    private func generateThumbnail(for url: URL) async throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)

        let (image, _) = try await generator.image(at: .zero)
        return UIImage(cgImage: image)
    }
}

// MARK: - PHPicker Configuration

struct VideoPickerConfig {
    static var configuration: PHPickerConfiguration {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .videos
        config.preferredAssetRepresentationMode = .current
        return config
    }
}

// MARK: - SwiftUI PHPicker Wrapper

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (PHPickerResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: VideoPickerConfig.configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker

        init(_ parent: VideoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard let result = results.first else { return }
            parent.onPick(result)
        }
    }
}

// MARK: - Error

enum ImporterError: Error, LocalizedError {
    case invalidFormat
    case loadFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "不支持的视频格式"
        case .loadFailed(let msg): return "视频加载失败：\(msg)"
        case .permissionDenied: return "请在设置中允许 SplitCam 访问相册"
        }
    }
}
