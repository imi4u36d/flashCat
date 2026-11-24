// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat
@testable import FlashCatCore

/// 对话列宽度的换算。
///
/// 这里守的是「拖动到底改了什么」：列、气泡、输入卡三条宽度必须一起动，默认
/// 宽度必须还是 Splash 版式那三个数（744 列 / 592 气泡 / 680 输入卡），落盘的
/// 宽度只夹不改——窗口缩小再放大，用户拖出来的宽度要能回来。
final class ChatColumnTests: XCTestCase {
    func testDefaultWidthReproducesTheSplashLayout() {
        // 不拖的时候版式不能有任何变化：744 列 / 592 气泡 / 680 输入卡。
        let width = ChatColumn.width(stored: ChatColumn.defaultWidth, pageWidth: 1360)
        XCTAssertEqual(width, 744)
        XCTAssertEqual(ChatColumn.bubbleWidth(column: width), 592)
        XCTAssertEqual(ChatColumn.composerWidth(column: width), 680)
        XCTAssertEqual(ChatColumn.contentWidth(column: width), 680)
    }

    func testStoredWidthBelowDefaultClampsToDefault() {
        // 默认值就是下限：手改 UserDefaults 或者旧版本留下的更窄值都要抬回来。
        XCTAssertEqual(ChatColumn.width(stored: 400, pageWidth: 1360), 744)
        XCTAssertEqual(ChatColumn.width(stored: -120, pageWidth: 1360), 744)
    }

    func testMaximumIsPageWidthMinusTheComposerMargin() {
        XCTAssertEqual(ChatColumn.maximum(pageWidth: 1360), 1320)
        // 窗口比默认列宽还窄时不再放宽，否则列会溢出页面。
        XCTAssertEqual(ChatColumn.maximum(pageWidth: 900), 860)
        XCTAssertEqual(ChatColumn.maximum(pageWidth: 700), 744)
        // 页面还没量出宽度（首帧 0）时给默认值，别夹成 0 宽的列。
        XCTAssertEqual(ChatColumn.maximum(pageWidth: 0), 744)
        // 推到最宽时输入卡正好用满页面让出的那 80pt，再去掉左右 32pt 内边距：
        // 1360 − 40 列 − 40 = 1280 的外层，内容 1256。
        XCTAssertEqual(ChatColumn.composerWidth(column: ChatColumn.maximum(pageWidth: 1360)), 1256)
    }

    func testClampingNeverRewritesTheStoredWidth() {
        // 窗口缩小时列跟着收窄，但落盘值不动；窗口放大回来宽度要能恢复。
        XCTAssertEqual(ChatColumn.width(stored: 1400, pageWidth: 1200), 1160)
        XCTAssertEqual(ChatColumn.width(stored: 1400, pageWidth: 2000), 1400)
    }

    func testBubblesAndComposerFollowTheColumn() {
        // 只放开外层的话，拖宽只会把消息之间推开，回答还是原来那么窄。
        XCTAssertEqual(ChatColumn.bubbleWidth(column: 1000), 848)
        XCTAssertEqual(ChatColumn.composerWidth(column: 1000), 936)
        let samples = stride(from: 744.0, through: 1200.0, by: 20.0)
        for column in samples {
            XCTAssertGreaterThan(ChatColumn.bubbleWidth(column: column), 0)
            XCTAssertLessThan(ChatColumn.bubbleWidth(column: column), column)
        }
    }

    func testInvalidStoredValuesFallBackToDefault() {
        XCTAssertEqual(ChatColumn.width(stored: .nan, pageWidth: 1360), 744)
        XCTAssertEqual(ChatColumn.width(stored: .infinity, pageWidth: 1360), 744)
    }
}
