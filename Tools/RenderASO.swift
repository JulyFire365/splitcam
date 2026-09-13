// Native, deterministic layout of ASO storyboards using unmodified app screenshots.
// Run from the repository root: swift Tools/RenderASO.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("Metadata/ASO/2026-09")
let canvas = CGSize(width: 1320, height: 2868)
let ink = NSColor(srgbRed: 0.055, green: 0.065, blue: 0.08, alpha: 1)
let paper = NSColor(srgbRed: 0.965, green: 0.95, blue: 0.915, alpha: 1)
let teal = NSColor(srgbRed: 0.32, green: 0.85, blue: 0.82, alpha: 1)
let orange = NSColor(srgbRed: 1, green: 0.61, blue: 0.30, alpha: 1)

struct Slide {
    let screen: String
    let title: [String]
    let detail: [String]
    var pro: [String]? = nil
}
let slides: [Slide] = [
    .init(screen: "split", title: ["Your view.\nAnd you.", "拍下眼前，\n也拍下自己。"], detail: ["Capture photos and videos\nwith both cameras.", "前后双摄，\n同步记录照片与视频。"]),
    .init(screen: "pip", title: ["The moment.\nYour reaction.", "精彩现场，\n还有你的表情。"], detail: ["Move and resize your\npicture-in-picture view.", "自由调整小窗口，\n让故事更完整。"], pro: ["PiP video requires Pro", "画中画视频需 Pro"]),
    .init(screen: "duet", title: ["Add your side\nto the story.", "灵感有了，\n拍下你的回应。"], detail: ["Import a photo or video.\nCreate alongside it.", "导入照片或视频，\n开始你的合拍。"], pro: ["Video duet requires Pro", "视频合拍需 Pro"]),
    .init(screen: "stack", title: ["A layout for\nevery story.", "换个布局，\n换种表达。"], detail: ["Side by side. Stacked.\nPicture in picture.", "左右、上下、画中画，\n随心构图。"]),
    .init(screen: "portrait", title: ["More room\nfor the moment.", "让画面，\n多一点空间。"], detail: ["Hide frame and quality\ncontrols in 9:16.", "9:16 一键收起\n画幅与画质控制条。"]),
    .init(screen: "quality", title: ["Big moments.\nSmaller files.", "精彩照录，\n文件更轻。"], detail: ["Choose Space Saver\nfor lighter videos.", "新增节省空间画质，\n分享更轻松。"]),
    .init(screen: "settings", title: ["Pick up where\nyou left off.", "熟悉的设置，\n打开就接着拍。"], detail: ["Keep your capture preferences\nready to go.", "记住拍摄模式、画幅、\n布局与镜像。"]),
    .init(screen: "icons", title: ["Your camera.\nYour signature.", "镜头之外，\n也有你的风格。"], detail: ["Find an app icon\nthat feels like you.", "多款 App 图标，\n换上你的最爱。"], pro: ["Selected icons require Pro", "部分图标需 Pro"])
]

func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, tracking: CGFloat = 0) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = size * 0.06
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph, .kern: tracking
    ]
    NSAttributedString(string: value, attributes: attributes).draw(in: CGRect(x: x, y: y, width: width, height: size * 3.5))
}

func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func drawPhone(_ source: URL, at rect: CGRect) {
    guard let image = NSImage(contentsOf: source) else { fatalError("Missing screenshot: \(source.path)") }
    let shell = rect.insetBy(dx: -14, dy: -14)
    rounded(shell, radius: 110, fill: NSColor(white: 0.22, alpha: 1))
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 98, yRadius: 98).addClip()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
}

func drawDetail(_ source: URL, crop: CGRect, at rect: CGRect) {
    let original = NSImage(contentsOf: source)!
    let cg = original.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let detail = NSImage(cgImage: cg.cropping(to: crop)!, size: crop.size)
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: rect, xRadius: 48, yRadius: 48).addClip()
    detail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
}

func render(size: CGSize, draw: () -> Void) -> NSBitmapImageRep {
    let cg = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: cg, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let transform = AffineTransform(translationByX: 0, byY: size.height)
    var flip = transform
    flip.scale(x: 1, y: -1)
    (flip as NSAffineTransform).concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: cg.makeImage()!)
}

