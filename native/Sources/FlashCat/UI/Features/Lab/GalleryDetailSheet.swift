// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AVKit
import AppKit
import SwiftUI

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
    var items: [GalleryDetailItem] = []
    var onSelect: ((GalleryDetailItem) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    @State private var missingVideo = false
    @State private var copiedPrompt = false
    @State private var copyResetTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private var fileExists: Bool {
        MediaFiles.exists(item.path)
    }

    private var currentIndex: Int? {
        items.firstIndex(where: { $0.id == item.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            HStack(alignment: .top, spacing: 20) {
                preview
                details
            }
            .padding(20)
            DSDivider()
            footer
        }
        .frame(width: 720, height: 540)
        .sheetCanvas()
        .onExitCommand { dismiss() }
        .onDisappear {
            player?.pause()
            player = nil
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: item.isVideo ? "film" : "photo.on.rectangle.angled", color: DS.accent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(item.isVideo ? "视频详情" : "图片详情"))
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(L10n.format("对话中生成 · %@", item.model.isEmpty ? L10n.t("未知模型") : item.model))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let index = currentIndex, items.count > 1, let onSelect {
                HStack(spacing: 6) {
                    Text(verbatim: "\(index + 1) / \(items.count)")
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                    DSIconButton(systemName: "chevron.left", help: "上一项", style: .outlined) {
                        onSelect(items[index - 1])
                    }
                    .disabled(index <= 0)
                    DSIconButton(systemName: "chevron.right", help: "下一项", style: .outlined) {
                        onSelect(items[index + 1])
                    }
                    .disabled(index >= items.count - 1)
                }
            }
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
                DS.rect(DS.Radius.lg)
                    .fill(DS.bg)
                thumbnail
            }
            .frame(width: 320, height: 320)
            .clipShape(DS.rect(DS.Radius.lg))
            .overlay {
                DS.rect(DS.Radius.lg)
                    .strokeBorder(DS.line, lineWidth: 1)
            }
            .contentShape(DS.rect(DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!fileExists)
        .help(L10n.t("在预览中打开原图"))
        .frame(width: 320, height: 320, alignment: .top)
    }

    /// 视频直接嵌 AVKit 原生播放器：播放、拖动、全屏都由系统控件接管，
    /// 不再交给 .mp4 的默认应用（有些机器上会误开音频软件）。
    private var videoPreview: some View {
        ZStack {
            DS.rect(DS.Radius.lg)
                .fill(missingVideo ? DS.bg : Color.black)
            if missingVideo {
                MissingPreview()
            } else if let player {
                VideoPlayer(player: player)
            } else {
                thumbnail
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 320, height: 320)
        .clipShape(DS.rect(DS.Radius.lg))
        .overlay {
            DS.rect(DS.Radius.lg)
                .strokeBorder(DS.line, lineWidth: 1)
        }
        .task(id: item.id) {
            player?.pause()
            player = nil
            copiedPrompt = false
            copyResetTask?.cancel()
            copyResetTask = nil
            guard item.isVideo else {
                missingVideo = false
                return
            }
            let exists = MediaFiles.exists(item.path)
            missingVideo = !exists
            guard exists else { return }
            player = AVPlayer(url: URL(fileURLWithPath: item.path))
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .help(L10n.t("在页面内播放"))
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
                DSDivider()
                infoRow("模型", item.model.isEmpty ? L10n.t("未知") : item.model)
                infoRow("尺寸", resolution)
                infoRow("Seed", item.seed.map(String.init) ?? L10n.t("随机（未记录）"), mono: true)
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
                Text(L10n.t("提示词"))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.prompt, forType: .string)
                    copyResetTask?.cancel()
                    withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copiedPrompt = true }
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copiedPrompt = false }
                    }
                } label: {
                    Label(
                        L10n.t(copiedPrompt ? "已复制" : "复制"),
                        systemImage: copiedPrompt ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.ds(.secondary, size: .small))
                .disabled(item.prompt.isEmpty)
            }
            Text(item.prompt.isEmpty ? L10n.t("（没有记录提示词）") : item.prompt)
                .font(DS.Font.md)
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(L10n.t("在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .disabled(!fileExists)
            if item.isVideo {
                Button(L10n.t("用 QuickTime 打开")) {
                    VideoPlayback.openInQuickTime(item.path)
                }
                .buttonStyle(.ds(.secondary, size: .regular))
                .disabled(!fileExists)
            } else {
                Button(L10n.t("用预览打开")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }
                .buttonStyle(.ds(.secondary, size: .regular))
                .disabled(!fileExists)
            }
            Spacer()
            Button(L10n.t("完成")) { dismiss() }
                .buttonStyle(.ds(.primary, size: .regular))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func infoRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.t(title))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(DS.text3)
            Text(value)
                .font(mono ? DS.Font.mono(11.5) : DS.Font.sm)
                .foregroundStyle(DS.text)
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
                let first = note.split(separator: "·").first
            {
                let text = first.trimmingCharacters(in: .whitespaces)
                if text.contains("×") { return text }
            }
        }
        return L10n.t("未知")
    }

    private var fileSize: String {
        guard let bytes = MediaFiles.size(item.path) else { return L10n.t("未知") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                    .foregroundStyle(DS.text3)
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
        _image = State(
            initialValue: ImageStore.cachedThumbnail(
                atPath: path,
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
            Text(L10n.t("原文件已不在"))
                .font(DS.Font.xs)
        }
        .foregroundStyle(DS.text3)
    }
}
