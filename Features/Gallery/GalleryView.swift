import SwiftUI
import AVKit

/// 相册页面 — 查看拍摄/拍照的作品
struct GalleryView: View {
    @EnvironmentObject var coordinator: AppCoordinator
    @ObservedObject var mediaStore = MediaStore.shared
    @State private var selectedFilter: GalleryFilter = .all
    @State private var selectedItem: MediaItem?
    @State private var showDeleteAlert = false
    @State private var itemToDelete: MediaItem?
    @State private var showShareSheet = false

    enum GalleryFilter: String, CaseIterable {
        case all = "全部"
        case photo = "照片"
        case video = "视频"
    }

    private var filteredItems: [MediaItem] {
        switch selectedFilter {
        case .all: return mediaStore.items
        case .photo: return mediaStore.items.filter { $0.type == .photo }
        case .video: return mediaStore.items.filter { $0.type == .video }
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                filterBar

                if filteredItems.isEmpty {
                    emptyState
                } else {
                    gridView
                }
            }
        }
        .navigationBarHidden(true)
        .fullScreenCover(item: $selectedItem) { item in
            MediaDetailView(item: item) {
                selectedItem = nil
            }
        }
        .alert("确认删除", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                if let item = itemToDelete {
                    mediaStore.deleteItem(item)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复，确定要删除吗？")
        }
        .alert("已保存", isPresented: $mediaStore.showSaveSuccess) {
            Button("好的") {}
        } message: {
            Text("已保存到系统相册")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: { coordinator.pop() }) {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(10)
            }

            Spacer()

            Text("我的作品")
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 0) {
            ForEach(GalleryFilter.allCases, id: \.rawValue) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 14, weight: selectedFilter == filter ? .bold : .regular))
                        .foregroundColor(selectedFilter == filter ? .white : .gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            selectedFilter == filter
                                ? Capsule().fill(.white.opacity(0.15))
                                : nil
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 50))
                .foregroundColor(.gray.opacity(0.5))
            Text("还没有作品")
                .font(.subheadline)
                .foregroundColor(.gray)
            Text("去拍摄你的第一个分屏作品吧")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))
            Spacer()
        }
    }

    // MARK: - Grid View

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(filteredItems) { item in
                    GalleryCell(item: item)
                        .aspectRatio(3/4, contentMode: .fill)
                        .onTapGesture {
                            selectedItem = item
                        }
                        .contextMenu {
                            Button {
                                mediaStore.saveToSystemAlbum(item)
                            } label: {
                                Label("保存到相册", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                showShareSheet = true
                            } label: {
                                Label("分享", systemImage: "square.and.arrow.up")
                            }

                            Divider()

                            Button(role: .destructive) {
                                itemToDelete = item
                                showDeleteAlert = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Gallery Cell

struct GalleryCell: View {
    let item: MediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncThumbnail(url: item.thumbnailURL)
                .clipped()

            // Video indicator
            if item.type == .video {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    Text("视频")
                        .font(.system(size: 9))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(6)
            }

            // Date
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(item.formattedDate)
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(4)
                }
            }
        }
    }
}

// MARK: - Media Detail View

struct MediaDetailView: View {
    let item: MediaItem
    let onDismiss: () -> Void

    @ObservedObject var mediaStore = MediaStore.shared
    @State private var showShareSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Circle().fill(.white.opacity(0.15)))
                    }

                    Spacer()

                    Text(item.type == .photo ? "照片" : "视频")
                        .foregroundColor(.white)
                        .font(.headline)

                    Spacer()

                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // Content
                if item.type == .photo {
                    if let image = UIImage(contentsOfFile: item.fileURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(.horizontal, 8)
                    }
                } else {
                    VideoPlayer(player: AVPlayer(url: item.fileURL))
                        .aspectRatio(contentMode: .fit)
                        .padding(.horizontal, 8)
                }

                Spacer()

                // Bottom actions
                HStack(spacing: 40) {
                    Button {
                        mediaStore.saveToSystemAlbum(item)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.title2)
                            Text("保存")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                    }

                    Button {
                        showShareSheet = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title2)
                            Text("分享")
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                    }

                    Button {
                        mediaStore.deleteItem(item)
                        onDismiss()
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.title2)
                            Text("删除")
                                .font(.caption)
                        }
                        .foregroundColor(.red)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [item.fileURL])
        }
        .alert("已保存", isPresented: $mediaStore.showSaveSuccess) {
            Button("好的") {}
        } message: {
            Text("已保存到系统相册")
        }
    }
}
