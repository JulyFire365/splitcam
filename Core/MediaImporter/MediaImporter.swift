import PhotosUI
import SwiftUI
import AVFoundation
import Combine

/// 导入内容类型
enum ImportedContent {
    case video(url: URL, player: AVPlayer)
    case image(UIImage)
}

/// 媒体导入模块 — 从相册选择视频或图片用于合拍
final class MediaImporter: ObservableObject, @unchecked Sendable {
    @Published var importedContent: ImportedContent?
    @Published var isImporting = false
    @Published var error: ImporterError?
    @Published var thumbnailImage: UIImage?

    private var player: AVPlayer?
    private var endObserver: Any?

    /// 视频播放结束回调
    var onVideoDidEnd: (() -> Void)?

    var importedVideoURL: URL? {
        if case .video(let url, _) = importedContent { return url }
        return nil
    }

    var isInDuetMode: Bool {
        importedContent != nil
    }

    // MARK: - Import Video

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

        let thumbnail = try await generateThumbnail(for: url)
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        self.player = player

        // 监听视频播放结束
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.onVideoDidEnd?()
        }

        await MainActor.run {
            self.importedContent = .video(url: url, player: player)
            self.thumbnailImage = thumbnail
            self.isImporting = false
        }

        return url
    }

    // MARK: - Import Image

    func importImage(from result: PHPickerResult) async throws {
        await MainActor.run { isImporting = true }

        guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else {
            await MainActor.run { isImporting = false }
            throw ImporterError.invalidFormat
        }

        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                if let error {
                    continuation.resume(throwing: ImporterError.loadFailed(error.localizedDescription))
                    return
                }
                guard let image = object as? UIImage else {
                    continuation.resume(throwing: ImporterError.loadFailed("无法加载图片"))
                    return
                }
                continuation.resume(returning: image)
            }
        }

        await MainActor.run {
            self.importedContent = .image(image)
            self.thumbnailImage = image
            self.isImporting = false
        }
    }

    // MARK: - Playback

    func createPlayer(for url: URL) -> AVPlayer {
        if let player { return player }
        let p = AVPlayer(playerItem: AVPlayerItem(url: url))
        self.player = p
        return p
    }

    func startPlayback() {
        player?.seek(to: .zero)
        player?.play()
    }

    func pausePlayback() {
        player?.pause()
    }

    func stopPlayback() {
        player?.pause()
        player?.seek(to: .zero)
    }

    func videoDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    // MARK: - Exit Duet Mode

    func exitDuetMode() {
        if let url = importedVideoURL {
            try? FileManager.default.removeItem(at: url)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        importedContent = nil
        thumbnailImage = nil
        player = nil
        onVideoDidEnd = nil
    }

    func cleanup() {
        exitDuetMode()
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

// MARK: - PHPicker Configuration (Video + Image)

struct MediaPickerConfig {
    static var configuration: PHPickerConfiguration {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .any(of: [.videos, .images])
        config.preferredAssetRepresentationMode = .current
        return config
    }
}

// MARK: - SwiftUI PHPicker Wrapper

struct MediaPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (PHPickerResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: MediaPickerConfig.configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MediaPicker

        init(_ parent: MediaPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.isPresented = false
            guard let result = results.first else { return }
            parent.onPick(result)
        }
    }
}

// MARK: - Legacy VideoPicker (kept for compatibility)

struct VideoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (PHPickerResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: MediaPickerConfig.configuration)
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
        case .invalidFormat: return "不支持的格式"
        case .loadFailed(let msg): return "加载失败：\(msg)"
        case .permissionDenied: return "请在设置中允许 SplitCam 访问相册"
        }
    }
}
