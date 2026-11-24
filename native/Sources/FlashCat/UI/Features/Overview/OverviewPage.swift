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
    @State private var checklistDismissed = false

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

    /// 激活引擎的颜色是页面上唯一的数据色：曲线、上下文进度与
    /// 「引擎实测」角标都跟着它走，换引擎时整页的重心跟着换。
    private var engineTint: Color { engineAccent(state.activeEngine) }

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

    private var averageBadge: String? {
        switch averageReading.origin {
        case .gatewayLive, .engineLive: return "LIVE"
        case .gatewayMean, .engineMean: return "AVG"
        default: return nil
        }
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
                pageHeader(compact: true)
                if showsChecklist { setupChecklist }
                modelHero(compact: true)
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
            .dsPageColumn()
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    private func wideLayout(_ proxy: GeometryProxy) -> some View {
        let topInset = Console.scrollTopInset(sidebarShown: state.showsSidebar)
        // 为页头、模型条与段间分隔预留大致高度，让中间双栏与底部请求表自然吃满视口。
        let reservedUpperHeight: CGFloat = topInset + Console.contentBottomInset + 58 + 84 + 72 + sectionGap * 4
        let availableBody = max(440, proxy.size.height - reservedUpperHeight)
        let middleHeight = max(248, min(288, floor(availableBody * 0.50)))
        let recentMinHeight = max(190, availableBody - middleHeight)

        return ScrollView {
            VStack(alignment: .leading, spacing: sectionGap) {
                pageHeader(compact: false)
                if showsChecklist { setupChecklist }
                modelHero(compact: false)
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
            .dsPageColumn()
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    // MARK: Page header & model strip

    /// 页名回到「概览」，模型名降为页内的当前模型条：切页时先看到自己在哪，
    /// 再看到现在跑的是什么。窄窗口省掉端口，把宽度留给引擎名与阶段。
    private func pageHeader(compact: Bool) -> some View {
        DSPageHeader(
            title: "概览",
            subtitle: compact
                ? state.activeEngine.displayName
                : "\(state.activeEngine.displayName) · 127.0.0.1:\(state.port)",
            status: DSPageStatus(stageTitle, color: statusColor, live: state.canChat)
        ) {
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
    }

    private var stageTitle: String {
        if state.serverState == .failed { return L10n.t("异常") }
        let stage = state.engineStageText
        return stage.isEmpty ? L10n.t(state.serverState.rawValue) : stage
    }

    private var statusColor: Color {
        if state.serverState == .failed { return DS.err }
        if state.canChat { return DS.ok }
        if state.isModelBusy || state.isRunning { return DS.warn }
        return DS.text4
    }

    /// 当前模型条：模型名 + 引擎/量化/体积 + 上下文占用。
    /// 宽版把上下文放在右侧；窄版放到名称下方并让进度条占满整行，
    /// 否则 150pt 的固定宽度会把模型名挤成 `Qwen3...ed-Speed`。
    @ViewBuilder
    private func modelHero(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ModelFamilyIcon(family: modelFamily, size: 30)
                    modelNameRow
                    Spacer(minLength: 0)
                }
                Text(modelMetaLine)
                    .font(DS.Font.proseNumber(11))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                contextBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .dsSurface(radius: DS.Radius.lg)
        } else {
            HStack(alignment: .center, spacing: 12) {
                ModelFamilyIcon(family: modelFamily, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    modelNameRow
                    Text(modelMetaLine)
                        .font(DS.Font.proseNumber(11))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                contextBlock
                    .frame(width: 132)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .dsSurface(radius: DS.Radius.lg)
        }
    }

    private var modelNameRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(modelTitleParts.name))
                .font(DS.Font.prose(20, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                .lineLimit(1)
                .truncationMode(.middle)

            if let variant = modelTitleParts.variant {
                Text(variant)
                    .font(DS.Font.mono(10.5, weight: .medium))
                    .foregroundStyle(DS.text2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(DS.rect(DS.Radius.sm).fill(DS.hover))
                    .fixedSize()
            }
        }
    }

    private var contextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(L10n.t("当前上下文"))
                    .font(DS.Font.prose(10.5))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Text(verbatim: contextFractionText)
                    .font(DS.Font.proseNumber(12, weight: .medium))
                    .foregroundStyle(state.overviewContextUsedTokens > 0 ? DS.text : DS.text3)
            }
            DSMeter(value: contextProgress, tint: engineTint)
                .opacity(contextProgress > 0 ? 1 : 0.45)
        }
    }

    private var modelFamily: ModelFamily {
        ModelFamily.resolve(id: state.selectedModel, hint: state.selectedModelInfo?.family)
    }

    // MARK: First-run checklist

    private var activeEngineHasLocalModels: Bool {
        state.libraryEntries(for: state.activeEngine).contains(where: \.installed)
    }

    private var showsChecklist: Bool {
        !checklistDismissed && !state.isRunning
            && (state.runtimeMissing != nil || !activeEngineHasLocalModels)
    }

    /// 首次使用的三步清单：装引擎 → 下模型 → 启动。三步都完成或用户关掉后不再出现。
    private var setupChecklist: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                checklistStep(
                    index: 1, title: "安装引擎", detail: "先在引擎页装一个运行时",
                    done: state.runtimeMissing == nil
                ) { state.section = .engines }
                checklistArrow
                checklistStep(
                    index: 2, title: "下载模型", detail: "在模型库下载一个能跑的权重",
                    done: activeEngineHasLocalModels
                ) { state.section = .models }
                checklistArrow
                checklistStep(
                    index: 3, title: "启动引擎", detail: "装好后回到这里启动",
                    done: false
                ) { state.toggleService() }
                Spacer(minLength: 8)
                dismissChecklistButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.t("三步开跑"))
                        .font(DS.Font.prose(12.5, weight: .medium))
                        .foregroundStyle(DS.text2)
                    Spacer()
                    dismissChecklistButton
                }
                checklistStep(
                    index: 1, title: "安装引擎", detail: "先在引擎页装一个运行时",
                    done: state.runtimeMissing == nil
                ) { state.section = .engines }
                checklistStep(
                    index: 2, title: "下载模型", detail: "在模型库下载一个能跑的权重",
                    done: activeEngineHasLocalModels
                ) { state.section = .models }
                checklistStep(
                    index: 3, title: "启动引擎", detail: "装好后回到这里启动",
                    done: false
                ) { state.toggleService() }
            }
            .padding(14)
        }
        .dsSurface(radius: DS.Radius.lg)
    }

    private var checklistArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DS.text4)
    }

    private var dismissChecklistButton: some View {
        Button {
            checklistDismissed = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.text3)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(L10n.t("关闭三步清单"))
        .accessibilityLabel(L10n.t("关闭三步清单"))
    }

    private func checklistStep(
        index: Int,
        title: String,
        detail: String,
        done: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(done ? DS.ok.opacity(0.16) : DS.hover)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.ok)
                    } else {
                        Text(verbatim: "\(index)")
                            .font(DS.Font.mono(10, weight: .semibold))
                            .foregroundStyle(DS.text2)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t(title))
                        .font(DS.Font.prose(12, weight: .medium))
                        .foregroundStyle(done ? DS.text3 : DS.text)
                    Text(L10n.t(detail))
                        .font(DS.Font.prose(10.5))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var modelMetaLine: String {
        var parts = [state.activeEngine.displayName]
        if let info = state.selectedModelInfo {
            if let quant = info.quantization, !quant.isEmpty { parts.append(quant) }
            if info.bytes > 0 { parts.append(Format.size(info.bytes)) }
        }
        if state.selectedModel.isEmpty { parts.append(L10n.t("从模型库选择一个模型")) }
        return parts.joined(separator: " · ")
    }

    private var contextFractionText: String {
        let used = Format.tokens(state.overviewContextUsedTokens)
        guard let ceiling = state.contextWindowCeiling else { return used }
        return "\(used) / \(Format.tokensShort(ceiling))"
    }

    // MARK: Controls

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

    // MARK: KPI strip
    //
    // 只留三格回答「这台机器现在多快」：平均解码、首字延迟、预填充。
    // 上下文占用搬进模型条（它说的是「装了多少」，不是速度），缓存命中率
    // 搬进右栏的运行时事实表——五格等宽指标里它和 hero 抢同一层注意力。

    @ViewBuilder
    private func metricsRow(compact: Bool) -> some View {
        if compact {
            // 窄窗口不用自适应网格：2+1 会拖出一大块空白，改成三行紧凑读数。
            VStack(spacing: 0) {
                compactMetricRow(
                    title: "平均解码", value: rateText(averageRate),
                    unit: averageRate > 0 ? "tok/s" : nil,
                    badge: averageBadge, emphasized: true)
                DSDivider()
                compactMetricRow(
                    title: "首字延迟", value: ttftText,
                    unit: ttftText == "—" ? nil : "ms",
                    badge: nil, emphasized: false)
                DSDivider()
                compactMetricRow(
                    title: "预填充", value: prefillText,
                    unit: prefillText == "—" ? nil : "tok/s",
                    badge: nil, emphasized: false)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                averageMetricCell
                    .frame(maxWidth: .infinity)
                DSDivider(vertical: true)
                ttftMetricCell
                    .frame(width: 220)
                DSDivider(vertical: true)
                prefillMetricCell
                    .frame(width: 220)
            }
            .padding(.vertical, 2)
        }
    }

    private func compactMetricRow(
        title: String,
        value: String,
        unit: String?,
        badge: String?,
        emphasized: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.t(title))
                .font(DS.Font.prose(12.5, weight: emphasized ? .medium : .regular))
                .foregroundStyle(emphasized ? DS.text2 : DS.text3)
            Spacer(minLength: 8)
            if let badge {
                DSSourceBadge(text: badge, live: badge == "LIVE")
            }
            Text(value)
                .font(DS.Font.number(emphasized ? 26 : 20, weight: .semibold))
                .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(DS.Font.proseNumber(11))
                    .foregroundStyle(DS.text3)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: emphasized ? 48 : 40)
    }

    private var averageMetricCell: some View {
        kpiCell(
            title: "平均解码",
            value: rateText(averageRate),
            unit: averageRate > 0 ? "tok/s" : nil,
            valueSize: 34,
            trailing: {
                HStack(spacing: 6) {
                    if let averageBadge {
                        DSSourceBadge(text: averageBadge, live: averageBadge == "LIVE")
                    }
                    DSSparkline(
                        values: Array(samples.suffix(24).map(\.value)),
                        color: engineTint,
                        floor: max(peak, 1)
                    )
                    .frame(width: 56, height: 18)
                }
            })
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

    private func kpiCell<Trailing: View, Bottom: View>(
        title: String,
        value: String,
        unit: String?,
        valueSize: CGFloat = 26,
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
                    .font(DS.Font.number(valueSize, weight: .semibold))
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
                        dot: engineTint,
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
                if samples.isEmpty && !state.isRunning {
                    lastRunCard
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if samples.isEmpty {
                    ZStack {
                        chartGrid
                        VStack(spacing: 7) {
                            Image(systemName: "waveform.path.ecg")
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
                                        colors: [engineTint.opacity(0.16), .clear],
                                        startPoint: .top, endPoint: .bottom)
                                )
                            LineMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(engineTint)
                                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        }
                        if samples.count == 1, let only = samples.first {
                            PointMark(x: .value("时间", only.at), y: .value("tok/s", only.value))
                                .foregroundStyle(engineTint)
                                .symbolSize(26)
                        }
                        if let hovered = hoveredSample {
                            RuleMark(x: .value("时间", hovered.at))
                                .foregroundStyle(DS.line3)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            PointMark(x: .value("时间", hovered.at), y: .value("tok/s", hovered.value))
                                .foregroundStyle(engineTint)
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
        case .engineLive: return ("引擎", engineTint, true)
        case .none: return (state.isRunning ? "等待" : "空闲", DS.text4, false)
        }
    }

    private var chartEmptyText: String {
        guard state.isRunning else { return "引擎未运行" }
        if chartFrozen { return "非流式请求无逐秒曲线" }
        return "等待样本"
    }

    private struct LastRun {
        let model: String
        let rate: Double
        let tokens: Int
        let date: Date?
        let failed: Bool
    }

    /// 上次运行：优先读网关会话表（本次启动内的请求），没有就退回本地对话
    /// 历史里最近一条完成的回答——重启应用之后仍然说得出「上次跑得怎么样」。
    private var lastRun: LastRun? {
        let sessions = GatewayMeter.shared.snapshot(limit: 32)
        if let session = sessions.last(where: {
            $0.state == .done || $0.state == .failed
        }) {
            return LastRun(
                model: session.model,
                rate: session.decodeRate,
                tokens: session.completionTokens,
                date: session.lastActivity,
                failed: session.state == .failed)
        }

        let messages = chat.threads.flatMap(\.messages).filter { message in
            guard message.role == "assistant", let model = message.model, !model.isEmpty else {
                return false
            }
            return !message.content.isEmpty || message.imagePath != nil
        }
        guard
            let message = messages.max(by: {
                ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
            })
        else { return nil }
        return LastRun(
            model: message.model ?? "",
            rate: message.tokensPerSecond ?? 0,
            tokens: message.usage.map { $0.promptTokens + $0.completionTokens } ?? 0,
            date: message.createdAt,
            failed: message.interrupted)
    }

    /// 停引擎时，曲线位置换成一张「上次运行」卡：模型、速度、tokens、时间，
    /// 外加启动按钮。空网格留给「等待样本」，不留给「今天什么都没跑」。
    private var lastRunCard: some View {
        ViewThatFits(in: .horizontal) {
            lastRunWideCard
            lastRunCompactCard
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsSurface(radius: DS.Radius.lg)
    }

    private var lastRunHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.text3)
            Text(L10n.t("上次运行"))
                .font(DS.Font.prose(12, weight: .medium))
                .foregroundStyle(DS.text3)
            if lastRun?.failed == true {
                DSChip(text: "失败", dot: DS.err, tint: DS.err)
            }
        }
    }

    private var lastRunWideCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                lastRunHeader
                if let run = lastRun {
                    Text(run.model.isEmpty ? L10n.t("未记录模型") : state.shortModelName(run.model))
                        .font(DS.Font.prose(19, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 14) {
                        lastRunMetric("解码", run.rate > 0 ? Format.compact(run.rate) : "—", run.rate > 0 ? "tok/s" : nil)
                        DSDivider(vertical: true).frame(height: 26)
                        lastRunMetric("输出", run.tokens > 0 ? "\(run.tokens)" : "—", run.tokens > 0 ? "tokens" : nil)
                        DSDivider(vertical: true).frame(height: 26)
                        lastRunMetric("时间", run.date.map(Format.relative) ?? "—", nil)
                    }
                    Text(L10n.t("启动后这里会显示 60 秒实时解码曲线。"))
                        .font(DS.Font.prose(10.5))
                        .foregroundStyle(DS.text4)
                } else {
                    lastRunEmptyText
                }
            }
            Spacer(minLength: 12)
            startEngineButton(size: .regular, labeled: true)
        }
    }

    private var lastRunCompactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                lastRunHeader
                Spacer(minLength: 6)
                startEngineButton(size: .small, labeled: true)
            }
            if let run = lastRun {
                Text(run.model.isEmpty ? L10n.t("未记录模型") : state.shortModelName(run.model))
                    .font(DS.Font.prose(16, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 10) {
                    lastRunMetric(
                        "解码", run.rate > 0 ? Format.compact(run.rate) : "—", run.rate > 0 ? "tok/s" : nil,
                        valueSize: 13, labelSize: 9)
                    DSDivider(vertical: true).frame(height: 22)
                    lastRunMetric(
                        "输出", run.tokens > 0 ? "\(run.tokens)" : "—", run.tokens > 0 ? "tokens" : nil, valueSize: 13,
                        labelSize: 9)
                    DSDivider(vertical: true).frame(height: 22)
                    lastRunMetric("时间", run.date.map(Format.relative) ?? "—", nil, valueSize: 13, labelSize: 9)
                }
                Text(L10n.t("启动后这里会显示 60 秒实时解码曲线。"))
                    .font(DS.Font.prose(10))
                    .foregroundStyle(DS.text4)
            } else {
                lastRunEmptyText
            }
        }
    }

    private var lastRunEmptyText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("还没有运行记录"))
                .font(DS.Font.prose(16, weight: .medium))
                .foregroundStyle(DS.text2)
            Text(L10n.t("启动引擎后，这里会留下第一轮的模型、速度与 tokens。"))
                .font(DS.Font.prose(11.5))
                .foregroundStyle(DS.text3)
        }
    }

    private func startEngineButton(size: DSButtonStyle.Size, labeled: Bool) -> some View {
        Button {
            state.toggleService()
        } label: {
            if labeled {
                Label(L10n.t("启动引擎"), systemImage: "play.fill")
            } else {
                Image(systemName: "play.fill")
            }
        }
        .buttonStyle(.ds(.primary, size: size))
        .disabled(engineToggleDisabled)
        .help(engineToggleHelp)
    }

    private func lastRunMetric(
        _ label: String,
        _ value: String,
        _ unit: String?,
        valueSize: CGFloat = 15,
        labelSize: CGFloat = 10
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.t(label))
                .font(DS.Font.prose(labelSize))
                .foregroundStyle(DS.text3)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(DS.Font.number(valueSize, weight: .semibold))
                    .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(DS.Font.prose(labelSize))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
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
    private var snippets: GatewaySnippets {
        GatewaySnippets(
            openAIBase: state.gatewayURL,
            claudeBase: state.gatewayClaudeURL,
            model: state.selectedModel)
    }

    // MARK: Recent clients

    /// 网关只监听回环，`User-Agent` 是唯一能区分「谁在用」的线索。
    private var recentClients: [GatewayClientSummary] {
        GatewayClientSummary.group(GatewayMeter.shared.snapshot(limit: 32))
    }

    private func dialectLabel(_ value: String) -> String {
        switch value {
        case "openai": return "OpenAI"
        case "claude": return "Claude"
        case "chat": return L10n.t("对话")
        case "image": return L10n.t("图像")
        case "video": return L10n.t("视频")
        default: return value.isEmpty ? "—" : value
        }
    }

    private var clientsList: some View {
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

    private var runtimeSection: some View {
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

    private func endpointRow(name: String, url: String, curl: String, python: String) -> some View {
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
