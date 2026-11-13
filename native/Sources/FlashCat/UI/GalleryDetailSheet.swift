import SwiftUI
import AppKit
import AVKit

/// 图库和视频页共用的详情弹层。
/// 一处定义、两种内容，避免图片详情和视频详情各长一套、字段慢慢跑偏。
enum GalleryDetailItem: Identifiable {
    case image(GalleryImage)
    case video(GalleryVideo)

    var id: String {
        switch self {
        case .image(let item): return "image:\(item.path)"
        case .video(let item): return "video:\(item.path)"
        }
    }

    var path: String {
        switch self {
        case .image(let item): return item.path
        case .video(let item): return item.path
        }
    }

    var prompt: String {
        switch self {
        case .image(let item): return item.prompt
        case .video(let item): return item.prompt
        }
    }

    var model: String {
        switch self {
        case .image(let item): return item.model
        case .video(let item): return item.model
        }
    }

    var createdAt: Date {
        switch self {
        case .image(let item): return item.createdAt
        case .video(let item): return item.createdAt
        }
    }

    var note: String? {
        switch self {
        case .image(let item): return item.note
        case .video(let item): return item.note
        }
    }

    var seed: Int? {
        switch self {
        case .image(let item): return item.seed
        case .video(let item): return item.seed
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    var kindName: String { isVideo ? "视频" : "图片" }
}

struct GalleryDetailSheet: View {
    let item: GalleryDetailItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(alignment: .top, spacing: 20) {
                preview
                details
            }
            .padding(20)
            Hairline()
            footer
        }
        .frame(width: 720, height: 540)
        .sheetCanvas()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isVideo ? "film" : "photo.on.rectangle.angled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Console.accent)
                .frame(width: 34, height: 34)
                .background {
                    LiquidGlassSurface(shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                       tint: Console.accent.opacity(0.12))
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.kindName)详情")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text("对话中生成 · \(item.model.isEmpty ? "未知模型" : item.model)")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var preview: some View {
        if item.isVideo {
            videoPreview
        } else {
            imagePreview
        }
    }

    private var imagePreview: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.16))
                thumbnail
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Console.cardStroke, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("在预览中打开原图")
        .frame(width: 320, height: 320, alignment: .top)
    }

    /// 视频直接嵌 AVKit 原生播放器：播放、拖动、全屏都由系统控件接管，
    /// 不再交给 .mp4 的默认应用（有些机器上会误开音频软件）。
    private var videoPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black)
            if let player {
                VideoPlayer(player: player)
            } else {
                thumbnail
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Console.cardStroke, lineWidth: 1)
        }
        .task(id: item.id) {
            guard item.isVideo, player == nil else { return }
            let url = URL(fileURLWithPath: item.path)
            player = FileManager.default.fileExists(atPath: item.path)
                ? AVPlayer(url: url)
                : nil
        }
        .onDisappear { player?.pause() }
        .help("在页面内播放")
        .frame(width: 320, height: 320, alignment: .top)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item {
        case .image(let image):
            ImagePreview(path: image.path)
        case .video(let video):
            VideoCover(path: video.path)
        }
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                promptSection
                Divider().overlay(Console.insetStroke)
                infoRow("模型", item.model.isEmpty ? "未知" : item.model)
                infoRow("尺寸", resolution)
                infoRow("Seed", item.seed.map(String.init) ?? "随机（未记录）", mono: true)
                if let note = item.note, !note.isEmpty {
                    infoRow("生成参数", note, mono: true)
                }
                infoRow("生成时间", Self.dateFormatter.string(from: item.createdAt))
                infoRow("文件大小", fileSize)
                infoRow("文件", item.path, mono: true)
            }
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("提示词")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Console.tertiary)
                Spacer(minLength: 4)
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.prompt, forType: .string)
                }
                .buttonStyle(.consoleSoft)
            }
            Text(item.prompt.isEmpty ? "（没有记录提示词）" : item.prompt)
                .font(.system(size: 12.5))
                .foregroundStyle(Console.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            .buttonStyle(.consoleSoft)
            if item.isVideo {
                Button("用 QuickTime 打开") {
                    VideoPlayback.openInQuickTime(item.path)
                }
                .buttonStyle(.consoleSoft)
            } else {
                Button("用预览打开") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }
                .buttonStyle(.consoleSoft)
            }
            Spacer()
            Button("完成") { dismiss() }
                .buttonStyle(.consolePrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func infoRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Console.tertiary)
            Text(value)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .foregroundStyle(Console.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 尺寸优先从生成参数里读（`768×512 · 49 帧 …`）；
    /// 视频没有 header 可扫，参数行就是唯一来源。
    private var resolution: String {
        switch item {
        case .image(let image):
            if let size = ImageStore.pixelSize(atPath: image.path) {
                return "\(Int(size.width)) × \(Int(size.height))"
            }
        case .video(let video):
            if let note = video.note,
               let first = note.split(separator: "·").first {
                let text = first.trimmingCharacters(in: .whitespaces)
                if text.contains("×") { return text }
            }
        }
        return "未知"
    }

    private var fileSize: String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.path),
              let bytes = attributes[.size] as? NSNumber
        else { return "未知" }
        return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }
}

/// 视频封面占位：缩略图是异步解出来的，先铺一层底，回来再替换。
private struct VideoCover: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Console.tertiary)
            }
        }
        .task(id: path) {
            image = await VideoThumbnailStore.thumbnail(atPath: path, maxPixel: 900)
        }
    }
}

/// 详情面板的大图。和网格卡片一样走后台解码：900 px 的成品一张要 30 ms 上下，
/// 在 `body` 里同步解，面板一打开就先顿一下，而且每次重绘都要再解一遍。
private struct ImagePreview: View {
    let path: String

    @State private var image: NSImage?
    @State private var missing = false

    private static let maxPixel: CGFloat = 900

    init(path: String) {
        self.path = path
        // 网格卡片已经解过 520 px 的，900 px 是另一个键；缓存里有就别再闪一次
        // 进度圈，直接从这张图开始显示。
        _image = State(initialValue: ImageStore.cachedThumbnail(atPath: path,
                                                                maxPixel: Self.maxPixel))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if missing {
                MissingPreview()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if image != nil { return }
        if let cached = ImageStore.cachedThumbnail(atPath: path, maxPixel: Self.maxPixel) {
            image = cached
            return
        }
        let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: Self.maxPixel)
        image = loaded
        missing = loaded == nil
    }
}

private struct MissingPreview: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 26, weight: .light))
            Text("原文件已不在")
                .font(.system(size: 11))
        }
        .foregroundStyle(Console.tertiary)
    }
}
