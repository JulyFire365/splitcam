#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import AVFoundation

/// Explicit simulator-only launch routes for repeatable visual QA and ASO
/// storyboards. These routes and demo frames do not exist in release builds.
enum ScreenshotSupport {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-preview-screen"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    @MainActor static func prepareCamera(_ model: CameraViewModel) -> Bool {
        guard let screen, ["split", "stack", "pip", "portrait", "duet", "recording-check"].contains(screen) else { return false }
        model.camerasReady = true
        model.shootingMode = .video
        model.aspectRatio = screen == "portrait" ? .ratio9_16 : .ratio3_4
        model.splitMode = screen == "pip" ? .pip : (screen == "split" || screen == "duet" ? .leftRight : .topBottom)
        model.layoutEngine.pipScale = 0.42
        model.layoutEngine.pipOffset = CGSize(width: -0.04, height: 0.46)
        model.backFrameBuffer = buffer(named: "demo-back.png")
        model.frontFrameBuffer = buffer(named: "demo-front.png")
        UserDefaults.standard.set(true, forKey: "settings.hasShownPipScaleHint")
        if screen == "duet", let image = UIImage(contentsOfFile: documents.appendingPathComponent("demo-back.png").path) {
            model.mediaImporter.importedContent = .image(image)
            model.importedImage = image
        }
        return true
    }

    private static func buffer(named name: String) -> CMSampleBuffer? {
        guard let image = CIImage(contentsOf: documents.appendingPathComponent(name)) else { return nil }
        var pixel: CVPixelBuffer?
        let width = Int(image.extent.width), height = Int(image.extent.height)
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { return nil }
        CIContext().render(image, to: pixel)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &description)
        guard let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
            (attachments[0] as? NSMutableDictionary)?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }
}

struct ScreenshotPreviewRoot: View {
    var body: some View {
        Group {
            switch ScreenshotSupport.screen {
            case "recording-check": RecordingSaveCheckView()
            case "paywall": PaywallView(triggeredBy: .pipMode)
            case "settings": SettingsView(settings: .shared)
            case "icons": NavigationStack { AppIconPickerView(settings: .shared) }.preferredColorScheme(.dark)
            case "quality": NavigationStack { VideoQualityPickerView(settings: .shared) }.preferredColorScheme(.dark)
            default: NavigationStack { CameraView(mode: .dualCamera) }
            }
        }
    }
}
#endif
