import AVFoundation
import CoreMedia
import Combine
import UIKit

/// 摄像头引擎 — 管理 AVCaptureMultiCamSession，实现前后双摄同时录制
final class CameraEngine: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - Published State

    @Published var isRunning = false
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var error: CameraError?
    @Published var currentZoom: ZoomLevel = .wide
    @Published var isBackUltraWide = false

    // MARK: - Capture Session

    private let multiCamSession = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "com.splitcam.camera.session")
    private let dataOutputQueue = DispatchQueue(label: "com.splitcam.camera.dataoutput")

    // Front camera
    private var frontDeviceInput: AVCaptureDeviceInput?
    private var frontVideoOutput: AVCaptureVideoDataOutput?
    private var frontConnection: AVCaptureConnection?

    // Back camera
    private var backDeviceInput: AVCaptureDeviceInput?
    private var backVideoOutput: AVCaptureVideoDataOutput?
    private var backConnection: AVCaptureConnection?

    // Photo (系统 ISP 管线拍照)
    private var backPhotoOutput: AVCapturePhotoOutput?
    private var frontPhotoOutput: AVCapturePhotoOutput?
    private var photoCaptureCompletion: ((UIImage?, UIImage?) -> Void)?
    private var capturedBackPhoto: UIImage?
    private var capturedFrontPhoto: UIImage?
    private var photoCaptureCount = 0

    // Audio
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    // MARK: - Recording

    private var frontAssetWriter: AVAssetWriter?
    private var backAssetWriter: AVAssetWriter?
    private var frontVideoWriterInput: AVAssetWriterInput?
    private var backVideoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var recordingStartTime: CMTime?
    private var recordingTimer: Timer?
    private var isWritingStarted = false

    // MARK: - Frame Delegates

    var onFrontFrame: ((CMSampleBuffer) -> Void)?
    var onBackFrame: ((CMSampleBuffer) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?

    /// 数据输出队列上的帧回调（用于录制，避免主线程跳转延迟）
    var onFrontFrameForRecording: ((CMSampleBuffer) -> Void)?
    var onBackFrameForRecording: ((CMSampleBuffer) -> Void)?

    // MARK: - Audio Source

    enum AudioSource {
        case front, back, mixed
    }
    var audioSource: AudioSource = .back

    // MARK: - Output URLs

    private(set) var frontVideoURL: URL?
    private(set) var backVideoURL: URL?

    // MARK: - Mirror State

    private var isFrontMirrored = true

    // MARK: - Public API

    static var isMultiCamSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    func checkPermissions() async -> Bool {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        let videoGranted: Bool
        switch videoStatus {
        case .authorized:
            videoGranted = true
        case .notDetermined:
            videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            videoGranted = false
        }

        let audioGranted: Bool
        switch audioStatus {
        case .authorized:
            audioGranted = true
        case .notDetermined:
            audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            audioGranted = false
        }

        return videoGranted && audioGranted
    }

    func setupSession(resolution: CaptureResolution = .hd1080p) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureSession(resolution: resolution)
            // 配置完直接启动，避免二次排队延迟
            if !self.multiCamSession.isRunning {
                self.multiCamSession.startRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.multiCamSession.isRunning {
                self.multiCamSession.startRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.multiCamSession.isRunning {
                self.multiCamSession.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        sessionQueue.async { [weak self] in
            self?.beginRecording()
        }
    }

    func stopRecording() async -> (front: URL, back: URL)? {
        guard isRecording else { return nil }
        return await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                self?.finishRecording { urls in
                    continuation.resume(returning: urls)
                }
            }
        }
    }

    // MARK: - Photo Capture (系统 ISP 管线)

    /// 使用 AVCapturePhotoOutput 拍照（Deep Fusion / Smart HDR）
    func capturePhotoWithISP(completion: @escaping (UIImage?, UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.photoCaptureCompletion = completion
            self.capturedBackPhoto = nil
            self.capturedFrontPhoto = nil
            self.photoCaptureCount = 0

            let totalCaptures = (self.backPhotoOutput != nil ? 1 : 0) + (self.frontPhotoOutput != nil ? 1 : 0)
            guard totalCaptures > 0 else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            // 后摄拍照
            if let backOutput = self.backPhotoOutput {
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                backOutput.capturePhoto(with: settings, delegate: self)
            }

            // 前摄拍照
            if let frontOutput = self.frontPhotoOutput {
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                frontOutput.capturePhoto(with: settings, delegate: self)
            }

            // 超时保护：5秒后如果回调没触发，强制返回避免卡死
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.photoCaptureCompletion != nil else { return }
                let back = self.capturedBackPhoto
                let front = self.capturedFrontPhoto
                let cb = self.photoCaptureCompletion
                self.photoCaptureCompletion = nil
                cb?(back, front)
            }
        }
    }

    /// 兼容旧方式：从帧缓冲区截取（合拍模式降级使用）
    func imageFromBuffer(_ buffer: CMSampleBuffer) -> UIImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    // MARK: - Zoom

    func setZoom(_ level: ZoomLevel) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.backDeviceInput?.device else { return }

            // If using ultra-wide camera: factor 1.0 = 0.5x, 2.0 = 1x, 6.0 = 3x
            // If using wide-angle camera: factor 1.0 = 1x, 3.0 = 3x
            let isUltraWide = device.deviceType == .builtInUltraWideCamera
            let factor: CGFloat
            switch level {
            case .ultraWide:
                factor = isUltraWide ? 1.0 : device.minAvailableVideoZoomFactor
            case .wide:
                factor = isUltraWide ? 2.0 : 1.0
            case .telephoto:
                factor = isUltraWide ? 6.0 : 3.0
            }

            let clamped = min(max(factor, device.minAvailableVideoZoomFactor),
                              device.maxAvailableVideoZoomFactor)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                print("[CameraEngine] Zoom configuration failed: \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                self.currentZoom = level
            }
        }
    }

    // MARK: - Mirror / Flip

    func toggleFrontMirror() {
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.frontConnection else { return }
            self.isFrontMirrored.toggle()
            connection.isVideoMirrored = self.isFrontMirrored
        }
    }

    func toggleBackMirror() {
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.backConnection else { return }
            connection.isVideoMirrored.toggle()
        }
    }

    // MARK: - Session Configuration

    private func configureSession(resolution: CaptureResolution) {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async {
                self.error = .multiCamNotSupported
            }
            return
        }

        multiCamSession.beginConfiguration()
        defer { multiCamSession.commitConfiguration() }

        // Remove existing inputs/outputs
        for input in multiCamSession.inputs {
            multiCamSession.removeInput(input)
        }
        for output in multiCamSession.outputs {
            multiCamSession.removeOutput(output)
        }

        // Setup back camera — prefer wide-angle (主摄) for best image quality
        let backCamera: AVCaptureDevice? =
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        if let backCamera {
            do {
                let input = try AVCaptureDeviceInput(device: backCamera)
                if multiCamSession.canAddInput(input) {
                    multiCamSession.addInputWithNoConnections(input)
                    backDeviceInput = input
                }

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: dataOutputQueue)
                if multiCamSession.canAddOutput(output) {
                    multiCamSession.addOutputWithNoConnections(output)
                    backVideoOutput = output
                }

                if let inputPort = input.ports(for: .video, sourceDeviceType: backCamera.deviceType, sourceDevicePosition: .back).first {
                    let connection = AVCaptureConnection(inputPorts: [inputPort], output: output)
                    if multiCamSession.canAddConnection(connection) {
                        multiCamSession.addConnection(connection)
                        backConnection = connection
                        connection.videoOrientation = .portrait
                        configureStabilization(for: connection)
                    }
                }

                configureDevice(backCamera, resolution: resolution)

                // 标记后摄镜头类型
                let backIsUltraWide = backCamera.deviceType == .builtInUltraWideCamera
                DispatchQueue.main.async { self.isBackUltraWide = backIsUltraWide }

                // Default zoom: wide-angle = 1.0 (原生1x), ultra-wide = 2.0 (模拟1x)
                if backCamera.deviceType == .builtInUltraWideCamera {
                    try? backCamera.lockForConfiguration()
                    let wide = min(2.0, backCamera.maxAvailableVideoZoomFactor)
                    backCamera.videoZoomFactor = wide
                    backCamera.unlockForConfiguration()
                }

                // 后摄 Photo Output（ISP 管线拍照）
                let backPhoto = AVCapturePhotoOutput()
                backPhoto.maxPhotoQualityPrioritization = .balanced
                if multiCamSession.canAddOutput(backPhoto) {
                    multiCamSession.addOutputWithNoConnections(backPhoto)
                    if let photoPort = input.ports(for: .video, sourceDeviceType: backCamera.deviceType, sourceDevicePosition: .back).first {
                        let photoConn = AVCaptureConnection(inputPorts: [photoPort], output: backPhoto)
                        if multiCamSession.canAddConnection(photoConn) {
                            multiCamSession.addConnection(photoConn)
                            photoConn.videoOrientation = .portrait
                        }
                    }
                    backPhotoOutput = backPhoto
                }
            } catch {
                DispatchQueue.main.async { self.error = .configurationFailed(error.localizedDescription) }
            }
        }

        // Setup front camera
        if let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            do {
                let input = try AVCaptureDeviceInput(device: frontCamera)
                if multiCamSession.canAddInput(input) {
                    multiCamSession.addInputWithNoConnections(input)
                    frontDeviceInput = input
                }

                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: dataOutputQueue)
                if multiCamSession.canAddOutput(output) {
                    multiCamSession.addOutputWithNoConnections(output)
                    frontVideoOutput = output
                }

                if let inputPort = input.ports(for: .video, sourceDeviceType: frontCamera.deviceType, sourceDevicePosition: .front).first {
                    let connection = AVCaptureConnection(inputPorts: [inputPort], output: output)
                    if multiCamSession.canAddConnection(connection) {
                        multiCamSession.addConnection(connection)
                        frontConnection = connection
                        connection.videoOrientation = .portrait
                        connection.isVideoMirrored = true
                        configureStabilization(for: connection, isFront: true)
                    }
                }

                configureDevice(frontCamera, resolution: resolution, isFrontCamera: true)

                // 前摄 Photo Output（ISP 管线拍照）
                let frontPhoto = AVCapturePhotoOutput()
                frontPhoto.maxPhotoQualityPrioritization = .balanced
                if multiCamSession.canAddOutput(frontPhoto) {
                    multiCamSession.addOutputWithNoConnections(frontPhoto)
                    if let photoPort = input.ports(for: .video, sourceDeviceType: frontCamera.deviceType, sourceDevicePosition: .front).first {
                        let photoConn = AVCaptureConnection(inputPorts: [photoPort], output: frontPhoto)
                        if multiCamSession.canAddConnection(photoConn) {
                            multiCamSession.addConnection(photoConn)
                            photoConn.videoOrientation = .portrait
                            photoConn.isVideoMirrored = true
                        }
                    }
                    frontPhotoOutput = frontPhoto
                }
            } catch {
                DispatchQueue.main.async { self.error = .configurationFailed(error.localizedDescription) }
            }
        }

        // Setup audio
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let input = try AVCaptureDeviceInput(device: audioDevice)
                if multiCamSession.canAddInput(input) {
                    multiCamSession.addInput(input)
                    audioDeviceInput = input
                }

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: dataOutputQueue)
                if multiCamSession.canAddOutput(output) {
                    multiCamSession.addOutput(output)
                    audioOutput = output
                }
            } catch {
                DispatchQueue.main.async { self.error = .configurationFailed(error.localizedDescription) }
            }
        }
    }

    private func configureDevice(_ device: AVCaptureDevice, resolution: CaptureResolution, isFrontCamera: Bool = false) {
        try? device.lockForConfiguration()

        // ───── 1. 智能格式选择 ─────
        let multiCamFormats = device.formats.filter { $0.isMultiCamSupported }

        let bestFormat: AVCaptureDevice.Format?
        if isFrontCamera {
            // 前摄：选 1080p 格式（前摄本身分辨率有限，选 1080p 即可）
            let targetWidth: Int32 = 1920
            let targetHeight: Int32 = 1080
            let preferred = multiCamFormats.filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width >= targetHeight && d.width <= targetWidth && d.height >= targetHeight
            }.sorted { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let diffA = abs(Int(da.width) - Int(targetWidth)) + abs(Int(da.height) - Int(targetHeight))
                let diffB = abs(Int(db.width) - Int(targetWidth)) + abs(Int(db.height) - Int(targetHeight))
                return diffA < diffB
            }
            bestFormat = preferred.first ?? multiCamFormats.first
        } else {
            // 后摄：选最高分辨率多摄格式（提升画质）
            bestFormat = multiCamFormats.sorted { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) > Int(db.width) * Int(db.height)
            }.first
        }

        if let bestFormat {
            device.activeFormat = bestFormat

            // 设置帧率 30fps
            let targetFPS: Double = 30
            for range in bestFormat.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFPS && targetFPS <= range.maxFrameRate {
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                    break
                }
            }
        }

        // ───── 2. 连续自动对焦 ─────
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = true
        }

        // ───── 3. 连续自动曝光 ─────
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }

        // ───── 4. 连续自动白平衡 ─────
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }

        // ───── 5. 低光增强 ─────
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }

        // ───── 6. 镜头畸变校正 ─────
        if device.isGeometricDistortionCorrectionSupported {
            device.isGeometricDistortionCorrectionEnabled = true
        }

        device.unlockForConfiguration()
    }

    /// 配置视频防抖（需要在 connection 建立后调用）
    private func configureStabilization(for connection: AVCaptureConnection, isFront: Bool = false) {
        if connection.isVideoStabilizationSupported {
            // 前摄不加防抖（减少延迟），后摄用标准防抖
            connection.preferredVideoStabilizationMode = isFront ? .off : .standard
        }
    }

    /// 手动对焦到指定点（屏幕坐标 0~1）
    func focusAtPoint(_ point: CGPoint, isBack: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device = isBack ? self.backDeviceInput?.device : self.frontDeviceInput?.device
            guard let device, device.isFocusPointOfInterestSupported else { return }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus // 先对焦到该点
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()

                // 2秒后恢复连续自动对焦/曝光
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.sessionQueue.async {
                        do {
                            try device.lockForConfiguration()
                            if device.isFocusModeSupported(.continuousAutoFocus) {
                                device.focusMode = .continuousAutoFocus
                            }
                            if device.isExposureModeSupported(.continuousAutoExposure) {
                                device.exposureMode = .continuousAutoExposure
                            }
                            device.unlockForConfiguration()
                        } catch {
                            print("[CameraEngine] Failed to restore auto focus: \(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                print("[CameraEngine] Tap-to-focus failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Recording

    private func beginRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        let frontURL = tempDir.appendingPathComponent("splitcam_front_\(UUID().uuidString).mp4")
        let backURL = tempDir.appendingPathComponent("splitcam_back_\(UUID().uuidString).mp4")

        frontVideoURL = frontURL
        backVideoURL = backURL

        // Setup asset writers
        do {
            frontAssetWriter = try AVAssetWriter(outputURL: frontURL, fileType: .mp4)
            backAssetWriter = try AVAssetWriter(outputURL: backURL, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1080,
                AVVideoHeightKey: 1920
            ]

            frontVideoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            frontVideoWriterInput?.expectsMediaDataInRealTime = true
            if let input = frontVideoWriterInput {
                frontAssetWriter?.add(input)
            }

            backVideoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            backVideoWriterInput?.expectsMediaDataInRealTime = true
            if let input = backVideoWriterInput {
                backAssetWriter?.add(input)
            }

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = true
            if let audioInput = audioWriterInput {
                backAssetWriter?.add(audioInput)
            }

            frontAssetWriter?.startWriting()
            backAssetWriter?.startWriting()
        } catch {
            DispatchQueue.main.async {
                self.error = .recordingFailed(error.localizedDescription)
            }
            return
        }

        recordingStartTime = nil
        isWritingStarted = false

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingDuration = 0
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let startTime = self.recordingStartTime else { return }
                self.recordingDuration = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(startTime)
            }
        }
    }

    private func finishRecording(completion: @escaping ((front: URL, back: URL)?) -> Void) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }

        let group = DispatchGroup()

        group.enter()
        frontVideoWriterInput?.markAsFinished()
        frontAssetWriter?.finishWriting { group.leave() }

        group.enter()
        backVideoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()
        backAssetWriter?.finishWriting { group.leave() }

        group.notify(queue: sessionQueue) { [weak self] in
            guard let self,
                  let frontURL = self.frontVideoURL,
                  let backURL = self.backVideoURL else {
                completion(nil)
                return
            }
            self.frontAssetWriter = nil
            self.backAssetWriter = nil
            self.frontVideoWriterInput = nil
            self.backVideoWriterInput = nil
            self.audioWriterInput = nil
            self.isWritingStarted = false
            completion((front: frontURL, back: backURL))
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if output == frontVideoOutput {
            if isRecording && recordingStartTime == nil {
                recordingStartTime = timestamp
                frontAssetWriter?.startSession(atSourceTime: timestamp)
                backAssetWriter?.startSession(atSourceTime: timestamp)
                isWritingStarted = true
            }
            onFrontFrame?(sampleBuffer)
            onFrontFrameForRecording?(sampleBuffer)

            // Write front video (legacy dual-recording)
            if isRecording && isWritingStarted,
               let input = frontVideoWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else if output == backVideoOutput {
            onBackFrame?(sampleBuffer)
            onBackFrameForRecording?(sampleBuffer)

            // Write back video (legacy dual-recording)
            if isRecording && isWritingStarted,
               let input = backVideoWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else if output == audioOutput {
            onAudioSample?(sampleBuffer)

            // Write audio (legacy dual-recording)
            if isRecording && isWritingStarted,
               let input = audioWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            // 拍照失败也要计数，避免死锁
            handlePhotoCaptured(image: nil, isBack: output == backPhotoOutput)
            return
        }
        handlePhotoCaptured(image: image, isBack: output == backPhotoOutput)
    }

    private func handlePhotoCaptured(image: UIImage?, isBack: Bool) {
        if isBack {
            capturedBackPhoto = image
        } else {
            capturedFrontPhoto = image
        }
        photoCaptureCount += 1

        let totalExpected = (backPhotoOutput != nil ? 1 : 0) + (frontPhotoOutput != nil ? 1 : 0)
        if photoCaptureCount >= totalExpected {
            let back = capturedBackPhoto
            let front = capturedFrontPhoto
            let completion = photoCaptureCompletion
            photoCaptureCompletion = nil
            DispatchQueue.main.async {
                completion?(back, front)
            }
        }
    }
}

// MARK: - Supporting Types

enum CaptureResolution {
    case hd720p
    case hd1080p

    var width: Int32 {
        switch self {
        case .hd720p: return 1280
        case .hd1080p: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .hd720p: return 720
        case .hd1080p: return 1080
        }
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

enum CameraError: Error, LocalizedError {
    case multiCamNotSupported
    case configurationFailed(String)
    case permissionDenied
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .multiCamNotSupported:
            return "error.multiCamNotSupported".localized
        case .configurationFailed(let msg):
            return "error.configFailed".localized(msg)
        case .permissionDenied:
            return "error.permissionDenied".localized
        case .recordingFailed(let msg):
            return "error.recordingFailed".localized(msg)
        }
    }
}
