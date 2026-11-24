// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: - API card

    var gatewayCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(L10n.t("接口"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "OpenAI + Claude")
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                Spacer(minLength: 6)
                GatewayTestButton(state: state)
                OverviewTintPill(
                    text: gateway.isRunning ? "在线" : "离线",
                    tint: gateway.isRunning ? DS.ok : DS.text4,
                    live: gateway.isRunning)
            }

            VStack(spacing: 6) {
                endpointRow(
                    name: "OpenAI",
                    url: state.gatewayURL,
                    curl: snippets.openAICurl,
                    python: snippets.openAIPython)
                endpointRow(
                    name: "Claude",
                    url: state.gatewayClaudeURL,
                    curl: snippets.claudeCurl,
                    python: snippets.claudePython)
            }

            if let failure = gateway.failureMessage, !gateway.isRunning {
                Text(failure)
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.warn)
                    .lineLimit(2)
            }

            DSDivider()
            clientsList
        }
        .overviewCard()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 调用片段：Base URL 与模型 ID 都来自当前设置与选择。
    var snippets: GatewaySnippets {
        GatewaySnippets(
            openAIBase: state.gatewayURL,
            claudeBase: state.gatewayClaudeURL,
            model: state.selectedModel)
    }

    func endpointRow(name: String, url: String, curl: String, python: String) -> some View {
        Button {
            state.copy(url, label: L10n.format("%@ 接口地址已复制", name))
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .frame(width: 48, alignment: .leading)

                Text(verbatim: url)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DS.text4)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .contentShape(DS.rect(9))
        }
        .buttonStyle(.plain)
        .dsSubcard(radius: 9)
        .contextMenu {
            Button(L10n.t("复制 curl 片段")) {
                state.copy(curl, label: L10n.t("curl 片段已复制"))
            }
            Button(L10n.t("复制 Python 片段")) {
                state.copy(python, label: L10n.t("Python 片段已复制"))
            }
        }
        .help(L10n.t("点击复制接口地址"))
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(L10n.t("最近客户端"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 0)
                Text(verbatim: "\(recentClients.count)")
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text4)
            }

            if recentClients.isEmpty {
                Text(L10n.t("还没有客户端连过。点地址复制片段，连一次后这里会显示来源与请求数。"))
                    .font(DS.Font.prose(10.5))
                    .foregroundStyle(DS.text4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            } else {
                ForEach(Array(recentClients.prefix(2))) { client in
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
                            .padding(.horizontal, 4)
                            .frame(height: 14)
                            .background(DS.rect(4).fill(DS.bg))
                        Spacer(minLength: 4)
                        Text(L10n.format("%lld 次", Int64(client.count)))
                            .font(DS.Font.mono(9.5))
                            .foregroundStyle(DS.text3)
                            .fixedSize()
                        Text(Format.relative(client.last))
                            .font(DS.Font.mono(9.5))
                            .foregroundStyle(DS.text4)
                            .fixedSize()
                    }
                    .frame(height: 20)
                }
            }
        }
    }

    // MARK: - Engine card

    var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L10n.t("引擎状态"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(state.activeEngine.displayName)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 6)
                OverviewTintPill(
                    text: state.isRunning ? "运行中" : "已停止",
                    tint: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                    live: state.canChat)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                portTile
                cacheTile
                memoryTile
                temperatureTile
            }

            Spacer(minLength: 0)
        }
        .overviewCard()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var portTile: some View {
        Button {
            state.copy(
                "127.0.0.1:\(state.port)",
                label: L10n.format("%@ 接口地址已复制", state.activeEngine.displayName))
        } label: {
            runtimeTile {
                runtimeTileHeader(label: "引擎端口") {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DS.text4)
                }
            } content: {
                Text(verbatim: "127.0.0.1:\(state.port)")
                    .font(DS.Font.mono(11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(L10n.t("点击复制引擎端口"))
    }

    var cacheTile: some View {
        runtimeTile {
            runtimeTileHeader(label: "缓存命中率") {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text4)
            }
        } content: {
            HStack(spacing: 6) {
                Text(verbatim: cacheHitText == "—" ? "—" : "\(cacheHitText)%")
                    .font(DS.Font.number(12.5, weight: .bold))
                    .foregroundStyle(cacheHitText == "—" ? DS.text4 : DS.text)
                    .contentTransition(.numericText())
                OverviewMiniBar(
                    value: cacheHitReading.value ?? 0,
                    tint: DS.accent,
                    gradientTo: DS.accentBlue)
            }
        }
    }

    var memoryTile: some View {
        runtimeTile {
            runtimeTileHeader(label: "内存压力") {
                Text(verbatim: stats?.memoryPressureText ?? "—")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text4)
                    .lineLimit(1)
            }
        } content: {
            HStack(spacing: 6) {
                Text(verbatim: memoryValueText)
                    .font(DS.Font.number(12.5, weight: .bold))
                    .foregroundStyle(memoryValueText == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                OverviewMiniBar(
                    value: memoryBarFraction,
                    tint: DS.accentBlue,
                    gradientTo: DS.accent)
            }
        }
    }

    var temperatureTile: some View {
        runtimeTile {
            runtimeTileHeader(label: "温度") {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text4)
            }
        } content: {
            Text(verbatim: stats.map { L10n.t($0.thermalText) } ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
        }
    }

    func runtimeTileHeader<Accessory: View>(
        label: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 4) {
            Text(L10n.t(label))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
            Spacer(minLength: 2)
            accessory()
        }
    }

    func runtimeTile<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header()
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .dsSubcard(radius: 10)
    }

    var memoryValueText: String {
        guard let bytes = stats?.memoryBytes, bytes > 0 else { return "—" }
        return Format.memory(bytes)
    }

    var memoryBarFraction: Double {
        switch stats?.memoryPressure {
        case .some("critical"): return 0.94
        case .some("warning"): return 0.72
        case .some: return 0.45
        case .none: return 0
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

    // MARK: - Recent requests

    var requestFilterLabel: String {
        switch requestFilterIndex {
        case 1: return "仅 chat"
        case 2: return "仅 openai"
        default: return "按请求"
        }
    }

    func filteredRequests(_ sessions: [GatewayMeter.SessionSnapshot]) -> [GatewayMeter.SessionSnapshot] {
        switch requestFilterIndex {
        case 1: return sessions.filter { $0.dialect == "chat" }
        case 2: return sessions.filter { $0.dialect == "openai" }
        default: return sessions
        }
    }

    var recentRequests: some View {
        TimelineView(.periodic(from: .now, by: (gateway.isRunning || state.isRunning) ? 1 : 5)) { _ in
            let all = Array(GatewayMeter.shared.snapshot(limit: 6).reversed())
            let sessions = filteredRequests(all)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(L10n.t("最近请求"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(DS.text)
                    Spacer(minLength: 6)
                    Button {
                        requestFilterIndex = (requestFilterIndex + 1) % 3
                    } label: {
                        Text(L10n.t(requestFilterLabel))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .dsGlassPill()
                    .help(L10n.t("点击切换筛选条件"))
                    Text(L10n.format("%lld 条", Int64(sessions.count)))
                        .font(DS.Font.proseNumber(11.5))
                        .foregroundStyle(DS.text3)
                }

                if sessions.isEmpty {
                    emptyRequests
                } else {
                    requestTable(sessions)
                }
            }
            .overviewCard()
        }
    }

    var emptyRequests: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(DS.text4)
            Text(L10n.t("暂无请求"))
                .font(DS.Font.prose(12.5))
                .foregroundStyle(DS.text2)
            Text(verbatim: "127.0.0.1:\(state.settings.gatewayPort)")
                .font(DS.Font.mono(10.5))
                .foregroundStyle(DS.text4)
            Spacer(minLength: 0)
        }
        .frame(height: 54)
    }

    func requestTable(_ sessions: [GatewayMeter.SessionSnapshot]) -> some View {
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DS.text3)
            .padding(.horizontal, 8)
            .frame(height: 26)

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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(live ? DS.text : DS.text2)
                }
                .frame(width: 68, alignment: .leading)

                Text(verbatim: dialect)
                    .font(DS.Font.mono(9.5, weight: .medium))
                    .foregroundStyle(dialectTint(dialect))
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background(DS.rect(5).fill(dialectTint(dialect).opacity(0.10)))
                    .overlay(DS.rect(5).strokeBorder(dialectTint(dialect).opacity(0.20), lineWidth: 1))
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
                    .font(DS.Font.proseNumber(11.5, weight: .semibold))
                    .foregroundStyle(decode > 0 ? DS.text : DS.text3)
                    .frame(width: 92, alignment: .trailing)

                Text(Format.tokens(session.ctxTokens))
                    .font(DS.Font.proseNumber(11.5))
                    .foregroundStyle(DS.text3)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(hovered ? DS.hover : .clear, in: DS.rect(8))
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

    func dialectTint(_ dialect: String) -> Color {
        switch dialect {
        case "openai": return DS.accent
        case "claude": return DS.accentBlue
        default: return DS.text3
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
