import SwiftUI
import AVFoundation
import Photos

/// 导出页面 — 分辨率选择 + 进度 + 分享
struct ExportView: View {
    let videoURL: URL

    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var viewModel = ExportViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                // Top bar
                topBar

                Spacer()

                // Content based on state
                switch viewModel.state {
                case .ready:
                    readyView
                case .exporting:
                    exportingView
                case .completed(let url):
                    completedView(url: url)
                case .failed(let message):
                    failedView(message: message)
                }

                Spacer()
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.videoURL = videoURL
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button("返回") { coordinator.pop() }
                .foregroundColor(.white)
            Spacer()
            Text("导出")
                .font(.headline)
                .foregroundColor(.white)
            Spacer()
            Color.clear.frame(width: 50) // Balance
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Ready View

    private var readyView: some View {
        VStack(spacing: 32) {
            // Video preview thumbnail
            VideoThumbnailView(url: videoURL)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)

            // Resolution selector
            VStack(spacing: 12) {
                Text("选择分辨率")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                HStack(spacing: 16) {
                    ForEach(ExportResolution.allCases) { res in
                        ResolutionButton(
                            resolution: res,
                            isSelected: viewModel.selectedResolution == res
                        ) {
                            viewModel.selectedResolution = res
                        }
                    }
                }
            }

            // Export button
            Button(action: { viewModel.startExport() }) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("导出视频")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                )
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Exporting View

    private var exportingView: some View {
        VStack(spacing: 24) {
            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: viewModel.progress)
                    .stroke(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.progress)

                Text("\(Int(viewModel.progress * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Text("正在导出...")
                .font(.subheadline)
                .foregroundColor(.gray)

            Button("取消") { viewModel.cancelExport() }
                .foregroundColor(.red)
        }
    }

    // MARK: - Completed View

    private func completedView(url: URL) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("导出完成！")
                .font(.title2.bold())
                .foregroundColor(.white)

            // Action buttons
            VStack(spacing: 12) {
                // Save to album
                Button(action: { viewModel.saveToAlbum(url: url) }) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("保存到相册")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue)
                    )
                }

                // Share
                Button(action: { viewModel.showShareSheet = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("分享到其他应用")
                    }
                    .font(.headline)
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.blue, lineWidth: 1.5)
                    )
                }

                // Back to home
                Button(action: { coordinator.popToRoot() }) {
                    Text("返回首页")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $viewModel.showShareSheet) {
            ShareSheet(items: [url])
        }
        .alert("已保存", isPresented: $viewModel.showSaveSuccess) {
            Button("好的") {}
        } message: {
            Text("视频已保存到相册")
        }
    }

    // MARK: - Failed View

    private func failedView(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text("导出失败")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("重试") { viewModel.startExport() }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue)
                )
        }
    }
}

// MARK: - Resolution Button

struct ResolutionButton: View {
    let resolution: ExportResolution
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(resolution.rawValue)
                    .font(.headline)
                Text("\(Int(resolution.size.width))×\(Int(resolution.size.height))")
                    .font(.caption2)
            }
            .foregroundColor(isSelected ? .white : .gray)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.blue : Color.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }
}
