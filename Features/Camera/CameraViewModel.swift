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
    @Published var shootingMode: ShootingMode = .video
    @Published var aspectRatio: AspectRatioMode = .ratio9_16
    @Published var resolution: CaptureResolution = .hd1080p
    @Published var resolutionQuality: ResolutionQuality = .standard
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
    @Published var importedPlayer: AVPlayer?
    @Published var importedImage: UIImage?
    @Published var importedVideoBuffer: CMSampleBuffer?

    // Duet mode recording support
    private var importedVideoOutput: AVPlayerItemVideoOutput?
    private var importedCIImage: CIImage?
    private var recIsDuetMode: Bool = false
    private var latestImportedCIImage: CIImage?
    private var importedVideoOrientation: CGImagePropertyOrientation = .up

    var isDuetMode: Bool {
        mediaImporter.isInDuetMode
    }

    private var frontReady = false
    private var backReady = false
    private var frontFrameCount = 0
    private var backFrameCount = 0

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Real-time Composed Recording

    private let recordingQueue = DispatchQueue(label: "com.splitcam.recording")
    private var composedWriter: AVAssetWriter?
    private var composedVideoInput: AVAssetWriterInput?
    private var composedAudioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var composedOutputURL: URL?
    private var recordingCIContext: CIContext = {
        // Metal GPU 加速，实时渲染优先性能
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .useSoftwareRenderer: false,
                .priorityRequestLow: false
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()
    private var recordingStartTime: CMTime?
    private var isWritingStarted = false

    // 最新帧缓存（录制用，通过 bufferLock 保护线程安全）
    private let bufferLock = NSLock()
    private var _latestFrontPixelBuffer: CVPixelBuffer?
    private var _latestBackPixelBuffer: CVPixelBuffer?

    private func setFrontBuffer(_ buffer: CVPixelBuffer?) {
        bufferLock.lock()
        _latestFrontPixelBuffer = buffer
        bufferLock.unlock()
    }
    private func setBackBuffer(_ buffer: CVPixelBuffer?) {
        bufferLock.lock()
        _latestBackPixelBuffer = buffer
        bufferLock.unlock()
    }
    private func getBuffers() -> (front: CVPixelBuffer?, back: CVPixelBuffer?) {
        bufferLock.lock()
        let f = _latestFrontPixelBuffer
        let b = _latestBackPixelBuffer
        bufferLock.unlock()
        return (f, b)
    }

    // 布局快照（录制开始前在主线程写入，录制期间仅在 recordingQueue 读取，不会并发写入，线程安全）
    private var recOutputSize: CGSize = CGSize(width: 1080, height: 1920)
    private var recSplitMode: SplitMode = .leftRight
    private var recSplitRatio: CGFloat = 0.5
    private var recPanelsSwapped: Bool = false
    private var recPipShape: PipShape = .roundedRect
    private var recPipScale: CGFloat = 0.3
    private var recPipOffset: CGSize = .zero
    private var recBorderStyle: BorderStyleConfig = .default

    // MARK: - Computed

    /// 当前导出分辨率（始终 1080p 基准，画质由码率控制）
    var currentExportSize: CGSize {
        aspectRatio.exportSize
    }

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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

        // 录制用帧回调（在 dataOutputQueue 上，不跳主线程）
        cameraEngine.onFrontFrameForRecording = { [weak self] buffer in
            guard let self else { return }
            self.setFrontBuffer(CMSampleBufferGetImageBuffer(buffer))
        }

        cameraEngine.onBackFrameForRecording = { [weak self] buffer in
            guard let self else { return }
            self.setBackBuffer(CMSampleBufferGetImageBuffer(buffer))

            // 合拍模式 + 录制中：抓取导入视频帧（仅用于后台合成，预览显示缩略图）
            if self.recIsDuetMode, self.composedWriter != nil,
               let vo = self.importedVideoOutput {
                let time = vo.itemTime(forHostTime: CACurrentMediaTime())
                if let pb = vo.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    // videoComposition 已应用 preferredTransform，无需额外旋转
                    let ci = CIImage(cvPixelBuffer: pb, options: [
                        .colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                    ])
                    self.latestImportedCIImage = ci
                }
            }

            // 以后摄帧为基准触发合成写入
            self.composeAndWriteFrame(timestamp: CMSampleBufferGetPresentationTimeStamp(buffer))
        }

        cameraEngine.onAudioSample = { [weak self] buffer in
            guard let self else { return }
            self.writeAudioSample(buffer)
        }

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
            let granted = await cameraEngine.checkPermissions()
            guard granted else {
                permissionDenied = true
                return
            }
            // setupSession 内部配置完后会自动 startRunning，减少一次队列调度延迟
            cameraEngine.setupSession(resolution: resolution)
        }
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

    /// 同步布局参数到录制线程可访问的快照
    func syncRecordingSnapshot() {
        recOutputSize = aspectRatio.exportSize
        recSplitMode = splitMode
        recSplitRatio = layoutEngine.splitRatio
        recPanelsSwapped = panelsSwapped
        recPipShape = layoutEngine.pipShape
        recPipScale = layoutEngine.pipScale
        recPipOffset = layoutEngine.pipOffset
        recBorderStyle = layoutEngine.borderStyle
        recIsDuetMode = mediaImporter.isInDuetMode
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

    // MARK: - Recording / Photo Actions

    func triggerCapture() {
        switch shootingMode {
        case .photo:
            // 拍照不中断录制，可以在录制过程中同时拍照
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

        // 使用 ISP 管线拍照（Deep Fusion / Smart HDR）
        cameraEngine.capturePhotoWithISP { [weak self] backPhoto, frontPhoto in
            guard let self else { return }
            Task { @MainActor in
                self.processISPPhotos(backPhoto: backPhoto, frontPhoto: frontPhoto)
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

    // MARK: - Video Recording (Real-time Composition)

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        syncRecordingSnapshot()
        let outputSize = currentExportSize
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("splitcam_composed_\(UUID().uuidString).mp4")
        composedOutputURL = outputURL

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

            // 根据画质档位调整码率
            let videoBitRate: Int = resolutionQuality.videoBitRate
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: videoBitRate,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoQualityKey: 0.95  // 高质量编码
                ] as [String: Any]
            ]

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true

            let sourcePixelAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: sourcePixelAttrs
            )

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput.expectsMediaDataInRealTime = true

            writer.add(videoInput)
            writer.add(audioInput)
            writer.startWriting()

            composedWriter = writer
            composedVideoInput = videoInput
            composedAudioInput = audioInput
            pixelBufferAdaptor = adaptor
            recordingStartTime = nil
            isWritingStarted = false
        } catch {
            errorMessage = "error.recordingInit".localized + ": \(error.localizedDescription)"
            showError = true
            return
        }

        isRecording = true
        recordingDuration = 0

        // 录制计时器
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                if !self.isRecording {
                    timer.invalidate()
                    return
                }
                self.recordingDuration += 1
            }
        }

        if isDuetMode && importedPlayer != nil {
            mediaImporter.startPlayback()
        }
    }

    /// 实时合成一帧并写入（在 dataOutputQueue 上调用）
    private func composeAndWriteFrame(timestamp: CMTime) {
        guard let writer = composedWriter,
              writer.status == .writing,
              let videoInput = composedVideoInput,
              let adaptor = pixelBufferAdaptor,
              let frontPB = _latestFrontPixelBuffer else { return }

        let backPB = _latestBackPixelBuffer
        if !recIsDuetMode && backPB == nil { return }

        // 首帧启动 session
        if !isWritingStarted {
            writer.startSession(atSourceTime: timestamp)
            recordingStartTime = timestamp
            isWritingStarted = true
        }

        guard videoInput.isReadyForMoreMediaData else { return }

        // 从快照读取当前布局参数（录制开始前在主线程写入）
        let currentOutputSize = recOutputSize
        let currentSplitMode = recSplitMode
        let currentSplitRatio = recSplitRatio
        let currentPanelsSwapped = recPanelsSwapped
        let currentPipShape = recPipShape
        let currentPipScale = recPipScale
        let currentPipOffset = recPipOffset
        let currentBorderStyle = recBorderStyle

        // 计算目标区域
        let frames: (first: CGRect, second: CGRect)
        if currentSplitMode == .pip {
            // 临时 layout engine 计算 PiP rect
            let pipWidth = currentOutputSize.width * currentPipScale
            let pipHeight = pipWidth * (4.0 / 3.0)
            let margin: CGFloat = 16
            let defaultX = currentOutputSize.width - pipWidth - margin
            let defaultY = margin + 50
            var x = defaultX + currentPipOffset.width
            var y = defaultY + currentPipOffset.height
            x = max(margin, min(currentOutputSize.width - pipWidth - margin, x))
            y = max(margin, min(currentOutputSize.height - pipHeight - margin, y))
            let pipRect = CGRect(x: x, y: y, width: pipWidth, height: pipHeight)
            frames = (CGRect(origin: .zero, size: currentOutputSize), pipRect)
        } else {
            let bw = currentBorderStyle.style != .none ? currentBorderStyle.width : 0
            switch currentSplitMode {
            case .leftRight:
                let fw = currentOutputSize.width * currentSplitRatio - bw / 2
                let sx = currentOutputSize.width * currentSplitRatio + bw / 2
                let sw = currentOutputSize.width - sx
                frames = (CGRect(x: 0, y: 0, width: fw, height: currentOutputSize.height),
                          CGRect(x: sx, y: 0, width: sw, height: currentOutputSize.height))
            case .topBottom:
                let fh = currentOutputSize.height * currentSplitRatio - bw / 2
                let sy = currentOutputSize.height * currentSplitRatio + bw / 2
                let sh = currentOutputSize.height - sy
                frames = (CGRect(x: 0, y: 0, width: currentOutputSize.width, height: fh),
                          CGRect(x: 0, y: sy, width: currentOutputSize.width, height: sh))
            case .pip:
                frames = (CGRect(origin: .zero, size: currentOutputSize), .zero)
            }
        }

        // 获取 CIImage（合拍模式用导入内容替代后摄）
        let frontCI = CIImage(cvPixelBuffer: frontPB)
        let backCI: CIImage
        if recIsDuetMode {
            if let ci = latestImportedCIImage {
                backCI = ci
            } else if let img = importedCIImage {
                backCI = img
            } else {
                return
            }
        } else {
            guard let bpb = backPB else { return }
            backCI = CIImage(cvPixelBuffer: bpb)
        }

        let firstCI = currentPanelsSwapped ? frontCI : backCI
        let secondCI = currentPanelsSwapped ? backCI : frontCI

        var composite = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: currentOutputSize))
        let h = currentOutputSize.height

        composite = fitAndClip(firstCI, into: frames.first, outputHeight: h).composited(over: composite)

        let fittedSecond = fitAndClip(secondCI, into: frames.second, outputHeight: h)
        if currentSplitMode == .pip {
            let masked = applyPipMaskForRecording(fittedSecond, rect: frames.second, shape: currentPipShape, outputHeight: h)
            composite = masked.composited(over: composite)
        } else {
            composite = fittedSecond.composited(over: composite)
        }

        // 轻量锐化（CISharpenLuminance 性能极高，不影响帧率）
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(composite, forKey: kCIInputImageKey)
            sharpen.setValue(0.4, forKey: kCIInputSharpnessKey)
            if let sharpened = sharpen.outputImage {
                composite = sharpened
            }
        }

        // 渲染到 pixel buffer
        guard let pool = adaptor.pixelBufferPool else { return }
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
        guard let buffer = outputBuffer else { return }

        recordingCIContext.render(composite, to: buffer)
        adaptor.append(buffer, withPresentationTime: timestamp)
    }

    private func writeAudioSample(_ buffer: CMSampleBuffer) {
        guard let writer = composedWriter,
              writer.status == .writing,
              isWritingStarted,
              let audioInput = composedAudioInput,
              audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(buffer)
    }

    /// 从 CVPixelBuffer 创建 CMSampleBuffer（用于预览显示）
    private func createSampleBufferFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc)
        guard let format = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        return sampleBuffer
    }

    /// CIImage aspect fill + clip（与 VideoComposer 中相同逻辑）
    private func fitAndClip(_ image: CIImage, into targetRect: CGRect, outputHeight: CGFloat) -> CIImage {
        let imageSize = image.extent.size
        guard targetRect.width > 0, targetRect.height > 0 else {
            return CIImage(color: .clear).cropped(to: .zero)
        }

        let scaleX = targetRect.width / imageSize.width
        let scaleY = targetRect.height / imageSize.height
        let scale = max(scaleX, scaleY)

        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let ciY = outputHeight - targetRect.origin.y - targetRect.height
        let ciRect = CGRect(x: targetRect.origin.x, y: ciY, width: targetRect.width, height: targetRect.height)

        let offsetX = ciRect.origin.x + (ciRect.width - scaledW) / 2
        let offsetY = ciRect.origin.y + (ciRect.height - scaledH) / 2

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: ciRect)
    }

    /// PiP 遮罩（录制用，线程安全）
    private func applyPipMaskForRecording(_ image: CIImage, rect: CGRect, shape: PipShape, outputHeight: CGFloat) -> CIImage {
        let ciY = outputHeight - rect.origin.y - rect.height
        let ciRect = CGRect(x: rect.origin.x, y: ciY, width: rect.width, height: rect.height)

        let mw = Int(rect.width), mh = Int(rect.height)
        guard mw > 0, mh > 0 else { return image }

        guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8,
                                   bytesPerRow: mw * 4, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.setFillColor(gray: 1, alpha: 1)

        if shape == .circle {
            let s = min(CGFloat(mw), CGFloat(mh))
            ctx.fillEllipse(in: CGRect(x: (CGFloat(mw)-s)/2, y: (CGFloat(mh)-s)/2, width: s, height: s))
        } else {
            let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: mw, height: mh),
                              cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        guard let maskCG = ctx.makeImage() else { return image }
        let maskCI = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(translationX: ciRect.origin.x, y: ciRect.origin.y))

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        importedVideoBuffer = nil
        latestImportedCIImage = nil

        if isDuetMode {
            mediaImporter.pausePlayback()
        }

        // 完成写入并保存
        composedVideoInput?.markAsFinished()
        composedAudioInput?.markAsFinished()

        guard let writer = composedWriter, let outputURL = composedOutputURL else { return }
        let writerRef = writer

        writerRef.finishWriting { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                if writerRef.status == .completed {
                    // 生成缩略图
                    Task {
                        let asset = AVURLAsset(url: outputURL)
                        let generator = AVAssetImageGenerator(asset: asset)
                        generator.appliesPreferredTrackTransform = true
                        generator.maximumSize = CGSize(width: 200, height: 200)
                        if let cgImage = try? await generator.image(at: .zero).image {
                            self.lastSavedThumbnail = UIImage(cgImage: cgImage)
                        }
                    }
                    self.saveVideoToAlbum(outputURL)
                } else {
                    self.errorMessage = "error.videoSaveFailed".localized
                    self.showError = true
                }
                self.composedWriter = nil
                self.composedVideoInput = nil
                self.composedAudioInput = nil
                self.pixelBufferAdaptor = nil
                self.isWritingStarted = false
                self.recordingStartTime = nil
            }
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
        latestImportedCIImage = nil
        importedVideoOrientation = .up
        recIsDuetMode = false
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
