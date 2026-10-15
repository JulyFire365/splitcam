import AppKit
import AVFoundation
import CoreVideo

private let videoSize = CGSize(width: 1080, height: 1920)
private let frameRate: Int32 = 30
private let duration = 18.0
private let chapterDuration = 4.5

private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
private func smooth(_ value: Double) -> Double {
    let amount = clamp(value)
    return amount * amount * (3 - 2 * amount)
}
private func easeOut(_ value: Double) -> Double { 1 - pow(1 - clamp(value), 3) }

private struct Theme {
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
}

private let darkTheme = Theme(
    background: NSColor(srgbRed: 0.035, green: 0.048, blue: 0.065, alpha: 1),
    foreground: NSColor(srgbRed: 0.975, green: 0.965, blue: 0.94, alpha: 1),
    accent: NSColor(srgbRed: 0.36, green: 0.91, blue: 0.82, alpha: 1)
)
private let lightTheme = Theme(
    background: NSColor(srgbRed: 0.96, green: 0.95, blue: 0.925, alpha: 1),
    foreground: NSColor(srgbRed: 0.065, green: 0.075, blue: 0.10, alpha: 1),
    accent: NSColor(srgbRed: 0.31, green: 0.28, blue: 0.81, alpha: 1)
)

private final class PromoRenderer {
    let root: URL
    let output: URL
    let language: String
    let chinese: Bool
    let screenshots: [CGImage]
    let backs: [CGImage]
    let fronts: [CGImage]
    let icon: CGImage

