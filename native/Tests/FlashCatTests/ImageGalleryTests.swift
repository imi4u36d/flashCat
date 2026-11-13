import XCTest
@testable import FlashCat

/// 图库索引最容易出错的地方：把用户底图当成作品、重复补登、以及文件被删后
/// 还拿一条死路径去画缩略图。三类都用临时目录里的假 PNG 覆盖。
final class ImageGalleryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url.path
    }

    private func makeStore() -> ImageGalleryStore {
        ImageGalleryStore(fileURL: root.appendingPathComponent("image-gallery.json"))
    }

    func testMergeKeepsOnlyAssistantImages() throws {
        let userImage = try makeFile("user-source.png")
        let generated = try makeFile("generated.png")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = ChatThread(
            id: "thread-1",
            title: "图库测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "把这张改成夜景", model: "qwen-image",
                            createdAt: now, imagePath: userImage),
                ChatMessage(role: "assistant", content: "", model: "qwen-image",
                            createdAt: now, imagePath: generated,
                            imageNote: "1024×1024 · 8 步", imageSeed: 42),
            ])

        let images = makeStore().merge(threads: [thread])

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.path, generated)
        XCTAssertEqual(images.first?.prompt, "把这张改成夜景")
        XCTAssertEqual(images.first?.model, "qwen-image")
        XCTAssertEqual(images.first?.note, "1024×1024 · 8 步")
        XCTAssertEqual(images.first?.seed, 42)
        XCTAssertFalse(images.contains { $0.path == userImage },
                       "用户发给模型的底图不是作品，不能进图库")
    }

    func testMergeIsIdempotentAndPersistsAcrossReload() throws {
        let generated = try makeFile("generated.png")
        let now = Date()
        let thread = ChatThread(
            id: "thread-1",
            title: "图库测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "一只猫", model: "qwen-image", createdAt: now),
                ChatMessage(role: "assistant", content: "", model: "qwen-image",
                            createdAt: now, imagePath: generated, imageSeed: 7),
            ])

        let first = makeStore().merge(threads: [thread])
        XCTAssertEqual(first.count, 1)

        // 每打开一次图库都会重新 merge；同一条历史不能长出第二张。
        let second = makeStore().merge(threads: [thread])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.path, generated)
        XCTAssertEqual(second.first?.seed, 7)
    }

    func testDeletedFilesAreSkippedUntilTheyComeBack() throws {
        let generated = try makeFile("generated.png")
        let now = Date()
        let image = GalleryImage(path: generated, prompt: "一只猫", model: "qwen-image",
                                 createdAt: now, note: nil, seed: 9)
        let store = makeStore()
        XCTAssertEqual(store.record(image).count, 1)

        try FileManager.default.removeItem(atPath: generated)
        XCTAssertTrue(store.images().isEmpty, "文件被删后不能留一条点不开的作品")

        try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: generated))
        XCTAssertEqual(store.images().count, 1, "文件放回来时索引仍然认得它")
    }

    func testRecordReplacesTheSamePath() throws {
        let generated = try makeFile("generated.png")
        let store = makeStore()
        let now = Date()
        store.record(GalleryImage(path: generated, prompt: "旧提示词", model: "a",
                                  createdAt: now, note: nil, seed: 1))
        let images = store.record(GalleryImage(path: generated, prompt: "新提示词", model: "b",
                                               createdAt: now.addingTimeInterval(1),
                                               note: "1024×1024", seed: 2))

        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.prompt, "新提示词")
        XCTAssertEqual(images.first?.seed, 2)
    }

    func testMergeSkipsImagesWhoseFileIsGone() throws {
        let now = Date()
        let thread = ChatThread(
            id: "thread-1",
            title: "图库测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "一只猫", model: "qwen-image", createdAt: now),
                ChatMessage(role: "assistant", content: "", model: "qwen-image",
                            createdAt: now, imagePath: root.appendingPathComponent("missing.png").path),
            ])

        XCTAssertTrue(makeStore().merge(threads: [thread]).isEmpty,
                      "历史里指向已删除文件的条目不能变成点不开的卡片")
    }

    /// 「文件暂时不在」不等于「用户删了」：登记或回填时重写索引，不能把
    /// 指向外置盘/已卸载位置的条目一起抹掉，文件放回来还得能看见。
    func testMergeKeepsEntriesWhoseFileIsTemporarilyGone() throws {
        let vanished = try makeFile("vanished.png")
        let generated = try makeFile("generated.png")
        let now = Date()
        let store = makeStore()
        store.record(GalleryImage(path: vanished, prompt: "旧图", model: "a",
                                  createdAt: now, note: nil, seed: nil))
        try FileManager.default.removeItem(atPath: vanished)

        let thread = ChatThread(
            id: "thread-1",
            title: "图库测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "新图", model: "a",
                            createdAt: now.addingTimeInterval(1)),
                ChatMessage(role: "assistant", content: "", model: "a",
                            createdAt: now.addingTimeInterval(1), imagePath: generated),
            ])
        let merged = store.merge(threads: [thread])
        XCTAssertEqual(merged.map(\.path), [generated], "文件不在的旧条目先不展示")

        // 恢复文件之后旧条目要回来，说明索引并没有被抹掉。
        _ = try makeFile("vanished.png")
        XCTAssertEqual(Set(store.images().map(\.path)), [vanished, generated])
    }
}