for (languageIndex, language) in ["en", "zh-Hans"].enumerated() {
    var paths: [URL] = []
    for (index, slide) in slides.enumerated() {
        let dark = index.isMultiple(of: 2)
        let background = dark ? ink : paper
        let foreground = dark ? paper : ink
        let highlight = dark ? teal : NSColor(srgbRed: 0.21, green: 0.28, blue: 0.83, alpha: 1)
        let bitmap = render(size: canvas) {
            background.setFill(); NSBezierPath(rect: CGRect(origin: .zero, size: canvas)).fill()
            text("SPLITCAM", x: 86, y: 86, width: 850, size: 30, color: foreground, weight: .bold, tracking: 6)
            text(String(format: "%02d / 08", index + 1), x: 1070, y: 91, width: 220, size: 25, color: foreground.withAlphaComponent(0.55), weight: .medium)
            rounded(CGRect(x: 86, y: 165, width: 72, height: 7), radius: 3, fill: highlight)
            text(slide.title[languageIndex], x: 80, y: 232, width: 1190, size: languageIndex == 1 ? 118 : 114, color: foreground, weight: .bold, tracking: -3)
            text(slide.detail[languageIndex], x: 86, y: 535, width: 1160, size: 43, color: foreground.withAlphaComponent(0.72), weight: .regular)
            if let pro = slide.pro {
                text(pro[languageIndex], x: 88, y: 675, width: 1140, size: 27, color: highlight, weight: .semibold)
            }

            if index == 5 || index == 6 {
                let source = base.appendingPathComponent("raw/\(language)/\(slide.screen).png")
                let crop = index == 5 ? CGRect(x: 0, y: 170, width: 1320, height: 1370) : CGRect(x: 0, y: 1100, width: 1320, height: languageIndex == 1 ? 800 : 860)
                let rect = CGRect(x: 72, y: index == 5 ? 870 : 990, width: 1176, height: crop.height * 1176 / 1320)
                drawDetail(source, crop: crop, at: rect)
                if index == 5 {
                    text(languageIndex == 0 ? "Three quality options.\nYour call." : "三档画质，\n按需选择。", x: 86, y: 2240, width: 1160, size: 68, color: foreground, weight: .semibold)
                    text(languageIndex == 0 ? "Photo resolution stays unchanged." : "视频画质设置不会影响照片分辨率。", x: 86, y: 2460, width: 1140, size: 34, color: foreground.withAlphaComponent(0.65))
                } else {
                    let labels = languageIndex == 0 ? ["Photo / Video", "Frame", "Layout", "Mirror"] : ["拍照 / 拍摄", "画幅", "布局", "镜像"]
                    for (i, label) in labels.enumerated() {
                        let x = CGFloat(90 + i % 2 * 595), y = CGFloat(2130 + i / 2 * 190)
                        rounded(CGRect(x: x, y: y, width: 525, height: 132), radius: 24, fill: foreground.withAlphaComponent(0.06))
                        text(label, x: x + 28, y: y + 39, width: 490, size: 39, color: foreground, weight: .medium)
                    }
                }
            } else if index == 7 {
                // New icon artwork is the focus; each card carries a visible Pro label.
                let names = ["Chrome", "Terrazzo", "Blueprint", "Bloom"]
                let labels = languageIndex == 0 ? names : ["液态银", "陶石", "蓝图", "花绽"]
                for (i, name) in names.enumerated() {
                    let x = CGFloat(90 + (i % 2) * 585)
                    let y = CGFloat(820 + (i / 2) * 680)
                    let image = NSImage(contentsOf: root.appendingPathComponent("Resources/Assets.xcassets/AppIcon\(name).appiconset/AppIcon\(name).png"))!
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: 555, height: 555), xRadius: 118, yRadius: 118).addClip()
                    image.draw(in: CGRect(x: x, y: y, width: 555, height: 555), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    text(labels[i], x: x + 8, y: y + 578, width: 400, size: 35, color: foreground, weight: .semibold)
                    text("PRO", x: x + 438, y: y + 582, width: 110, size: 26, color: highlight, weight: .bold)
                }
                text(languageIndex == 0 ? "Four new ways to make it yours." : "四款新设计，四种不同的你。", x: 90, y: 2370, width: 1160, size: 43, color: foreground, weight: .medium)
                text(languageIndex == 0 ? "Choose your icon in Settings → App Icon" : "在「设置 → App 图标」中选择", x: 90, y: 2460, width: 1160, size: 32, color: foreground.withAlphaComponent(0.6))
            } else {
                let width: CGFloat = 916
                let phone = CGRect(x: (1320 - width) / 2, y: 782, width: width, height: width * 2868 / 1320)
                drawPhone(base.appendingPathComponent("raw/\(language)/\(slide.screen).png"), at: phone)
            }
            text(languageIndex == 0 ? "TWO PERSPECTIVES. ONE STORY." : "双重视角，让故事更完整。", x: 86, y: 2810, width: 1160, size: 22, color: foreground.withAlphaComponent(0.5), weight: .medium, tracking: 2)
        }
        let output = base.appendingPathComponent("\(language)/\(String(format: "%02d", index + 1))-\(slide.screen).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        paths.append(output)
    }
    let contact = render(size: CGSize(width: 1440, height: 1630)) {
        paper.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: 1440, height: 1630)).fill()
        text(languageIndex == 0 ? "SplitCam / A fresh perspective" : "SplitCam / 全新双视角叙事", x: 28, y: 26, width: 1380, size: 28, color: ink, weight: .bold)
        for (i, path) in paths.enumerated() {
            let rect = CGRect(x: CGFloat(24 + (i % 4) * 355), y: CGFloat(90 + (i / 4) * 764), width: 327, height: 710.7)
            NSImage(contentsOf: path)!.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
    try contact.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent("overview-\(language).png"))
}
print("Rendered 16 ASO boards and 2 overviews in \(base.path)")