    init(root: URL, language: String) throws {
        self.root = root
        self.language = language
        chinese = language == "zh-Hans"
        output = root.appendingPathComponent("Metadata/Promo/2026-10")
        func load(_ path: String) throws -> CGImage {
            let url = root.appendingPathComponent(path)
            guard let image = NSImage(contentsOf: url),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NSError(domain: "SplitCam.Promo.Asset", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing image: \(path)"])
            }
            return cgImage
        }
        screenshots = try ["split", "pip", "duet"].map { scene in
            let nativePath = "Metadata/Promo/2026-10/source/native/\(language)/\(scene).png"
            let rawPath = "Metadata/ASO/2026-09/raw/\(language)/\(scene).png"
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(nativePath).path) {
                return try load(nativePath)
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(rawPath).path) {
                return try load(rawPath)
            }
            let board = scene == "split" ? "01-split" : "02-pip"
            let source = try load("Metadata/ASO/2026-09/\(language)/\(board).png")
            let scale: CGFloat = 2778.0 / 2868.0
            let horizontalInset = (1284.0 - 1320.0 * scale) / 2.0
            let crop = CGRect(x: horizontalInset + 202 * scale, y: 782 * scale,
                              width: 916 * scale, height: 916 * 2868 / 1320 * scale)
            guard let cropped = source.cropping(to: crop),
                  let context = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8,
                    bytesPerRow: 1320 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw NSError(domain: "SplitCam.Promo.NativeCrop", code: 1)
            }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1320, height: 2868))
            return context.makeImage()!
        }
        backs = try ["demo-back.png", "demo-back.png", "scenes/duet-back.png"].map {
            try load("Metadata/ASO/2026-09/source/\($0)")
        }
        fronts = try ["demo-front.png", "scenes/pip-front.png", "scenes/duet-front.png"].map {
            try load("Metadata/ASO/2026-09/source/\($0)")
        }
        icon = try load("Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    }

    func rounded(_ rect: CGRect, radius: CGFloat, color: NSColor, context: CGContext) {
        context.setFillColor(color.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    func text(_ value: String, rect: CGRect, size: CGFloat, color: NSColor,
              weight: NSFont.Weight = .regular, centered: Bool = false, tracking: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: tracking
        ]).draw(in: rect)
    }

    func image(_ source: CGImage, rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(source, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    func photo(_ source: CGImage, rect: CGRect, progress: Double, radius: CGFloat,
               phase: Double = 0, context: CGContext) {
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        let zoom = CGFloat(1.04 + 0.025 * sin(progress * 1.3 + phase))
        let factor = max(rect.width / CGFloat(source.width), rect.height / CGFloat(source.height)) * zoom
        let width = CGFloat(source.width) * factor
        let height = CGFloat(source.height) * factor
        let horizontal = CGFloat(0.5 + 0.06 * sin(progress * 1.1 + phase))
        let vertical = CGFloat(0.46 + 0.035 * sin(progress * 0.8 + phase))
        image(source, rect: CGRect(x: rect.minX - (width - rect.width) * horizontal,
                                   y: rect.minY - (height - rect.height) * vertical,
                                   width: width, height: height), context: context)
        context.restoreGState()
    }

    func glow(center: CGPoint, radius: CGFloat, color: NSColor, context: CGContext) {
        let colors = [color.withAlphaComponent(0.13).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
    }

    func background(theme: Theme, time: Double, context: CGContext) {
        context.setFillColor(theme.background.cgColor)
        context.fill(CGRect(origin: .zero, size: videoSize))
        glow(center: CGPoint(x: 100 + 100 * sin(time * 0.24), y: 950), radius: 700,
             color: theme.accent, context: context)
        glow(center: CGPoint(x: 1030, y: 420 + 100 * cos(time * 0.2)), radius: 610,
             color: NSColor(srgbRed: 0.46, green: 0.38, blue: 0.92, alpha: 1), context: context)
        context.setStrokeColor(theme.foreground.withAlphaComponent(0.035).cgColor)
        context.setLineWidth(1)
        for column in 0...9 {
            let horizontal = CGFloat(column) * 135 + CGFloat(sin(time * 0.1)) * 20
            context.move(to: CGPoint(x: horizontal, y: 0))
            context.addLine(to: CGPoint(x: horizontal, y: 1920))
        }
        context.strokePath()
    }

    func brand(theme: Theme, context: CGContext) {
        context.setStrokeColor(theme.accent.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: 78, y: 100, width: 22, height: 22))
        context.strokeEllipse(in: CGRect(x: 95, y: 100, width: 22, height: 22))
        text("SPLITCAM", rect: CGRect(x: 136, y: 94, width: 450, height: 48), size: 27,
             color: theme.foreground, weight: .semibold, tracking: 6)
    }

    func phone(scene: Int, local: Double, rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 20), blur: 55,
                          color: NSColor.black.withAlphaComponent(0.38).cgColor)
        rounded(rect.insetBy(dx: -11, dy: -11), radius: 79,
                color: NSColor(srgbRed: 0.16, green: 0.18, blue: 0.21, alpha: 1), context: context)
        context.restoreGState()
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        let source = screenshots[scene]
        let scale = rect.width / CGFloat(source.width)
        context.scaleBy(x: scale, y: scale)
        let sourceRect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.addPath(CGPath(roundedRect: sourceRect, cornerWidth: 145, cornerHeight: 145, transform: nil))
        context.clip()
        image(source, rect: sourceRect, context: context)
        let preview = CGRect(x: 0, y: 554, width: 1320, height: 1760)
        context.saveGState()
        context.addPath(CGPath(roundedRect: preview, cornerWidth: 42, cornerHeight: 42, transform: nil))
        context.clip()
        if scene == 1 {
            photo(backs[scene], rect: preview, progress: local * 0.4, radius: 0, context: context)
            let movement = smooth((local - 0.65) / 1.65)
            let enlargement = smooth((local - 2.35) / 1.1)
            let width = preview.width * CGFloat(0.32 + 0.12 * enlargement)
            let height = width * 4 / 3
            let margin = preview.width * 0.04
            let horizontal = preview.width - width - margin - CGFloat(movement) * 380
            let vertical = preview.minY + CGFloat(0.55 - 0.42 * movement) * preview.height
            let pipRect = CGRect(x: horizontal, y: vertical, width: width, height: height)
            photo(fronts[scene], rect: pipRect, progress: local * 0.25, radius: 20, phase: 0.6, context: context)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(3)
            context.addPath(CGPath(roundedRect: pipRect, cornerWidth: 20, cornerHeight: 20, transform: nil))
            context.strokePath()
            let touchAlpha = smooth((local - 0.55) / 0.2) * (1 - smooth((local - 3.45) / 0.4))
            if touchAlpha > 0 {
                let touch = CGPoint(x: pipRect.maxX - 26, y: pipRect.maxY - 26)
                context.setFillColor(NSColor.white.withAlphaComponent(0.22 * touchAlpha).cgColor)
                context.fillEllipse(in: CGRect(x: touch.x - 34, y: touch.y - 34, width: 68, height: 68))
                context.setFillColor(NSColor.white.withAlphaComponent(0.9 * touchAlpha).cgColor)
                context.fillEllipse(in: CGRect(x: touch.x - 10, y: touch.y - 10, width: 20, height: 20))
            }
        } else {
            let ratio: CGFloat = scene == 0 ? 0.5 + 0.095 * CGFloat(sin(smooth((local - 0.75) / 2.7) * .pi)) : 0.5
            let first = CGRect(x: 0, y: preview.minY, width: preview.width * ratio, height: preview.height)
            let second = CGRect(x: first.maxX + 2, y: preview.minY, width: preview.width - first.width - 2, height: preview.height)
            photo(backs[scene], rect: first, progress: local * 0.28, radius: 0, phase: 0.5, context: context)
            photo(fronts[scene], rect: second, progress: local * 0.22, radius: 0, phase: 0.2, context: context)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(2)
            context.move(to: CGPoint(x: first.maxX, y: preview.minY))
            context.addLine(to: CGPoint(x: first.maxX, y: preview.maxY))
            context.strokePath()
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(5)
            context.setLineCap(.round)
            for direction in [-1.0, 1.0] {
                let center = first.maxX + CGFloat(direction) * 29
                context.move(to: CGPoint(x: center - CGFloat(direction) * 9, y: preview.midY - 14))
                context.addLine(to: CGPoint(x: center + CGFloat(direction) * 3, y: preview.midY))
                context.addLine(to: CGPoint(x: center - CGFloat(direction) * 9, y: preview.midY + 14))
                context.strokePath()
            }
        }
        context.restoreGState()
        let zoomRect = CGRect(x: 512, y: 2252, width: 298, height: 145)
        if scene != 2, let zoom = source.cropping(to: zoomRect) {
            context.saveGState()
            context.addPath(CGPath(roundedRect: zoomRect, cornerWidth: 72, cornerHeight: 72, transform: nil))
            context.clip()
            image(zoom, rect: zoomRect, context: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    func feature(scene: Int, local: Double, time: Double, context: CGContext) {
        let theme = scene == 1 ? lightTheme : darkTheme
        background(theme: theme, time: time, context: context)
        brand(theme: theme, context: context)
        let labels = chinese ? ["双摄同步", "画中画视频 · PRO", "视频合拍 · PRO"] : ["DUAL CAMERA", "PiP VIDEO · PRO", "VIDEO DUET · PRO"]
        text(labels[scene], rect: CGRect(x: 640, y: 100, width: 365, height: 40), size: 22,
             color: theme.accent, weight: .semibold, centered: true, tracking: chinese ? 2 : 1.1)
        let chineseTitles = [["拍下眼前，", "也拍下自己。"], ["精彩现场，", "还有你的表情。"], ["导入灵感，", "拍下你的回应。"]]
        let englishTitles = [["Your view.", "And you."], ["The moment.", "Your reaction."], ["Add your side.", "To the story."]]
        let lines = chinese ? chineseTitles[scene] : englishTitles[scene]
        let entry = scene == 0 ? 1 : easeOut(local / 0.65)
        context.saveGState()
        context.setAlpha(entry)
        let offset = CGFloat((1 - entry) * 35)
        text(lines[0], rect: CGRect(x: 76, y: 186 + offset, width: 950, height: 112), size: chinese ? 84 : 88,
             color: theme.foreground, weight: .bold, tracking: chinese ? -3 : -3.5)
        text(lines[1], rect: CGRect(x: 76, y: 286 + offset, width: 950, height: 112), size: chinese ? 84 : 88,
             color: theme.accent, weight: .bold, tracking: chinese ? -3 : -3.5)
        let subtitles = chinese
            ? ["前后双摄，同时记录两个视角", "移动小窗，缩放你的视角", "导入照片或视频，和灵感一起出镜"]
            : ["Front and back. Capture both at once.", "Move it. Resize it. Make room for you.", "Import a photo or video. Create alongside it."]
        text(subtitles[scene], rect: CGRect(x: 80, y: 409 + offset, width: 945, height: 50), size: chinese ? 28 : 27,
             color: theme.foreground.withAlphaComponent(0.68))
        context.restoreGState()
        let phoneEntry = scene == 0 ? 1 : easeOut((local - 0.1) / 0.8)
        let width = CGFloat(614 + 10 * smooth(local / 4.5))
        let height = width * 2868 / 1320
        let phoneRect = CGRect(x: (1080 - width) / 2 + CGFloat(1 - phoneEntry) * 70,
                               y: 492 + CGFloat(1 - phoneEntry) * 90 + 5 * sin(local * 1.1), width: width, height: height)
        context.saveGState()
        context.setAlpha(phoneEntry)
        phone(scene: scene, local: local, rect: phoneRect, context: context)
        context.restoreGState()
        let footers = chinese
            ? ["示例画面演示", "示例画面演示 · 画中画视频需 Pro", "示例画面演示 · 视频合拍需 Pro"]
            : ["Illustrative demo footage", "Illustrative demo · PiP video requires Pro", "Illustrative demo · Video duet requires Pro"]
        text(footers[scene], rect: CGRect(x: 80, y: 1858, width: 920, height: 36), size: 22,
             color: theme.foreground.withAlphaComponent(0.55), centered: true)
    }

    func outro(local: Double, time: Double, context: CGContext) {
        background(theme: darkTheme, time: time, context: context)
        brand(theme: darkTheme, context: context)
        let entry = easeOut(local / 0.65)
        context.saveGState()
        context.setAlpha(entry)
        let iconRect = CGRect(x: 430, y: 350 + 30 * (1 - entry) + 5 * sin(local * 1.5), width: 220, height: 220)
        glow(center: CGPoint(x: 540, y: 470), radius: 420, color: darkTheme.accent, context: context)
        context.saveGState()
        context.addPath(CGPath(roundedRect: iconRect, cornerWidth: 49, cornerHeight: 49, transform: nil))
        context.clip()
        image(icon, rect: iconRect, context: context)
        context.restoreGState()
        text("SplitCam", rect: CGRect(x: 70, y: 625, width: 940, height: 145), size: 112,
             color: darkTheme.foreground, weight: .bold, centered: true, tracking: -4)
        text(chinese ? "双镜头，同一个故事。" : "Two views. One great story.",
             rect: CGRect(x: 65, y: 795, width: 950, height: 80), size: chinese ? 47 : 43,
             color: darkTheme.accent, weight: .medium, centered: true)
        context.restoreGState()
        for scene in 0..<3 {
            let appear = easeOut((local - 0.35 - Double(scene) * 0.12) / 0.65)
            let tile = CGRect(x: 92 + CGFloat(scene) * 308, y: 994 + CGFloat(1 - appear) * 45,
                              width: 280, height: 312)
            context.saveGState()
            context.setAlpha(appear)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 30, cornerHeight: 30, transform: nil))
            context.clip()
            if scene == 1 {
                photo(backs[scene], rect: tile, progress: local, radius: 0, context: context)
                photo(fronts[scene], rect: CGRect(x: tile.maxX - 118, y: tile.maxY - 157, width: 105, height: 140),
                      progress: local, radius: 12, context: context)
            } else {
                photo(backs[scene], rect: CGRect(x: tile.minX, y: tile.minY, width: 139, height: tile.height),
                      progress: local, radius: 0, context: context)
                photo(fronts[scene], rect: CGRect(x: tile.minX + 141, y: tile.minY, width: 139, height: tile.height),
                      progress: local, radius: 0, context: context)
            }
            context.restoreGState()
            let labels = chinese ? ["双摄", "画中画", "合拍"] : ["DUAL CAMERA", "PiP", "DUET"]
            text(labels[scene], rect: CGRect(x: tile.minX - 5, y: 1330, width: 290, height: 45), size: 25,
                 color: darkTheme.foreground.withAlphaComponent(0.75), weight: .medium, centered: true)
        }
        let buttonEntry = easeOut((local - 0.9) / 0.6)
        context.saveGState()
        context.setAlpha(buttonEntry)
        rounded(CGRect(x: 165, y: 1472, width: 750, height: 104), radius: 52,
                color: darkTheme.foreground, context: context)
        text(chinese ? "App Store 搜索 SplitCam" : "Find SplitCam on the App Store",
             rect: CGRect(x: 180, y: 1503, width: 720, height: 55), size: chinese ? 33 : 30,
             color: darkTheme.background, weight: .semibold, centered: true)
        text(chinese ? "拍下眼前，也拍下自己。" : "Your view. And you.",
             rect: CGRect(x: 80, y: 1662, width: 920, height: 60), size: 30,
             color: darkTheme.foreground.withAlphaComponent(0.6), centered: true)
        context.restoreGState()
    }

    func frame(time: Double, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: videoSize.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let chapter = min(3, Int(time / chapterDuration))
        let local = time - Double(chapter) * chapterDuration
        func drawChapter(_ index: Int, local: Double) {
            if index == 3 { outro(local: local, time: time, context: context) }
            else { feature(scene: index, local: local, time: time, context: context) }
        }
        drawChapter(chapter, local: local)
        if local < 0.28 && chapter > 0 {
            context.saveGState()
            context.setAlpha(1 - smooth(local / 0.28))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawChapter(chapter - 1, local: chapterDuration)
            context.endTransparencyLayer()
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    func renderVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1080,
            AVVideoHeightKey: 1920,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 7_000_000,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 1080,
                kCVPixelBufferHeightKey as String: 1920,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frameIndex in 0..<Int(duration * Double(frameRate)) {
            try autoreleasepool {
                let deadline = Date().addingTimeInterval(30)
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error! }
                    if Date() > deadline { throw NSError(domain: "SplitCam.Promo.Timeout", code: 1) }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                var buffer: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                      let buffer else { throw NSError(domain: "SplitCam.Promo.Buffer", code: 1) }
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1080, height: 1920,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
                context.interpolationQuality = .high
                frame(time: Double(frameIndex) / Double(frameRate), context: context)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: frameRate)) else {
                    throw writer.error ?? NSError(domain: "SplitCam.Promo.Append", code: 1)
                }
            }
            if frameIndex.isMultiple(of: 90) { print("\(language): rendered \(frameIndex)/540 frames") }
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: frameRate))
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else {
            throw writer.error ?? NSError(domain: "SplitCam.Promo.Finish", code: 1)
        }
    }
}

