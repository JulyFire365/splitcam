// Run from the repository root: swift Tools/ValidateASO.swift
import AppKit
import Vision
import CryptoKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let base = root.appendingPathComponent("Metadata/ASO/2026-09")
let expected = ["01-split.png", "02-pip.png", "03-duet.png", "04-stack.png", "05-portrait.png", "06-quality.png", "07-settings.png", "08-icons.png"]

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

// This heuristic applies only to our colorful demo fixtures, not arbitrary user photos.
func cameraFrameIsReady(_ path: URL) throws -> Bool {
    guard let raw = NSBitmapImageRep(data: try Data(contentsOf: path)) else { return false }
    var colorfulSamples = 0
    for row in 0..<12 {
        for column in 0..<12 {
            let x = Int(Double(raw.pixelsWide) * (0.15 + Double(column) * 0.7 / 11))
            let y = Int(Double(raw.pixelsHigh) * (0.3 + Double(row) * 0.4 / 11))
            if let color = raw.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.max()! - channels.min()! > 0.05 && channels.max()! > 0.15 {
                    colorfulSamples += 1
                }
            }
        }
    }
    return colorfulSamples > 20
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--frame" {
    exit(try cameraFrameIsReady(URL(fileURLWithPath: CommandLine.arguments[2])) ? 0 : 1)
}

for language in ["en", "zh-Hans"] {
    for screen in ["split", "pip", "duet", "stack", "portrait"] {
        let path = base.appendingPathComponent("raw/\(language)/\(screen).png")
        let ready = try cameraFrameIsReady(path)
        require(ready, "Camera content may be blank / not ready: raw/\(language)/\(screen).png")
    }
    let directory = base.appendingPathComponent(language)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "png" }.map(\.lastPathComponent).sorted()
    require(files == expected, "Unexpected upload files in \(language)")
    for name in files {
        let url = directory.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
        require(bitmap.pixelsWide == 1284 && bitmap.pixelsHigh == 2778, "Wrong 6.5-inch size: \(name)")
        require(!bitmap.hasAlpha, "Alpha channel is not allowed: \(name)")
        let cg = bitmap.cgImage!
        require(cg.colorSpace?.name == CGColorSpace.sRGB, "Expected sRGB: \(name)")

        // OCR the former page-counter location (Vision coordinates start bottom-left).
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = CGRect(x: 0.72, y: 0.91, width: 0.28, height: 0.09)
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        require(text.range(of: #"\b0?[1-8]\s*[/／]\s*0?8\b"#, options: .regularExpression) == nil, "Page counter found: \(language)/\(name): \(text)")
        print("PASS \(language)/\(name): 1284 × 2778, opaque sRGB, no page counter")
    }
}

let portraits = ["source/demo-front.png", "source/scenes/pip-front.png", "source/scenes/duet-front.png", "source/scenes/stack-front.png", "source/scenes/portrait-front.png"]
let hashes = try portraits.map { SHA256.hash(data: try Data(contentsOf: base.appendingPathComponent($0))) }
require(Set(hashes).count == 5, "The five camera scenes must use distinct portrait photos")
print("PASS five distinct portrait sources. Manually review outfits, expressions, composition, and UI before upload.")
