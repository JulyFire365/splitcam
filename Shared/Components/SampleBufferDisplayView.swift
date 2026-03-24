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
