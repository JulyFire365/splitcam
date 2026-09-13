import AVFoundation
import Photos

enum VideoAlbumSaveError: Error {
    case permissionDenied
    case permissionRestricted
    case missingFile
    case albumWrite(Error)
}

protocol VideoPhotoLibrary: Sendable {
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    func addVideo(at url: URL) async throws
}

struct SystemVideoPhotoLibrary: VideoPhotoLibrary {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    func addVideo(at url: URL) async throws {
        // Do not remove or move the source until this asynchronous transaction succeeds.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
    }
}

struct VideoAlbumSaver {
    var library: any VideoPhotoLibrary = SystemVideoPhotoLibrary()

    func save(_ url: URL) async throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw VideoAlbumSaveError.missingFile
        }
        var status = library.authorizationStatus()
        if status == .notDetermined {
            status = await library.requestAuthorization()
        }
        switch status {
        case .authorized, .limited: break
        case .restricted:
            VideoSaveDiagnostics.record("photos-restricted")
            throw VideoAlbumSaveError.permissionRestricted
        default:
            VideoSaveDiagnostics.record("photos-permission-denied")
            throw VideoAlbumSaveError.permissionDenied
        }
        do {
            try await library.addVideo(at: url)
        } catch {
            VideoSaveDiagnostics.record("photos-write", error: error)
            throw VideoAlbumSaveError.albumWrite(error)
        }
    }
}

/// Completed but unsaved videos live outside tmp, survive app restarts, and are
/// removed only after Photos confirms success. In-progress outputs are separate.
struct PendingVideoStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingVideoSaves", isDirectory: true)
    }

    func makeRecordingURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(UUID().uuidString).recording.mp4")
    }

    func markReady(_ url: URL) throws -> URL {
        guard owns(url), url.lastPathComponent.hasSuffix(".recording.mp4") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let ready = directory.appendingPathComponent(url.lastPathComponent.replacingOccurrences(of: ".recording.mp4", with: ".mp4"))
        try FileManager.default.moveItem(at: url, to: ready)
        return ready
    }

    func pendingURLs() -> [URL] {
        files().filter {
            !$0.lastPathComponent.hasSuffix(".recording.mp4") && !$0.lastPathComponent.hasSuffix(".saved.mp4")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func markSaved(_ url: URL) {
        guard owns(url) else { return }
        // A receipt-like filename prevents duplicate retries if cleanup is interrupted.
        let saved = url.deletingPathExtension().appendingPathExtension("saved.mp4")
        do {
            try FileManager.default.moveItem(at: url, to: saved)
            try FileManager.default.removeItem(at: saved)
        } catch {
            VideoSaveDiagnostics.record("saved-file-cleanup", error: error)
            // Photos already succeeded. Never misreport an encode/save failure here.
        }
    }

    /// Recover a file if the app exited after encoding completed but before the
    /// atomic ready rename. Incomplete/corrupt output is never offered to Photos.
    func recoverFinishedRecordings() async {
        for url in files() where url.lastPathComponent.hasSuffix(".recording.mp4") {
            let asset = AVURLAsset(url: url)
            guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty,
                  let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else { continue }
            let generator = AVAssetImageGenerator(asset: asset)
            guard (try? await generator.image(at: .zero)) != nil else { continue }
            do { _ = try markReady(url) }
            catch { VideoSaveDiagnostics.record("recover-finished-video", error: error) }
        }
    }

    private func owns(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL && url.pathExtension == "mp4"
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "mp4" } ?? []
    }
}
