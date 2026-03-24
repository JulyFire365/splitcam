import SwiftUI
import AVFoundation

/// 编辑页面 ViewModel
@MainActor
final class EditorViewModel: ObservableObject {
    // MARK: - State

    @Published var splitMode: SplitMode = .leftRight {
        didSet { layoutEngine.splitMode = splitMode }
    }
    @Published var borderType: BorderType = .thin
    @Published var borderColor: Color = .white
    @Published var borderWidth: CGFloat = 2

    let layoutEngine = SplitLayoutEngine()
    let videoComposer = VideoComposer()

    private var videoAURL: URL?
    private var videoBURL: URL?

    // MARK: - Available Colors

    let availableColors: [Color] = [
        .white, .black, .gray,
        .red, .orange, .yellow,
        .green, .blue, .purple
    ]

    // MARK: - Setup

    func loadVideos(videoA: URL, videoB: URL) {
        videoAURL = videoA
        videoBURL = videoB
    }

    // MARK: - Actions

    func setBorderType(_ type: BorderType) {
        borderType = type
        borderWidth = type.defaultWidth
        layoutEngine.borderStyle = BorderStyleConfig(
            style: type,
            color: borderColor,
            width: borderWidth
        )
    }

    func setBorderColor(_ color: Color) {
        borderColor = color
        layoutEngine.borderStyle.color = color
    }

    func setBorderWidth(_ width: CGFloat) {
        borderWidth = width
        layoutEngine.borderStyle.width = width
    }

    /// 合成并导出视频
    func composeAndExport(
        resolution: ExportResolution = .hd1080p,
        completion: @escaping (Result<URL, ComposerError>) -> Void
    ) {
        guard let videoA = videoAURL, let videoB = videoBURL else {
            completion(.failure(.invalidInput("视频文件缺失")))
            return
        }

        videoComposer.compose(
            videoA: videoA,
            videoB: videoB,
            splitMode: layoutEngine.splitMode,
            splitRatio: layoutEngine.splitRatio,
            borderStyle: layoutEngine.borderStyle,
            resolution: resolution,
            completion: completion
        )
    }
}
