import XCTest
@testable import FlashCat

/// 视频索引和图片索引同构，但更容易出错的点有两个：
/// 首帧图会被写进 user 消息，不能算作品；seed 只存在说明行里，要从 `·` 分隔的参数里读回来。
final class VideoGalleryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-gallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]).write(to: url)
        return url.path
    }

    private func makeStore() -> VideoGalleryStore {
        VideoGalleryStore(fileURL: root.appendingPathComponent("video-gallery.json"))
    }

    func testMergeKeepsOnlyAssistantVideos() throws {
        let sourceFrame = try makeFile("source.png")
        let generated = try makeFile("generated.mp4")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let note = "768×512 · 49 帧 · 24fps · 8 步 · seed 42"
        let thread = ChatThread(
            id: "thread-1",
            title: "视频测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "让这张图动起来", model: "wan2.2",
                            createdAt: now, imagePath: sourceFrame),
                ChatMessage(role: "assistant", content: "", model: "wan2.2",
                            createdAt: now, videoPath: generated, videoNote: note),
            ])

        let videos = makeStore().merge(threads: [thread])

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.path, generated)
        XCTAssertEqual(videos.first?.prompt, "让这张图动起来")
        XCTAssertEqual(videos.first?.model, "wan2.2")
        XCTAssertEqual(videos.first?.note, note)
        XCTAssertEqual(videos.first?.seed, 42, "seed 要从落盘说明里解析出来")
        XCTAssertFalse(videos.contains { $0.path == sourceFrame },
                       "用户给的首帧图不是作品，不能进视频库")
    }

    func testSeedParsing() {
        XCTAssertEqual(VideoGalleryStore.seed(in: "768×512 · 49 帧 · 24fps · 8 步 · seed 7"), 7)
        XCTAssertEqual(VideoGalleryStore.seed(in: "seed 128"), 128)
        XCTAssertNil(VideoGalleryStore.seed(in: "768×512 · 49 帧"))
        XCTAssertNil(VideoGalleryStore.seed(in: "seed abc"))
        XCTAssertNil(VideoGalleryStore.seed(in: nil))
    }

    func testMergeIsIdempotentAndPersistsAcrossReload() throws {
        let generated = try makeFile("generated.mp4")
        let now = Date()
        let thread = ChatThread(
            id: "thread-1",
            title: "视频测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "一只猫在跑", model: "wan2.2", createdAt: now),
                ChatMessage(role: "assistant", content: "", model: "wan2.2",
                            createdAt: now, videoPath: generated,
                            videoNote: "512×384 · 49 帧 · 16fps · 8 步 · seed 9"),
            ])

        let first = makeStore().merge(threads: [thread])
        XCTAssertEqual(first.count, 1)

        let second = makeStore().merge(threads: [thread])
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.path, generated)
        XCTAssertEqual(second.first?.seed, 9)
    }

    func testDeletedFilesAreSkippedUntilTheyComeBack() throws {
        let generated = try makeFile("generated.mp4")
        let video = GalleryVideo(path: generated, prompt: "一只猫", model: "wan2.2",
                                 createdAt: Date(), note: nil, seed: 3)
        let store = makeStore()
        XCTAssertEqual(store.record(video).count, 1)

        try FileManager.default.removeItem(atPath: generated)
        XCTAssertTrue(store.videos().isEmpty, "文件被删后不能留一条点不开的作品")

        try Data([0x00, 0x00]).write(to: URL(fileURLWithPath: generated))
        XCTAssertEqual(store.videos().count, 1, "文件放回来时索引仍然认得它")
    }

    func testRecordReplacesTheSamePath() throws {
        let generated = try makeFile("generated.mp4")
        let store = makeStore()
        let now = Date()
        store.record(GalleryVideo(path: generated, prompt: "旧提示词", model: "a",
                                  createdAt: now, note: nil, seed: 1))
        let videos = store.record(GalleryVideo(path: generated, prompt: "新提示词", model: "b",
                                               createdAt: now.addingTimeInterval(1),
                                               note: "512×384", seed: 2))

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos.first?.prompt, "新提示词")
        XCTAssertEqual(videos.first?.seed, 2)
    }

    func testMergeSkipsVideosWhoseFileIsGone() throws {
        let now = Date()
        let thread = ChatThread(
            id: "thread-1",
            title: "视频测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "一只猫", model: "wan2.2", createdAt: now),
                ChatMessage(role: "assistant", content: "", model: "wan2.2",
                            createdAt: now,
                            videoPath: root.appendingPathComponent("missing.mp4").path),
            ])

        XCTAssertTrue(makeStore().merge(threads: [thread]).isEmpty,
                      "历史里指向已删除文件的条目不能变成点不开的卡片")
    }

    /// 同图片库：回填时不能把「文件暂时不在」的条目从索引里删掉。
    func testMergeKeepsEntriesWhoseFileIsTemporarilyGone() throws {
        let vanished = try makeFile("vanished.mp4")
        let generated = try makeFile("generated.mp4")
        let now = Date()
        let store = makeStore()
        store.record(GalleryVideo(path: vanished, prompt: "旧片", model: "a",
                                  createdAt: now, note: nil, seed: nil))
        try FileManager.default.removeItem(atPath: vanished)

        let thread = ChatThread(
            id: "thread-1",
            title: "视频测试",
            updatedAt: now,
            messages: [
                ChatMessage(role: "user", content: "新片", model: "a",
                            createdAt: now.addingTimeInterval(1)),
                ChatMessage(role: "assistant", content: "", model: "a",
                            createdAt: now.addingTimeInterval(1), videoPath: generated),
            ])
        let merged = store.merge(threads: [thread])
        XCTAssertEqual(merged.map(\.path), [generated], "文件不在的旧条目先不展示")

        _ = try makeFile("vanished.mp4")
        XCTAssertEqual(Set(store.videos().map(\.path)), [vanished, generated])
    }
}
