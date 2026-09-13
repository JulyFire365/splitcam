// Compile alongside Core/CameraEngine/VideoQuality.swift and String+L10n.swift.
// Encodes the same moving fixture with production settings, checks dimensions,
// decodability and real file sizes. Outputs go to a unique temporary directory.
import Foundation
import AVFoundation
import CoreImage

@main enum ValidateVideoQuality {
    static func main() async throws {
        let fullSizes = [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1440), CGSize(width: 1080, height: 1080), CGSize(width: 1920, height: 1080)]
        let lowSizes = [CGSize(width: 720, height: 1280), CGSize(width: 720, height: 960), CGSize(width: 720, height: 720), CGSize(width: 1280, height: 720)]
        for (full, expected) in zip(fullSizes, lowSizes) {
            precondition(ResolutionQuality.low.outputSize(for: full) == expected)
            precondition(ResolutionQuality.standard.outputSize(for: full) == full)
            precondition(ResolutionQuality.high.outputSize(for: full) == full)
        }
        precondition(ResolutionQuality(rawValue: "standard") == .standard)
        precondition(ResolutionQuality(rawValue: "high") == .high)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SplitCam-Quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var fileSizes: [ResolutionQuality: Int] = [:]
        let ci = CIContext()
        for quality in ResolutionQuality.allCases {
            let output = directory.appendingPathComponent("\(quality.rawValue).mp4")
            let size = quality.outputSize(for: fullSizes[0])
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: quality.videoOutputSettings(for: fullSizes[0]))
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
            precondition(writer.canAdd(input))
            writer.add(input)
            precondition(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
            for frame in 0..<90 {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                let pixel = buffer!
                // Identical source texture and motion, then scale for each preset.
                let fixture = noise.transformed(by: CGAffineTransform(translationX: CGFloat(frame * 7), y: CGFloat(frame * 3)))
                    .cropped(to: CGRect(origin: .zero, size: fullSizes[0]))
                    .transformed(by: CGAffineTransform(scaleX: size.width / fullSizes[0].width, y: size.height / fullSizes[0].height))
                ci.render(fixture, to: pixel)
                precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
            }
            writer.endSession(atSourceTime: CMTime(seconds: 3, preferredTimescale: 30))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error! }
            let asset = AVURLAsset(url: output)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let encodedSize = try await tracks[0].load(.naturalSize)
            precondition(encodedSize == size)
            let duration = try await asset.load(.duration)
            precondition(abs(duration.seconds - 3) < 0.05)
            let generator = AVAssetImageGenerator(asset: asset)
            _ = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 30))
            let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            fileSizes[quality] = bytes
            print("\(quality.rawValue): \(Int(size.width))x\(Int(size.height)), \(bytes) bytes; decode OK")
        }
        precondition(fileSizes[.low]! < fileSizes[.standard]!, "Low must produce a smaller actual file")
        precondition(fileSizes[.standard]! < fileSizes[.high]!, "Standard must remain smaller than High")
        print("PASS — 4 aspect ratios, legacy values and 3 real HEVC exports. Files: \(directory.path)")
    }
}
