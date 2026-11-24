// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 概览「接口」卡的自检请求：按 OpenAI 方言发一条最小聊天，把状态、耗时与
/// 真实响应正文带回界面。
///
/// 传输逻辑放在 Core 而不是视图里：它要能被测试单独调用，视图只负责按钮与弹层。
package enum GatewaySelfTest {
    package static func send(baseURL: String, model: String) async -> GatewayTestResult {
        guard let url = URL(string: baseURL + "/chat/completions") else {
            return GatewayTestResult(ok: false, status: 0, reply: "无效的接口地址", milliseconds: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("flashCat-test", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "max_tokens": 64,
            "messages": [["role": "user", "content": L10n.t("只回复两个字：你好")]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = GatewayTestResponse.parse(data: data, status: status)
            return GatewayTestResult(
                ok: parsed.ok, status: status, reply: parsed.reply, milliseconds: 0)
        } catch {
            return GatewayTestResult(
                ok: false, status: 0,
                reply: error.localizedDescription, milliseconds: 0)
        }
    }
}

package struct GatewayTestResult {
    package let ok: Bool
    package let status: Int
    package let reply: String
    package let milliseconds: Int

    package func withMilliseconds(_ value: Int) -> GatewayTestResult {
        GatewayTestResult(ok: ok, status: status, reply: reply, milliseconds: value)
    }
}

/// 只解析测试请求关心的两种形状：正常 `choices[0].message.content`，
/// 以及网关 / 引擎返回的错误正文。其它情况原样给出文本，不吞掉证据。
package enum GatewayTestResponse {
    package static func parse(data: Data, status: Int) -> (ok: Bool, reply: String) {
        let ok = (200..<300).contains(status)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let choices = object["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any]
            {
                let content =
                    (message["content"] as? String)
                    ?? (message["reasoning_content"] as? String)
                    ?? ""
                if !content.isEmpty {
                    return (ok && status < 300, content)
                }
            }
            if let error = object["error"] as? [String: Any],
                let message = error["message"] as? String
            {
                return (false, message)
            }
            if let error = object["error"] as? String {
                return (false, error)
            }
            if let message = object["message"] as? String {
                return (ok, message)
            }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return (ok, text.isEmpty ? "—" : text)
    }
}
