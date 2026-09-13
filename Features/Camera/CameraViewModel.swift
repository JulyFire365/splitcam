import SwiftUI
import AVFoundation
import CoreMedia
import PhotosUI
import Photos
import Combine
import UniformTypeIdentifiers

/// 拍摄页面 ViewModel
@MainActor
final class CameraViewModel: ObservableObject {
    // MARK: - Published State

    @Published var isRecording = false
    @Published var splitMode: SplitMode = .leftRight {
        didSet {
            layoutEngine.splitMode = splitMode
            syncRecordingSnapshot()
        }
    }
    @Published var shootingMode: ShootingMode = .photo
    @Published var aspectRatio: AspectRatioMode = .ratio3_4
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
    @Published var camerasReady = false
    @Published var permissionDenied = false

    // MARK: - Engines

    let layoutEngine = SplitLayoutEngine()
    let cameraEngine = CameraEngine()
    let mediaImporter = MediaImporter()

    // MARK: - State

    private var captureMode: CaptureMode = .dualCamera
    private let settings: AppSettings
    @Published var importedPlayer: AVPlayer?
    @Published var importedImage: UIImage?
    @Published var importedVideoBuffer: CMSampleBuffer?

    // Duet mode recording support
    private var importedVideoOutput: AVPlayerItemVideoOutput?
    private var importedCIImage: CIImage?
    private var importedVideoOrientation: CGImagePropertyOrientation = .up

    var isDuetMode: Bool {
        mediaImporter.isInDuetMode
    }

    private var frontReady = false
    private var backReady = false
    private var frontFrameCount = 0
    private var backFrameCount = 0

    private var cancellables = Set<AnyCancellable>()
    private var layoutPersistenceCancellables = Set<AnyCancellable>()

    // MARK: - Recording and Save Lifecycle

    private let recorder = VideoRecordingSession()
    private let recordingComposer = CameraRecordingComposer()
    private let pendingVideoStore: PendingVideoStore
    private let albumSaver: VideoAlbumSaver
    private var recordingID: UUID?
    private var recordingGeneration = UUID()
    private var recordingTimer: Timer?
    private var saveBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingVideoURLs: [URL] = []
    @Published private(set) var pendingVideoCount = 0
    @Published private(set) var photoAccessDenied = false
    var hasPendingVideoSaves: Bool { pendingVideoCount > 0 }

    // MARK: - Computed

    init(settings: AppSettings? = nil, pendingVideoStore: PendingVideoStore = PendingVideoStore(),
         albumSaver: VideoAlbumSaver = VideoAlbumSaver()) {
        self.settings = settings ?? .shared
        self.pendingVideoStore = pendingVideoStore
        self.albumSaver = albumSaver
        pendingVideoURLs = pendingVideoStore.pendingURLs()
        pendingVideoCount = pendingVideoURLs.count
    }

    /// One persisted preference, shared by both pickers. Layout restoration must
    /// never replace it with a second, stale camera-local value.
    var resolutionQuality: ResolutionQuality { settings.defaultVideoQuality }

    /// Photo output stays independent of the video quality preference.
    var currentExportSize: CGSize {
        aspectRatio.exportSize
    }

    var currentVideoExportSize: CGSize {
        resolutionQuality.outputSize(for: aspectRatio.exportSize)
    }

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Setup

    func setup(mode: CaptureMode) {
        captureMode = mode
        cancellables.removeAll()
        restoreLayout(from: settings)
        observeLayoutPersistence(using: settings)

        cameraEngine.$error
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.errorMessage = error.localizedDescription
                self?.showError = true
            }
            .store(in: &cancellables)