private func createMusic(at url: URL) throws {
    let sampleRate = 44_100.0
    let count = Int(duration * sampleRate)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    let channels = buffer.floatChannelData!
    let chords: [[Double]] = [
        [174.614, 220, 261.626, 329.628],
        [220, 261.626, 329.628, 391.995],
        [261.626, 329.628, 391.995, 493.883],
        [195.998, 246.942, 293.665, 440]
    ]
    let melody = [523.251, 659.255, 783.991, 659.255, 587.33, 659.255, 880, 783.991]
    let beatDuration = 0.5625
    var randomState: UInt32 = 8_271_935
    for sampleIndex in 0..<count {
        let time = Double(sampleIndex) / sampleRate
        let chapter = min(3, Int(time / chapterDuration))
        let chapterTime = time.truncatingRemainder(dividingBy: chapterDuration)
        let padEnvelope = smooth(chapterTime / 0.22) * (1 - smooth((chapterTime - 4.1) / 0.4))
        var pad = 0.0
        for (index, frequency) in chords[chapter].enumerated() {
            pad += sin(2 * .pi * frequency * time + Double(index) * 0.4) * 0.018
            pad += sin(2 * .pi * frequency * 2.003 * time) * 0.006
        }
        pad *= padEnvelope
        let beatIndex = Int(time / beatDuration)
        let beatTime = time.truncatingRemainder(dividingBy: beatDuration)
        let pluck = sin(2 * .pi * melody[beatIndex % melody.count] * beatTime)
            * (1 - exp(-beatTime * 500)) * exp(-beatTime * 7) * 0.10
        let kickTime = time.truncatingRemainder(dividingBy: beatDuration * 2)
        let kick = sin(2 * .pi * (48 * kickTime + 95 * (1 - exp(-kickTime * 28)) / 28))
            * exp(-kickTime * 18) * 0.19
        randomState ^= randomState << 13
        randomState ^= randomState >> 17
        randomState ^= randomState << 5
        let noise = Double(randomState) / Double(UInt32.max) * 2 - 1
        let hatTime = time.truncatingRemainder(dividingBy: beatDuration / 2)
        let hat = noise * exp(-hatTime * 150) * 0.018
        let snareTime = (time + beatDuration).truncatingRemainder(dividingBy: beatDuration * 2)
        let snare = noise * exp(-snareTime * 42) * 0.044
        let envelope = smooth(time / 0.4) * (1 - smooth((time - 17.25) / 0.75))
        let balance = 0.08 * sin(time * 0.7)
        channels[0][sampleIndex] = Float(tanh((pad + pluck * (1 + balance) + kick + hat + snare) * 1.45) * envelope)
        channels[1][sampleIndex] = Float(tanh((pad + pluck * (1 - balance) + kick + hat + snare) * 1.45) * envelope)
    }
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
}

