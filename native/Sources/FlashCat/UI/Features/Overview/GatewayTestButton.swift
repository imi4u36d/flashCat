// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Foundation
import SwiftUI

/// 概览「接口」卡上的自检按钮：按 OpenAI 方言发一条最小请求，把网关的真实
/// 响应（或错误正文）贴在弹层里。复制片段只能证明「地址写对了」，一次真实
/// 往返才能证明引擎、网关、模型三者都通了。
struct GatewayTestButton: View {
    @ObservedObject var state: AppState
    @ObservedObject private var gateway = GatewayController.shared

    @State private var running = false
    @State private var showing = false
    @State private var result: GatewayTestResult?

    var body: some View {
        DSIconButton(
            systemName: "bolt.horizontal",
            help: running ? "正在测试…" : "发送测试请求",
            size: 24,
            style: .outlined
        ) {
            run()
        }
        .disabled(running || state.selectedModel.isEmpty)
        .popover(isPresented: $showing, arrowEdge: .leading) {
            popover
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                DSStatusDot(
                    color: running ? DS.warn : (result?.ok == true ? DS.ok : DS.err),
                    live: running,
                    size: 6)
                Text(L10n.t(running ? "网关测试 · 进行中" : "网关测试"))
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 8)
                Button {
                    showing = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.text3)
                .accessibilityLabel(L10n.t("关闭通知"))
            }

            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("等待网关响应…"))
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let result {
                Text(result.reply.isEmpty ? L10n.t("网关没有返回内容") : result.reply)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(result.ok ? DS.text : DS.err)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(DS.rect(DS.Radius.sm).fill(DS.bg))

                HStack(spacing: 8) {
                    Text(verbatim: "HTTP \(result.status) · \(result.milliseconds) ms")
                        .font(DS.Font.mono(10))
                        .foregroundStyle(DS.text3)
                    Spacer(minLength: 0)
                    Button(L10n.t("复制结果")) {
                        state.copy(result.reply, label: L10n.t("已复制响应"))
                    }
                    .buttonStyle(.ds(.secondary, size: .small))
                    .disabled(result.reply.isEmpty)
                    Button(L10n.t("重试")) { run() }
                        .buttonStyle(.ds(.secondary, size: .small))
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .dsPopoverSurface()
    }

    private func run() {
        guard !running, !state.selectedModel.isEmpty else { return }
        running = true
        showing = true
        result = nil
        let started = Date()
        Task {
            let outcome = await Self.send(
                baseURL: state.gatewayURL, model: state.selectedModel)
            await MainActor.run {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                result = outcome.withMilliseconds(elapsed)
                running = false
            }
        }
    }

    private static func send(baseURL: String, model: String) async -> GatewayTestResult {
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

struct GatewayTestResult {
    let ok: Bool
    let status: Int
    let reply: String
    let milliseconds: Int

    func withMilliseconds(_ value: Int) -> GatewayTestResult {
        GatewayTestResult(ok: ok, status: status, reply: reply, milliseconds: value)
    }
}

/// 只解析测试请求关心的两种形状：正常 `choices[0].message.content`，
/// 以及网关 / 引擎返回的错误正文。其它情况原样给出文本，不吞掉证据。
enum GatewayTestResponse {
    static func parse(data: Data, status: Int) -> (ok: Bool, reply: String) {
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
