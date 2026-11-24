// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest

@testable import FlashCat

/// 概览页「API 网关」下拉里的调用片段：地址、模型与方言头都要和设置一致，
/// 否则用户照抄下来只会得到一条连不上的命令。
final class GatewaySnippetsTests: XCTestCase {
    private let snippets = GatewaySnippets(
        openAIBase: "http://127.0.0.1:9000/v1",
        claudeBase: "http://127.0.0.1:9000",
        model: "Qwen/Qwen3.8-27B")

    func testOpenAISnippetsUseConfiguredBaseAndModel() {
        XCTAssertTrue(snippets.openAICurl.contains("http://127.0.0.1:9000/v1/chat/completions"))
        XCTAssertTrue(snippets.openAICurl.contains("\"model\":\"Qwen/Qwen3.8-27B\""))
        XCTAssertTrue(snippets.openAIPython.contains("base_url=\"http://127.0.0.1:9000/v1\""))
        XCTAssertTrue(snippets.openAIPython.contains("model=\"Qwen/Qwen3.8-27B\""))
    }

    func testClaudeSnippetsCarryAnthropicHeadersAndRootBase() {
        XCTAssertTrue(snippets.claudeCurl.contains("http://127.0.0.1:9000/v1/messages"))
        XCTAssertTrue(snippets.claudeCurl.contains("x-api-key: local"))
        XCTAssertTrue(snippets.claudeCurl.contains("anthropic-version: 2023-06-01"))
        XCTAssertTrue(snippets.claudePython.contains("base_url=\"http://127.0.0.1:9000\""))
        XCTAssertTrue(snippets.claudePython.contains("messages.create"))
    }

    /// 没有选模型时片段仍然是可复制的完整命令，而不是一个空字符串。
    func testMissingModelFallsBackToPlaceholder() {
        let empty = GatewaySnippets(openAIBase: "b", claudeBase: "c", model: "  ")
        XCTAssertTrue(empty.openAICurl.contains("<模型 ID>"))
        XCTAssertTrue(empty.claudeCurl.contains("<模型 ID>"))
        XCTAssertTrue(empty.openAIPython.contains("<模型 ID>"))
    }
}
