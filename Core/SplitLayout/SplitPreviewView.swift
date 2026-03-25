import SwiftUI

/// 分屏预览容器 — 显示两个画面 + 可拖拽分割线 / 画中画
struct SplitPreviewView<FirstContent: View, SecondContent: View>: View {
    @ObservedObject var layout: SplitLayoutEngine
    @Binding var isDraggingBinding: Bool
    let firstContent: () -> FirstContent
    let secondContent: () -> SecondContent

    @State private var isDragging = false
    @State private var pipDragStartOffset: CGSize = .zero
    @State private var pipScaleStart: CGFloat = 0.3
    /// 是否已交互过（拖拽/缩放），用于隐藏引导提示
    @State private var hasInteracted = false

    init(layout: SplitLayoutEngine,
         isDraggingBinding: Binding<Bool> = .constant(false),
         @ViewBuilder firstContent: @escaping () -> FirstContent,
         @ViewBuilder secondContent: @escaping () -> SecondContent) {
        self.layout = layout
        self._isDraggingBinding = isDraggingBinding
        self.firstContent = firstContent
        self.secondContent = secondContent
    }

    var body: some View {
        GeometryReader { geo in
            if layout.splitMode == .pip {
                pipLayout(in: geo.size)
            } else {
                splitLayout(in: geo.size)
            }
        }
        // 切换分屏模式时重置引导提示
        .onChange(of: layout.splitMode) { _ in
            hasInteracted = false
        }
    }

    // MARK: - Split Layout (左右/上下)

    private func splitLayout(in containerSize: CGSize) -> some View {
        let frames = layout.frames(in: containerSize)

        return ZStack {
            // 第一个画面
            firstContent()
                .frame(width: frames.first.width, height: frames.first.height)
                .position(x: frames.first.midX, y: frames.first.midY)
                .clipped()

            // 第二个画面
            secondContent()
                .frame(width: frames.second.width, height: frames.second.height)
                .position(x: frames.second.midX, y: frames.second.midY)
                .clipped()

            // 分割线 + 可拖拽区域
            dividerOverlay(in: containerSize)
        }
    }

    // MARK: - PiP Layout (画中画)

    private func pipLayout(in containerSize: CGSize) -> some View {
        let pipFrame = layout.pipRect(in: containerSize)

        return ZStack {
            // 全屏背景画面
            firstContent()
                .frame(width: containerSize.width, height: containerSize.height)
                .clipped()

            // 画中画小窗口
            pipWindow(in: containerSize, pipFrame: pipFrame)
        }
    }

