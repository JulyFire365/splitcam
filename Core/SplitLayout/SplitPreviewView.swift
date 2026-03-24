import SwiftUI

/// 分屏预览容器 — 显示两个画面 + 可拖拽分割线
struct SplitPreviewView<FirstContent: View, SecondContent: View>: View {
    @ObservedObject var layout: SplitLayoutEngine
    @Binding var isDraggingBinding: Bool
    let firstContent: () -> FirstContent
    let secondContent: () -> SecondContent

    @State private var isDragging = false

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
            let frames = layout.frames(in: geo.size)

            ZStack {
                // 第一个画面
                firstContent()
                    .frame(width: frames.first.width, height: frames.first.height)
                    .position(
                        x: frames.first.midX,
                        y: frames.first.midY
                    )
                    .clipped()

                // 第二个画面
                secondContent()
                    .frame(width: frames.second.width, height: frames.second.height)
                    .position(
                        x: frames.second.midX,
                        y: frames.second.midY
                    )
                    .clipped()

                // 分割线 + 可拖拽区域
                dividerOverlay(in: geo.size)
            }
        }
    }

    // MARK: - Divider

    @ViewBuilder
    private func dividerOverlay(in containerSize: CGSize) -> some View {
        // 可见的分割线
        dividerLine(in: containerSize)

        // 透明的拖拽热区 (宽度 44pt，方便手指触摸)
        dragHitArea(in: containerSize)

        // 拖拽把手指示器（始终显示）
        dragHandle(in: containerSize)
    }

    private func dividerLine(in containerSize: CGSize) -> some View {
        Rectangle()
            .fill(layout.borderStyle.style == .none ? Color.white.opacity(0.3) : layout.borderStyle.color)
            .frame(
                width: layout.splitMode == .leftRight ? max(layout.borderStyle.width, 1) : containerSize.width,
                height: layout.splitMode == .topBottom ? max(layout.borderStyle.width, 1) : containerSize.height
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
                            // 触觉反馈
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
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
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        isDraggingBinding = false
                        // 结束触觉反馈
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    }
            )
    }

    private func dragHandle(in containerSize: CGSize) -> some View {
        let handleSize: CGFloat = isDragging ? 36 : 28

        return Circle()
            .fill(.white.opacity(isDragging ? 0.95 : 0.7))
            .frame(width: handleSize, height: handleSize)
            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
            .overlay(
                Image(systemName: layout.splitMode == .leftRight
                      ? "arrow.left.and.right"
                      : "arrow.up.and.down")
                    .font(.system(size: isDragging ? 14 : 11, weight: .bold))
                    .foregroundColor(.gray)
            )
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
