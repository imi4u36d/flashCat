// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import SwiftUI

/// 「实验室」页：侧边栏设置之后的独立入口，顶部用分段控件在图片/视频之间切换。
/// 两个库都只认 assistant 消息里落盘的结果，用户给的底图/首帧图不会混进来。
///
/// 采用连续滚动的自适应网格呈现全部作品；卡片封面依旧异步解码并缓存。
struct LabPage: View {
    @ObservedObject var state: AppState

    private enum LabTab: Hashable {
        case images
        case videos

        var kind: LabGridKind {
            switch self {
            case .images: return .images
            case .videos: return .videos
            }
        }

        var unit: String {
            switch self {
            case .images: return "张"
            case .videos: return "个"
            }
        }
    }

    @State private var tab: LabTab = .images
    @State private var images: [GalleryImage] = []
    @State private var videos: [GalleryVideo] = []
    @State private var detail: GalleryDetailItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Console.contentPadding)
                .padding(.top, Console.contentTopInset)
                .padding(.bottom, 14)

            if itemCount == 0 {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.bottom, Console.contentBottomInset)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: tab == .images ? 220 : 300),
                                spacing: 16, alignment: .top)
                        ],
                        spacing: 16
                    ) {
                        gridItems
                    }
                    .padding(.horizontal, Console.contentPadding)
                    .padding(.bottom, Console.contentBottomInset)
                }
                .scrollIndicators(.never)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: tab) { _, _ in
            reload()
        }
        .sheet(item: $detail) { item in
            GalleryDetailSheet(item: item)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: "flask", color: DS.accent, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("实验室")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.text)
                    Text("对话中生成的图片和视频；只收模型产出的结果")
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                DSIconButton(systemName: "arrow.clockwise", help: "刷新") { reload() }
                Button("打开文件夹") {
                    let folder = tab == .images ? ImageStore.directory : VideoStore.directory
                    Paths.ensureDirectory(folder)
                    NSWorkspace.shared.open(URL(fileURLWithPath: folder))
                }
                .buttonStyle(.ds(.secondary, size: .regular))
            }

            HStack(spacing: 12) {
                DSSegmented(
                    selection: $tab,
                    options: [
                        (.images, "图片 \(images.count)"),
                        (.videos, "视频 \(videos.count)"),
                    ])
                if itemCount > 0 {
                    Text("共 \(itemCount) \(tab.unit)")
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var itemCount: Int {
        switch tab {
        case .images: return images.count
        case .videos: return videos.count
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch tab {
        case .images:
            LabEmptyState(
                icon: "photo.on.rectangle.angled",
                title: "还没有生成的图片",
                detail: "在对话里让模型生成图片后，作品会自动出现在这里。\n你发给模型的底图不会收录。")
        case .videos:
            LabEmptyState(
                icon: "film",
                title: "还没有生成的视频",
                detail: "在对话里让模型生成视频后，作品会自动出现在这里。\n你发给模型的首帧图不会收录。")
        }
    }

    // MARK: - 网格

    @ViewBuilder
    private var gridItems: some View {
        switch tab {
        case .images:
            ForEach(images) { image in
                GalleryImageTile(
                    image: image,
                    modelName: modelLabel(image.model),
                    coverHeight: 210,
                    maxPixel: 640,
                    openDetail: { detail = .image(image) })
            }
        case .videos:
            ForEach(videos) { video in
                GalleryVideoTile(
                    video: video,
                    modelName: modelLabel(video.model),
                    coverHeight: 175,
                    maxPixel: 800,
                    openDetail: { detail = .video(video) })
            }
        }
    }

    /// 卡片页脚只放得下仓库名（去掉 owner/ 前缀），完整 id 留给详情面板。
    private func modelLabel(_ model: String) -> String {
        model.isEmpty ? "未知模型" : state.shortModelName(model)
    }

    private func reload() {
        images = ImageGalleryStore.shared.merge(threads: state.threads)
        videos = VideoGalleryStore.shared.merge(threads: state.threads)
    }
}

// MARK: - 一屏一页的排版

enum LabGridKind: String {
    case images
    case videos

    /// 一列至少要有这么宽，窗口再窄就少放一列。
    var minCellWidth: CGFloat {
        switch self {
        case .images: return 220
        case .videos: return 300
        }
    }

    /// 超宽窗口上不让单元格无限拉大。
    var maxColumns: Int {
        switch self {
        case .images: return 6
        case .videos: return 4
        }
    }

    /// 封面宽 / 高。图片是正方形原图，视频是 16:9 的封面帧。
    var coverAspect: CGFloat {
        switch self {
        case .images: return 1
        case .videos: return 16.0 / 9.0
        }
    }
}

/// 一页的栅格尺寸：列数按可用宽度算，行数按可用高度尽量多放。
///
/// 尺寸只取决于可用区域，跟数据无关——所以窗口一缩放，页面就跟着重排，
/// 不会出现半行卡片被切在屏幕外面。卡片结构变了（多一行文字之类），
/// 要同步改 `chrome`，否则行高会算少。
struct LabGridLayout: Equatable {
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let coverHeight: CGFloat

    static let spacing: CGFloat = 12
    /// 封面之外的部分：内边距 7×2、两处 5pt 间距、一行提示词、一行信息。
    static let chrome: CGFloat = 50
    static let cardInset: CGFloat = 7
    static let maxRows = 4
    static let minCoverHeight: CGFloat = 96

    var pageSize: Int { columns * rows }
    var cellHeight: CGFloat { coverHeight + Self.chrome }

    var gridWidth: CGFloat {
        CGFloat(columns) * cellWidth + Self.spacing * CGFloat(columns - 1)
    }

    var requiredHeight: CGFloat {
        CGFloat(rows) * cellHeight + Self.spacing * CGFloat(rows - 1)
    }

    var coverWidth: CGFloat { cellWidth - Self.cardInset * 2 }

    /// - Parameters:
    ///   - size: 去掉页面留白之后、留给网格的区域。
    ///   - kind: 图片（方图）还是视频（16:9）。
    static func make(size: CGSize, kind: LabGridKind) -> LabGridLayout {
        let width = max(size.width, 1)
        let height = max(size.height, 1)

        let columns = max(
            1,
            min(
                kind.maxColumns,
                Int((width + spacing) / (kind.minCellWidth + spacing))))
        let cellWidth = max(1, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let coverWidth = max(1, cellWidth - cardInset * 2)
        var coverHeight = max(minCoverHeight, coverWidth / kind.coverAspect)

        var rows = 1
        while rows < maxRows {
            let next = rows + 1
            let needed = CGFloat(next) * (coverHeight + chrome) + spacing * CGFloat(next - 1)
            if needed <= height { rows = next } else { break }
        }

        // 窗口矮到连一行都放不下时，把封面压扁，保住「一页一定在一屏里」。
        if coverHeight + chrome > height {
            coverHeight = max(minCoverHeight, height - chrome)
        }

        return LabGridLayout(
            columns: columns,
            rows: rows,
            cellWidth: cellWidth,
            coverHeight: coverHeight)
    }
}

private struct LabEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(DS.text3)
                .frame(width: 48, height: 48)
                .dsSurface(radius: DS.Radius.lg, fill: DS.raised, stroke: DS.line)
            Text(title)
                .font(DS.Font.md.weight(.medium))
                .foregroundStyle(DS.text2)
            Text(detail)
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct GalleryImageTile: View {
    let image: GalleryImage
    let modelName: String
    let coverHeight: CGFloat
    let maxPixel: CGFloat
    let openDetail: () -> Void

    var body: some View {
        Button(action: openDetail) {
            VStack(alignment: .leading, spacing: 5) {
                GalleryImageCover(path: image.path, maxPixel: maxPixel)
                    .frame(maxWidth: .infinity)
                    .frame(height: coverHeight)
                    .clipped()
                    .clipShape(DS.rect(DS.Radius.md))
                    .overlay {
                        DS.rect(DS.Radius.md)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }

                Text(image.prompt.isEmpty ? "（无提示词）" : image.prompt)
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Text(modelName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 3)
                    if let seed = image.seed {
                        Text(verbatim: "seed \(String(seed))")
                            .monospacedDigit()
                    }
                }
                .font(DS.Font.mono(10))
                .foregroundStyle(DS.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(LabGridLayout.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsSurface(radius: DS.Radius.lg, hoverable: true)
        .help(image.prompt.isEmpty ? "查看详情" : image.prompt)
        .contextMenu {
            Button("查看详情", action: openDetail)
            Button("用预览打开") {
                NSWorkspace.shared.open(URL(fileURLWithPath: image.path))
            }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: image.path)])
            }
            Button("复制提示词") { copyToPasteboard(image.prompt) }
        }
    }
}

/// 网格卡片的封面图。
///
/// 封面必须自己拿着 `@State` 并异步解码：一屏十几张 2–4 MB 的原图在 `body` 里
/// 同步解成缩略图要 20 ms 上下，切进实验室页面就是一秒左右的主线程停顿。
/// 解码期间铺一层浅底，图回来再淡入；翻页时父视图重算 body 也不会重新解码。
private struct GalleryImageCover: View {
    let path: String
    let maxPixel: CGFloat

    @State private var image: NSImage?
    @State private var missing = false

    init(path: String, maxPixel: CGFloat) {
        self.path = path
        self.maxPixel = maxPixel
        // 从别的页面切回来时图已经在缓存里了，直接当初始值，省掉一帧占位闪烁。
        _image = State(initialValue: ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel))
    }

    var body: some View {
        // 封面自己定尺寸（Color.clear 吃掉父级提议），图层用 overlay 叠上去再裁：
        // 直接让 Image 当 ZStack 的兄弟，`.fill` 会按高度反推宽度并撑大整个 ZStack，
        // 卡片就被顶出右边界了。
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if missing {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(DS.text3)
                } else {
                    DS.bg
                }
            }
            .clipped()
            .animation(DS.Motion.snappy, value: image == nil)
            .task(id: path) { await load() }
    }

    private func load() async {
        if image != nil { return }
        if let cached = ImageStore.cachedThumbnail(atPath: path, maxPixel: maxPixel) {
            image = cached
            return
        }
        let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: maxPixel)
        image = loaded
        missing = loaded == nil
    }
}

