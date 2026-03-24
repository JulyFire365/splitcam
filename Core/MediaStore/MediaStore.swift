import SwiftUI
import AVFoundation
import Photos

/// 媒体文件目录（非 actor 隔离，供 MediaItem 使用）
enum MediaDirectories {
    static var media: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SplitCamMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var thumbnails: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SplitCamThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 媒体项目
struct MediaItem: Codable, Identifiable, Equatable {
    let id: UUID
    let type: MediaType
    let fileName: String
    let thumbnailName: String
    let createdAt: Date
    let aspectRatio: String

    enum MediaType: String, Codable {
        case photo
        case video
    }

    var fileURL: URL {
        MediaDirectories.media.appendingPathComponent(fileName)
    }

    var thumbnailURL: URL {
        MediaDirectories.thumbnails.appendingPathComponent(thumbnailName)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: createdAt)
    }
}

/// 本地媒体存储管理
@MainActor
final class MediaStore: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var showSaveSuccess = false

    static let shared = MediaStore()

    private static var manifestURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("splitcam_manifest.json")
    }

    private init() {
        loadItems()
    }

    // MARK: - Save Photo

    func savePhoto(_ image: UIImage, aspectRatio: AspectRatioMode) {
        let id = UUID()
        let fileName = "photo_\(id.uuidString).jpg"
        let thumbnailName = "thumb_\(id.uuidString).jpg"

        // Save full image
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: MediaDirectories.media.appendingPathComponent(fileName))
        }

        // Save thumbnail
        let thumbSize = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: thumbSize)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: thumbSize))
        }
        if let thumbData = thumb.jpegData(compressionQuality: 0.7) {
            try? thumbData.write(to: MediaDirectories.thumbnails.appendingPathComponent(thumbnailName))
        }

        let item = MediaItem(
            id: id,
            type: .photo,
            fileName: fileName,
            thumbnailName: thumbnailName,
            createdAt: Date(),
            aspectRatio: aspectRatio.rawValue
        )

        items.insert(item, at: 0)
        saveManifest()
    }

    // MARK: - Save Video

    func saveVideo(from sourceURL: URL, aspectRatio: AspectRatioMode) async {
        let id = UUID()
        let fileName = "video_\(id.uuidString).mp4"
        let thumbnailName = "thumb_\(id.uuidString).jpg"
        let destURL = MediaDirectories.media.appendingPathComponent(fileName)

        // Copy video file
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            return
        }

        // Generate thumbnail
        let asset = AVURLAsset(url: destURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        if let cgImage = try? await generator.image(at: .zero).image {
            let thumb = UIImage(cgImage: cgImage)
            if let data = thumb.jpegData(compressionQuality: 0.7) {
                try? data.write(to: MediaDirectories.thumbnails.appendingPathComponent(thumbnailName))
            }
        }

        let item = MediaItem(
            id: id,
            type: .video,
            fileName: fileName,
            thumbnailName: thumbnailName,
            createdAt: Date(),
            aspectRatio: aspectRatio.rawValue
        )

        items.insert(item, at: 0)
        saveManifest()
    }

    // MARK: - Delete

    func deleteItem(_ item: MediaItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        items.removeAll { $0.id == item.id }
        saveManifest()
    }

    // MARK: - Save to System Album

    func saveToSystemAlbum(_ item: MediaItem) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                if item.type == .photo {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: item.fileURL)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: item.fileURL)
                }
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    if success {
                        self?.showSaveSuccess = true
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    private func loadItems() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else {
            return
        }
        // Filter out items whose files no longer exist
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func saveManifest() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.manifestURL)
    }
}
