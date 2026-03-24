import SwiftUI
import Combine

/// 分屏布局引擎 — 管理分屏模式、比例、边框样式
final class SplitLayoutEngine: ObservableObject {
    // MARK: - Layout State

    @Published var splitMode: SplitMode = .leftRight
    @Published var splitRatio: CGFloat = 0.5  // 0.0~1.0, 第一个画面占比
    @Published var borderStyle: BorderStyleConfig = .default

    // MARK: - Constraints

    static let minRatio: CGFloat = 0.2
    static let maxRatio: CGFloat = 0.8

    // MARK: - Layout Calculation

    /// 计算两个分屏区域的 frame
    func frames(in containerSize: CGSize) -> (first: CGRect, second: CGRect) {
        let clampedRatio = min(Self.maxRatio, max(Self.minRatio, splitRatio))

        switch splitMode {
        case .leftRight:
            let firstWidth = containerSize.width * clampedRatio
            let secondWidth = containerSize.width - firstWidth - borderStyle.width
            let first = CGRect(x: 0, y: 0, width: firstWidth, height: containerSize.height)
            let second = CGRect(
                x: firstWidth + borderStyle.width,
                y: 0,
                width: secondWidth,
                height: containerSize.height
            )
            return (first, second)

        case .topBottom:
            let firstHeight = containerSize.height * clampedRatio
            let secondHeight = containerSize.height - firstHeight - borderStyle.width
            let first = CGRect(x: 0, y: 0, width: containerSize.width, height: firstHeight)
            let second = CGRect(
                x: 0,
                y: firstHeight + borderStyle.width,
                width: containerSize.width,
                height: secondHeight
            )
            return (first, second)
        }
    }

    /// 分割线的位置和大小
    func dividerRect(in containerSize: CGSize) -> CGRect {
        let clampedRatio = min(Self.maxRatio, max(Self.minRatio, splitRatio))
        let hitAreaExtra: CGFloat = 20 // 扩大触摸区域

        switch splitMode {
        case .leftRight:
            let x = containerSize.width * clampedRatio - hitAreaExtra / 2
            return CGRect(x: x, y: 0, width: borderStyle.width + hitAreaExtra, height: containerSize.height)

        case .topBottom:
            let y = containerSize.height * clampedRatio - hitAreaExtra / 2
            return CGRect(x: 0, y: y, width: containerSize.width, height: borderStyle.width + hitAreaExtra)
        }
    }

    /// 根据拖拽手势更新分割比例
    func updateRatio(dragTranslation: CGSize, containerSize: CGSize) {
        switch splitMode {
        case .leftRight:
            let delta = dragTranslation.width / containerSize.width
            splitRatio = min(Self.maxRatio, max(Self.minRatio, splitRatio + delta))
        case .topBottom:
            let delta = dragTranslation.height / containerSize.height
            splitRatio = min(Self.maxRatio, max(Self.minRatio, splitRatio + delta))
        }
    }

    /// 用于视频合成的归一化 frame (0~1 坐标系)
    func normalizedFrames() -> (first: CGRect, second: CGRect) {
        let clampedRatio = min(Self.maxRatio, max(Self.minRatio, splitRatio))

        switch splitMode {
        case .leftRight:
            let first = CGRect(x: 0, y: 0, width: clampedRatio, height: 1)
            let second = CGRect(x: clampedRatio, y: 0, width: 1 - clampedRatio, height: 1)
            return (first, second)
        case .topBottom:
            let first = CGRect(x: 0, y: 0, width: 1, height: clampedRatio)
            let second = CGRect(x: 0, y: clampedRatio, width: 1, height: 1 - clampedRatio)
            return (first, second)
        }
    }
}

// MARK: - Border Style

struct BorderStyleConfig: Equatable {
    var style: BorderType
    var color: Color
    var width: CGFloat

    static let `default` = BorderStyleConfig(style: .thin, color: .white, width: 2)

    var cgColor: CGColor {
        UIColor(color).cgColor
    }
}

enum BorderType: String, CaseIterable, Identifiable {
    case none = "无边框"
    case thin = "细线"
    case thick = "粗线"
    case rounded = "圆角"

    var id: String { rawValue }

    var defaultWidth: CGFloat {
        switch self {
        case .none: return 0
        case .thin: return 2
        case .thick: return 6
        case .rounded: return 4
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .rounded: return 12
        default: return 0
        }
    }
}
