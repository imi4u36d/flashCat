import AppKit
import XCTest
import FlashCatKit
@testable import FlashCat

/// 成品图回传给视觉模型时必须是引擎能吃的 data URL。
/// 本机引擎对 PNG 的兼容性并不一致（mlx-serve 会拒掉一些 PNG），
/// 所以这里守住「统一转成 JPEG」这条线，别让回传路径悄悄换回 PNG。
final class ImageStoreEncodingTests: XCTestCase {
    private func makePNG() throws -> Data {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(red: 0.86, green: 0.12, blue: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testChatImageURLIsAJpegDataURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flashcat-image-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("frame.png").path
        try makePNG().write(to: URL(fileURLWithPath: path))

        let url = try XCTUnwrap(ImageStore.chatImageURL(atPath: path))
        let prefix = "data:image/jpeg;base64,"
        XCTAssertTrue(url.hasPrefix(prefix))
        let payload = try XCTUnwrap(Data(base64Encoded: String(url.dropFirst(prefix.count))))
        XCTAssertEqual(Array(payload.prefix(2)), [0xFF, 0xD8], "回传的应当是 JPEG，而不是原始 PNG")
        XCTAssertGreaterThan(payload.count, 100)
    }

    func testChatImageURLReturnsNilForMissingFile() {
        XCTAssertNil(ImageStore.chatImageURL(atPath: "/tmp/flashcat-not-a-real-image.png"))
    }
}
