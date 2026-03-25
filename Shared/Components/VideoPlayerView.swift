import SwiftUI
import AVFoundation
import AVKit

// MARK: - 合拍预览视图（缩略图 + 播放器 全部在 UIKit 层处理）

struct DuetPreviewView: UIViewRepresentable {
    let player: AVPlayer?
    let thumbnail: UIImage?

    func makeUIView(context: Context) -> DuetPreviewUIView {
        DuetPreviewUIView()
    }

    func updateUIView(_ uiView: DuetPreviewUIView, context: Context) {
        uiView.update(player: player, thumbnail: thumbnail)
    }
}

class DuetPreviewUIView: UIView {
    private let thumbnailView = UIImageView()
    private let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        // 缩略图层 — 立刻可见
        thumbnailView.contentMode = .scaleAspectFill
        thumbnailView.clipsToBounds = true
        addSubview(thumbnailView)

        // 播放器层 — 视频加载后覆盖缩略图
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = UIColor.clear.cgColor
        // 强制 HDR → SDR 色调映射，防止户外视频预览过曝
        if #available(iOS 17.2, *) {
            playerLayer.toneMapToStandardDynamicRange = true
        }
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(player: AVPlayer?, thumbnail: UIImage?) {
        thumbnailView.image = thumbnail

        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        thumbnailView.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 普通视频播放视图（非合拍场景）

struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(player: player)
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

class PlayerUIView: UIView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
