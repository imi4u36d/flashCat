// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
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
    @StateObject private var copyFlash = ActionFlashState()

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
                    Button {
                        state.copy(result.reply)
                        copyFlash.succeed()
                    } label: {
                        ActionFlashLabel(title: "复制结果", flash: copyFlash.value)
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
            let outcome = await GatewaySelfTest.send(
                baseURL: state.gatewayURL, model: state.selectedModel)
            await MainActor.run {
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                result = outcome.withMilliseconds(elapsed)
                running = false
            }
        }
    }

}
