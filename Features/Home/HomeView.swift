import SwiftUI

/// 首页 — 模式选择页面
struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showUnsupportedAlert = false

    var body: some View {
        ZStack {
            // 背景
            LinearGradient(
                colors: [Color.black, Color(hex: "1a1a2e")],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Logo & Title
                VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x1.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text("SplitCam")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("分屏拍摄，创意无限")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }

                Spacer()

                // Mode Selection Cards
                VStack(spacing: 16) {
                    ModeCard(
                        icon: "camera.fill",
                        title: "双摄拍摄",
                        subtitle: "前后摄像头同时录制",
                        gradient: [Color.blue, Color.cyan]
                    ) {
                        if CameraEngine.isMultiCamSupported {
                            coordinator.navigateToCamera(mode: .dualCamera)
                        } else {
                            showUnsupportedAlert = true
                        }
                    }

                    ModeCard(
                        icon: "photo.on.rectangle.angled",
                        title: "导入 + 拍摄",
                        subtitle: "已有视频与实时画面组合",
                        gradient: [Color.purple, Color.pink]
                    ) {
                        coordinator.navigateToCamera(mode: .importAndShoot)
                    }

                    // Gallery card
                    ModeCard(
                        icon: "photo.on.rectangle",
                        title: "我的作品",
                        subtitle: "查看拍摄和拍照的作品",
                        gradient: [Color.orange, Color.yellow]
                    ) {
                        coordinator.navigateToGallery()
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // Version info
                Text("v1.1.0")
                    .font(.caption2)
                    .foregroundColor(.gray.opacity(0.5))
                    .padding(.bottom, 8)
            }
        }
        .navigationBarHidden(true)
        .alert("设备不支持", isPresented: $showUnsupportedAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("双摄拍摄需要 iPhone XS 或更新的设备")
        }
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let gradient: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(
                            LinearGradient(
                                colors: gradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.gray)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
