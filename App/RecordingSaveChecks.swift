#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import AVFoundation
import Photos

/// Test-only Photos adapter. The sequential harness mutates it only between awaits.
private final class CheckPhotoLibrary: VideoPhotoLibrary, @unchecked Sendable {
    var status: PHAuthorizationStatus = .notDetermined
    var writeFails = false
    var writes = 0
    func authorizationStatus() -> PHAuthorizationStatus { status }
    func requestAuthorization() async -> PHAuthorizationStatus {
        status = .denied
        return status
    }
    func addVideo(at url: URL) async throws {
        if writeFails { throw NSError(domain: "SplitCam.CheckPhotos", code: 1) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw CheckFailure("No video track") }
        let size = try await track.load(.naturalSize)
        guard size == CGSize(width: 720, height: 960) else { throw CheckFailure("Wrong output size") }
        _ = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
        writes += 1
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@MainActor private final class RecordingSaveChecks: ObservableObject {
    @Published var lines: [String] = []
    @Published var finished = false
    @Published var passed = false
    private let library: CheckPhotoLibrary
    private let store: PendingVideoStore
    var model: CameraViewModel

    init() {
        let library = CheckPhotoLibrary()
        let store = PendingVideoStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("SaveChecks-\(UUID().uuidString)"))
        self.library = library
        self.store = store
        self.model = CameraViewModel(pendingVideoStore: store, albumSaver: .init(library: library))
    }

    func run() async {
        guard lines.isEmpty else { return }
        lines.append("Running production capture/save pipeline…")
        let oldQuality = AppSettings.shared.defaultVideoQuality
        AppSettings.shared.defaultVideoQuality = .low
        defer {
            AppSettings.shared.defaultVideoQuality = oldQuality
            finished = true
            let report = lines.joined(separator: "\n")
            try? report.write(to: ScreenshotSupport.documents.appendingPathComponent("recording-save-checks.txt"), atomically: true, encoding: .utf8)
        }
        do {
            prepareModel()
            model.toggleRecording()
            model.toggleRecording()
            try await waitForSave()
            try require(!model.isRecording && model.pendingVideoCount == 0 && model.errorMessage == "error.videoNoFrames".localized, "Empty capture state")
            lines.append("PASS empty recording: clear error, no stuck overlay")

            try await recordFixture()
            try require(model.photoAccessDenied && model.pendingVideoCount == 1, "First authorization denial")
            try require(store.pendingURLs().count == 1, "Completed video not retained")
            lines.append("PASS first authorization denied: encoded file retained")

            model = CameraViewModel(pendingVideoStore: store, albumSaver: .init(library: library))
            try require(model.pendingVideoCount == 1, "Relaunch recovery")
            library.status = .authorized
            library.writeFails = true
            model.retryPendingVideoSaves()
            try await waitForSave()
            try require(model.pendingVideoCount == 1 && model.errorMessage == "error.videoAlbumSave".localized, "Write failure distinction")
            lines.append("PASS recreated model recovers file; Photos write failure stays retryable")

            library.writeFails = false
            model.retryPendingVideoSaves()
            try await waitForSave()
            try require(model.pendingVideoCount == 0 && model.lastSavedThumbnail != nil && library.writes == 1, "Retry failed")
            try require(store.pendingURLs().isEmpty, "Saved file still queued")
            lines.append("PASS retry succeeds without re-recording; thumbnail and cleanup confirmed")

            prepareModel()
            for _ in 0..<2 { try await recordFixture() }
            try require(library.writes == 3 && model.pendingVideoCount == 0, "Subsequent recordings failed")
            lines.append("PASS two subsequent recordings; stop/start blocked while finishing")

            // Leave one known retained fixture for inspecting the real camera alert/retry UI.
            library.status = .denied
            try await recordFixture()
            try require(model.pendingVideoCount == 1 && model.photoAccessDenied, "Inspection fixture")
            // Simulates the user subsequently enabling permission in Settings.
            library.status = .authorized
            passed = true
            lines.append("PASS all checks. Inspect UI, then tap Retry Save (test Photos only).")
        } catch {
            lines.append("FAIL \(error)")
        }
    }

    private func prepareModel() {
        model.camerasReady = true
        model.shootingMode = .video
        model.aspectRatio = .ratio3_4
        model.configureRecordingCallbacks()
    }

    private func recordFixture() async throws {
        model.showError = false
        model.toggleRecording()
        try require(model.isRecording, "Start rejected unexpectedly")
        let engine = model.cameraEngine
        try await Task.detached {
            for index in 0..<12 {
                let time = CMTime(value: Int64(index + 90), timescale: 30)
                engine.onFrontFrameForRecording?(try Self.sample(color: CIColor.green, at: time))
                engine.onBackFrameForRecording?(try Self.sample(color: CIColor.blue, at: time))
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }.value
        model.toggleRecording()
        try require(model.isProcessing && !model.isRecording, "Finishing not locked")
        model.toggleRecording()
        try require(!model.isRecording, "Rapid restart bypassed finishing lock")
        try await waitForSave()
    }

    private func waitForSave() async throws {
        for _ in 0..<1000 {
            if !model.isProcessing { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw CheckFailure("Save did not settle within 20 seconds")
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message) }
    }

    nonisolated private static func sample(color: CIColor, at time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 480, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { throw CheckFailure("Fixture pixel buffer") }
        CIContext().render(CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)), to: pixel)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if let description {
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: description,
                                                    sampleTiming: &timing, sampleBufferOut: &sample)
        }
        guard let sample else { throw CheckFailure("Fixture sample buffer") }
        return sample
    }
}

struct RecordingSaveCheckView: View {
    @StateObject private var checks = RecordingSaveChecks()
    @State private var inspecting = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(checks.lines.enumerated()), id: \.offset) { _, line in Text(line) }
                if checks.finished && checks.passed {
                    Button("Inspect retained video UI") { inspecting = true }
                }
            }
            .navigationTitle("Recording / Save QA")
            .task { await checks.run() }
            .fullScreenCover(isPresented: $inspecting) {
                CameraView(mode: .dualCamera, viewModel: checks.model)
            }
        }
    }
}
#endif
