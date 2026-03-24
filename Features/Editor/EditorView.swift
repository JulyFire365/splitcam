import SwiftUI
import AVFoundation

/// 编辑页面 — 调整边框样式、颜色、宽度
struct EditorView: View {
    let videoA: URL
    let videoB: URL

    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var viewModel = EditorViewModel()
    @State private var showBorderPanel = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar

                // Video preview
                videoPreview
                    .padding(.horizontal, 12)

                Spacer()

                // Border editing panel
                if showBorderPanel {
                    borderPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadVideos(videoA: videoA, videoB: videoB)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button("取消") { coordinator.pop() }
                .foregroundColor(.white)

            Spacer()

            Text("编辑")
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            Button("下一步") {
                // Export with current settings
                coordinator.navigateToExport(videoURL: videoA) // Will be replaced with composed URL
            }
            .foregroundColor(.blue)
            .fontWeight(.semibold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Video Preview

    private var videoPreview: some View {
        SplitPreviewView(layout: viewModel.layoutEngine) {
            VideoThumbnailView(url: videoA)
        } secondContent: {
            VideoThumbnailView(url: videoB)
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Border Panel

    private var borderPanel: some View {
        VStack(spacing: 16) {
            // Handle
            Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 40, height: 4)
                .padding(.top, 8)

            // Split mode selector
            HStack(spacing: 12) {
                Text("布局")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                Picker("布局", selection: $viewModel.splitMode) {
                    ForEach(SplitMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)

            // Border style selector
            VStack(alignment: .leading, spacing: 8) {
                Text("边框样式")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(BorderType.allCases) { type in
                            BorderStyleButton(
                                type: type,
                                isSelected: viewModel.borderType == type
                            ) {
                                viewModel.setBorderType(type)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            // Border color selector
            VStack(alignment: .leading, spacing: 8) {
                Text("边框颜色")
                    .font(.subheadline)
                    .foregroundColor(.gray)

                HStack(spacing: 12) {
                    ForEach(viewModel.availableColors, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: viewModel.borderColor == color ? 3 : 0)
                            )
                            .onTapGesture {
                                viewModel.setBorderColor(color)
                            }
                    }
                }
            }
            .padding(.horizontal, 16)

            // Border width slider
            if viewModel.borderType != .none {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("边框宽度")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Spacer()
                        Text("\(Int(viewModel.borderWidth))pt")
                            .font(.caption)
                            .foregroundColor(.white)
                    }

                    Slider(value: $viewModel.borderWidth, in: 0...10, step: 1)
                        .tint(.blue)
                        .onChange(of: viewModel.borderWidth) { newValue in
                            viewModel.setBorderWidth(newValue)
                        }
                }
                .padding(.horizontal, 16)
            }

            Spacer().frame(height: 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "1c1c1e"))
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Border Style Button

struct BorderStyleButton: View {
    let type: BorderType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: type == .rounded ? 8 : 2)
                    .stroke(
                        isSelected ? Color.blue : Color.gray,
                        lineWidth: type == .thick ? 4 : (type == .none ? 0 : 2)
                    )
                    .frame(width: 50, height: 35)
                    .overlay(
                        type == .none
                            ? AnyView(
                                Image(systemName: "slash.circle")
                                    .foregroundColor(.gray)
                              )
                            : AnyView(EmptyView())
                    )

                Text(type.rawValue)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .blue : .gray)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Video Thumbnail View

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task {
            thumbnail = await generateThumbnail()
        }
    }

    private func generateThumbnail() async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
