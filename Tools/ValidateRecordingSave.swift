// Compile with VideoRecordingSession.swift, VideoQuality.swift,
// VideoAlbumSaver.swift and String+L10n.swift. No real Photos writes or permission prompts.
import Foundation
import AVFoundation
import CoreImage
import Photos

private final class TestPhotoLibrary: VideoPhotoLibrary, @unchecked Sendable {
    var status: PHAuthorizationStatus = .notDetermined
    var requestedStatus: PHAuthorizationStatus = .authorized
    var writeFails = false
    var requests = 0
    var writes = 0
    func authorizationStatus() -> PHAuthorizationStatus { status }
    func requestAuthorization() async -> PHAuthorizationStatus {
        requests += 1
        status = requestedStatus
        return status
    }
    func addVideo(at url: URL) async throws {
        precondition(FileManager.default.fileExists(atPath: url.path))
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(FileManager.default.fileExists(atPath: url.path), "Source was removed during Photos transaction")
        if writeFails { throw NSError(domain: "TestPhotoLibrary", code: 42) }
        writes += 1
    }
}

@main enum ValidateRecordingSave {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SplitCam-Save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = VideoRecordingSession()
        let fullSize = CGSize(width: 1080, height: 1440)
        var fixture: URL!

        // Real HEVC + AAC, including cold-start audio preceding the first video timestamp.
        for quality in ResolutionQuality.allCases {
            let url = root.appendingPathComponent("\(quality.rawValue).mp4")
            let id = try recorder.start(url: url, fullSize: fullSize, quality: quality) { _ in }
            recorder.appendAudio(try audio(at: CMTime(seconds: 99, preferredTimescale: 44100)))
            for frame in 0..<30 {
                let time = CMTime(value: Int64(3000 + frame), timescale: 30)
                try await append(recorder, at: time)
                recorder.appendAudio(try audio(at: time))
            }
            let saved = try await finish(recorder, id: id).get()
            precondition(saved == url)
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let size = try await videos[0].load(.naturalSize)
            let duration = try await asset.load(.duration)
            precondition(size == quality.outputSize(for: fullSize))
            precondition(abs(duration.seconds - 1) < 0.05)
            precondition(!audios.isEmpty, "Expected an AAC audio track")
            let reader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(audioOutput)
            precondition(reader.startReading())
            precondition(audioOutput.copyNextSampleBuffer() != nil, "Audio must decode")
            reader.cancelReading()
            _ = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
            fixture = url
            print("PASS \(quality.rawValue): \(Int(size.width))×\(Int(size.height)), 1 second, video and audio decode")
        }

        // No accepted frames is a distinct result, not generic save failure or silent success.
        let empty = root.appendingPathComponent("empty.mp4")
        let emptyID = try recorder.start(url: empty, fullSize: fullSize, quality: .low) { _ in }
        let emptyResult = await finish(recorder, id: emptyID)
        guard case .failure(.noVideoFrames) = emptyResult else { fatalError("Empty capture was not distinguished") }
        precondition(!FileManager.default.fileExists(atPath: empty.path))

        // Quick single-frame recordings, repeated on the same session object.
        for index in 0..<12 {
            let url = root.appendingPathComponent("quick-\(index).mp4")
            let id = try recorder.start(url: url, fullSize: fullSize, quality: .low) { _ in }
            do {
                _ = try recorder.start(url: root.appendingPathComponent("must-not-start.mp4"), fullSize: fullSize, quality: .low) { _ in }
                fatalError("Overlapping start was accepted")
            } catch VideoRecordingSession.Failure.busy {}
            try await append(recorder, at: CMTime(value: 10, timescale: 1))
            _ = try await finish(recorder, id: id).get()
            let duration = try await AVURLAsset(url: url).load(.duration)
            precondition(duration.seconds > 0)
            _ = try await AVAssetImageGenerator(asset: AVURLAsset(url: url)).image(at: .zero)
        }
        print("PASS empty capture, overlapping-start guard and 12 consecutive single-frame recordings")

