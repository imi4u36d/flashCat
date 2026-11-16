// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatKit
import SwiftUI

/// 概览：线性/工作台风——顶部模型控制带、5 格连通 KPI 指标条、60 秒吞吐图表 + API 网关、底部最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    @ObservedObject private var gateway = GatewayController.shared

    @State private var hoveredSessionID: Int?

    private var stats: ServerStats? { state.stats }
    private var samples: [ThroughputSample] { state.overviewThroughput(window: 60) }
    private var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    private var modelTitle: String {
        state.selectedModelInfo?.shortName
            ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    private var modelTitleParts: (name: String, variant: String?) {
        let title = modelTitle
        guard let colon = title.lastIndex(of: ":") else { return (title, nil) }
        let name = String(title[title.startIndex..<colon])
        let variant = String(title[title.index(after: colon)...])
        guard !name.isEmpty, !variant.isEmpty, variant.count <= 16 else { return (title, nil) }
        return (name, variant)
    }

    private var averageReading: MetricReading { state.averageDecodeReading }
    private var averageRate: Double { averageReading.value ?? 0 }

    private var chartRate: Double { samples.last?.value ?? 0 }
    private var chartFrozen: Bool { state.throughputFrozenAt != nil }
    private var speedOrigin: SpeedOrigin { state.speedOrigin }

    private var prefillReading: MetricReading { state.prefillReading }
    private var ttftReading: TTFTReading { state.ttftReading }
    private var cacheHitReading: MetricReading { state.cacheHitReading }

    private func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
    }

    private var runningText: String {
        let stage = state.engineStageText
        guard !stage.isEmpty else { return state.activeEngine.displayName }
        return "\(state.activeEngine.displayName) · \(stage)"
    }

    private var sessionCount: Int {
        state.stats?.activeRequests ?? 0
    }

    private let sectionGap: CGFloat = 14
    private let sideColumnWidth: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < Console.compactContentWidth {
                compactLayout
            } else {
                wideLayout(proxy)
            }
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionGap) {
                hero
                metricsRow(compact: true)
                decodeChart
                    .frame(height: 240)
                gatewayCard
                recentRequests
                    .frame(minHeight: 200)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    private func wideLayout(_ proxy: GeometryProxy) -> some View {
        let middleHeight = max(220, min(300, proxy.size.height - 460))

        return ScrollView {
            VStack(alignment: .leading, spacing: sectionGap) {
                hero
                metricsRow(compact: false)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: sectionGap) {
                    decodeChart
                    gatewayCard
                        .frame(width: sideColumnWidth)
                }
                .frame(height: middleHeight)
                recentRequests
                    .frame(minHeight: 196)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.t(modelTitleParts.name))
                        .font(DS.Font.title)
                        .tracking(-0.35)
                        .foregroundStyle(DS.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    if let variant = modelTitleParts.variant {
                        Text(variant)
                            .font(DS.Font.mono(11, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DS.rect(DS.Radius.sm).fill(DS.raised))
                            .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
                            .fixedSize()
                    }
                }

                HStack(spacing: 8) {
                    DSStatusDot(
                        color: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                        live: state.canChat,
                        size: 6)
                    Text(runningText)
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                    Text("·")
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text4)
                    Text(verbatim: "127.0.0.1:\(state.port)")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                    Text("·")
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text4)
                    Text("\(sessionCount) SESSIONS")
                        .font(DS.Font.mono(10, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(DS.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        state.toggleService()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
                        }
                    }
                    .buttonStyle(.ds(state.isRunning ? .danger : .secondary))
                    .disabled(state.isSwitchingModel)

                    ModelPickerButton(state: state) {
                        DSMenuTriggerLabel(
                            title: "切换模型",
                            systemImage: "square.stack.3d.up.fill",
                            kind: .primary,
                            size: .regular
                        )
                    }
                    .disabled(state.isSwitchingModel)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .dsSurface(radius: DS.Radius.lg)
    }

    // MARK: Connected 5-Cell KPI Strip

    @ViewBuilder
    private func metricsRow(compact: Bool) -> some View {
        if compact {
            GlassEffectContainer(spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    averageMetricCell
                        .dsSurface(radius: DS.Radius.md)
                    contextMetricCell
                        .dsSurface(radius: DS.Radius.md)
                    ttftMetricCell
                        .dsSurface(radius: DS.Radius.md)
                    prefillMetricCell
                        .dsSurface(radius: DS.Radius.md)
                    cacheMetricCell
                        .dsSurface(radius: DS.Radius.md)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                averageMetricCell
                DSDivider(vertical: true)
                contextMetricCell
                DSDivider(vertical: true)
                ttftMetricCell
                DSDivider(vertical: true)
                prefillMetricCell
                DSDivider(vertical: true)
                cacheMetricCell
            }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
        }
    }

    private var averageMetricCell: some View {
        kpiCell(
            title: "平均解码",
            value: rateText(averageRate),
            unit: averageRate > 0 ? "tok/s" : nil,
            trailing: {
                DSSparkline(
                    values: Array(samples.suffix(24).map(\.value)),
                    color: DS.accent,
                    floor: max(peak, 1)
                )
                .frame(width: 56, height: 18)
            })
    }

    private var contextMetricCell: some View {
        let ceiling = state.contextWindowCeiling.map { "/ \(Format.tokensShort($0))" } ?? "/ —"
        return kpiCell(
            title: "当前上下文",
            value: Format.tokens(state.overviewContextUsedTokens),
            unit: ceiling
        ) {
            EmptyView()
        } bottom: {
            DSMeter(value: contextProgress, tint: DS.accent)
                .padding(.vertical, 2)
        }
    }

    private var ttftMetricCell: some View {
        kpiCell(
            title: "首字延迟",
            value: ttftText,
            unit: ttftText == "—" ? nil : "ms")
    }

    private var prefillMetricCell: some View {
        kpiCell(
            title: "预填充",
            value: prefillText,
            unit: prefillText == "—" ? nil : "tok/s")
    }

    private var cacheMetricCell: some View {
        kpiCell(
            title: "缓存命中率",
            value: cacheHitText,
            unit: cacheHitText == "—" ? nil : "%")
    }

    private func kpiCell<Trailing: View, Bottom: View>(
        title: String,
        value: String,
        unit: String?,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder bottom: () -> Bottom = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t(title))
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text2)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(DS.Font.number(24, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing()
            }

            bottom()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Metric Formatting & Metering

    private var contextProgress: Double {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0 else { return 0 }
        return min(1, max(0, Double(state.overviewContextUsedTokens) / Double(ceiling)))
    }

    private var ttftText: String {
        guard let value = ttftReading.milliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    private var prefillText: String {
        guard let value = prefillReading.value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    private var cacheHitText: String {
        guard let value = cacheHitReading.value else { return "—" }
        return "\(Int((value * 100).rounded()))"
    }

    // MARK: Decode Chart

    private var decodeChart: some View {
        DSPanel(title: "总解码 · 最近 60 秒") {
            HStack(spacing: 8) {
                if chartRate > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(rateText(chartRate))
                            .font(DS.Font.mono(13, weight: .semibold))
                            .foregroundStyle(DS.text)
                            .contentTransition(.numericText())
                        Text("tok/s")
                            .font(DS.Font.mono(10))
                            .foregroundStyle(DS.text3)
                    }
                }
                DSChip(text: speedChip.text, dot: speedChip.color, live: speedChip.live)
            }
        } content: {
            Group {
                if samples.isEmpty {
                    ZStack {
                        chartGrid
                        VStack(spacing: 7) {
                            Image(systemName: state.isRunning ? "waveform.path.ecg" : "bolt.slash")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(DS.text4)
                            Text(L10n.t(chartEmptyText))
                                .font(DS.Font.sm)
                                .foregroundStyle(DS.text3)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                    }
                } else {
                    Chart {
                        ForEach(samples) { sample in
                            AreaMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [DS.accent.opacity(0.16), .clear],
                                        startPoint: .top, endPoint: .bottom)
                                )
                            LineMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(DS.accent)
                                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        }
                        if samples.count == 1, let only = samples.first {
                            PointMark(x: .value("时间", only.at), y: .value("tok/s", only.value))
                                .foregroundStyle(DS.accent)
                                .symbolSize(26)
                        }
                    }
                    .chartXScale(domain: chartWindow)
                    .chartYScale(domain: 0...(peak * 1.2))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(DS.line)
                            AxisValueLabel()
                                .font(DS.Font.mono(10))
                                .foregroundStyle(DS.text3)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var chartWindow: ClosedRange<Date> {
        let end = state.overviewChartEnd
        return end.addingTimeInterval(-60)...end
    }

    private var speedChip: (text: String, color: Color, live: Bool) {
        if chartFrozen {
            return samples.isEmpty ? ("无样本", DS.text4, false) : ("已冻结", DS.text4, false)
        }
        switch speedOrigin {
        case .gatewayLive: return ("网关", DS.info, true)
        case .engineLive: return ("引擎", DS.accent, true)
        case .none: return (state.isRunning ? "等待" : "IDLE", DS.text4, false)
        }
    }

    private var chartEmptyText: String {
        guard state.isRunning else { return "引擎未运行" }
        if chartFrozen { return "非流式请求无逐秒曲线" }
        return "等待样本"
    }

    private var chartGrid: some View {
        GeometryReader { proxy in
            let step: CGFloat = 88
            Path { path in
                var x: CGFloat = 0
                while x <= proxy.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= proxy.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    y += step / 2
                }
            }
            .stroke(DS.line, lineWidth: 1)
        }
    }

    // MARK: Gateway

    private var gatewayCard: some View {
        DSPanel(title: "API 网关", subtitle: "OpenAI + Claude") {
            DSChip(
                text: gateway.isRunning ? "ONLINE" : "OFFLINE",
                dot: gateway.isRunning ? DS.ok : DS.text4,
                live: gateway.isRunning)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    endpointRow(name: "OpenAI", url: state.gatewayURL)
                    DSDivider()
                    endpointRow(name: "Claude", url: state.gatewayClaudeURL)
                }
                .padding(.horizontal, 14)

                if let failure = gateway.failureMessage, !gateway.isRunning {
                    Text(failure)
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.warn)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                DSDivider()

                VStack(spacing: 6) {
                    telemetryRow(label: "引擎端口", value: "127.0.0.1:\(state.port)")
                    telemetryRow(label: "内存压力", value: stats?.memoryPressureText ?? "—")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Spacer(minLength: 0)
            }
        }
    }

    private func endpointRow(name: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text)
                .frame(width: 52, alignment: .leading)

            Text(verbatim: url)
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            DSIconButton(systemName: "doc.on.doc", help: "复制地址", size: 24) {
                state.copy(url, label: "\(name) 接口地址已复制")
            }
        }
        .padding(.vertical, 9)
    }

    private func telemetryRow(label: String, value: String) -> some View {
        HStack {
            Text(L10n.t(label))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
        }
    }

    // MARK: Recent Requests

    private var recentRequests: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sessions = Array(GatewayMeter.shared.snapshot(limit: 6).reversed())
            DSPanel(title: "最近请求") {
                HStack(spacing: 8) {
                    DSSourceBadge(text: L10n.t("按请求"))
                    Text("\(sessions.count) 条")
                        .font(DS.Font.mono(11))
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
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text2)
                        Text(verbatim: "127.0.0.1:\(state.settings.gatewayPort)")
                            .font(DS.Font.mono(11))
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
                        .font(DS.Font.xs.weight(.medium))
                        .foregroundStyle(DS.text3)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(DS.bg.opacity(0.6))

                        DSDivider()

                        ForEach(sessions, id: \.id) { session in
                            requestRow(session)
                                .transition(.dsRowInsert)
                            if session.id != sessions.last?.id {
                                DSDivider()
                            }
                        }
                    }
                    .animation(DS.Motion.smooth, value: sessions.map(\.id))
                }
            }
        }
    }

    private func requestRow(_ session: GatewayMeter.SessionSnapshot) -> some View {
        let decode = session.decodeRate
        let ttftText = session.ttftMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        let decodeText = decode > 0 ? "\(Format.compact(decode)) tok/s" : "—"
        let live = session.state == .decode || session.state == .prefill
        let hovered = hoveredSessionID == session.id

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                DSStatusDot(color: sessionColor(session.state), live: live, size: 6)
                Text(L10n.t(stateLabel(session.state)))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(live ? DS.text : DS.text2)
            }
            .frame(width: 68, alignment: .leading)

            Text(verbatim: session.dialect.isEmpty ? "API" : session.dialect)
                .font(DS.Font.mono(10))
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(DS.rect(4).fill(DS.bg))
                .overlay(DS.rect(4).strokeBorder(DS.line, lineWidth: 1))
                .frame(width: 72, alignment: .leading)

            Text(state.shortModelName(session.model.isEmpty ? "未命名" : session.model))
                .font(DS.Font.sm)
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: ttftText)
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text2)
                .frame(width: 72, alignment: .trailing)

            Text(verbatim: decodeText)
                .font(DS.Font.mono(11))
                .foregroundStyle(decode > 0 ? DS.text : DS.text3)
                .frame(width: 92, alignment: .trailing)

            Text(Format.tokens(session.ctxTokens))
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text3)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(hovered ? DS.hover : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(DS.Motion.snappy) {
                hoveredSessionID = inside ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
            }
        }
    }

    private func sessionColor(_ state: GatewayMeter.SessionSnapshot.State) -> Color {
        switch state {
        case .decode: return DS.ok
        case .prefill: return DS.info
        case .failed: return DS.err
        case .done: return DS.text4
        }
    }

    private func stateLabel(_ state: GatewayMeter.SessionSnapshot.State) -> String {
        switch state {
        case .decode: return "解码"
        case .prefill: return "预填"
        case .failed: return "失败"
        case .done: return "完成"
        }
    }
}
