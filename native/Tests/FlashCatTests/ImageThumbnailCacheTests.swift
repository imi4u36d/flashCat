import XCTest
@testable import FlashCat

/// 缩略图缓存是实验室页面掉帧那一处的边界：解码必须落在后台队列、同一张图只
/// 解一次、缓存要能命中第二次。视图本身没法在测试里断言，这层可以。
final class ImageThumbnailCacheTests: XCTestCase {
    private var directory = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = NSTemporaryDirectory() + "flashcat-thumbnails-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
        try super.tearDownWithError()
    }

    func testAsyncThumbnailCapsTheLongestSide() async throws {
        let path = try writePNG(width: 1200, height: 800)

        let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: 240)
        let image = try XCTUnwrap(loaded)

        // 1200×800 缩到最长边 240，宽高比不变。
        XCTAssertEqual(image.size.width, 240, accuracy: 1)
        XCTAssertEqual(image.size.height, 160, accuracy: 1)
    }

    func testCachedThumbnailStaysNilUntilDecoded() async throws {
        let path = try writePNG(width: 400, height: 400)

        XCTAssertNil(ImageStore.cachedThumbnail(atPath: path, maxPixel: 200),
                     "没解过的图不该出现在缓存里")
        let loaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: 200)
        _ = try XCTUnwrap(loaded)
        XCTAssertNotNil(ImageStore.cachedThumbnail(atPath: path, maxPixel: 200),
                        "解完之后再问缓存必须能命中")
    }

    func testSecondRequestReusesTheDecodedImage() async throws {
        let path = try writePNG(width: 600, height: 600)

        let firstLoaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: 300)
        let secondLoaded = await ImageStore.thumbnailAsync(atPath: path, maxPixel: 300)
        let first = try XCTUnwrap(firstLoaded)
        let second = try XCTUnwrap(secondLoaded)

        XCTAssertTrue(first === second, "同一张图第二次请求应该直接拿缓存对象")
    }

    func testConcurrentRequestsShareOneDecode() async throws {
        let path = try writePNG(width: 1600, height: 1200)

        // 拿 ObjectIdentifier 而不是 NSImage 回来：跨任务传图画对象只会换来
        // Sendable 警告，这里要断言的本来就是「是不是同一个对象」。
        let identifiers = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await ImageStore.thumbnailAsync(atPath: path, maxPixel: 300)
                        .map(ObjectIdentifier.init)
                }
            }
            var collected: [ObjectIdentifier?] = []
            for await identifier in group { collected.append(identifier) }
            return collected
        }

        XCTAssertEqual(identifiers.count, 8)
        let first = try XCTUnwrap(identifiers.first ?? nil)
        for identifier in identifiers {
            XCTAssertEqual(identifier, first, "并发请求应该挂在同一次解码上")
        }
    }

    func testMissingFileReturnsNil() async {
        let path = directory + "/does-not-exist.png"

        let image = await ImageStore.thumbnailAsync(atPath: path, maxPixel: 300)

        XCTAssertNil(image)
        XCTAssertNil(ImageStore.cachedThumbnail(atPath: path, maxPixel: 300))
    }

    /// 同步接口还留着给本来就在后台的位置用（比如导出），别让它跟着一起坏掉。
    func testSyncThumbnailStillWorks() throws {
        let path = try writePNG(width: 500, height: 300)

        let image = try XCTUnwrap(ImageStore.thumbnail(atPath: path, maxPixel: 200))

        XCTAssertEqual(image.size.width, 200, accuracy: 1)
        XCTAssertEqual(image.size.height, 120, accuracy: 1)
    }

    // MARK: - 测试数据

    /// 写一张纯色 PNG：真实解码走的是同一条 ImageIO 路径，但不用把大图塞进仓库。
    private func writePNG(width: Int, height: Int) throws -> String {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                                                 pixelsWide: width,
                                                 pixelsHigh: height,
                                                 bitsPerSample: 8,
                                                 samplesPerPixel: 4,
                                                 hasAlpha: true,
                                                 isPlanar: false,
                                                 colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0,
                                                 bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let path = directory + "/\(UUID().uuidString)-\(width)x\(height).png"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}
