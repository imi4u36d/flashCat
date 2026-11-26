// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import XCTest

@testable import FlashCat

/// 截图粘贴的可达性。
///
/// AppKit 只按 `NSTextView` 能读的文本类型校验「粘贴」：剪贴板里只有
/// `public.png` / `public.tiff` 时，菜单项会被判成不可用，⌘V 的按键等价物
/// 因此不会派发到 `paste(_:)`。微信 / QQ 截图正好是这种形态，表现就是
/// 「⌘V 完全没反应」。这里守住输入框把附件分支也算进可粘贴的覆盖。
final class ChatComposerPasteTests: XCTestCase {
    /// 剪贴板是全局资源：每条用例前存一份，结束后原样写回。
    private var snapshot: [[NSPasteboard.PasteboardType: Data]] = []

    override func setUp() {
        super.setUp()
        snapshot = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let value = item.data(forType: type) { data[type] = value }
            }
            return data
        }
    }

    override func tearDown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(
            snapshot.map { stored in
                let item = NSPasteboardItem()
                for (type, data) in stored { item.setData(data, forType: type) }
                return item
            })
        super.tearDown()
    }

    private func pngData() -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 8,
                pixelsHigh: 8,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0),
            let png = rep.representation(using: .png, properties: [:])
        else {
            XCTFail("造不出一张测试位图")
            return Data()
        }
        return png
    }

    private func pasteMenuItem() -> NSMenuItem {
        NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    }

    private func composer(
        onPasteImage: ((NSImage) -> Bool)? = nil,
        onPasteFiles: (([URL]) -> Bool)? = nil
    ) -> ComposerTextView {
        let view = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        view.onPasteImage = onPasteImage
        view.onPasteFiles = onPasteFiles
        return view
    }

    @MainActor
    func testImageOnlyClipboardCountsAsPasteable() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)

        let view = composer(onPasteImage: { _ in true })
        XCTAssertTrue(view.validateUserInterfaceItem(pasteMenuItem()))
    }

    @MainActor
    func testImageWithoutHandlerStaysUnpasteable() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)

        // 没人接手时不要谎报可粘贴：否则 ⌘V 会落到 NSTextView 的原生粘贴上，
        // 在纯文本输入框里什么都插不进来，反而更像「坏掉」。
        XCTAssertFalse(composer().validateUserInterfaceItem(pasteMenuItem()))
    }

    @MainActor
    func testPlainTextClipboardStaysPasteable() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("普通文本", forType: .string)

        XCTAssertTrue(composer(onPasteImage: { _ in true }).validateUserInterfaceItem(pasteMenuItem()))
    }

    @MainActor
    func testFileURLClipboardCountsAsPasteable() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("file:///tmp/flashcat-shot.png", forType: .fileURL)

        let view = composer(onPasteFiles: { _ in true })
        XCTAssertTrue(view.validateUserInterfaceItem(pasteMenuItem()))
    }
}
