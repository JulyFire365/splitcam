import SwiftUI
import Photos
import AVFoundation

/// 导出页面 ViewModel
@MainActor
final class ExportViewModel: ObservableObject {
    enum ExportState {
        case ready
        case exporting
        case completed(URL)
        case failed(String)
    }

    @Published var state: ExportState = .ready
    @Published var progress: Double = 0
    @Published var selectedResolution: ExportResolution = .hd1080p
    @Published var showShareSheet = false
    @Published var showSaveSuccess = false

    var videoURL: URL?

    private let composer = VideoComposer()

    // MARK: - Actions

    func startExport() {
        guard let url = videoURL else { return }
        state = .exporting
        progress = 0

        // Simulate export progress for MVP (actual composition is done in EditorView)
        // In production, this would use VideoComposer
        simulateExport(url: url)
    }

    func cancelExport() {
        composer.cancelExport()
        state = .ready
        progress = 0
    }

    func saveToAlbum(url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self.state = .failed("请在设置中允许 SplitCam 访问相册")
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.showSaveSuccess = true
                    } else {
                        self.state = .failed(error?.localizedDescription ?? "保存失败")
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func simulateExport(url: URL) {
        // For MVP: copy the video to output location with progress animation
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitcam_final_\(UUID().uuidString).mp4")

        Task {
            do {
                // Simulate progress
                for i in 1...10 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    progress = Double(i) / 10.0
                }

                try FileManager.default.copyItem(at: url, to: outputURL)
                state = .completed(outputURL)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