private struct GalleryVideoTile: View {
    let video: GalleryVideo
    let modelName: String
    let coverHeight: CGFloat
    let maxPixel: CGFloat
    let openDetail: () -> Void

    @State private var cover: NSImage?

    var body: some View {
        Button(action: openDetail) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: coverHeight)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let cover {
                            Image(nsImage: cover)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "film")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(DS.text3)
                        }
                    }
                    .clipped()
                    .clipShape(DS.rect(DS.Radius.md))
                    .overlay {
                        DS.rect(DS.Radius.md)
                            .strokeBorder(DS.line, lineWidth: 1)
                    }
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    }
                    .task(id: video.path) {
                        cover = await VideoThumbnailStore.thumbnail(atPath: video.path, maxPixel: maxPixel)
                    }

                Text(video.prompt.isEmpty ? "（无提示词）" : video.prompt)
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Text(modelName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 3)
                    if let seed = video.seed {
                        Text(verbatim: "seed \(String(seed))")
                            .monospacedDigit()
                    }
                }
                .font(DS.Font.mono(10))
                .foregroundStyle(DS.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(LabGridLayout.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dsSurface(radius: DS.Radius.lg, hoverable: true)
        .help(video.prompt.isEmpty ? "查看详情" : video.prompt)
        .contextMenu {
            Button("查看详情", action: openDetail)
            Button("播放视频", action: openDetail)
            Button("用 QuickTime 打开") {
                VideoPlayback.openInQuickTime(video.path)
            }
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: video.path)])
            }
            Button("复制提示词") { copyToPasteboard(video.prompt) }
        }
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
