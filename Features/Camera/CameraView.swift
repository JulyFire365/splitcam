import SwiftUI
import AVFoundation

/// 拍摄页面 — 沉浸式全屏预览 + 浮层控件
struct CameraView: View {
    let mode: CaptureMode

    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var viewModel = CameraViewModel()
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @State private var showPaywall = false
    @State private var paywallTrigger: ProFeature?

    var body: some View {
        ZStack {
            // ① 全屏预览铺满
            Color.black.ignoresSafeArea()
            fullScreenPreview
                .ignoresSafeArea()

            // ② 浮层控件（渐变遮罩保证可读性）
            VStack(spacing: 0) {
                // 顶部控件 + 渐变遮罩
                topOverlay
                Spacer()
                // 底部控件 + 渐变遮罩
                bottomOverlay
            }
            .ignoresSafeArea(.container, edges: .bottom)

            // ③ 摄像头未就绪时的黑色蒙版
            Color.black
                .ignoresSafeArea()
                .opacity(viewModel.camerasReady ? 0 : 1)
                .animation(viewModel.camerasReady ? .easeOut(duration: 0.3) : nil,
                           value: viewModel.camerasReady)
                .allowsHitTesting(false)

            // ⑤ 闪光效果 (拍照)
            if viewModel.showFlashEffect {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: viewModel.showFlashEffect)
            }

            // ⑥ 处理中蒙版
            if viewModel.isProcessing {
                processingOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear { viewModel.setup(mode: mode) }
        .onDisappear { viewModel.cleanup() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.resumeSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.pauseSession()
        }
        .sheet(isPresented: $viewModel.showVideoPicker) {
            MediaPicker(isPresented: $viewModel.showVideoPicker) { result in
                viewModel.handlePickedMedia(result)
            }
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView(triggeredBy: paywallTrigger)
        }
        .onChange(of: viewModel.freeRecordingLimitReached) { reached in
            if reached {
                paywallTrigger = .unlimitedRecording
                showPaywall = true
                viewModel.freeRecordingLimitReached = false
            }
        }
    }

    // MARK: - Full Screen Preview

    private var fullScreenPreview: some View {
        GeometryReader { geo in
            let previewSize = calculatePreviewSize(in: geo.size)

            SplitPreviewView(layout: viewModel.layoutEngine, isDraggingBinding: $viewModel.isDraggingDivider) {
                CameraPreviewPanel(
                    sampleBuffer: viewModel.panelsSwapped ? viewModel.frontFrameBuffer : viewModel.backFrameBuffer,
                    importedImage: viewModel.panelsSwapped ? nil : viewModel.importedImage,
                    importedPlayer: viewModel.panelsSwapped ? nil : viewModel.importedPlayer
                )
            } secondContent: {
                CameraPreviewPanel(
                    sampleBuffer: viewModel.panelsSwapped ? viewModel.backFrameBuffer : viewModel.frontFrameBuffer,
                    importedImage: viewModel.panelsSwapped ? viewModel.importedImage : nil,
                    importedPlayer: viewModel.panelsSwapped ? viewModel.importedPlayer : nil
                )
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private func calculatePreviewSize(in containerSize: CGSize) -> CGSize {
        let ratio = viewModel.aspectRatio.aspectRatio
        let containerRatio = containerSize.width / containerSize.height

        if ratio > containerRatio {
            return CGSize(width: containerSize.width, height: containerSize.width / ratio)
        } else {
            return CGSize(width: containerSize.height * ratio, height: containerSize.height)
        }
    }

    // MARK: - Top Overlay

    private var topOverlay: some View {
        VStack(spacing: 0) {
            // 渐变遮罩背景
            HStack(alignment: .center) {
                // 左: 导入按钮 (合拍 Pro)
                toolButton(icon: "photo.badge.plus") {
                    requirePro(.duetMode) {
                        viewModel.showVideoPicker = true
                    }
                }
                .opacity(viewModel.isRecording ? 0 : 1)

                Spacer()

                // 中: 分屏模式选择器
                splitModeSelector

                Spacer()

                // 右: 最近拍摄缩略图
                lastMediaButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.6), .black.opacity(0.3), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )

            // 比例选择器 + 合拍标签（录制时隐藏比例）
            HStack(spacing: 8) {
                if !viewModel.isRecording {
                    aspectRatioBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()

                if viewModel.isDuetMode {
                    duetModeBadge
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }

    // MARK: - Bottom Overlay

    private var bottomOverlay: some View {
        VStack(spacing: 16) {
            // 录制计时器
            if viewModel.isRecording {
                recordingTimer
                    .transition(.opacity.combined(with: .scale))
            }

            // 变焦胶囊
            zoomCapsule

            // 功能按钮行：交换 + 拍摄按钮 + 镜像
            captureRow

            // 拍摄模式切换（拍照/录像）
            shootingModeBar
                .padding(.bottom, 24)
        }
        .padding(.top, 20)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.3), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    // MARK: - Split Mode Selector

    private var splitModeSelector: some View {
        HStack(spacing: 0) {
            ForEach(SplitMode.allCases) { splitMode in
                Button {
                    if splitMode == .pip && !subscriptionManager.isPro {
                        requirePro(.pipMode) {}
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            viewModel.splitMode = splitMode
                        }
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: splitModeIcon(splitMode))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(viewModel.splitMode == splitMode ? .white : .white.opacity(0.45))
                            .frame(width: 44, height: 36)
                            .background(
                                Capsule()
                                    .fill(viewModel.splitMode == splitMode ? .white.opacity(0.25) : .clear)
                            )

                        // Pro 锁标
                        if splitMode == .pip && !subscriptionManager.isPro {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7))
                                .foregroundColor(.orange)
                                .offset(x: -2, y: 4)
                        }
                    }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
    }

    // MARK: - Aspect Ratio Bar

    private var aspectRatioBar: some View {
        HStack(spacing: 8) {
            ForEach(AspectRatioMode.allCases) { ratio in
                Button {
                    if ratio != .ratio9_16 && !subscriptionManager.isPro {
                        requirePro(.allAspectRatios) {}
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.setAspectRatio(ratio)
                        }
                    }
                } label: {
                    Text(ratio.rawValue)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(viewModel.aspectRatio == ratio ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(viewModel.aspectRatio == ratio ? .white.opacity(0.2) : .clear)
                        )
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
    }

    // MARK: - Zoom Capsule

    private var zoomCapsule: some View {
        HStack(spacing: 2) {
            ForEach(ZoomLevel.allCases, id: \.rawValue) { level in
                Button {
                    if level == .telephoto && !subscriptionManager.isPro {
                        requirePro(.telephotoZoom) {}
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            viewModel.setZoom(level)
                        }
                    }
                } label: {
                    Text(level.label)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.zoomLevel == level ? .yellow : .white.opacity(0.7))
                        .frame(width: viewModel.zoomLevel == level ? 40 : 34,
                               height: viewModel.zoomLevel == level ? 40 : 34)
                        .background(
                            Circle()
                                .fill(viewModel.zoomLevel == level
                                      ? .white.opacity(0.2)
                                      : .black.opacity(0.3))
                        )
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.zoomLevel)
                }
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
    }

    // MARK: - Capture Row (交换 + 拍摄按钮 + 镜像)

    private var captureRow: some View {
        HStack {
            // 左：交换前后镜头
            toolButton(icon: "arrow.triangle.2.circlepath") {
                viewModel.swapPanels()
            }
            .frame(maxWidth: .infinity)

            // 中：拍摄按钮
            captureButton

            // 右：镜像翻转
            toolButton(icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                viewModel.toggleMirror()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Capture Button

    private var captureButton: some View {
        Button(action: { viewModel.triggerCapture() }) {
            ZStack {
                // 外圈
                Circle()
                    .stroke(.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 76, height: 76)

                if viewModel.shootingMode == .photo {
                    // 拍照：白色实心圆
                    Circle()
                        .fill(.white)
                        .frame(width: 64, height: 64)
                } else {
                    if viewModel.isRecording {
                        // 录制中：红色圆角方块 + 脉冲动画
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red)
                            .frame(width: 32, height: 32)
                    } else {
                        // 待录制：红色实心圆
                        Circle()
                            .fill(.red)
                            .frame(width: 64, height: 64)
                    }
                }

                // 录制中：外圈红色脉冲
                if viewModel.isRecording {
                    RecordingPulseRing()
                }
            }
        }
        .disabled(viewModel.isProcessing)
    }

    // MARK: - Recording Timer

    private var recordingTimer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier())

            Text(viewModel.formattedDuration)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.5)))
    }

    // MARK: - Shooting Mode Bar

    private var shootingModeBar: some View {
        HStack(spacing: 32) {
            ForEach(ShootingMode.allCases, id: \.rawValue) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.setShootingMode(mode)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(mode.rawValue)
                            .font(.system(size: 15, weight: viewModel.shootingMode == mode ? .bold : .regular))
                            .foregroundColor(viewModel.shootingMode == mode ? .white : .white.opacity(0.5))

                        // 选中指示器小圆点
                        Circle()
                            .fill(viewModel.shootingMode == mode ? .yellow : .clear)
                            .frame(width: 5, height: 5)
                    }
                }
            }
        }
    }

    // MARK: - Duet Mode Badge (紧凑胶囊)

    private var duetModeBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10))
            Text("合拍")
                .font(.system(size: 12, weight: .medium))

            if !viewModel.isRecording {
                Button(action: { viewModel.exitDuetMode() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                Text("正在处理...")
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Tool Button (统一圆形按钮风格)

    private func toolButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.15)))
                .contentShape(Circle())
        }
    }

    // MARK: - Last Media Button

    private var lastMediaButton: some View {
        Group {
            if let lastThumbnail = viewModel.lastSavedThumbnail {
                Button(action: { viewModel.openSystemPhotos() }) {
                    Image(uiImage: lastThumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(0.4), lineWidth: 1.5)
                        )
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
    }

    // MARK: - Helpers

    /// 检查 Pro 功能，未订阅则弹付费墙
    private func requirePro(_ feature: ProFeature, action: @escaping () -> Void) {
        if subscriptionManager.isPro {
            action()
        } else {
            paywallTrigger = feature
            showPaywall = true
        }
    }

    private func splitModeIcon(_ mode: SplitMode) -> String {
        switch mode {
        case .leftRight: return "rectangle.split.2x1"
        case .topBottom: return "rectangle.split.1x2"
        case .pip: return "pip"
        }
    }
}

// MARK: - Recording Pulse Ring Animation

struct RecordingPulseRing: View {
    @State private var animating = false

    var body: some View {
        Circle()
            .stroke(.red.opacity(0.5), lineWidth: 3)
            .frame(width: 76, height: 76)
            .scaleEffect(animating ? 1.2 : 1.0)
            .opacity(animating ? 0 : 0.8)
            .animation(
                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                value: animating
            )
            .onAppear { animating = true }
    }
}

// MARK: - Pulse Modifier (录制红点闪烁)

struct PulseModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

// MARK: - Camera Preview Panel

struct CameraPreviewPanel: View {
    let sampleBuffer: CMSampleBuffer?
    var importedImage: UIImage?
    var importedPlayer: AVPlayer?

    var body: some View {
        ZStack {
            Color.black

            if importedImage != nil || importedPlayer != nil {
                DuetPreviewView(player: importedPlayer, thumbnail: importedImage)
            } else if let buffer = sampleBuffer {
                SampleBufferDisplayView(sampleBuffer: buffer)
            }
        }
    }
}

// MARK: - Async Thumbnail

struct AsyncThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .task {
            image = UIImage(contentsOfFile: url.path)
        }
    }
}
