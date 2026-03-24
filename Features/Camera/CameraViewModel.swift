import SwiftUI
import AVFoundation
import CoreMedia
import PhotosUI
import Photos
import Combine

/// 拍摄页面 ViewModel
@MainActor
final class CameraViewModel: ObservableObject {
    // MARK: - Published State

    @Published var isRecording = false
    @Published var splitMode: SplitMode = .leftRight {
        didSet { layoutEngine.splitMode = splitMode }
    }
    @Published var shootingMode: ShootingMode = .video
    @Published var aspectRatio: AspectRatioMode = .ratio9_16
    @Published var resolution: CaptureResolution = .hd1080p
    @Published var zoomLevel: ZoomLevel = .wide
    @Published var showVideoPicker = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var frontFrameBuffer: CMSampleBuffer?
    @Published var backFrameBuffer: CMSampleBuffer?
    @Published var panelsSwapped = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var showFlashEffect = false
    @Published var isFrontMirrored = true
    @Published var isProcessing = false
    @Published var isDraggingDivider = false
    @Published var lastSavedThumbnail: UIImage?

    // MARK: - Engines

    let layoutEngine = SplitLayoutEngine()
    let cameraEngine = CameraEngine()
    let mediaImporter = MediaImporter()
    private let videoComposer = VideoComposer()

    // MARK: - State

    private var captureMode: CaptureMode = .dualCamera
    var importedPlayer: AVPlayer?

    private var recordedFrontURL: URL?
    private var recordedBackURL: URL?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let tenths = Int((recordingDuration.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    // MARK: - Setup

    func setup(mode: CaptureMode) {
        captureMode = mode

        cameraEngine.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        cameraEngine.$recordingDuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)

        cameraEngine.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
            .store(in: &cancellables)

        // Frame callbacks - always deliver frames for real-time preview
        cameraEngine.onFrontFrame = { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.frontFrameBuffer = buffer
            }
        }

        cameraEngine.onBackFrame = { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backFrameBuffer = buffer
            }
        }