        // Frame callbacks — 检测非黑帧才标记 ready
        cameraEngine.onFrontFrame = { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.frontFrameBuffer = buffer
                if !self.frontReady {
                    self.frontFrameCount += 1
                    if self.frontFrameCount >= 1 {
                        self.frontReady = true
                        self.checkCamerasReady()
                    }
                }
            }
        }

        cameraEngine.onBackFrame = { [weak self] buffer in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backFrameBuffer = buffer
                if !self.backReady {
                    self.backFrameCount += 1
                    if self.backFrameCount >= 1 {
                        self.backReady = true
                        self.checkCamerasReady()
                    }
                }
            }
        }

        configureRecordingCallbacks()

        // 布局变化同步到录制快照
        layoutEngine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncRecordingSnapshot()
            }
            .store(in: &cancellables)

        // PiP 点击交换画面
        NotificationCenter.default.publisher(for: .splitCamSwapPanels)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.swapPanels()
            }
            .store(in: &cancellables)

        Task {
            // Recover prior completed files before cameras become recordable.
            await pendingVideoStore.recoverFinishedRecordings()
            refreshPendingVideoSaves()
            let granted = await cameraEngine.checkPermissions()
            guard granted else {
                permissionDenied = true
                return
            }
            // setupSession 内部配置完后会自动 startRunning，减少一次队列调度延迟
            cameraEngine.setupSession(resolution: resolution)
            cameraEngine.setFrontMirrored(isFrontMirrored)
        }
    }

    /// Separate from camera permission/session setup so deterministic sample fixtures
    /// can exercise the production pipeline without accessing camera hardware.
    func configureRecordingCallbacks() {
    // Capture callbacks never read main-actor state or own writer inputs.
    let composer = recordingComposer
    let recorder = recorder
    cameraEngine.onFrontFrameForRecording = { buffer in
        composer.updateFront(CMSampleBufferGetImageBuffer(buffer))
    }
    cameraEngine.onBackFrameForRecording = { buffer in
        composer.updateBack(CMSampleBufferGetImageBuffer(buffer))
        recorder.appendVideo(at: CMSampleBufferGetPresentationTimeStamp(buffer)) { size in
            composer.compose(in: size)
        }
    }
    cameraEngine.onAudioSample = { buffer in
        recorder.appendAudio(buffer)
    }
    }

    // MARK: - Layout Persistence

    private func restoreLayout(from settings: AppSettings) {
        guard settings.remembersLastLayout else {
            splitMode = .leftRight
            panelsSwapped = false
            shootingMode = .photo
            aspectRatio = settings.defaultAspectRatio
            isFrontMirrored = settings.frontCameraMirrored
            layoutEngine.splitRatio = 0.5
            layoutEngine.pipShape = .roundedRect
            layoutEngine.pipScale = 0.3
            layoutEngine.pipOffset = .zero
            return
        }

        splitMode = settings.lastSplitMode
        panelsSwapped = settings.lastPanelsSwapped
        shootingMode = settings.lastShootingMode
        aspectRatio = settings.lastAspectRatio
        isFrontMirrored = settings.lastFrontCameraMirrored
        layoutEngine.splitRatio = settings.lastSplitRatio
        layoutEngine.pipShape = settings.lastPipShape
        layoutEngine.pipScale = settings.lastPipScale
        layoutEngine.pipOffset = settings.lastPipOffset
    }

    private func observeLayoutPersistence(using settings: AppSettings) {
        layoutPersistenceCancellables.removeAll()

        $splitMode.dropFirst()
            .sink { [weak settings] mode in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastSplitMode = mode
            }
            .store(in: &layoutPersistenceCancellables)
        $panelsSwapped.dropFirst()
            .sink { [weak settings] swapped in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastPanelsSwapped = swapped
            }
            .store(in: &layoutPersistenceCancellables)
        $shootingMode.dropFirst()
            .sink { [weak settings] mode in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastShootingMode = mode
            }
            .store(in: &layoutPersistenceCancellables)
        $aspectRatio.dropFirst()
            .sink { [weak settings] ratio in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastAspectRatio = ratio
            }
            .store(in: &layoutPersistenceCancellables)
        $isFrontMirrored.dropFirst()
            .sink { [weak settings] mirrored in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastFrontCameraMirrored = mirrored
            }
            .store(in: &layoutPersistenceCancellables)
        layoutEngine.$splitRatio.dropFirst()
            .sink { [weak settings] ratio in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastSplitRatio = ratio
            }
            .store(in: &layoutPersistenceCancellables)
        layoutEngine.$pipShape.dropFirst()
            .sink { [weak settings] shape in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastPipShape = shape
            }
            .store(in: &layoutPersistenceCancellables)
        layoutEngine.$pipScale.dropFirst()
            .sink { [weak settings] scale in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastPipScale = scale
            }
            .store(in: &layoutPersistenceCancellables)
        layoutEngine.$pipOffset.dropFirst()
            .sink { [weak settings] offset in
                guard let settings, settings.remembersLastLayout else { return }
                settings.lastPipOffset = offset
            }
            .store(in: &layoutPersistenceCancellables)
        settings.$remembersLastLayout
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak settings] enabled in
                if enabled, let self, let settings {
                    self.persistCurrentLayout(to: settings)
                }
            }
            .store(in: &layoutPersistenceCancellables)
    }

    private func persistCurrentLayout(to settings: AppSettings) {
        settings.lastSplitMode = splitMode
        settings.lastPanelsSwapped = panelsSwapped
        settings.lastShootingMode = shootingMode
        settings.lastAspectRatio = aspectRatio
        settings.lastFrontCameraMirrored = isFrontMirrored
        settings.lastSplitRatio = layoutEngine.splitRatio
        settings.lastPipShape = layoutEngine.pipShape
        settings.lastPipScale = layoutEngine.pipScale
        settings.lastPipOffset = layoutEngine.pipOffset
    }

    /// Called at explicit lifecycle boundaries as a safeguard for force-quit flows.
    func persistLayoutIfNeeded(to settings: AppSettings) {
        guard settings.remembersLastLayout else { return }
        persistCurrentLayout(to: settings)
    }

    func recheckPermissions() {
        Task {
            let granted = await cameraEngine.checkPermissions()
            if granted {
                permissionDenied = false
                cameraEngine.setupSession(resolution: resolution)
            }
        }
    }

    func cleanup() {
        if isRecording { stopRecording() }
        cameraEngine.stopSession()
        mediaImporter.cleanup()
    }

    func pauseSession() {
        // 录制中切后台：自动停止录制并保存
        if isRecording {
            stopRecording()
        }
        cameraEngine.stopSession()
    }

    func resumeSession() {
        // 重新等待两个摄像头都出稳定帧
        frontReady = false
        backReady = false
        frontFrameCount = 0
        backFrameCount = 0
        camerasReady = false
        cameraEngine.startSession()
    }

    private func checkCamerasReady() {
        if frontReady && backReady && !camerasReady {
            camerasReady = true
        }
    }

    /// The writer owns output size; only layout/source values change while recording.
    func syncRecordingSnapshot() {
        recordingComposer.update(.init(
            generation: recordingGeneration,
            splitMode: splitMode,
            splitRatio: layoutEngine.splitRatio,
            panelsSwapped: panelsSwapped,
            pipShape: layoutEngine.pipShape,
            pipScale: layoutEngine.pipScale,
            pipOffset: layoutEngine.pipOffset,
            borderWidth: layoutEngine.borderStyle.style == .none ? 0 : layoutEngine.borderStyle.width,
            isDuet: mediaImporter.isInDuetMode,
            importedImage: importedCIImage,
            importedVideoOutput: importedVideoOutput
        ))
    }

    func openSystemPhotos() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Shooting Mode

    func setShootingMode(_ mode: ShootingMode) {
        shootingMode = mode
    }

    // MARK: - Aspect Ratio

    func setAspectRatio(_ ratio: AspectRatioMode) {
        aspectRatio = ratio
        syncRecordingSnapshot()
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

    func setFrontMirrored(_ mirrored: Bool) {
        guard isFrontMirrored != mirrored else { return }
        isFrontMirrored = mirrored
        cameraEngine.setFrontMirrored(mirrored)
    }

    // MARK: - Recording / Photo Actions

    func triggerCapture() {
        guard !isProcessing else { return }
        switch shootingMode {
        case .photo:
            // 拍照不中断录制，可以在录制过程中同时拍照
            capturePhoto()
        case .video:
            toggleRecording()
        }
    }

    // MARK: - Photo Capture

    private var isCapturingPhoto = false

    private func capturePhoto() {
        // 防止连续拍照声音踩踏
        guard !isCapturingPhoto else { return }
        isCapturingPhoto = true

        showFlashEffect = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.showFlashEffect = false
        }

        // 使用 ISP 管线拍照
        cameraEngine.capturePhotoWithISP { [weak self] backPhoto, frontPhoto in
            guard let self else { return }
            Task { @MainActor in
                self.processISPPhotos(backPhoto: backPhoto, frontPhoto: frontPhoto)
                self.isCapturingPhoto = false
            }
        }
    }

    private func processISPPhotos(backPhoto: UIImage?, frontPhoto: UIImage?) {
        guard let frontImage = frontPhoto else {
            // ISP 拍照失败，降级使用帧缓冲区
            guard let fb = frontFrameBuffer,
                  let fi = cameraEngine.imageFromBuffer(fb) else {
                errorMessage = "拍照失败：无法获取摄像头画面"
                showError = true
                return
            }
            processCapturedPhotos(frontImage: fi, backPhotoFromISP: backPhoto)
            return
        }
        processCapturedPhotos(frontImage: frontImage, backPhotoFromISP: backPhoto)
    }

    private func processCapturedPhotos(frontImage: UIImage, backPhotoFromISP: UIImage?) {
        // 合拍模式：用导入内容替代后摄
        let backImage: UIImage?
        if isDuetMode {
            if let img = importedImage {
                backImage = img
            } else if let vo = importedVideoOutput {
                let time = vo.itemTime(forHostTime: CACurrentMediaTime())
                if let pb = vo.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    let ci = CIImage(cvPixelBuffer: pb, options: [
                        .colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                    ])
                    let ctx = CIContext()
                    if let cg = ctx.createCGImage(ci, from: ci.extent) {
                        backImage = UIImage(cgImage: cg)
                    } else {
                        backImage = nil
                    }
                } else {
                    backImage = nil
                }
            } else {
                backImage = nil
            }
        } else {
            // 优先使用 ISP 拍摄结果，降级使用帧缓冲区
            if let bp = backPhotoFromISP {
                backImage = bp
            } else if let bb = backFrameBuffer {
                backImage = cameraEngine.imageFromBuffer(bb)
            } else {
                backImage = nil
            }
        }

        guard let backImage else {
            errorMessage = "拍照失败：无法获取画面"
            showError = true
            return
        }

        let compositeImage = composeSplitPhoto(
            first: panelsSwapped ? frontImage : backImage,
            second: panelsSwapped ? backImage : frontImage
        )

        if let composite = compositeImage {
            saveImageToAlbum(composite)
            lastSavedThumbnail = composite
        }
    }

    private func composeSplitPhoto(first: UIImage, second: UIImage) -> UIImage? {
        let outputSize = currentExportSize
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        return renderer.image { context in
            let frames = layoutEngine.frames(in: outputSize)

            if splitMode == .pip {
                // PiP: 全屏背景 + 小窗口叠加
                drawImage(first, in: frames.first, context: context.cgContext)
                drawPipImage(second, in: frames.second, context: context.cgContext)
            } else {
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
                    case .pip:
                        break
                    }
                    context.cgContext.strokePath()
                }
            }
        }
    }

    /// 绘制画中画小窗口（带圆角/圆形裁切和边框）
    private func drawPipImage(_ image: UIImage, in rect: CGRect, context: CGContext) {
        context.saveGState()

        // 根据形状裁切
        if layoutEngine.pipShape == .circle {
            let size = min(rect.width, rect.height)
            let circleRect = CGRect(
                x: rect.midX - size / 2,
                y: rect.midY - size / 2,
                width: size,
                height: size
            )
            context.addEllipse(in: circleRect)
            context.clip()
            drawImage(image, in: circleRect, context: context)
            context.restoreGState()

            // 边框
            context.saveGState()
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1.5)
            context.addEllipse(in: circleRect)
            context.strokePath()
            context.restoreGState()
        } else {
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
            context.addPath(path.cgPath)
            context.clip()
            drawImage(image, in: rect, context: context)
            context.restoreGState()

            // 边框
            context.saveGState()
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.6).cgColor)
            context.setLineWidth(1.5)
            let borderPath = UIBezierPath(roundedRect: rect, cornerRadius: 12)
            context.addPath(borderPath.cgPath)
            context.strokePath()
            context.restoreGState()
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
            } completionHandler: { success, _ in
                guard success else { return }
                DispatchQueue.main.async {
                    ReviewPromptManager.shared.recordSuccessfulCreation()
                    ReviewPromptManager.shared.queueAfterSuccessfulCreation()
                }
            }
        }
    }

    private func refreshPendingVideoSaves() {
        var seenPaths = Set<String>()
        pendingVideoURLs = (pendingVideoURLs + pendingVideoStore.pendingURLs())
            .filter { url in
                let path = url.standardizedFileURL.path
                return FileManager.default.isReadableFile(atPath: path) && seenPaths.insert(path).inserted
            }
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        pendingVideoCount = pendingVideoURLs.count
    }

    private func removePendingVideo(_ url: URL) {
        let path = url.standardizedFileURL.path
        pendingVideoURLs.removeAll {
            $0.standardizedFileURL.path == path || !FileManager.default.isReadableFile(atPath: $0.path)
        }
        refreshPendingVideoSaves()
    }

    func retryPendingVideoSaves() {
        // A completed Photos save may have already removed the local retry copy.
        // Reconcile first so a stale badge cannot produce a misleading error.
        refreshPendingVideoSaves()
        guard !isRecording, !isProcessing, hasPendingVideoSaves else { return }
        isProcessing = true
        photoAccessDenied = false
        beginSaveBackgroundTask()
        let urls = pendingVideoURLs
        Task { await savePendingVideos(urls) }
    }

    private func savePendingVideos(_ urls: [URL]) async {
        defer {
            isProcessing = false
            endSaveBackgroundTask()
        }
        for url in urls {
            do {
                // Keep the source alive through thumbnail generation and the Photos transaction.
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 200, height: 200)
                let thumbnail = try? await generator.image(at: .zero).image
                try await albumSaver.save(url)
                if let thumbnail { lastSavedThumbnail = UIImage(cgImage: thumbnail) }
                pendingVideoStore.markSaved(url)
                removePendingVideo(url)
                ReviewPromptManager.shared.recordSuccessfulCreation()
                ReviewPromptManager.shared.queueAfterSuccessfulCreation()
            } catch {
                photoAccessDenied = false
                switch error {
                case VideoAlbumSaveError.permissionDenied:
                    photoAccessDenied = true
                    errorMessage = "error.videoPhotosPermission".localized
                case VideoAlbumSaveError.permissionRestricted:
                    errorMessage = "error.videoPhotosRestricted".localized
                case VideoAlbumSaveError.missingFile:
                    // The primary save may already have succeeded while a stale
                    // in-memory reference survived. Nothing remains to retry.
                    removePendingVideo(url)
                    continue
                default:
                    errorMessage = "error.videoAlbumSave".localized
                }
                showError = true
                return
            }
        }
    }

    private func beginSaveBackgroundTask() {
        guard saveBackgroundTask == .invalid else { return }
        saveBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishAndSaveVideo") { [weak self] in
            Task { @MainActor in
                VideoSaveDiagnostics.record("background-time-expired")
                self?.endSaveBackgroundTask()
            }
        }
    }

    private func endSaveBackgroundTask() {
        guard saveBackgroundTask != .invalid else { return }
        let task = saveBackgroundTask
        saveBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    // MARK: - Video Recording

    func toggleRecording() {
        guard !isProcessing else { return }
        if isRecording { stopRecording() }
        else { startRecording() }
    }

    private func startRecording() {
        guard !isProcessing, !isRecording, camerasReady else { return }
        isProcessing = true
        photoAccessDenied = false
        recordingGeneration = UUID()
        syncRecordingSnapshot()
        do {
            let url = try pendingVideoStore.makeRecordingURL()
            recordingID = try recorder.start(url: url, fullSize: aspectRatio.exportSize, quality: resolutionQuality) { [weak self] id in
                DispatchQueue.main.async {
                    guard let self, self.recordingID == id, self.isRecording else { return }
                    self.stopRecording()
                }
            }
        } catch {
            VideoSaveDiagnostics.record("recording-setup", error: error)
            isProcessing = false
            errorMessage = "error.recordingInit".localized
            showError = true
            return
        }

        isRecording = true
        isProcessing = false
        recordingDuration = 0
        recordingTimer?.invalidate()
        let startedAt = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.isRecording else { timer.invalidate(); return }
                self.recordingDuration = Date().timeIntervalSince(startedAt)
            }
        }
        if isDuetMode && importedPlayer != nil { mediaImporter.startPlayback() }
    }

    private func stopRecording() {
        guard isRecording, let id = recordingID else { return }
        // Lock the UI before the asynchronous writer finalization begins.
        isProcessing = true
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        importedVideoBuffer = nil
        if isDuetMode { mediaImporter.pausePlayback() }
        beginSaveBackgroundTask()

        recorder.finish(id: id) { [self] result in
            // Keep the owner alive until the finalized file reaches durable storage.
            Task { @MainActor in await self.handleFinishedRecording(result, id: id) }
        }
    }

    private func handleFinishedRecording(_ result: Result<URL, VideoRecordingSession.Failure>, id: UUID) async {
        guard recordingID == id else { return }
        recordingID = nil
        switch result {
        case .success(let outputURL):
            do {
                let ready = try pendingVideoStore.markReady(outputURL)
                pendingVideoURLs.append(ready)
                refreshPendingVideoSaves()
                await savePendingVideos([ready])
            } catch {
                // A failed rename must not discard the successfully encoded video.
                VideoSaveDiagnostics.record("video-ready-storage", error: error)
                pendingVideoURLs.append(outputURL)
                pendingVideoCount = pendingVideoURLs.count
                isProcessing = false
                endSaveBackgroundTask()
                errorMessage = "error.videoAlbumSave".localized
                showError = true
            }
        case .failure(let error):
            isProcessing = false
            endSaveBackgroundTask()
            if case .noVideoFrames = error {
                errorMessage = "error.videoNoFrames".localized
            } else {
                errorMessage = "error.videoEncoding".localized
            }
            showError = true
        }
    }

    // MARK: - Other Actions

    func swapPanels() {
        panelsSwapped.toggle()
        syncRecordingSnapshot()
    }

    func handlePickedMedia(_ result: PHPickerResult) {
        // 开始导入
        Task {
            do {
                if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    let url = try await mediaImporter.importVideo(from: result)
                    let player = mediaImporter.createPlayer(for: url)
                    let thumb = mediaImporter.thumbnailImage
                    importedImage = thumb
                    importedPlayer = player

                    // 强制 HDR→SDR：通过 videoComposition 设置 BT.709 色彩空间
                    if let item = player.currentItem {
                        let asset = AVURLAsset(url: url)
                        let comp = try? await AVMutableVideoComposition.videoComposition(
                            withPropertiesOf: asset)
                        if let comp {
                            comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
                            comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
                            comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
                            item.videoComposition = comp
                        }
                    }

                    // 设置视频输出（强制 SDR 避免 HDR 户外视频过曝）
                    let output = AVPlayerItemVideoOutput(outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        AVVideoColorPropertiesKey: [
                            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                        ]
                    ])
                    player.currentItem?.add(output)
                    importedVideoOutput = output
                    importedCIImage = nil

                    // 加载视频方向
                    let orientAsset = AVURLAsset(url: url)
                    if let track = try? await orientAsset.loadTracks(withMediaType: .video).first {
                        let transform = try? await track.load(.preferredTransform)
                        if let t = transform {
                            importedVideoOrientation = Self.orientationFromTransform(t)
                        } else {
                            importedVideoOrientation = .up
                        }
                    } else {
                        importedVideoOrientation = .up
                    }

                    // 视频播放结束自动停止录制
                    mediaImporter.onVideoDidEnd = { [weak self] in
                        guard let self, self.isRecording else { return }
                        self.stopRecording()
                    }
                } else {
                    try await mediaImporter.importImage(from: result)
                    if case .image(let image) = mediaImporter.importedContent {
                        importedImage = image
                        importedPlayer = nil
                        importedVideoOutput = nil
                        importedCIImage = CIImage(image: image)
                    }
                }
                syncRecordingSnapshot()
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func exitDuetMode() {
        mediaImporter.exitDuetMode()
        importedPlayer = nil
        importedImage = nil
        importedVideoBuffer = nil
        importedVideoOutput = nil
        importedCIImage = nil
        importedVideoOrientation = .up
        syncRecordingSnapshot()
    }

    // MARK: - Orientation Helper

    /// 从 AVAssetTrack 的 preferredTransform 推导用于 CIImage.oriented() 的方向
    ///
    /// 关键：preferredTransform 在 UIKit 坐标系（Y轴向下），
    /// 但 CIImage 坐标系 Y轴向上，所以旋转方向需要反转：
    /// - UIKit 90° CW  → CIImage 需要 .left（90° CCW）
    /// - UIKit 90° CCW → CIImage 需要 .right（90° CW）
    private static func orientationFromTransform(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a)
        let degrees = angle * 180.0 / .pi

        if abs(degrees - 90) < 10 {
            return .left       // UIKit 90° CW → CIImage .left
        } else if abs(degrees + 90) < 10 || abs(degrees - 270) < 10 {
            return .right      // UIKit 90° CCW → CIImage .right
        } else if abs(abs(degrees) - 180) < 10 {
            return .down       // 180°（方向一致）
        }
        return .up             // 0°（无旋转）
    }
}

extension Notification.Name {
    static let splitCamNavigateToEditor = Notification.Name("splitCamNavigateToEditor")
    static let splitCamSwapPanels = Notification.Name("splitCamSwapPanels")
}
