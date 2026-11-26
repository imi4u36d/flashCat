// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: - API card

    func gatewayCard(cardPadding: CGFloat = 14) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(L10n.t("接口"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 6)
                GatewayTestButton(state: state)
                if !gateway.isRunning {
                    OverviewTintPill(
                        text: "离线",
                        tint: DS.warn,
                        live: false)
                }
            }

            VStack(spacing: 0) {
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
            }

            if let failure = gateway.failureMessage, !gateway.isRunning {
                Text(failure)
                    .font(DS.Font.prose(11))
                    .foregroundStyle(DS.warn)
                    .lineLimit(2)
            }
        }
        .overviewCard(padding: cardPadding)
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
        let key = "endpoint-\(name)"
        let copied = copiedKey == key
        return Button {
            state.copy(url)
            flashCopied(key)
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .frame(width: 48, alignment: .leading)

                Text(verbatim: url)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(copied ? DS.ok : DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                ActionFlashIcon(
                    systemName: "doc.on.doc",
                    flash: copied ? .success : nil,
                    size: 10.5,
                    baseColor: DS.text4)
                    .frame(width: 12, height: 12)
            }
            .frame(height: 32)
            .contentShape(DS.rect(9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L10n.t("复制 curl 片段")) {
                state.copy(curl)
                flashCopied(key)
            }
            Button(L10n.t("复制 Python 片段")) {
                state.copy(python)
                flashCopied(key)
            }
        }
        .help(copied ? L10n.t("接口地址已复制") : L10n.t("点击复制接口地址"))
    }

    // MARK: - Engine card

    func runtimeCard(cardPadding: CGFloat = 14) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("引擎读数"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.text)

            DSDivider()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    portTile
                    DSDivider(vertical: true)
                    cacheTile
                }
                .frame(maxHeight: .infinity)
                DSDivider()
                HStack(alignment: .top, spacing: 0) {
                    memoryTile
                    DSDivider(vertical: true)
                    temperatureTile
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .overviewCard(padding: cardPadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    var portTile: some View {
        let copied = copiedKey == "engine-port"
        return Button {
            state.copy("127.0.0.1:\(state.port)")
            flashCopied("engine-port")
        } label: {
            runtimeTile {
                runtimeTileHeader(label: "引擎端口") {
                    ActionFlashIcon(
                        systemName: "doc.on.doc",
                        flash: copied ? .success : nil,
                        size: 9.5,
                        baseColor: DS.text4)
                        .frame(width: 12, height: 12)
                }
            } content: {
                Text(verbatim: "127.0.0.1:\(state.port)")
                    .font(DS.Font.mono(11.5, weight: .semibold))
                    .foregroundStyle(copied ? DS.ok : DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(copied ? L10n.t("引擎端口已复制") : L10n.t("点击复制引擎端口"))
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
                    gradientTo: DS.accentPeach)
            }
        }
    }

    var memoryTile: some View {
        runtimeTile {
            runtimeTileHeader(label: "内存") {
                EmptyView()
            }
        } content: {
            HStack(spacing: 6) {
                Text(verbatim: memoryValueText)
                    .font(DS.Font.number(12.5, weight: .bold))
                    .foregroundStyle(memoryValueText == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                OverviewMiniBar(
                    value: memoryBarFraction,
                    tint: DS.accentPeach,
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
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
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

    @ViewBuilder
    func recentRequestsCard(
        maxRows: Int = 6,
        cardPadding: CGFloat = 14,
        alwaysVisible: Bool = false
    ) -> some View {
        TimelineView(.periodic(from: .now, by: (gateway.isRunning || state.isRunning) ? 1 : 5)) { _ in
            let all = Array(GatewayMeter.shared.snapshot(limit: maxRows).reversed())
            let sessions = filteredRequests(all)
            if alwaysVisible || !all.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
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
                        .dsQuietPill()
                        .help(L10n.t("点击切换筛选条件"))
                    }

                    if sessions.isEmpty {
                        emptyRequests
                    } else {
                        requestTable(sessions)
                    }
                }
                // 定长布局里这张卡和曲线各占一半高度：卡面铺满，表格从顶上排，
                // 余下的空位留在卡内，而不是让卡片缩成一条。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overviewCard(padding: cardPadding)
            }
        }
    }

    var emptyRequests: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DS.text4)
            Text(L10n.t("暂无请求"))
                .font(DS.Font.prose(12.5))
                .foregroundStyle(DS.text2)
            Text(verbatim: "127.0.0.1:\(state.settings.gatewayPort)")
                .font(DS.Font.mono(10.5))
                .foregroundStyle(DS.text4)
            Spacer(minLength: 0)
        }
        .frame(height: 36)
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
        let copyKey = "request-\(session.id)"
        let copied = copiedKey == copyKey
        let dialect = session.dialect.isEmpty ? "API" : session.dialect
        let rawModel = session.model.isEmpty ? L10n.t("未命名") : session.model
        let modelDisplay = session.model.isEmpty ? L10n.t("未命名") : state.shortModelName(session.model)
        let summary =
            "\(dialect) · \(rawModel) · TTFT \(ttftText) · Decode \(decodeText) · Ctx \(Format.tokens(session.ctxTokens))"

        return Button {
            state.copy(summary)
            flashCopied(copyKey)
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

                // 悬停才显形；宽度常驻，行内列不会因为鼠标移动而重排。
                ActionFlashIcon(
                    systemName: "doc.on.doc",
                    flash: copied ? .success : nil,
                    size: 10,
                    baseColor: DS.text4)
                    .frame(width: 12, height: 12)
                    .opacity(hovered || copied ? 1 : 0)
                    .animation(reduceMotion ? nil : DS.Motion.snappy, value: hovered)
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
        .help(copied ? L10n.t("请求摘要已复制") : L10n.t("点击复制请求摘要"))
        .contextMenu {
            Button(L10n.t("复制模型名")) {
                state.copy(rawModel)
                flashCopied(copyKey)
            }
            Button(L10n.t("复制请求指标")) {
                state.copy(summary)
                flashCopied(copyKey)
            }
        }
    }

    func dialectTint(_ dialect: String) -> Color {
        switch dialect {
        case "openai": return DS.accent
        case "claude": return DS.accentPeachText
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
