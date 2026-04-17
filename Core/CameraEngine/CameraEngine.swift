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
    private var photoCaptureExpected = 0

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
    /// 只走后摄 ISP 管线触发一次系统快门声。iOS 无法关闭 capturePhoto 的系统快门音，
    /// 同时对前后两个 output 调用会产生双击声，快速连拍时多对声音叠加非常明显。
    /// 前摄图像由 VideoDataOutput 的最近一帧提供（CameraViewModel 已实现该降级路径）。
    func capturePhotoWithISP(completion: @escaping (UIImage?, UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.photoCaptureCompletion = completion
            self.capturedBackPhoto = nil
            self.capturedFrontPhoto = nil
            self.photoCaptureCount = 0
            self.photoCaptureExpected = 0

            guard let backOutput = self.backPhotoOutput else {
                // 无后摄 output，整个 ISP 路径失败，让上层降级处理两个方向的 frameBuffer
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }

            self.photoCaptureExpected = 1
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            backOutput.capturePhoto(with: settings, delegate: self)

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

    // MARK: - Device Capability

    /// 设备是否有超广角后摄（决定 UI 是否显示 0.5x）
    static var hasUltraWideCamera: Bool {
        AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil
    }

    /// 标记是否正在切换镜头，防止重入
    private var isSwitchingLens = false

    // MARK: - Zoom

    func setZoom(_ level: ZoomLevel) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let device = self.backDeviceInput?.device else { return }

            let currentIsUltraWide = device.deviceType == .builtInUltraWideCamera
            let needsUltraWide = (level == .ultraWide)

            // 录制中不切换镜头（会导致帧丢失）
            if needsUltraWide != currentIsUltraWide && !self.isRecording {
                let switched = self.switchBackCameraLens(toUltraWide: needsUltraWide)
                if !switched && needsUltraWide {
                    // 切换失败，不做任何操作
                    print("[CameraEngine] Lens switch failed, staying on current lens")
                    return
                }
            }

            // 切换后重新获取 device
            guard let currentDevice = self.backDeviceInput?.device else { return }
            let isUltraWide = currentDevice.deviceType == .builtInUltraWideCamera

            let factor: CGFloat
            if isUltraWide {
                switch level {
                case .ultraWide:  factor = 1.0   // 超广角原生 0.5x
                case .wide:       factor = 2.0   // 数码变焦到 1x
                case .telephoto:  factor = 6.0   // 数码变焦到 3x
                }
            } else {
                switch level {
                case .ultraWide:  factor = 1.0   // 不应到达此分支
                case .wide:       factor = 1.0   // 主摄原生 1x
                case .telephoto:  factor = 3.0   // 数码变焦到 3x
                }
            }

            let clamped = min(max(factor, currentDevice.minAvailableVideoZoomFactor),
                              currentDevice.maxAvailableVideoZoomFactor)
            do {
                try currentDevice.lockForConfiguration()
                currentDevice.videoZoomFactor = clamped
                currentDevice.unlockForConfiguration()
            } catch {
                print("[CameraEngine] Failed to set zoom: \(error)")
            }

            DispatchQueue.main.async {
                self.currentZoom = level
            }
        }
    }

    // MARK: - Dynamic Lens Switch (安全热切换)

    /// 安全切换后摄镜头：主摄 ↔ 超广角
    /// 全程在 beginConfiguration/commitConfiguration 内，失败自动回滚
    /// - Returns: 是否切换成功
    private func switchBackCameraLens(toUltraWide: Bool) -> Bool {
        guard !isSwitchingLens else { return false }
        isSwitchingLens = true
        defer { isSwitchingLens = false }

        let targetType: AVCaptureDevice.DeviceType = toUltraWide ? .builtInUltraWideCamera : .builtInWideAngleCamera

        // 1. 已经是目标镜头
        guard let currentInput = backDeviceInput,
              currentInput.device.deviceType != targetType else { return true }

        // 2. 查找目标设备
        guard let targetDevice = AVCaptureDevice.default(targetType, for: .video, position: .back) else {
            print("[CameraEngine] Target device not found: \(targetType)")
            return false
        }

        // 3. 预检查多摄格式
        let multiCamFormats = targetDevice.formats.filter { $0.isMultiCamSupported }
        guard !multiCamFormats.isEmpty else {
            print("[CameraEngine] No multi-cam formats for target device")
            return false
        }

        // 4. 预创建新 Input（在修改 session 之前）
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: targetDevice)
        } catch {
            print("[CameraEngine] Failed to create input: \(error)")
            return false
        }

        // 5. 保存回滚状态
        let oldInput = currentInput

        multiCamSession.beginConfiguration()

        // 6. 移除旧的后摄连接（仅后摄，保留前摄）
        let connectionsToRemove = multiCamSession.connections.filter { conn in
            conn.inputPorts.contains { $0.sourceDevicePosition == .back }
        }
        for conn in connectionsToRemove {
            multiCamSession.removeConnection(conn)
        }
        backConnection = nil

        // 7. 移除旧 Photo Output（需重建）
        if let oldPhoto = backPhotoOutput {
            multiCamSession.removeOutput(oldPhoto)
            backPhotoOutput = nil
        }

        // 8. 移除旧 Input
        multiCamSession.removeInput(oldInput)

        // 9. 尝试添加新 Input
        guard multiCamSession.canAddInput(newInput) else {
            print("[CameraEngine] Cannot add new input, rolling back")
            rollbackBackCamera(oldInput: oldInput)
            multiCamSession.commitConfiguration()
            return false
        }

        multiCamSession.addInputWithNoConnections(newInput)
        backDeviceInput = newInput

        // 10. 重建视频连接
        guard let videoPort = newInput.ports(for: .video, sourceDeviceType: targetDevice.deviceType, sourceDevicePosition: .back).first,
              let videoOutput = backVideoOutput else {
            print("[CameraEngine] Cannot get video port, rolling back")
            multiCamSession.removeInput(newInput)
            rollbackBackCamera(oldInput: oldInput)
            multiCamSession.commitConfiguration()
            return false
        }

        let videoConn = AVCaptureConnection(inputPorts: [videoPort], output: videoOutput)
        guard multiCamSession.canAddConnection(videoConn) else {
            print("[CameraEngine] Cannot add video connection, rolling back")
            multiCamSession.removeInput(newInput)
            rollbackBackCamera(oldInput: oldInput)
            multiCamSession.commitConfiguration()
            return false
        }

        multiCamSession.addConnection(videoConn)
        backConnection = videoConn
        videoConn.videoOrientation = .portrait
        configureStabilization(for: videoConn)

        // 11. 重建 Photo Output + 连接
        let newPhoto = AVCapturePhotoOutput()
        newPhoto.maxPhotoQualityPrioritization = .balanced
        if multiCamSession.canAddOutput(newPhoto) {
            multiCamSession.addOutputWithNoConnections(newPhoto)
            if let photoPort = newInput.ports(for: .video, sourceDeviceType: targetDevice.deviceType, sourceDevicePosition: .back).first {
                let photoConn = AVCaptureConnection(inputPorts: [photoPort], output: newPhoto)
                if multiCamSession.canAddConnection(photoConn) {
                    multiCamSession.addConnection(photoConn)
                    photoConn.videoOrientation = .portrait
                }
            }
            backPhotoOutput = newPhoto
        }

        // 12. 配置设备格式（分辨率、帧率等）
        configureDevice(targetDevice, resolution: .hd1080p)

        multiCamSession.commitConfiguration()

        let isUW = toUltraWide
        DispatchQueue.main.async { self.isBackUltraWide = isUW }

        print("[CameraEngine] Lens switch successful: \(toUltraWide ? "ultra-wide" : "wide-angle")")
        return true
    }

    /// 回滚：恢复旧的后摄 Input + 连接
    private func rollbackBackCamera(oldInput: AVCaptureDeviceInput) {
        guard multiCamSession.canAddInput(oldInput) else {
            print("[CameraEngine] CRITICAL: Cannot rollback camera input!")
            return
        }

        multiCamSession.addInputWithNoConnections(oldInput)
        backDeviceInput = oldInput

        let deviceType = oldInput.device.deviceType

        // 恢复视频连接
        if let port = oldInput.ports(for: .video, sourceDeviceType: deviceType, sourceDevicePosition: .back).first,
           let videoOutput = backVideoOutput {
            let conn = AVCaptureConnection(inputPorts: [port], output: videoOutput)
            if multiCamSession.canAddConnection(conn) {
                multiCamSession.addConnection(conn)
                backConnection = conn
                conn.videoOrientation = .portrait
                configureStabilization(for: conn)
            }
        }

        // 恢复 Photo Output
        let photo = AVCapturePhotoOutput()
        photo.maxPhotoQualityPrioritization = .balanced
        if multiCamSession.canAddOutput(photo) {
            multiCamSession.addOutputWithNoConnections(photo)
            if let photoPort = oldInput.ports(for: .video, sourceDeviceType: deviceType, sourceDevicePosition: .back).first {
                let photoConn = AVCaptureConnection(inputPorts: [photoPort], output: photo)
                if multiCamSession.canAddConnection(photoConn) {
                    multiCamSession.addConnection(photoConn)
                    photoConn.videoOrientation = .portrait
                }
            }
            backPhotoOutput = photo
        }

        print("[CameraEngine] Rollback successful")
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

        if photoCaptureCount >= photoCaptureExpected {
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
