import Foundation
import AVFoundation

/// Raw values stay stable so existing video preferences survive an upgrade.
enum ResolutionQuality: String, CaseIterable {
    case low
    case standard
    case high

    var displayName: String { "quality.\(rawValue)".localized }
    var detail: String { "quality.\(rawValue).detail".localized }

    var shortLabel: String {
        switch self {
        case .low: "LOW"
        case .standard: "SD"
        case .high: "HD"
        }
    }

    var symbol: String {
        switch self {
        case .low: "arrow.down.right.and.arrow.up.left"
        case .standard: "circle.lefthalf.filled"
        case .high: "sparkles"
        }
    }

    var videoBitRate: Int {
        switch self {
        case .low: 3_000_000
        case .standard: 12_000_000
        case .high: 25_000_000
        }
    }

    /// Estimated decimal MB/min including the existing 128 kbps audio track.
    var estimatedMegabytesPerMinute: Int {
        Int((Double(videoBitRate + 128_000) * 60 / 8_000_000).rounded())
    }

    /// Standard/HD retain the existing 1080-based size; Low uses a 720-based
    /// canvas. Even dimensions are required by the HEVC encoder.
    func outputSize(for fullSize: CGSize) -> CGSize {
        guard self == .low else { return fullSize }
        return CGSize(
            width: (fullSize.width * 2 / 3 / 2).rounded() * 2,
            height: (fullSize.height * 2 / 3 / 2).rounded() * 2
        )
    }

    func videoOutputSettings(for fullSize: CGSize) -> [String: Any] {
        let size = outputSize(for: fullSize)
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ]
    }
}