private func export(_ asset: AVAsset, preset: String, to url: URL, type: AVFileType) async throws {
    guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw NSError(domain: "SplitCam.Promo.Export", code: 1)
    }
    exporter.shouldOptimizeForNetworkUse = true
    try await exporter.export(to: url, as: type)
}

@main private enum RenderPromoVideo {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("Metadata/Promo/2026-10")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SplitCamPromo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            for language in ["zh-Hans", "en"] {
                let renderer = try PromoRenderer(root: root, language: language)
                for time in [1.5, 6.8, 11.2, 16.5] {
                    let context = CGContext(data: nil, width: 1080, height: 1920, bitsPerComponent: 8,
                        bytesPerRow: 1080 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    renderer.frame(time: time, context: context)
                    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
                    let preview = temporary.appendingPathComponent("\(language)-\(time).jpg")
                    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: preview)
                }
            }
            print("Previews: \(temporary.path)")
            return
        }
        let music = temporary.appendingPathComponent("original-music.wav")
        let encodedMusic = temporary.appendingPathComponent("original-music.m4a")
        try createMusic(at: music)
        try await export(AVURLAsset(url: music), preset: AVAssetExportPresetAppleM4A, to: encodedMusic, type: .m4a)
        for language in ["zh-Hans", "en"] {
            let renderer = try PromoRenderer(root: root, language: language)
            let silent = temporary.appendingPathComponent("\(language)-silent.mp4")
            try renderer.renderVideo(to: silent)
            let composition = AVMutableComposition()
            let videoAsset = AVURLAsset(url: silent)
            let audioAsset = AVURLAsset(url: encodedMusic)
            let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
            let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
            let timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                .insertTimeRange(timeRange, of: videoTrack, at: .zero)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                .insertTimeRange(timeRange, of: audioTrack, at: .zero)
            let destination = output.appendingPathComponent("SplitCam-Promo-18s-\(language).mp4")
            if FileManager.default.fileExists(atPath: destination.path) {
                throw NSError(domain: "SplitCam.Promo.OutputExists", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Preserve or move the previous render before rendering again: \(destination.path)"])
            }
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: destination, type: .mp4)
            print("Exported \(destination.path)")
        }
        print("Render completed. Intermediates: \(temporary.path)")
    }
}
