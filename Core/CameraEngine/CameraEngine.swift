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
            self?.configureSession(resolution: resolution)
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

    // MARK: - Photo Capture

    /// 从当前帧捕获照片 (返回前后摄像头的 UIImage)
    func capturePhoto(frontBuffer: CMSampleBuffer?, backBuffer: CMSampleBuffer?) -> (front: UIImage?, back: UIImage?) {
        let frontImage = frontBuffer.flatMap { imageFromBuffer($0) }
        let backImage = backBuffer.flatMap { imageFromBuffer($0) }
        return (front: frontImage, back: backImage)
    }

    private func imageFromBuffer(_ buffer: CMSampleBuffer) -> UIImage? {
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
                // Ignore zoom errors silently
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

        // Setup back camera — prefer ultra-wide for 0.5x/1x/3x zoom support
        let backCamera: AVCaptureDevice? =
            AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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
                    }
                }

                configureDevice(backCamera, resolution: resolution)

                // Default to 1x (wide) zoom — on ultra-wide this is factor 2.0
                if backCamera.deviceType == .builtInUltraWideCamera {
                    try? backCamera.lockForConfiguration()
                    let wide = min(2.0, backCamera.maxAvailableVideoZoomFactor)
                    backCamera.videoZoomFactor = wide
                    backCamera.unlockForConfiguration()
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
                    }
                }

                configureDevice(frontCamera, resolution: resolution)
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

    private func configureDevice(_ device: AVCaptureDevice, resolution: CaptureResolution) {
        try? device.lockForConfiguration()
        if !device.activeFormat.isMultiCamSupported {
            let formats = device.formats.filter { $0.isMultiCamSupported }
            if let bestFormat = formats.first(where: {
                let dims = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return dims.width >= resolution.width && dims.height >= resolution.height
            }) ?? formats.last {
                device.activeFormat = bestFormat
            }
        }
        device.unlockForConfiguration()
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

            // Write front video
            if isRecording && isWritingStarted,
               let input = frontVideoWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else if output == backVideoOutput {
            onBackFrame?(sampleBuffer)

            // Write back video
            if isRecording && isWritingStarted,
               let input = backVideoWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        } else if output == audioOutput {
            // Write audio
            if isRecording && isWritingStarted,
               let input = audioWriterInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
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
            return "此设备不支持多摄像头同时录制，需要 iPhone XS 或更新机型"
        case .configurationFailed(let msg):
            return "摄像头配置失败：\(msg)"
        case .permissionDenied:
            return "请在设置中允许 SplitCam 访问摄像头和麦克风"
        case .recordingFailed(let msg):
            return "录制失败：\(msg)"
        }
    }
}
