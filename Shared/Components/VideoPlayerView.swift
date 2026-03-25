import SwiftUI
import AVFoundation
import AVKit

/// AVPlayer 的 SwiftUI 包装视图
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
    private var statusObserver: NSKeyValueObservation?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(playerLayer)

        // 监听 player item 状态，就绪后确保显示首帧
        statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak player] item, _ in
            if item.status == .readyToPlay {
                // 如果 player 还没有播放，至少显示第一帧
                if player?.rate == 0 {
                    player?.play()
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        statusObserver?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
