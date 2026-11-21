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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredSessionID: Int?
    @State private var hoveredChartDate: Date?

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

    private let sectionGap: CGFloat = 20
    private let sideColumnWidth: CGFloat = 336

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
                DSDivider()
                metricsRow(compact: true)
                DSDivider()
                decodeChart
                    .frame(height: 228)
                DSDivider()
                gatewaySection
                DSDivider()
                runtimeSection
                DSDivider()
                recentRequests
                    .frame(minHeight: 200)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    private func wideLayout(_ proxy: GeometryProxy) -> some View {
        let topInset = Console.scrollTopInset(sidebarShown: state.showsSidebar)
        // 为页头、5 格指标条与段间分隔预留大致高度，让中间双栏与底部请求表自然吃满视口。
        let reservedUpperHeight: CGFloat = topInset + Console.contentBottomInset + 58 + 84 + sectionGap * 4
        let availableBody = max(440, proxy.size.height - reservedUpperHeight)
        let middleHeight = max(248, min(288, floor(availableBody * 0.50)))
        let recentMinHeight = max(190, availableBody - middleHeight)

        return ScrollView {
            VStack(alignment: .leading, spacing: sectionGap) {
                hero
                VStack(spacing: 0) {
                    DSDivider()
                    metricsRow(compact: false)
                        .fixedSize(horizontal: false, vertical: true)
                    DSDivider()
                }
                HStack(alignment: .top, spacing: 24) {
                    decodeChart
                        .frame(minHeight: middleHeight)
                    DSDivider(vertical: true)
                    VStack(alignment: .leading, spacing: 18) {
                        gatewaySection
                        DSDivider()
                        runtimeSection
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: sideColumnWidth)
                }
                .frame(minHeight: middleHeight)
                DSDivider()
                recentRequests
                    .frame(minHeight: recentMinHeight)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, topInset)
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
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
                        .font(DS.Font.prose(22, weight: .semibold))
                        .tracking(-0.35)
                        .foregroundStyle(DS.text)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    if let variant = modelTitleParts.variant {
                        Text(variant)
                            .font(DS.Font.mono(11, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(DS.rect(DS.Radius.sm).fill(DS.hover))
                            .fixedSize()
                    }
                }

                HStack(spacing: 8) {
                    DSStatusDot(
                        color: state.canChat ? DS.ok : (state.isModelBusy ? DS.warn : DS.text4),
                        live: state.canChat,
                        size: 6)
                    Text(runningText)
                        .font(DS.Font.prose(12.5))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                    Text("·")
                        .font(DS.Font.prose(12.5))
                        .foregroundStyle(DS.text4)
                    Text(verbatim: "127.0.0.1:\(state.port)")
                        .font(DS.Font.proseNumber(11.5))
                        .foregroundStyle(DS.text3)
                    Text("·")
                        .font(DS.Font.prose(12.5))
                        .foregroundStyle(DS.text4)
                    Text(L10n.format("%lld 个活跃会话", Int64(sessionCount)))
                        .font(DS.Font.proseNumber(11, weight: .medium))
                        .tracking(0.3)
                        .foregroundStyle(DS.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
                .buttonStyle(.ds(state.isRunning ? .danger : .primary))
                .disabled(engineToggleDisabled)
                .help(engineToggleHelp)

                ModelPickerButton(state: state, kind: .secondary) {
                    DSMenuTriggerLabel(
                        title: "切换模型",
                        systemImage: "square.stack.3d.up.fill",
                        kind: .secondary,
                        size: .regular
                    )
                }
                .disabled(state.isSwitchingModel)
            }
            .fixedSize()
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private var engineToggleDisabled: Bool {
        state.isSwitchingModel
            || state.serverState == .starting
            || state.serverState == .stopping
            || (!state.isRunning && (state.selectedModel.isEmpty || state.runtimeMissing != nil))
    }

    private var engineToggleHelp: String {
        if !state.isRunning {
            if state.runtimeMissing != nil { return L10n.t("引擎尚未安装") }
            if state.selectedModel.isEmpty { return L10n.t("请先选择模型") }
            return L10n.t("启动引擎")
        }
        return L10n.t("停止引擎")
    }

    // MARK: Connected 5-Cell KPI Strip

    @ViewBuilder
    private func metricsRow(compact: Bool) -> some View {
        if compact {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 16, alignment: .top)],
                alignment: .leading,
                spacing: 14
            ) {
                averageMetricCell
                contextMetricCell
                ttftMetricCell
                prefillMetricCell
                cacheMetricCell
            }
            .padding(.vertical, 4)
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
            .padding(.vertical, 2)
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
                .opacity(contextProgress > 0 ? 1 : 0.45)
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
                .font(DS.Font.prose(12, weight: .medium))
                .foregroundStyle(DS.text3)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(DS.Font.number(26, weight: .semibold))
                    .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(DS.Font.proseNumber(11.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing()
            }

            bottom()
                .frame(height: 5, alignment: .center)
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
        overviewSection(title: "总解码 · 最近 60 秒") {
            HStack(spacing: 8) {
                if let hovered = hoveredSample {
                    let secondsAgo = max(
                        0,
                        Int64(state.overviewChartEnd.timeIntervalSince(hovered.at).rounded()))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(rateText(hovered.value))
                            .font(DS.Font.proseNumber(13, weight: .semibold))
                            .foregroundStyle(DS.text)
                            .contentTransition(.numericText())
                        Text("tok/s")
                            .font(DS.Font.prose(10.5))
                            .foregroundStyle(DS.text3)
                    }
                    DSChip(
                        text: L10n.format("%lld 秒前", secondsAgo),
                        dot: DS.accent,
                        live: false)
                } else {
                    if chartRate > 0 {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(rateText(chartRate))
                                .font(DS.Font.proseNumber(13, weight: .semibold))
                                .foregroundStyle(DS.text)
                                .contentTransition(.numericText())
                            Text("tok/s")
                                .font(DS.Font.prose(10.5))
                                .foregroundStyle(DS.text3)
                        }
                    }
                    DSChip(text: speedChip.text, dot: speedChip.color, live: speedChip.live)
                }
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
                                .font(DS.Font.prose(12.5))
                                .foregroundStyle(DS.text3)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(DS.canvas.opacity(0.85), in: DS.rect(DS.Radius.sm))
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
                        if let hovered = hoveredSample {
                            RuleMark(x: .value("时间", hovered.at))
                                .foregroundStyle(DS.line3)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            PointMark(x: .value("时间", hovered.at), y: .value("tok/s", hovered.value))
                                .foregroundStyle(DS.accent)
                                .symbolSize(36)
                        }
                    }
                    .chartXScale(domain: chartWindow)
                    .chartYScale(domain: 0...(peak * 1.2))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(DS.line)
                            AxisValueLabel()
                                .font(DS.Font.proseNumber(10.5))
                                .foregroundStyle(DS.text3)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let plotAnchor = proxy.plotFrame else {
                                            hoveredChartDate = nil
                                            return
                                        }
                                        let plotFrame = geo[plotAnchor]
                                        let relativeX = location.x - plotFrame.origin.x
                                        guard relativeX >= 0, relativeX <= plotFrame.width,
                                            let date: Date = proxy.value(atX: relativeX)
                                        else {
                                            hoveredChartDate = nil
                                            return
                                        }
                                        hoveredChartDate = date
                                    case .ended:
                                        hoveredChartDate = nil
                                    }
                                }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hoveredSample: ThroughputSample? {
        guard let hoveredChartDate, !samples.isEmpty else { return nil }
        var best: ThroughputSample?
        var bestDelta: TimeInterval = .greatestFiniteMagnitude
        for sample in samples {
            let delta = abs(sample.at.timeIntervalSince(hoveredChartDate))
            if delta < bestDelta {
                bestDelta = delta
                best = sample
            }
        }
        return bestDelta <= 3.0 ? best : nil
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
        case .none: return (state.isRunning ? "等待" : "空闲", DS.text4, false)
        }
    }

    private var chartEmptyText: String {
        guard state.isRunning else { return "引擎未运行" }
        if chartFrozen { return "非流式请求无逐秒曲线" }
        return "等待样本"
    }

    private var chartGrid: some View {
        GeometryReader { proxy in
            let cols = max(4, Int((proxy.size.width / 88).rounded()))
            let rows = max(3, Int((proxy.size.height / 44).rounded()))
            let dx = proxy.size.width / CGFloat(cols)
            let dy = proxy.size.height / CGFloat(rows)
            Path { path in
                for col in 0...cols {
                    let x = CGFloat(col) * dx
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                }
                for row in 0...rows {
                    let y = CGFloat(row) * dy
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(DS.line, lineWidth: 1)
        }
    }

    // MARK: Gateway & Runtime

    private var gatewaySection: some View {
        overviewSection(title: "API 网关", subtitle: "OpenAI + Claude") {
            DSChip(
                text: L10n.t(gateway.isRunning ? "在线" : "离线"),
                dot: gateway.isRunning ? DS.ok : DS.text4,
                live: gateway.isRunning)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                endpointRow(name: "OpenAI", url: state.gatewayURL)
                DSDivider()
                endpointRow(name: "Claude", url: state.gatewayClaudeURL)

                if let failure = gateway.failureMessage, !gateway.isRunning {
                    Text(failure)
                        .font(DS.Font.prose(11.5))
                        .foregroundStyle(DS.warn)
                        .padding(.top, 6)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var runtimeSection: some View {
        overviewSection(title: "运行时", subtitle: state.activeEngine.displayName) {
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
                telemetryRow(label: "内存压力", value: memorySummaryText)
                DSDivider()
                telemetryRow(label: "温度", value: stats.map { L10n.t($0.thermalText) } ?? "—")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func overviewSection<Accessory: View, Content: View>(
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

    private var memorySummaryText: String {
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

    private func endpointRow(name: String, url: String) -> some View {
        HStack(spacing: 8) {
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
        }
        .padding(.vertical, 6)
    }

    private func telemetryRow(
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

    private var recentRequests: some View {
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

    private func requestRow(_ session: GatewayMeter.SessionSnapshot) -> some View {
        let decode = session.decodeRate
        let ttftText = session.ttftMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—"
        let decodeText = decode > 0 ? "\(Format.compact(decode)) tok/s" : "—"
        let live = session.state == .decode || session.state == .prefill
        let hovered = hoveredSessionID == session.id
        let dialect = session.dialect.isEmpty ? "API" : session.dialect
        let rawModel = session.model.isEmpty ? L10n.t("未命名") : session.model
        let modelDisplay = session.model.isEmpty ? L10n.t("未命名") : state.shortModelName(session.model)
        let summary = "\(dialect) · \(rawModel) · TTFT \(ttftText) · Decode \(decodeText) · Ctx \(Format.tokens(session.ctxTokens))"

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
