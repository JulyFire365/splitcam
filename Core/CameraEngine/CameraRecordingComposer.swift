import AVFoundation
import CoreImage

/// Camera buffers and main-actor layout/import state cross threads only through
/// these short locked snapshots. compose is called solely on the writer queue.
final class CameraRecordingComposer: @unchecked Sendable {
    struct Snapshot {
        var generation = UUID()
        var splitMode: SplitMode = .leftRight
        var splitRatio: CGFloat = 0.5
        var panelsSwapped = false
        var pipShape: PipShape = .roundedRect
        var pipScale: CGFloat = 0.3
        var pipOffset: CGSize = .zero
        var borderWidth: CGFloat = 0
        var isDuet = false
        var importedImage: CIImage?
        var importedVideoOutput: AVPlayerItemVideoOutput?
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var frontBuffer: CVPixelBuffer?
    private var backBuffer: CVPixelBuffer?
    // Only accessed while composing on the recorder's serial queue.
    private var cachedVideoOutput: AVPlayerItemVideoOutput?
    private var importedFrame: CIImage?
    private var cachedGeneration: UUID?

    func update(_ value: Snapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func updateFront(_ value: CVPixelBuffer?) {
        lock.lock()
        frontBuffer = value
        lock.unlock()
    }

    func updateBack(_ value: CVPixelBuffer?) {
        lock.lock()
        backBuffer = value
        lock.unlock()
    }

    func compose(in outputSize: CGSize) -> CIImage? {
        lock.lock()
        let state = snapshot
        let front = frontBuffer
        let backPB = backBuffer
        lock.unlock()
        guard let frontPB = front, state.isDuet || backPB != nil else { return nil }

        if cachedVideoOutput !== state.importedVideoOutput || cachedGeneration != state.generation {
            cachedVideoOutput = state.importedVideoOutput
            cachedGeneration = state.generation
            importedFrame = nil
        }
        if state.isDuet, let output = state.importedVideoOutput {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                importedFrame = CIImage(cvPixelBuffer: pixel, options: [
                    .colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                ])
            }
        }
        let currentOutputSize = outputSize
        let currentSplitMode = state.splitMode
        let currentSplitRatio = state.splitRatio
        let currentPanelsSwapped = state.panelsSwapped
        let currentPipShape = state.pipShape
        let currentPipScale = state.pipScale
        let currentPipOffset = state.pipOffset
        // 计算目标区域 — 用 SplitLayoutEngine 的静态方法保证预览与录制几何一致
        let frames: (first: CGRect, second: CGRect)
        if currentSplitMode == .pip {
            let pipRect = SplitLayoutEngine.pipRect(
                in: currentOutputSize,
                scale: currentPipScale,
                offset: currentPipOffset
            )
            frames = (CGRect(origin: .zero, size: currentOutputSize), pipRect)
        } else {
            let bw = state.borderWidth
            switch currentSplitMode {
            case .leftRight:
                let fw = currentOutputSize.width * currentSplitRatio - bw / 2
                let sx = currentOutputSize.width * currentSplitRatio + bw / 2
                let sw = currentOutputSize.width - sx
                frames = (CGRect(x: 0, y: 0, width: fw, height: currentOutputSize.height),
                          CGRect(x: sx, y: 0, width: sw, height: currentOutputSize.height))
            case .topBottom:
                let fh = currentOutputSize.height * currentSplitRatio - bw / 2
                let sy = currentOutputSize.height * currentSplitRatio + bw / 2
                let sh = currentOutputSize.height - sy
                frames = (CGRect(x: 0, y: 0, width: currentOutputSize.width, height: fh),
                          CGRect(x: 0, y: sy, width: currentOutputSize.width, height: sh))
            case .pip:
                frames = (CGRect(origin: .zero, size: currentOutputSize), .zero)
            }
        }

        // 获取 CIImage（合拍模式用导入内容替代后摄）
        let frontCI = CIImage(cvPixelBuffer: frontPB)
        let backCI: CIImage
        if state.isDuet {
            if let ci = importedFrame {
                backCI = ci
            } else if let img = state.importedImage {
                backCI = img
            } else {
                return nil
            }
        } else {
            guard let bpb = backPB else { return nil }
            backCI = CIImage(cvPixelBuffer: bpb)
        }

        let firstCI = currentPanelsSwapped ? frontCI : backCI
        let secondCI = currentPanelsSwapped ? backCI : frontCI

        var composite = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: currentOutputSize))
        let h = currentOutputSize.height

        composite = fitAndClip(firstCI, into: frames.first, outputHeight: h).composited(over: composite)

        let fittedSecond = fitAndClip(secondCI, into: frames.second, outputHeight: h)
        if currentSplitMode == .pip {
            let masked = applyPipMaskForRecording(fittedSecond, rect: frames.second, shape: currentPipShape, outputHeight: h)
            composite = masked.composited(over: composite)
        } else {
            composite = fittedSecond.composited(over: composite)
        }

        // 轻量锐化（CISharpenLuminance 性能极高，不影响帧率）
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(composite, forKey: kCIInputImageKey)
            sharpen.setValue(0.4, forKey: kCIInputSharpnessKey)
            if let sharpened = sharpen.outputImage {
                composite = sharpened
            }
        }
        return composite
    }

    /// CIImage aspect fill + clip（与 VideoComposer 中相同逻辑）
    private func fitAndClip(_ image: CIImage, into targetRect: CGRect, outputHeight: CGFloat) -> CIImage {
        let imageSize = image.extent.size
        guard targetRect.width > 0, targetRect.height > 0 else {
            return CIImage(color: .clear).cropped(to: .zero)
        }

        let scaleX = targetRect.width / imageSize.width
        let scaleY = targetRect.height / imageSize.height
        let scale = max(scaleX, scaleY)

        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let ciY = outputHeight - targetRect.origin.y - targetRect.height
        let ciRect = CGRect(x: targetRect.origin.x, y: ciY, width: targetRect.width, height: targetRect.height)

        let offsetX = ciRect.origin.x + (ciRect.width - scaledW) / 2
        let offsetY = ciRect.origin.y + (ciRect.height - scaledH) / 2

        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: ciRect)
    }

    /// PiP 遮罩（录制用，线程安全）
    private func applyPipMaskForRecording(_ image: CIImage, rect: CGRect, shape: PipShape, outputHeight: CGFloat) -> CIImage {
        let ciY = outputHeight - rect.origin.y - rect.height
        let ciRect = CGRect(x: rect.origin.x, y: ciY, width: rect.width, height: rect.height)

        let mw = Int(rect.width), mh = Int(rect.height)
        guard mw > 0, mh > 0 else { return image }

        guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8,
                                   bytesPerRow: mw * 4, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return image }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.setFillColor(gray: 1, alpha: 1)

        if shape == .circle {
            let s = min(CGFloat(mw), CGFloat(mh))
            ctx.fillEllipse(in: CGRect(x: (CGFloat(mw)-s)/2, y: (CGFloat(mh)-s)/2, width: s, height: s))
        } else {
            let path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: mw, height: mh),
                              cornerWidth: 12, cornerHeight: 12, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        guard let maskCG = ctx.makeImage() else { return image }
        let maskCI = CIImage(cgImage: maskCG)
            .transformed(by: CGAffineTransform(translationX: ciRect.origin.x, y: ciRect.origin.y))

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: image.extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }
}
