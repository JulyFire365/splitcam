import SwiftUI

// MARK: - Routes

enum AppRoute: Hashable {
    case camera(CaptureMode)
    case editor(URL, URL)
    case export(URL)
    case gallery
}

// MARK: - Capture Mode

enum CaptureMode: String, Hashable {
    case dualCamera    // 前后双摄
    case importAndShoot // 导入视频 + 实时拍摄
}

// MARK: - Split Mode

enum SplitMode: String, CaseIterable, Identifiable {
    case leftRight
    case topBottom
    case pip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .leftRight: return "layout.leftRight".localized
        case .topBottom: return "layout.topBottom".localized
        case .pip:       return "layout.pip".localized
        }
    }
}

// MARK: - PiP Shape

enum PipShape: String, CaseIterable {
    case roundedRect
    case circle

    var displayName: String {
        switch self {
        case .roundedRect: return "shape.rectangle".localized
        case .circle:      return "shape.circle".localized
        }
    }
}

// MARK: - Shooting Mode

enum ShootingMode: String, CaseIterable {
    case photo
    case video

    var displayName: String {
        switch self {
        case .photo: return "mode.photo".localized
        case .video: return "mode.video".localized
        }
    }
}

// MARK: - Aspect Ratio

enum AspectRatioMode: String, CaseIterable, Identifiable {
    case ratio9_16 = "9:16"
    case ratio3_4 = "3:4"
    case ratio1_1 = "1:1"
    case ratio16_9 = "16:9"

    var id: String { rawValue }

    /// 宽高比 (width / height)
    var aspectRatio: CGFloat {
        switch self {
        case .ratio9_16: return 9.0 / 16.0
        case .ratio3_4: return 3.0 / 4.0
        case .ratio1_1: return 1.0
        case .ratio16_9: return 16.0 / 9.0
        }
    }

    /// 用于导出的像素尺寸 (基于1080p宽度)
    var exportSize: CGSize {
        switch self {
        case .ratio9_16: return CGSize(width: 1080, height: 1920)
        case .ratio3_4: return CGSize(width: 1080, height: 1440)
        case .ratio1_1: return CGSize(width: 1080, height: 1080)
        case .ratio16_9: return CGSize(width: 1920, height: 1080)
        }
    }
}

// MARK: - Resolution Quality

enum ResolutionQuality: String, CaseIterable {
    case standard
    case high

    var displayName: String {
        switch self {
        case .standard: return "quality.standard".localized
        case .high:     return "quality.high".localized
        }
    }

    /// 视频码率（bps）
    var videoBitRate: Int {
        switch self {
        case .standard: return 12_000_000   // 12 Mbps — 日常分享
        case .high:     return 25_000_000   // 25 Mbps — 画质优先
        }
    }
}

// MARK: - Zoom Level

enum ZoomLevel: CGFloat, CaseIterable {
    case ultraWide = 0.5
    case wide = 1.0
    case telephoto = 3.0

    var label: String {
        switch self {
        case .ultraWide: return "0.5x"
        case .wide: return "1x"
        case .telephoto: return "3x"
        }
    }
}

// MARK: - Coordinator

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var path = NavigationPath()

    func navigateToCamera(mode: CaptureMode) {
        path.append(AppRoute.camera(mode))
    }

    func navigateToEditor(videoA: URL, videoB: URL) {
        path.append(AppRoute.editor(videoA, videoB))
    }

    func navigateToExport(videoURL: URL) {
        path.append(AppRoute.export(videoURL))
    }

    func navigateToGallery() {
        path.append(AppRoute.gallery)
    }

    func popToRoot() {
        path = NavigationPath()
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    @ViewBuilder
    func view(for route: AppRoute) -> some View {
        switch route {
        case .camera(let mode):
            CameraView(mode: mode)
        case .editor(let videoA, let videoB):
            EditorView(videoA: videoA, videoB: videoB)
        case .export(let url):
            ExportView(videoURL: url)
        case .gallery:
            GalleryView()
        }
    }
}