        // Hold a render in flight, enqueue stop, then submit a late frame.
        let raceURL = root.appendingPathComponent("in-flight.mp4")
        let raceID = try recorder.start(url: raceURL, fullSize: fullSize, quality: .low) { _ in }
        try await append(recorder, at: .zero)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writing = Task.detached {
            for _ in 0..<500 {
                if recorder.appendVideo(at: CMTime(value: 1, timescale: 30), render: { size in
                    entered.signal()
                    precondition(release.wait(timeout: .now() + 5) == .success)
                    return picture(size)
                }) { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            fatalError("Render never became ready")
        }
        precondition(entered.wait(timeout: .now() + 5) == .success)
        let results = AsyncStream<Result<URL, VideoRecordingSession.Failure>> { continuation in
            recorder.finish(id: raceID) { continuation.yield($0); continuation.finish() }
        }
        release.signal()
        precondition(!recorder.appendVideo(at: CMTime(value: 2, timescale: 30), render: picture))
        try await writing.value
        for await result in results {
            let completed = try result.get()
            precondition(completed == raceURL)
        }
        let raceDuration = try await AVURLAsset(url: raceURL).load(.duration)
        precondition(abs(raceDuration.seconds - 2.0 / 30) < 0.01)
        print("PASS stop waits for in-flight append; late frame is rejected")

        // A stale finish request must not clear a newer context.
        let nextURL = root.appendingPathComponent("after-stale.mp4")
        let nextID = try recorder.start(url: nextURL, fullSize: fullSize, quality: .low) { _ in }
        guard case .failure(.busy) = await finish(recorder, id: raceID) else { fatalError("Stale finish accepted") }
        try await append(recorder, at: .zero)
        _ = try await finish(recorder, id: nextID).get()
        let existingBytes = try Data(contentsOf: nextURL)
        do {
            _ = try recorder.start(url: nextURL, fullSize: fullSize, quality: .low) { _ in }
            fatalError("Existing output should be protected")
        } catch {}
        let protectedBytes = try Data(contentsOf: nextURL)
        precondition(protectedBytes == existingBytes)
        print("PASS stale completion isolation and existing-file protection")

        let store = PendingVideoStore(directory: root.appendingPathComponent("pending"))
        let staging = try store.makeRecordingURL()
        try FileManager.default.copyItem(at: fixture, to: staging)
        precondition(store.pendingURLs().isEmpty)
        await store.recoverFinishedRecordings()
        let ready = store.pendingURLs()[0]
        let library = TestPhotoLibrary()
        let saver = VideoAlbumSaver(library: library)
        library.requestedStatus = .denied
        do { try await saver.save(ready); fatalError("Denied save succeeded") }
        catch VideoAlbumSaveError.permissionDenied {}
        precondition(library.requests == 1 && library.writes == 0)
        precondition(PendingVideoStore(directory: store.directory).pendingURLs() == [ready])
        library.status = .restricted
        do { try await saver.save(ready); fatalError("Restricted save succeeded") }
        catch VideoAlbumSaveError.permissionRestricted {}
        library.status = .authorized
        library.writeFails = true
        do { try await saver.save(ready); fatalError("Injected Photos failure succeeded") }
        catch VideoAlbumSaveError.albumWrite {}
        precondition(FileManager.default.fileExists(atPath: ready.path))
        library.writeFails = false
        try await saver.save(ready)
        precondition(library.writes == 1)
        store.markSaved(ready)
        precondition(store.pendingURLs().isEmpty && !FileManager.default.fileExists(atPath: ready.path))
        library.status = .notDetermined
        library.requestedStatus = .authorized
        try await saver.save(fixture)
        precondition(library.requests == 2 && library.writes == 2)
        print("PASS first authorization, denied/restricted access, write failure, restart recovery and retry without re-encoding")
        print("PASS — all recording/save regressions. Artifacts: \(root.path)")
    }

    static func finish(_ recorder: VideoRecordingSession, id: UUID) async -> Result<URL, VideoRecordingSession.Failure> {
        await withCheckedContinuation { continuation in
            recorder.finish(id: id) { continuation.resume(returning: $0) }
        }
    }

    static func append(_ recorder: VideoRecordingSession, at time: CMTime) async throws {
        for _ in 0..<1000 {
            if recorder.appendVideo(at: time, render: picture) { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NSError(domain: "Validation.WriterNotReady", code: 1)
    }

    static func picture(_ size: CGSize) -> CIImage {
        CIImage(color: CIColor(red: 0.1, green: 0.65, blue: 0.8)).cropped(to: CGRect(origin: .zero, size: size))
    }

    static func audio(at time: CMTime) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        precondition(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr)
        let samples = (0..<1470).map { Int16(sin(Double($0) * 2 * .pi * 440 / 44100) * 8000) }
        var block: CMBlockBuffer?
        precondition(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 2,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: samples.count * 2,
            flags: 0, blockBufferOut: &block) == noErr)
        samples.withUnsafeBytes {
            precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) == noErr)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44100), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
            sampleCount: samples.count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        return sample!
    }
}
