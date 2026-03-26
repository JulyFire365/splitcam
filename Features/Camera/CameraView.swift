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
    @State private var focusPoint: CGPoint?
    @State private var showFocusIndicator = false

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

            // ③ 摄像头未就绪时的启动画面
            if !viewModel.camerasReady {
                LaunchLoadingView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // ⑤ 快门动画 (拍照 — 上下黑幕合拢再展开)
            if viewModel.showFlashEffect {
                ShutterAnimationView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
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
        .alert("error".localized, isPresented: $viewModel.showError) {
            Button("ok".localized, role: .cancel) {}
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
            .overlay {
                // 对焦指示器（不拦截触摸）
                if showFocusIndicator, let pt = focusPoint {
                    FocusIndicatorView()
                        .position(pt)
                        .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let location = value.location
                        let normalizedX = location.x / previewSize.width
                        let normalizedY = location.y / previewSize.height
                        let point = CGPoint(x: normalizedX, y: normalizedY)

                        let isBack: Bool
                        if viewModel.splitMode == .leftRight {
                            isBack = viewModel.panelsSwapped ? (normalizedX > viewModel.layoutEngine.splitRatio) : (normalizedX <= viewModel.layoutEngine.splitRatio)
                        } else if viewModel.splitMode == .topBottom {
                            isBack = viewModel.panelsSwapped ? (normalizedY > viewModel.layoutEngine.splitRatio) : (normalizedY <= viewModel.layoutEngine.splitRatio)
                        } else {
                            isBack = !viewModel.panelsSwapped
                        }

                        viewModel.cameraEngine.focusAtPoint(point, isBack: isBack)
                        focusPoint = location
                        showFocusIndicator = true
                        withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                            showFocusIndicator = false
                        }
                    }
            )
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

            // 比例选择器 + 合拍标签（录制时隐藏）
            if !viewModel.isRecording {
                ZStack {
                    // 比例栏：无合拍时居中，有合拍时左移
                    HStack {
                        aspectRatioBar
                        if viewModel.isDuetMode { Spacer() }
                    }
                    .frame(maxWidth: .infinity)

                    // 合拍胶囊：右对齐
                    if viewModel.isDuetMode {
                        HStack {
                            Spacer()
                            duetModeBadge
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
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
        HStack(spacing: 6) {
            // 比例选项
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(viewModel.aspectRatio == ratio ? .white.opacity(0.2) : .clear)
                        )
                }
            }

            // 分隔线
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1, height: 16)

            // 画质切换
            resolutionToggle
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark))
    }

    // MARK: - Zoom Capsule

    private var zoomCapsule: some View {
        HStack(spacing: 6) {
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
            ForEach(ShootingMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.setShootingMode(mode)
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(mode.displayName)
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

    // MARK: - Resolution Toggle (画质切换)

    private var resolutionToggle: some View {
        Button {
            if viewModel.resolutionQuality == .standard {
                // 高画质是 Pro 功能
                requirePro(.pipMode) {
                    withAnimation(.spring(response: 0.3)) {
                        viewModel.resolutionQuality = .high
                        viewModel.syncRecordingSnapshot()
                    }
                }
            } else {
                withAnimation(.spring(response: 0.3)) {
                    viewModel.resolutionQuality = .standard
                    viewModel.syncRecordingSnapshot()
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: viewModel.resolutionQuality == .high ? "sparkles" : "circle")
                    .font(.system(size: 8))
                Text(viewModel.resolutionQuality == .high ? "HD" : "SD")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            .foregroundColor(viewModel.resolutionQuality == .high ? .yellow : .white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(viewModel.resolutionQuality == .high ? .yellow.opacity(0.2) : .clear)
            )
        }
    }

    // MARK: - Duet Mode Badge (紧凑胶囊)

    private var duetModeBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10))
            Text("duet".localized)
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
                Text("processing".localized)
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

// MARK: - Shutter Animation (快门动画 — 上下黑幕合拢再展开)

struct ShutterAnimationView: View {
    @State private var closed = false
    @State private var done = false

    var body: some View {
        if !done {
            ZStack {
                // 上半幕
                VStack {
                    Color.black
                        .frame(height: UIScreen.main.bounds.height / 2)
                        .offset(y: closed ? 0 : -UIScreen.main.bounds.height / 2)
                    Spacer()
                }

                // 下半幕
                VStack {
                    Spacer()
                    Color.black
                        .frame(height: UIScreen.main.bounds.height / 2)
                        .offset(y: closed ? 0 : UIScreen.main.bounds.height / 2)
                }
            }
            .onAppear {
                // 合拢
                withAnimation(.easeIn(duration: 0.12)) {
                    closed = true
                }
                // 展开
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        closed = false
                    }
                }
                // 结束
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    done = true
                }
            }
        }
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

// MARK: - Focus Indicator

struct FocusIndicatorView: View {
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    scale = 1.0
                }
                withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
                    opacity = 0
                }
            }
    }
}

// MARK: - Launch Loading View (启动加载画面)

struct LaunchLoadingView: View {
    @State private var iconScale: CGFloat = 0.6
    @State private var iconOpacity: Double = 0
    @State private var ringRotation: Double = 0
    @State private var ringOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            // 深色渐变背景
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.16),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 28) {
                ZStack {
                    // 外圈旋转光环
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .blue.opacity(0),
                                    .blue.opacity(0.5),
                                    .purple.opacity(0.8)
                                ],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .frame(width: 100, height: 100)
                        .rotationEffect(.degrees(ringRotation))
                        .opacity(ringOpacity)

                    // App 图标
                    Group {
                        if let icon = UIImage(named: "AppIcon") {
                            Image(uiImage: icon)
                                .resizable()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            // fallback 镜头图标
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 72, height: 72)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
                }

                // 加载文字
                Text("SplitCam")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .opacity(textOpacity)
            }
        }
        .onAppear {
            // 图标弹入
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.1)) {
                iconScale = 1.0
                iconOpacity = 1
            }
            // 光环淡入 + 旋转
            withAnimation(.easeIn(duration: 0.4).delay(0.3)) {
                ringOpacity = 1
            }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
            // 文字淡入
            withAnimation(.easeIn(duration: 0.4).delay(0.5)) {
                textOpacity = 1
            }
        }
    }
}

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