        Task {
            let granted = await cameraEngine.checkPermissions()
            guard granted else {
                errorMessage = CameraError.permissionDenied.localizedDescription
                showError = true
                return
            }
            cameraEngine.setupSession(resolution: resolution)
            cameraEngine.startSession()
        }
    }

    func cleanup() {
        cameraEngine.stopSession()
        mediaImporter.stopPlayback()
    }

    func pauseSession() {
        cameraEngine.stopSession()
    }

    func resumeSession() {
        cameraEngine.startSession()
    }

    func openSystemPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Shooting Mode

    func setShootingMode(_ mode: ShootingMode) {
        guard !isRecording else { return }
        shootingMode = mode
    }

    // MARK: - Aspect Ratio

    func setAspectRatio(_ ratio: AspectRatioMode) {
        guard !isRecording else { return }
        aspectRatio = ratio
    }

    // MARK: - Zoom

    func setZoom(_ level: ZoomLevel) {
        zoomLevel = level
        cameraEngine.setZoom(level)
    }

    // MARK: - Mirror / Flip

    func toggleMirror() {
        isFrontMirrored.toggle()
        cameraEngine.toggleFrontMirror()
    }

    // MARK: - Recording / Photo Actions

    func triggerCapture() {
        switch shootingMode {
        case .photo:
            capturePhoto()
        case .video:
            toggleRecording()
        }
    }

    // MARK: - Photo Capture

    private func capturePhoto() {
        showFlashEffect = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.showFlashEffect = false
        }

        let photos = cameraEngine.capturePhoto(
            frontBuffer: frontFrameBuffer,
            backBuffer: backFrameBuffer
        )

        guard let frontImage = photos.front, let backImage = photos.back else {
            errorMessage = "拍照失败：无法获取摄像头画面"
            showError = true
            return
        }

        let compositeImage = composeSplitPhoto(
            first: panelsSwapped ? frontImage : backImage,
            second: panelsSwapped ? backImage : frontImage
        )

        if let composite = compositeImage {
            // Save directly to system Photos album
            saveImageToAlbum(composite)
            // Update thumbnail
            lastSavedThumbnail = composite
        }
    }

    private func composeSplitPhoto(first: UIImage, second: UIImage) -> UIImage? {
        let outputSize = aspectRatio.exportSize
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        return renderer.image { context in
            let frames = layoutEngine.frames(in: outputSize)

            drawImage(first, in: frames.first, context: context.cgContext)
            drawImage(second, in: frames.second, context: context.cgContext)

            if layoutEngine.borderStyle.style != .none {
                let borderColor = UIColor(layoutEngine.borderStyle.color)
                context.cgContext.setStrokeColor(borderColor.cgColor)
                context.cgContext.setLineWidth(layoutEngine.borderStyle.width)

                switch splitMode {
                case .leftRight:
                    let x = outputSize.width * layoutEngine.splitRatio
                    context.cgContext.move(to: CGPoint(x: x, y: 0))
                    context.cgContext.addLine(to: CGPoint(x: x, y: outputSize.height))
                case .topBottom:
                    let y = outputSize.height * layoutEngine.splitRatio
                    context.cgContext.move(to: CGPoint(x: 0, y: y))
                    context.cgContext.addLine(to: CGPoint(x: outputSize.width, y: y))
                }
                context.cgContext.strokePath()
            }
        }
    }

    private func drawImage(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)

        let imageSize = image.size
        let scaleX = rect.width / imageSize.width
        let scaleY = rect.height / imageSize.height
        let scale = max(scaleX, scaleY)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let drawRect = CGRect(
            x: rect.origin.x + (rect.width - scaledWidth) / 2,
            y: rect.origin.y + (rect.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )

        image.draw(in: drawRect)
        context.restoreGState()
    }

    // MARK: - Save to System Album

    private func saveImageToAlbum(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { _, _ in }
        }
    }

    private func saveVideoToAlbum(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { _, _ in
                DispatchQueue.main.async {
                    self.isProcessing = false
                }
            }
        }
    }

    // MARK: - Video Recording

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        cameraEngine.startRecording()
        if captureMode == .importAndShoot {
            mediaImporter.startPlayback()
        }
    }

    private func stopRecording() {
        Task {
            if captureMode == .importAndShoot {
                mediaImporter.stopPlayback()
            }

            guard let urls = await cameraEngine.stopRecording() else { return }
            recordedFrontURL = urls.front
            recordedBackURL = urls.back

            let videoA: URL
            let videoB: URL

            switch captureMode {
            case .dualCamera:
                videoA = panelsSwapped ? urls.front : urls.back
                videoB = panelsSwapped ? urls.back : urls.front
            case .importAndShoot:
                guard let imported = mediaImporter.importedVideoURL else { return }
                videoA = panelsSwapped ? urls.back : imported
                videoB = panelsSwapped ? imported : urls.back
            }

            // Compose split-screen video then save to album
            isProcessing = true
            videoComposer.compose(
                videoA: videoA,
                videoB: videoB,
                splitMode: splitMode,
                splitRatio: layoutEngine.splitRatio,
                borderStyle: layoutEngine.borderStyle,
                resolution: .hd1080p
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let composedURL):
                    // Generate thumbnail for the button
                    Task {
                        let asset = AVURLAsset(url: composedURL)
                        let generator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true
                        generator.maximumSize = CGSize(width: 200, height: 200)
                        if let cgImage = try? await generator.image(at: .zero).image {
                            self.lastSavedThumbnail = UIImage(cgImage: cgImage)
                        }
                    }
                    // Save composed video to system album
                    self.saveVideoToAlbum(composedURL)
                case .failure(let error):
                    self.isProcessing = false
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    // MARK: - Other Actions

    func swapPanels() {
        panelsSwapped.toggle()
    }

    func handlePickedVideo(_ result: PHPickerResult) {
        Task {
            do {
                let url = try await mediaImporter.importVideo(from: result)
                importedPlayer = mediaImporter.createPlayer(for: url)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

extension Notification.Name {
    static let splitCamNavigateToEditor = Notification.Name("splitCamNavigateToEditor")
}
