import Combine
import Foundation
import UIKit

enum SplitCamAppIcon: String, CaseIterable, Identifiable {
    case signature
    case midnight
    case sunset
    case mono

    var id: String { rawValue }

    var alternateIconName: String? {
        switch self {
        case .signature: nil
        case .midnight: "AppIconMidnight"
        case .sunset: "AppIconSunset"
        case .mono: "AppIconMono"
        }
    }

    var previewImageName: String {
        switch self {
        case .signature: "AppIconImage"
        case .midnight: "AppIconPreviewMidnight"
        case .sunset: "AppIconPreviewSunset"
        case .mono: "AppIconPreviewMono"
        }
    }

    var displayName: String {
        "settings.icon.\(rawValue)".localized
    }

    init(alternateIconName: String?) {
        switch alternateIconName {
        case "AppIconMidnight": self = .midnight
        case "AppIconSunset": self = .sunset
        case "AppIconMono": self = .mono
        default: self = .signature
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var defaultAspectRatio: AspectRatioMode {
        didSet { defaults.set(defaultAspectRatio.rawValue, forKey: Key.defaultAspectRatio) }
    }

    @Published var frontCameraMirrored: Bool {
        didSet { defaults.set(frontCameraMirrored, forKey: Key.frontCameraMirrored) }
    }

    @Published var remembersLastLayout: Bool {
        didSet { defaults.set(remembersLastLayout, forKey: Key.remembersLastLayout) }
    }

    @Published var lastSplitMode: SplitMode {
        didSet { defaults.set(lastSplitMode.rawValue, forKey: Key.lastSplitMode) }
    }

    @Published var lastSplitRatio: CGFloat {
        didSet { defaults.set(lastSplitRatio, forKey: Key.lastSplitRatio) }
    }

    @Published var lastPipShape: PipShape {
        didSet { defaults.set(lastPipShape.rawValue, forKey: Key.lastPipShape) }
    }

    @Published var lastPipScale: CGFloat {
        didSet { defaults.set(lastPipScale, forKey: Key.lastPipScale) }
    }

    @Published var lastPipOffset: CGSize {
        didSet {
            defaults.set(lastPipOffset.width, forKey: Key.lastPipOffsetX)
            defaults.set(lastPipOffset.height, forKey: Key.lastPipOffsetY)
        }
    }

    @Published var lastPanelsSwapped: Bool {
        didSet { defaults.set(lastPanelsSwapped, forKey: Key.lastPanelsSwapped) }
    }

    @Published var defaultVideoQuality: ResolutionQuality {
        didSet { defaults.set(defaultVideoQuality.rawValue, forKey: Key.defaultVideoQuality) }
    }

    @Published private(set) var selectedAppIcon: SplitCamAppIcon

    private enum Key {
        static let defaultAspectRatio = "settings.defaultAspectRatio"
        static let frontCameraMirrored = "settings.frontCameraMirrored"
        static let remembersLastLayout = "settings.remembersLastLayout"
        static let lastSplitMode = "settings.lastSplitMode"
        static let lastSplitRatio = "settings.lastSplitRatio"
        static let lastPipShape = "settings.lastPipShape"
        static let lastPipScale = "settings.lastPipScale"
        static let lastPipOffsetX = "settings.lastPipOffsetX"
        static let lastPipOffsetY = "settings.lastPipOffsetY"
        static let lastPanelsSwapped = "settings.lastPanelsSwapped"
        static let defaultVideoQuality = "settings.defaultVideoQuality"
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultAspectRatio = AspectRatioMode(rawValue: defaults.string(forKey: Key.defaultAspectRatio) ?? "") ?? .ratio3_4
        frontCameraMirrored = defaults.object(forKey: Key.frontCameraMirrored) as? Bool ?? true
        remembersLastLayout = defaults.object(forKey: Key.remembersLastLayout) as? Bool ?? true
        lastSplitMode = SplitMode(rawValue: defaults.string(forKey: Key.lastSplitMode) ?? "") ?? .leftRight
        lastSplitRatio = defaults.object(forKey: Key.lastSplitRatio) == nil
            ? 0.5
            : CGFloat(defaults.double(forKey: Key.lastSplitRatio))
        lastPipShape = PipShape(rawValue: defaults.string(forKey: Key.lastPipShape) ?? "") ?? .roundedRect
        lastPipScale = defaults.object(forKey: Key.lastPipScale) == nil
            ? 0.3
            : CGFloat(defaults.double(forKey: Key.lastPipScale))
        lastPipOffset = CGSize(
            width: CGFloat(defaults.double(forKey: Key.lastPipOffsetX)),
            height: CGFloat(defaults.double(forKey: Key.lastPipOffsetY))
        )
        lastPanelsSwapped = defaults.object(forKey: Key.lastPanelsSwapped) as? Bool ?? false
        defaultVideoQuality = ResolutionQuality(rawValue: defaults.string(forKey: Key.defaultVideoQuality) ?? "") ?? .standard
        selectedAppIcon = SplitCamAppIcon(alternateIconName: UIApplication.shared.alternateIconName)
    }

    func selectAppIcon(_ icon: SplitCamAppIcon) async throws {
        guard UIApplication.shared.supportsAlternateIcons else {
            throw AppIconError.notSupported
        }

        try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)
        selectedAppIcon = icon
    }
}

enum AppIconError: LocalizedError {
    case notSupported

    var errorDescription: String? {
        "settings.icon.notSupported".localized
    }
}
