// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Gateway & Runtime

    var gatewaySection: some View {
        overviewSection(title: "接口", subtitle: "OpenAI + Claude") {
            HStack(spacing: 6) {
                DSChip(
                    text: L10n.t(gateway.isRunning ? "在线" : "离线"),
                    dot: gateway.isRunning ? DS.ok : DS.text4,
                    live: gateway.isRunning)
                GatewayTestButton(state: state)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                endpointRow(
                    name: "OpenAI",
                    url: state.gatewayURL,
                    curl: snippets.openAICurl,
                    python: snippets.openAIPython)
                DSDivider()
                endpointRow(
                    name: "Claude",
                    url: state.gatewayClaudeURL,
                    curl: snippets.claudeCurl,
                    python: snippets.claudePython)

                if let failure = gateway.failureMessage, !gateway.isRunning {
                    Text(failure)
                        .font(DS.Font.prose(11.5))
                        .foregroundStyle(DS.warn)
                        .padding(.top, 6)
                }

                DSDivider()
                    .padding(.top, 8)
                clientsList
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 调用片段：Base URL 与模型 ID 都来自当前设置与选择。
    var snippets: GatewaySnippets {
        GatewaySnippets(
            openAIBase: state.gatewayURL,
            claudeBase: state.gatewayClaudeURL,
            model: state.selectedModel)
    }

    // MARK: Recent clients

    /// 网关只监听回环，`User-Agent` 是唯一能区分「谁在用」的线索。
    var recentClients: [GatewayClientSummary] {
        GatewayClientSummary.group(GatewayMeter.shared.snapshot(limit: 32))
    }

    func dialectLabel(_ value: String) -> String {
        switch value {
        case "openai": return "OpenAI"
        case "claude": return "Claude"
        case "chat": return L10n.t("对话")
        case "image": return L10n.t("图像")
        case "video": return L10n.t("视频")
        default: return value.isEmpty ? "—" : value
        }
    }

    var clientsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L10n.t("最近客户端"))
                    .font(DS.Font.prose(11.5, weight: .medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 0)
                Text(verbatim: "\(recentClients.count)")
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text4)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)

            if recentClients.isEmpty {
                Text(L10n.t("还没有客户端连过。点端点旁的箭头复制片段，连一次后这里会显示来源与请求数。"))
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 3)
            } else {
                ForEach(recentClients) { client in
                    HStack(spacing: 6) {
                        DSStatusDot(color: client.active ? DS.ok : DS.text4, size: 5)
                        Text(client.name)
                            .font(DS.Font.prose(11.5))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        Text(verbatim: dialectLabel(client.dialect))
                            .font(DS.Font.mono(9))
                            .foregroundStyle(DS.text3)
                        Spacer(minLength: 4)
                        Text(L10n.format("%lld 次", Int64(client.count)))
                            .font(DS.Font.mono(10))
                            .foregroundStyle(DS.text3)
                            .fixedSize()
                        Text(Format.relative(client.last))
                            .font(DS.Font.mono(9.5))
                            .foregroundStyle(DS.text4)
                            .fixedSize()
                    }
                    .frame(height: 24)
                }
            }
        }
    }

    var runtimeSection: some View {
        overviewSection(title: "引擎", subtitle: state.activeEngine.displayName) {
            DSChip(
                text: L10n.t(state.isRunning ? "运行中" : "已停止"),
                dot: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                live: state.canChat)
        } content: {
            VStack(spacing: 0) {
                telemetryRow(
                    label: "引擎端口",
                    value: "127.0.0.1:\(state.port)",
                    copyLabel: "%@ 接口地址已复制",
                    copyArg: state.activeEngine.displayName)
                DSDivider()
                telemetryRow(
                    label: "缓存命中率",
                    value: cacheHitText == "—" ? "—" : "\(cacheHitText)%")
                DSDivider()
                telemetryRow(label: "内存压力", value: memorySummaryText)
                DSDivider()
                telemetryRow(label: "温度", value: stats.map { L10n.t($0.thermalText) } ?? "—")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func overviewSection<Accessory: View, Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: DS.Space.sm) {
                Text(L10n.t(title))
                    .font(DS.Font.prose(13.5, weight: .medium))
                    .foregroundStyle(DS.text)
                if let subtitle {
                    Text(L10n.t(subtitle))
                        .font(DS.Font.prose(12))
                        .foregroundStyle(DS.text3)
                }
                Spacer(minLength: DS.Space.sm)
                accessory()
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var memorySummaryText: String {
        if let bytes = stats?.memoryBytes, bytes > 0 {
            if let pressure = stats?.memoryPressure, !pressure.isEmpty,
                let pressureText = stats?.memoryPressureText
            {
                return "\(Format.memory(bytes)) · \(L10n.t(pressureText))"
            }
            return Format.memory(bytes)
        }
        return stats.map { L10n.t($0.memoryPressureText) } ?? "—"
    }

    func endpointRow(name: String, url: String, curl: String, python: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(DS.Font.prose(12.5, weight: .medium))
                .foregroundStyle(DS.text)
                .frame(width: 52, alignment: .leading)

            Text(verbatim: url)
                .font(DS.Font.proseNumber(11.5))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            DSIconButton(systemName: "doc.on.doc", help: "复制地址", size: 24) {
                state.copy(url, label: L10n.format("%@ 接口地址已复制", name))
            }

            DSMenu(kind: .ghost, size: .small) {
                DSMenuTriggerLabel(
                    systemImage: "chevron.down",
                    trailingChevron: false,
                    kind: .ghost,
                    size: .small
                )
                .foregroundStyle(DS.text3)
            } content: {
                Button(L10n.t("复制 curl 片段")) {
                    state.copy(curl, label: L10n.t("curl 片段已复制"))
                }
                Button(L10n.t("复制 Python 片段")) {
                    state.copy(python, label: L10n.t("Python 片段已复制"))
                }
            }
            .help(L10n.t("复制调用片段"))
            .accessibilityLabel(L10n.t("复制调用片段"))
        }
        .padding(.vertical, 6)
    }

    func telemetryRow(
        label: String,
        value: String,
        copyLabel: String? = nil,
        copyArg: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(L10n.t(label))
                .font(DS.Font.prose(12.5))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(DS.Font.proseNumber(12))
                .foregroundStyle(value == "—" ? DS.text4 : DS.text2)
                .lineLimit(1)
                .textSelection(.enabled)
            if let copyLabel, value != "—" {
                DSIconButton(systemName: "doc.on.doc", help: "复制地址", size: 22) {
                    let message = copyArg.map { L10n.format(copyLabel, $0) } ?? L10n.t(copyLabel)
                    state.copy(value, label: message)
                }
            }
        }
        .frame(minHeight: 28, maxHeight: .infinity)
    }

    // MARK: Recent Requests

    var recentRequests: some View {
        TimelineView(.periodic(from: .now, by: (gateway.isRunning || state.isRunning) ? 1 : 5)) { _ in
            let sessions = Array(GatewayMeter.shared.snapshot(limit: 6).reversed())
            overviewSection(title: "最近请求") {
                HStack(spacing: 8) {
                    DSSourceBadge(text: L10n.t("按请求"))
                    Text(L10n.format("%lld 条", Int64(sessions.count)))
                        .font(DS.Font.proseNumber(11.5))
                        .foregroundStyle(DS.text3)
                }
            } content: {
                if sessions.isEmpty {
                    VStack(spacing: 7) {
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(DS.text4)
                        Text(L10n.t("暂无请求"))
                            .font(DS.Font.prose(13))
                            .foregroundStyle(DS.text2)
                        Text(verbatim: "127.0.0.1:\(state.settings.gatewayPort)")
                            .font(DS.Font.proseNumber(11.5))
                            .foregroundStyle(DS.text3)
                        Spacer(minLength: 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text(L10n.t("状态"))
                                .frame(width: 68, alignment: .leading)
                            Text(L10n.t("协议"))
                                .frame(width: 72, alignment: .leading)
                            Text(L10n.t("模型"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(L10n.t("首字"))
                                .frame(width: 72, alignment: .trailing)
                            Text(L10n.t("解码"))
                                .frame(width: 92, alignment: .trailing)
                            Text(L10n.t("上下文"))
                                .frame(width: 76, alignment: .trailing)
                        }
                        .font(DS.Font.prose(11.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                        .padding(.horizontal, 8)
                        .frame(height: 28)

                        DSDivider()

                        ForEach(sessions, id: \.id) { session in
                            requestRow(session)
                                .transition(.dsRowInsert)
                            if session.id != sessions.last?.id {
                                DSDivider()
                            }
                        }
                    }
                    .animation(reduceMotion ? nil : DS.Motion.smooth, value: sessions.map(\.id))
                }
            }
        }
    }

    func requestRow(_ session: GatewayMeter.SessionSnapshot) -> some View {
        let decode = session.decodeRate
        let ttftText = session.ttftMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        let decodeText = decode > 0 ? "\(Format.compact(decode)) tok/s" : "—"
        let live = session.state == .decode || session.state == .prefill
        let hovered = hoveredSessionID == session.id
        let dialect = session.dialect.isEmpty ? "API" : session.dialect
        let rawModel = session.model.isEmpty ? L10n.t("未命名") : session.model
        let modelDisplay = session.model.isEmpty ? L10n.t("未命名") : state.shortModelName(session.model)
        let summary =
            "\(dialect) · \(rawModel) · TTFT \(ttftText) · Decode \(decodeText) · Ctx \(Format.tokens(session.ctxTokens))"

        return Button {
            state.copy(summary, label: L10n.t("已复制请求摘要"))
        } label: {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    DSStatusDot(color: sessionColor(session.state), live: live, size: 6)
                    Text(L10n.t(stateLabel(session.state)))
                        .font(DS.Font.prose(12, weight: .medium))
                        .foregroundStyle(live ? DS.text : DS.text2)
                }
                .frame(width: 68, alignment: .leading)

                Text(verbatim: dialect)
                    .font(DS.Font.prose(10.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(DS.rect(4).fill(DS.hover))
                    .frame(width: 72, alignment: .leading)

                Text(modelDisplay)
                    .font(DS.Font.prose(12.5))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(verbatim: ttftText)
                    .font(DS.Font.proseNumber(11.5))
                    .foregroundStyle(DS.text2)
                    .frame(width: 72, alignment: .trailing)

                Text(verbatim: decodeText)
                    .font(DS.Font.proseNumber(11.5))
                    .foregroundStyle(decode > 0 ? DS.text : DS.text3)
                    .frame(width: 92, alignment: .trailing)

                Text(Format.tokens(session.ctxTokens))
                    .font(DS.Font.proseNumber(11.5))
                    .foregroundStyle(DS.text3)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(hovered ? DS.hover : .clear, in: DS.rect(DS.Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(reduceMotion ? nil : DS.Motion.snappy) {
                hoveredSessionID = inside ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
            }
        }
        .help(L10n.t("点击复制请求摘要"))
        .contextMenu {
            Button(L10n.t("复制模型名")) {
                state.copy(rawModel, label: L10n.t("已复制模型名"))
            }
            Button(L10n.t("复制请求指标")) {
                state.copy(summary, label: L10n.t("已复制请求摘要"))
            }
        }
    }

    func sessionColor(_ state: GatewayMeter.SessionSnapshot.State) -> Color {
        switch state {
        case .decode: return DS.ok
        case .prefill: return DS.info
        case .failed: return DS.err
        case .done: return DS.text4
        }
    }

    func stateLabel(_ state: GatewayMeter.SessionSnapshot.State) -> String {
        switch state {
        case .decode: return "解码"
        case .prefill: return "预填"
        case .failed: return "失败"
        case .done: return "完成"
        }
    }
}
