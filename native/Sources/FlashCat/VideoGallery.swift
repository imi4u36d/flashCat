import Foundation
import AppKit
import AVFoundation

/// 视频图库里的一条作品：模型在对话里生成、已经落成 MP4 的文件。
///
/// 和图片一样，用户提供的首帧图挂在 user 消息的 `imagePath` /
/// assistant 消息的 `videoSourcePath` 上；索引只登记 assistant 的
/// `videoPath`，所以首帧图不会被当成作品。
struct GalleryVideo: Identifiable, Equatable {
    let path: String
    let prompt: String
    let model: String
    let createdAt: Date
    let note: String?
    let seed: Int?

    var id: String { path }
}

/// 生成视频的索引。和 `ImageGalleryStore` 一样独立于聊天历史：
/// 历史只保留最近六段对话，删对话也不该把已经保存的视频一起抹掉。
/// 索引本身只存在磁盘文件里，实例上只有一个不变的路径，没有可变的引用
/// 状态，所以可以安全地跨隔离域共享。同一个文件的并发写入仍是后写者覆盖
/// 先写者（加 `Sendable` 之前也是这样），应用里的登记与合并都在主线程。
final class VideoGalleryStore: Sendable {
    static let shared = VideoGalleryStore()

    private struct StoredVideo: Codable {
        let path: String
        let prompt: String
        let model: String
        let createdAt: Double
        let note: String?
        let seed: Int?
    }

    private let fileURL: URL

    init(fileURL: URL = URL(fileURLWithPath: Paths.supportDirectory + "/video-gallery.json")) {
        self.fileURL = fileURL
    }

    /// 新片在前。指向已删除文件的条目先跳过，文件放回来还能重新出现。
    func videos() -> [GalleryVideo] {
        Self.visible(Self.read(fileURL))
    }

    /// 生成成功后登记。同一路径重复登记时覆盖，不会留下两条。
    /// 写回以原始索引为底，别把「文件暂时不在」当成「用户删了」。
    @discardableResult
    func record(_ video: GalleryVideo) -> [GalleryVideo] {
        var values = Self.read(fileURL).filter { $0.path != video.path }
        values.append(video)
        let sorted = values.sorted { $0.createdAt > $1.createdAt }
        write(sorted)
        return Self.visible(sorted)
    }

    /// 从聊天历史回填老视频。只认 assistant 消息的 `videoPath`；
    /// `videoSourcePath` 是用户给的首帧图，不属于生成结果。
    @discardableResult
    func merge(threads: [ChatThread]) -> [GalleryVideo] {
        var values = Self.read(fileURL)
        var known = Set(values.map(\.path))
        var added = false
        for thread in threads {
            for (index, message) in thread.messages.enumerated() {
                guard message.role == "assistant",
                      let path = message.videoPath, !path.isEmpty,
                      !known.contains(path),
                      FileManager.default.fileExists(atPath: path)
                else { continue }
                let prompt = thread.messages[..<index]
                    .last(where: { $0.role == "user" })?.content ?? ""
                values.append(GalleryVideo(path: path,
                                           prompt: prompt,
                                           model: message.model ?? "",
                                           createdAt: message.createdAt ?? thread.updatedAt,
                                           note: message.videoNote,
                                           seed: Self.seed(in: message.videoNote)))
                known.insert(path)
                added = true
            }
        }
        let sorted = values.sorted { $0.createdAt > $1.createdAt }
        if added { write(sorted) }
        return Self.visible(sorted)
    }

    /// 视频的 seed 只存在于落盘那行说明里（`… · seed 42`）。
    /// 新生成的会直接带 seed 登记；这里兜住从历史回填的旧视频。
    static func seed(in note: String?) -> Int? {
        guard let note else { return nil }
        for part in note.split(separator: "·") {
            let text = part.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("seed ") else { continue }
            return Int(text.dropFirst(5))
        }
        return nil
    }

    /// 只用于展示：文件不在的条目跳过。索引本身原样保留。
    private static func visible(_ values: [GalleryVideo]) -> [GalleryVideo] {
        values.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func read(_ url: URL) -> [GalleryVideo] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredVideo].self, from: data)
        else { return [] }
        return stored.map { item in
            GalleryVideo(path: item.path,
                         prompt: item.prompt,
                         model: item.model,
                         createdAt: Date(timeIntervalSince1970: item.createdAt),
                         note: item.note,
                         seed: item.seed)
        }
    }

    private func write(_ values: [GalleryVideo]) {
        Paths.ensureDirectory(fileURL.deletingLastPathComponent().path)
        let stored = values.map { item in
            StoredVideo(path: item.path,
                        prompt: item.prompt,
                        model: item.model,
                        createdAt: item.createdAt.timeIntervalSince1970,
                        note: item.note,
                        seed: item.seed)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 视频卡片的封面：取第一帧并缩到目标像素，按路径缓存。
/// AVAssetImageGenerator 每次都重新解封装，滚动列表时不能每帧都调。
enum VideoThumbnailStore {
    /// `NSCache` 自身是线程安全的（文档明确保证可在多线程下增删查），
    /// 所以这里不需要额外加锁；`nonisolated(unsafe)` 只是告诉编译器这个
    /// `static let` 的底层语义由 `NSCache` 自己保证。
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // 封面是 640 px 的 16:9，一张不到 1 MB；上限按张数给足几屏，别让滚动
        // 回头时反复重解。和图片缩略图缓存保持同一个数量级。
        cache.countLimit = 120
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func thumbnail(atPath path: String, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // 封面不需要精确到第 0 帧，给足容差可以少解码一段。
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let image: NSImage? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(
                forTimes: [NSValue(time: CMTime(value: 0, timescale: 600))]) { _, cgImage, _, result, _ in
                guard result == .succeeded, let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage,
                                                      size: NSSize(width: cgImage.width,
                                                                   height: cgImage.height)))
            }
        }
        if let image {
            let cost = max(1, Int(image.size.width * image.size.height)) * 4
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }
}
