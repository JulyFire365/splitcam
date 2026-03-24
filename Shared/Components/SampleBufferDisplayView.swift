import SwiftUI
import AVFoundation
import CoreMedia

/// 用于显示 CMSampleBuffer 的 UIKit 视图（Metal 渲染）
struct SampleBufferDisplayView: UIViewRepresentable {
    let sampleBuffer: CMSampleBuffer

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        SampleBufferDisplayUIView()
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        uiView.enqueueIfNew(sampleBuffer)
    }
}

class SampleBufferDisplayUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var lastTimestamp: CMTime = .invalid

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    func enqueueIfNew(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts != lastTimestamp else { return }
        lastTimestamp = pts

        // If the layer entered an error state (e.g. after app backgrounding), flush and reset
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        // 确保 layer frame 已设置，避免首帧在零尺寸下被丢弃
        if displayLayer.frame.isEmpty && !bounds.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }

        displayLayer.enqueue(buffer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
