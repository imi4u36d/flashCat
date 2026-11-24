// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI
import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 输入卡右下角的模型 / 思考切换。
///
/// 这里守的是可见性：模型切换对所有模型都在，思考等级只跟纯对话模型走。
/// 图像 / 视频模型要是把整枚控件一起带走，对话页就再也切不回文本模型了。
final class ChatComposerControlsTests: XCTestCase {
    private func model(_ capabilities: [String]) -> EngineModel {
        EngineModel(id: "test/model", capabilities: capabilities, engine: .splash)
    }

    func testThinkingLevelShowsForChatAndVisionModels() {
        XCTAssertTrue(ChatComposerControls.showsThinkingLevel(for: model(["chat"])))
        // 视觉是「图进文出」的对话模型，推理等级照样有效。
        XCTAssertTrue(ChatComposerControls.showsThinkingLevel(for: model(["chat", "vision"])))
        // 引擎没报能力时按对话模型处理。
        XCTAssertTrue(ChatComposerControls.showsThinkingLevel(for: model([])))
    }

    func testThinkingLevelHidesForImageAndVideoModels() {
        XCTAssertFalse(ChatComposerControls.showsThinkingLevel(for: model(["image"])))
        XCTAssertFalse(ChatComposerControls.showsThinkingLevel(for: model(["video"])))
        XCTAssertFalse(ChatComposerControls.showsThinkingLevel(for: model(["image", "video"])))
    }

    func testThinkingLevelShowsBeforeAModelIsPicked() {
        // 还没选模型 / 选中的模型不在引擎列表里时按文本模型处理，别把控件藏起来。
        XCTAssertTrue(ChatComposerControls.showsThinkingLevel(for: nil))
    }

    func testThinkingLevelBadgeTextMatchesModeAndEffort() {
        XCTAssertEqual(ChatThinkingLevel.text(mode: .automatic, effort: .high), "自动")
        XCTAssertEqual(ChatThinkingLevel.text(mode: .off, effort: .low), "关闭")
        XCTAssertEqual(ChatThinkingLevel.text(mode: .on, effort: .low), "Low")
        XCTAssertEqual(ChatThinkingLevel.text(mode: .on, effort: .medium), "Medium")
        XCTAssertEqual(ChatThinkingLevel.text(mode: .on, effort: .high), "High")
        XCTAssertEqual(ChatThinkingLevel.text(mode: .on, effort: .xhigh), "XHigh")
    }

    @MainActor
    func testModelPickerPopoverReportsIntrinsicHeightForPopoverSizing() {
        let host = NSHostingController(rootView: ModelPickerPopover(state: AppState.shared) {})
        let size = host.view.fittingSize
        XCTAssertEqual(size.width, 300, accuracy: 1)
        XCTAssertGreaterThanOrEqual(size.height, 44)
        XCTAssertLessThanOrEqual(size.height, 380)
    }
}