    private func pipWindow(in containerSize: CGSize, pipFrame: CGRect) -> some View {
        let isCircle = layout.pipShape == .circle
        let size = isCircle ? min(pipFrame.width, pipFrame.height) : 0

        return ZStack {
            secondContent()
                .frame(width: isCircle ? size : pipFrame.width,
                       height: isCircle ? size : pipFrame.height)
                .clipShape(pipClipShapeValue)
                .overlay(pipBorderOverlayView)
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)

            // 缩放引导提示
            if !hasInteracted {
                PipScaleHint()
                    .frame(width: isCircle ? size : pipFrame.width,
                           height: isCircle ? size : pipFrame.height)
                    .clipShape(pipClipShapeValue)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .position(x: pipFrame.midX, y: pipFrame.midY)
        // 拖拽移动
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        isDraggingBinding = true
                        pipDragStartOffset = layout.pipOffset
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    layout.pipOffset = CGSize(
                        width: pipDragStartOffset.width + value.translation.width,
                        height: pipDragStartOffset.height + value.translation.height
                    )
                    dismissHint()
                }
                .onEnded { _ in
                    isDragging = false
                    isDraggingBinding = false
                }
        )
        // 双指缩放
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    if pipScaleStart == 0 {
                        pipScaleStart = layout.pipScale
                    }
                    let newScale = pipScaleStart * scale
                    layout.pipScale = min(SplitLayoutEngine.pipMaxScale,
                                          max(SplitLayoutEngine.pipMinScale, newScale))
                    dismissHint()
                }
                .onEnded { _ in
                    pipScaleStart = 0
                }
        )
        // 点击切换小窗口形状（圆形/矩形）
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                layout.pipShape = layout.pipShape == .roundedRect ? .circle : .roundedRect
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dismissHint()
        }
    }

    private func dismissHint() {
        guard !hasInteracted else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            hasInteracted = true
        }
    }

    private var pipClipShapeValue: AnyShape {
        if layout.pipShape == .circle {
            return AnyShape(Circle())
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    private var pipBorderOverlayView: some View {
        if layout.pipShape == .circle {
            Circle()
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
    }

    // MARK: - Divider (分屏模式)

    @ViewBuilder
    private func dividerOverlay(in containerSize: CGSize) -> some View {
        dividerLine(in: containerSize)
        dragHitArea(in: containerSize)
        dragHandle(in: containerSize)

        // 引导箭头提示
        if !hasInteracted {
            DividerArrowHint(isHorizontal: layout.splitMode == .leftRight)
                .position(
                    x: layout.splitMode == .leftRight
                        ? containerSize.width * layout.splitRatio
                        : containerSize.width / 2,
                    y: layout.splitMode == .topBottom
                        ? containerSize.height * layout.splitRatio
                        : containerSize.height / 2
                )
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func dividerLine(in containerSize: CGSize) -> some View {
        // 细线分隔 — 使用半透明白色 + 模糊效果模拟毛玻璃
        let lineThickness: CGFloat = 1.5

        return Rectangle()
            .fill(.white.opacity(0.5))
            .frame(
                width: layout.splitMode == .leftRight ? lineThickness : containerSize.width,
                height: layout.splitMode == .topBottom ? lineThickness : containerSize.height
            )
            .position(
                x: layout.splitMode == .leftRight
                    ? containerSize.width * layout.splitRatio
                    : containerSize.width / 2,
                y: layout.splitMode == .topBottom
                    ? containerSize.height * layout.splitRatio
                    : containerSize.height / 2
            )
            .allowsHitTesting(false)
    }

    private func dragHitArea(in containerSize: CGSize) -> some View {
        let hitWidth: CGFloat = 44

        return Rectangle()
            .fill(Color.clear)
            .frame(
                width: layout.splitMode == .leftRight ? hitWidth : containerSize.width,
                height: layout.splitMode == .topBottom ? hitWidth : containerSize.height
            )
            .contentShape(Rectangle())
            .position(
                x: layout.splitMode == .leftRight
                    ? containerSize.width * layout.splitRatio
                    : containerSize.width / 2,
                y: layout.splitMode == .topBottom
                    ? containerSize.height * layout.splitRatio
                    : containerSize.height / 2
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            isDraggingBinding = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }

                        switch layout.splitMode {
                        case .leftRight:
                            let newRatio = value.location.x / containerSize.width
                            layout.splitRatio = min(SplitLayoutEngine.maxRatio,
                                                     max(SplitLayoutEngine.minRatio, newRatio))
                        case .topBottom:
                            let newRatio = value.location.y / containerSize.height
                            layout.splitRatio = min(SplitLayoutEngine.maxRatio,
                                                     max(SplitLayoutEngine.minRatio, newRatio))
                        case .pip:
                            break
                        }

                        dismissHint()
                    }
                    .onEnded { _ in
                        isDragging = false
                        isDraggingBinding = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
            )
    }

    private func dragHandle(in containerSize: CGSize) -> some View {
        let handleWidth: CGFloat = isDragging ? 6 : 4
        let handleLength: CGFloat = isDragging ? 44 : 36
        let isH = layout.splitMode == .leftRight

        return Capsule()
            .fill(.white.opacity(isDragging ? 0.95 : 0.7))
            .frame(
                width: isH ? handleWidth : handleLength,
                height: isH ? handleLength : handleWidth
            )
            .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
            .position(
                x: layout.splitMode == .leftRight
                    ? containerSize.width * layout.splitRatio
                    : containerSize.width / 2,
                y: layout.splitMode == .topBottom
                    ? containerSize.height * layout.splitRatio
                    : containerSize.height / 2
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
            .allowsHitTesting(false)
    }
}

// MARK: - Divider Arrow Hint (分隔条引导箭头)

/// 分隔条两侧缓慢闪动的箭头提示
struct DividerArrowHint: View {
    let isHorizontal: Bool // true = 左右分屏, false = 上下分屏
    @State private var animating = false

    var body: some View {
        Group {
            if isHorizontal {
                HStack(spacing: 28) {
                    Image(systemName: "chevron.left")
                        .offset(x: animating ? -4 : 0)
                    Image(systemName: "chevron.right")
                        .offset(x: animating ? 4 : 0)
                }
            } else {
                VStack(spacing: 28) {
                    Image(systemName: "chevron.up")
                        .offset(y: animating ? -4 : 0)
                    Image(systemName: "chevron.down")
                        .offset(y: animating ? 4 : 0)
                }
            }
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundColor(.white.opacity(0.8))
        .animation(
            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
            value: animating
        )
        .onAppear { animating = true }
    }
}

// MARK: - PiP Scale Hint (画中画缩放引导)

/// 画中画小窗口上的缩放提示（双指箭头图标）
struct PipScaleHint: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.3)

            VStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 22, weight: .semibold))
                    .scaleEffect(animating ? 1.15 : 0.9)

                Text("捏合缩放")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.9))
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: animating
            )
            .onAppear { animating = true }
        }
    }
}
