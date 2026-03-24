import SwiftUI
import AVFoundation

/// 拍摄页面 — 全屏预览 + 拍照/拍摄 + 比例/变焦控制
struct CameraView: View {
    let mode: CaptureMode

    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var viewModel = CameraViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 全屏分屏预览（圆角）
            splitPreview
                .ignoresSafeArea()

            // 摄像头未就绪时的黑色蒙版
            // opacity 实现：未就绪时立刻全黑，就绪后平滑淡出
            Color.black
                .ignoresSafeArea()
                .opacity(viewModel.camerasReady ? 0 : 1)
                .animation(viewModel.camerasReady ? .easeOut(duration: 0.3) : nil,
                           value: viewModel.camerasReady)
                .allowsHitTesting(false)

            // 闪光效果 (拍照)
            if viewModel.showFlashEffect {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: viewModel.showFlashEffect)
            }

            // 处理中蒙版
            if viewModel.isProcessing {
                processingOverlay
            }

            // 控制层 (四角布局)
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear {
            viewModel.setup(mode: mode)
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            viewModel.resumeSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.pauseSession()
        }
        .sheet(isPresented: $viewModel.showVideoPicker) {
            VideoPicker(isPresented: $viewModel.showVideoPicker) { result in
                viewModel.handlePickedVideo(result)
            }
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage)
        }
    }

    private func splitModeIcon(_ mode: SplitMode) -> String {
        switch mode {
        case .leftRight: return "rectangle.split.2x1"
        case .topBottom: return "rectangle.split.1x2"
        case .pip: return "pip"
        }
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

    // MARK: - Full Screen Split Preview

    private var splitPreview: some View {
        GeometryReader { geo in
            let previewSize = calculatePreviewSize(in: geo.size)

            SplitPreviewView(layout: viewModel.layoutEngine, isDraggingBinding: $viewModel.isDraggingDivider) {
                CameraPreviewPanel(
                    sampleBuffer: viewModel.panelsSwapped ? viewModel.frontFrameBuffer : viewModel.backFrameBuffer,
                    player: viewModel.panelsSwapped ? nil : viewModel.importedPlayer
                )
            } secondContent: {
                CameraPreviewPanel(
                    sampleBuffer: viewModel.panelsSwapped ? viewModel.backFrameBuffer : viewModel.frontFrameBuffer,
                    player: viewModel.panelsSwapped ? viewModel.importedPlayer : nil
                )
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .top) {
            // 左上角: 占位
            Color.clear.frame(width: 40, height: 40)

            Spacer()

            // 中间: 分屏模式 + 比例选择
            VStack(spacing: 8) {
                // Split mode toggle
                HStack(spacing: 2) {
                    ForEach(SplitMode.allCases) { splitMode in
                        Button {
                            viewModel.splitMode = splitMode
                        } label: {
                            Image(systemName: splitModeIcon(splitMode))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(viewModel.splitMode == splitMode ? .white : .white.opacity(0.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(viewModel.splitMode == splitMode ? .white.opacity(0.3) : .clear)
                                )
                        }
                    }
                }
                .background(Capsule().fill(.black.opacity(0.3)))

                // Aspect ratio selector
                if !viewModel.isRecording {
                    aspectRatioBar
                }
            }

            Spacer()

            // 右上角: 翻转 + 模式切换
            VStack(spacing: 10) {
                Button(action: { viewModel.toggleMirror() }) {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.black.opacity(0.35)))
                }

                // 导入模式切换
                if !viewModel.isRecording {
                    Button(action: { viewModel.showVideoPicker = true }) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Aspect Ratio Bar

    private var aspectRatioBar: some View {
        HStack(spacing: 6) {
            ForEach(AspectRatioMode.allCases) { ratio in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setAspectRatio(ratio)
                    }
                } label: {
                    Text(ratio.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(viewModel.aspectRatio == ratio ? .yellow : .white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(viewModel.aspectRatio == ratio ? .white.opacity(0.15) : .clear)
                        )
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(.black.opacity(0.25)))
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 14) {
            // Recording timer
            if viewModel.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(viewModel.formattedDuration)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.5)))
            }

            // Zoom controls
            zoomBar

            // Shooting mode toggle
            if !viewModel.isRecording {
                shootingModeBar
            }

            // Main action row
            HStack {
                // 左下: 交换镜头
                Button(action: { viewModel.swapPanels() }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .disabled(viewModel.isRecording)

                Spacer()

                // 中间: 拍摄按钮
                captureButton

                Spacer()

                // 右下: 最近一张缩略图
                lastMediaButton
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 25)
        }
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.4), .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Zoom Bar

    private var zoomBar: some View {
        HStack(spacing: 4) {
            ForEach(ZoomLevel.allCases, id: \.rawValue) { level in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.setZoom(level)
                    }
                } label: {
                    Text(level.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(viewModel.zoomLevel == level ? .yellow : .white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(viewModel.zoomLevel == level ? .white.opacity(0.2) : .black.opacity(0.3))
                        )
                }
            }
        }
    }

    // MARK: - Shooting Mode Bar

    private var shootingModeBar: some View {
        HStack(spacing: 24) {
            ForEach(ShootingMode.allCases, id: \.rawValue) { mode in
                Button {
                    viewModel.setShootingMode(mode)
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 15, weight: viewModel.shootingMode == mode ? .bold : .regular))
                        .foregroundColor(viewModel.shootingMode == mode ? .yellow : .white.opacity(0.6))
                }
            }
        }
    }

    // MARK: - Capture Button

    private var captureButton: some View {
        Button(action: { viewModel.triggerCapture() }) {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                if viewModel.shootingMode == .photo {
                    Circle()
                        .fill(.white)
                        .frame(width: 60, height: 60)
                } else {
                    if viewModel.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 60, height: 60)
                    }
                }
            }
        }
        .disabled(viewModel.isProcessing)
    }

    // MARK: - Last Media Button

    private var lastMediaButton: some View {
        Group {
            if let lastThumbnail = viewModel.lastSavedThumbnail {
                Button(action: { viewModel.openSystemPhotos() }) {
                    Image(uiImage: lastThumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(.white.opacity(0.5), lineWidth: 1.5)
                        )
                }
            } else {
                Color.clear.frame(width: 50, height: 50)
            }
        }
    }
}

// MARK: - Camera Preview Panel

struct CameraPreviewPanel: View {
    let sampleBuffer: CMSampleBuffer?
    let player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayerView(player: player)
            } else if let buffer = sampleBuffer {
                SampleBufferDisplayView(sampleBuffer: buffer)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.largeTitle)
                    Text("预览")
                        .font(.caption)
                }
                .foregroundColor(.gray)
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
