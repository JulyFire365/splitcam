import SwiftUI
import AVFoundation

/// 用于显示 CMSampleBuffer 的 UIKit 视图（Metal 渲染）
struct SampleBufferDisplayView: UIViewRepresentable {
    let sampleBuffer: CMSampleBuffer

    func makeUIView(context: Context) -> SampleBufferDisplayUIView {
        SampleBufferDisplayUIView()
    }

    func updateUIView(_ uiView: SampleBufferDisplayUIView, context: Context) {
        uiView.displayLayer.enqueue(sampleBuffer)
    }
}

class SampleBufferDisplayUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

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

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
}
