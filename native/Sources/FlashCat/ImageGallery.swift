import Foundation

/// 图库里的一张作品：模型在对话中生成、已经落盘的图片。
///
/// 用户发给模型的底图也会被 `ImageStore.importImage` 拷贝进 `support/images`，
/// 但它们挂在 user 消息的 `imagePath` 上；这里只登记 assistant 消息的结果，
/// 所以图库天然不含用户附件。
struct GalleryImage: Identifiable, Equatable {
    let path: String
    let prompt: String
    let model: String
    let createdAt: Date
    let note: String?
    let seed: Int?

    var id: String { path }
}

/// 生成图片的索引。索引和聊天历史分开存：历史只保留最近六段对话，
/// 图库不该跟着一起淘汰；删掉一段对话也不该把已经保存的作品抹掉
/// （`ImageStore` 的注释里也是这个约定）。
///
/// 1.5.6 之前生成的图没有索引记录，第一次打开图库时会从当前聊天历史回填；
/// 只认 assistant 消息，用户底图不会被误收进来。
/// 索引本身只存在磁盘文件里，实例上只有一个不变的路径，没有可变的引用
/// 状态，所以可以安全地跨隔离域共享。同一个文件的并发写入仍是后写者覆盖
/// 先写者（加 `Sendable` 之前也是这样），应用里的登记与合并都在主线程。
final class ImageGalleryStore: Sendable {
    static let shared = ImageGalleryStore()

    private struct StoredImage: Codable {
        let path: String
        let prompt: String
        let model: String
        let createdAt: Double
        let note: String?
        let seed: Int?
    }

    private let fileURL: URL

    /// 测试可以指向临时目录；应用里用支持目录下的固定文件。
    init(fileURL: URL = URL(fileURLWithPath: Paths.supportDirectory + "/image-gallery.json")) {
        self.fileURL = fileURL
    }

    /// 新图在前。指向已删除文件的条目先跳过：用户可能只是把文件挪走了，
    /// 索引留着，放回来还能重新出现。
    func images() -> [GalleryImage] {
        Self.visible(Self.read(fileURL))
    }

    /// 生成成功后登记一张图。同一路径重复登记时覆盖，重试不会留下两条。
    /// 写回必须以磁盘上的原始索引为底：`images()` 会滤掉暂时找不到文件的
    /// 条目，拿它当底再写回，等于把「文件挪走了」记成「用户删了」。
    @discardableResult
    func record(_ image: GalleryImage) -> [GalleryImage] {
        var values = Self.read(fileURL).filter { $0.path != image.path }
        values.append(image)
        let sorted = values.sorted { $0.createdAt > $1.createdAt }
        write(sorted)
        return Self.visible(sorted)
    }

    /// 从聊天历史补登老作品。只看 assistant 消息：user 消息上的 `imagePath`
    /// 是发给模型的底图，不是生成结果。
    @discardableResult
    func merge(threads: [ChatThread]) -> [GalleryImage] {
        var values = Self.read(fileURL)
        var known = Set(values.map(\.path))
        var added = false
        for thread in threads {
            for (index, message) in thread.messages.enumerated() {
                guard message.role == "assistant",
                      let path = message.imagePath, !path.isEmpty,
                      !known.contains(path),
                      FileManager.default.fileExists(atPath: path)
                else { continue }
                let prompt = thread.messages[..<index]
                    .last(where: { $0.role == "user" })?.content ?? ""
                values.append(GalleryImage(path: path,
                                           prompt: prompt,
                                           model: message.model ?? "",
                                           createdAt: message.createdAt ?? thread.updatedAt,
                                           note: message.imageNote,
                                           seed: message.imageSeed))
                known.insert(path)
                added = true
            }
        }
        guard added else { return Self.visible(values) }
        let sorted = values.sorted { $0.createdAt > $1.createdAt }
        write(sorted)
        return Self.visible(sorted)
    }

    /// 只用于展示：文件不在的条目跳过。索引本身由 `read`/`write` 原样保留。
    private static func visible(_ values: [GalleryImage]) -> [GalleryImage] {
        values.filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private static func read(_ url: URL) -> [GalleryImage] {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredImage].self, from: data)
        else { return [] }
        return stored.map { item in
            GalleryImage(path: item.path,
                         prompt: item.prompt,
                         model: item.model,
                         createdAt: Date(timeIntervalSince1970: item.createdAt),
                         note: item.note,
                         seed: item.seed)
        }
    }

    private func write(_ values: [GalleryImage]) {
        let directory = fileURL.deletingLastPathComponent().path
        Paths.ensureDirectory(directory)
        let stored = values.map { item in
            StoredImage(path: item.path,
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
