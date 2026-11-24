// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 概览页「API 网关」两枚下拉里给出的调用片段。
///
/// 单独成类型而不是散在 View 里，是因为片段本身有可验证的契约：Base URL
/// 要来自设置里的真实端口、模型 ID 要跟着当前选择走、Claude 片段必须带
/// `x-api-key` 与 `anthropic-version`。这些都能在没有窗口的测试里钉住。
package struct GatewaySnippets {
    package let openAIBase: String
    package let claudeBase: String
    package let model: String

    package init(openAIBase: String, claudeBase: String, model: String) {
        self.openAIBase = openAIBase
        self.claudeBase = claudeBase
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? "<模型 ID>" : trimmed
    }

    /// OpenAI 方言：`base_url` 已经带 `/v1`，SDK 自己接 `/chat/completions`。
    package var openAICurl: String {
        """
        curl -s \(openAIBase)/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{"model":"\(model)","messages":[{"role":"user","content":"你好"}]}'
        """
    }

    package var openAIPython: String {
        """
        from openai import OpenAI

        client = OpenAI(base_url="\(openAIBase)", api_key="local")
        reply = client.chat.completions.create(
            model="\(model)",
            messages=[{"role": "user", "content": "你好"}],
        )
        print(reply.choices[0].message.content)
        """
    }

    /// Anthropic 方言：SDK 自己追加 `/v1/messages`，所以 `base_url` 到根为止。
    package var claudeCurl: String {
        """
        curl -s \(claudeBase)/v1/messages \\
          -H "Content-Type: application/json" \\
          -H "x-api-key: local" \\
          -H "anthropic-version: 2023-06-01" \\
          -d '{"model":"\(model)","max_tokens":1024,"messages":[{"role":"user","content":"你好"}]}'
        """
    }

    package var claudePython: String {
        """
        from anthropic import Anthropic

        client = Anthropic(base_url="\(claudeBase)", api_key="local")
        reply = client.messages.create(
            model="\(model)",
            max_tokens=1024,
            messages=[{"role": "user", "content": "你好"}],
        )
        print(reply.content[0].text)
        """
    }
}
