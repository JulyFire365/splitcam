// Run: swift Tools/ValidateReleaseMetadata.swift 1.8 9 [compiled Info.plist paths...]
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    fatalError("Usage: ValidateReleaseMetadata.swift <version> <build> [compiled Info.plist paths...]")
}
let version = arguments[0]
let build = arguments[1]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func plist(_ path: String) throws -> [String: Any] {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    guard let dictionary = object as? [String: Any] else { fatalError("Invalid plist: \(path)") }
    return dictionary
}

let project = try read("SplitCam.xcodeproj/project.pbxproj")
for (key, expected) in [("MARKETING_VERSION", version), ("CURRENT_PROJECT_VERSION", build)] {
    let expression = try NSRegularExpression(pattern: "\\b\(key) = ([^;]+);")
    let matches = expression.matches(in: project, range: NSRange(project.startIndex..., in: project))
    require(matches.count == 2, "Expected Debug and Release values for \(key)")
    for match in matches {
        let value = String(project[Range(match.range(at: 1), in: project)!])
        require(value == expected, "\(key): expected \(expected), got \(value)")
    }
}
let source = try plist("Info.plist")
require(source["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)", "Info.plist must use MARKETING_VERSION")
require(source["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)", "Info.plist must use CURRENT_PROJECT_VERSION")

for path in arguments.dropFirst(2) {
    let compiled = try plist(path)
    require(compiled["CFBundleShortVersionString"] as? String == version, "Compiled version mismatch: \(path)")
    require(compiled["CFBundleVersion"] as? String == build, "Compiled build mismatch: \(path)")
    print("PASS compiled app: \(version) (\(build)) — \(path)")
}

for language in ["en", "zh-Hans"] {
    let proposed = "Metadata/ASO/\(version)-proposed"
    let fields: [(String, Int, Bool)] = [
        ("Metadata/whats_new_\(language).txt", 4000, false),
        ("Metadata/promotional_text_\(language).txt", 170, false),
        ("\(proposed)/description_\(language).txt", 4000, false),
        ("\(proposed)/name_\(language).txt", 30, false),
        ("\(proposed)/subtitle_\(language).txt", 30, false),
        ("\(proposed)/keywords_\(language).txt", 100, true)
    ]
    for (path, limit, byteLimit) in fields {
        let raw = try read(path)
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        require(!value.isEmpty, "Empty field: \(path)")
        require(raw == value + "\n", "Unexpected surrounding whitespace: \(path)")
        require(!raw.contains("\r") && !raw.contains("\u{FEFF}"), "Use UTF-8 without BOM and LF line endings: \(path)")
        let length = byteLimit ? value.utf8.count : value.utf16.count
        require(length <= limit, "Field exceeds limit: \(path) (\(length)/\(limit))")
        if path.contains("whats_new_") {
            require(value.hasPrefix("SplitCam \(version)"), "Missing version in release notes: \(path)")
            require(!value.lowercased().contains("custody"), "Cross-promotion must stay out of release notes")
        }
        if path.contains("promotional_text_") {
            require(!value.contains("1.7"), "Stale promotional version: \(path)")
            require(!value.contains("\n"), "Promotional text must be a single line: \(path)")
        }
        if byteLimit {
            let terms = value.components(separatedBy: ",")
            require(terms.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) }, "Malformed keyword separator: \(path)")
            require(Set(terms.map { $0.lowercased() }).count == terms.count, "Duplicate keywords: \(path)")
        }
        print("PASS \(length)/\(limit) \(byteLimit ? "UTF-8 bytes" : "UTF-16 units"): \(path)")
    }
}
print("Release metadata validation passed for \(version) (\(build)).")
