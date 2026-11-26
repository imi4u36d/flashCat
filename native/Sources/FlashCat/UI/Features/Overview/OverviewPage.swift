// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 概览：页头、当前模型与上下文、实时指标与 60 秒解码曲线、接口与运行状态、最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var metrics: MetricsStore
    @ObservedObject var gateway = GatewayController.shared
    /// 壳层在布局这一拍量到的详情区尺寸。宽窄版式直接由它决定，不再先渲染
    /// 一版再用 `onGeometryChange` 纠正——切页时那一拍纠正就是整页上下跳。
    let pageSize: CGSize

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var hoveredSessionID: Int?
    @State var hoveredChartDate: Date?
    @State var checklistDismissed = false
    /// 最近请求的筛选：0 全部 / 1 仅 chat / 2 仅 openai。
    @State var requestFilterIndex = 0
    /// 复制回执只落在被点的那一行：接口行、端口格、请求行共用一个「谁刚复制」键。
    @State var copiedKey: String?
    @State var copyResetTask: Task<Void, Never>?
    /// 未启动时的用量盘点：统计窗口只换聚合范围，不改版式。
    @State var usageRange: UsageSummary.Window = .all
    /// 会话列表来自 `ChatStore`，概览不直接观察它（否则流式 token 会带着
    /// 整页重绘），只接线程列表的变化来刷新用量盘点。
    @State var usageThreads: [ChatThread] = []

    private var layoutKey: LayoutKey {
        LayoutKey(
            isCompact: pageSize.width < Console.compactContentWidth,
            isExtraWide: pageSize.width >= 1440,
            height: (pageSize.height / 2).rounded() * 2)
    }

    /// 记录一次复制回执；1.4 秒后清空。键相同的控件显示对勾。
    func flashCopied(_ key: String) {
        copyResetTask?.cancel()
        withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copiedKey = key }
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : DS.Motion.snappy) { copiedKey = nil }
        }
    }

    struct LayoutKey: Equatable {
        var isCompact: Bool
        var isExtraWide: Bool
        /// 页面可用高度（标题栏以下）。垂直节奏只认这一个数，不认宽度。
        var height: CGFloat
    }

    var isLiveDashboard: Bool {
        state.isRunning || state.isSwitchingModel
    }

    /// 只读本机会话聚合出的用量。首次渲染时 `ChatStore` 还没送出线程列表，
    /// 回退到 `AppState.threads`，避免闪一帧空状态。
    var usageSummary: UsageSummary {
        UsageSummary.make(
            threads: usageThreads.isEmpty ? state.threads : usageThreads,
            window: usageRange)
    }

    var stats: ServerStats? { state.stats }
    var samples: [ThroughputSample] { metrics.overviewThroughput(window: 60) }
    var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    var modelTitle: String {
        state.selectedModelInfo?.shortName
            ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    var engineTint: Color { engineAccent(state.activeEngine) }

    var averageReading: MetricReading { metrics.averageDecodeReading(isRunning: state.isRunning) }
    var averageRate: Double { averageReading.value ?? 0 }

    var chartRate: Double { samples.last?.value ?? 0 }
    var chartFrozen: Bool { metrics.throughputFrozenAt != nil }

    var prefillReading: MetricReading { metrics.prefillReading(isRunning: state.isRunning) }
    var ttftReading: TTFTReading { metrics.ttftReading(isRunning: state.isRunning) }
    var cacheHitReading: MetricReading { metrics.cacheHitReading(isRunning: state.isRunning) }

    func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
    }

    struct CanvasMetrics {
        let layout: LayoutKey

        var isCompact: Bool { layout.isCompact }
        /// 高一点的窗口才放大垂直节奏。只看高度：侧栏显隐改的是宽度，
        /// 一旦垂直度量跟着宽度走，收放侧栏就会让整页上下跳。
        var isRoomy: Bool { layout.height >= 900 }
        var viewportHeight: CGFloat { layout.height }
        var maxWidth: CGFloat { 1480 }
        var horizontalPadding: CGFloat {
            if isCompact { return Console.compactContentPadding }
            return layout.isExtraWide ? 28 : Console.contentPadding
        }
        /// 顶部留白固定 16pt，与其余控制台页面同一口径。
        var topInset: CGFloat { DS.Space.lg }
        var bottomInset: CGFloat { isRoomy ? 24 : Console.contentBottomInset }
        var sectionGap: CGFloat { isRoomy ? 16 : Console.pageSectionGap }
        var columnGap: CGFloat { isRoomy ? 14 : 12 }
        var cardPadding: CGFloat { isRoomy ? 16 : 14 }
        /// 顶部读数条。常规高度压到 140pt，一屏还要同时放下曲线和请求表。
        var topKpiHeight: CGFloat { isRoomy ? 148 : 140 }

        /// 「最近请求」固定展示的条数：常规 5 条、宽屏 6 条。
        /// 条数固定，卡片高度不随请求进来逐条长高，整页不会跳。
        var recentRequestLimit: Int { isRoomy ? 6 : 5 }

        /// 最近请求卡的固定开销：上下内边距 + 标题行 + 标题到表头的间距 + 表头。
        var recentChromeHeight: CGFloat { cardPadding * 2 + 22 + 8 + 26 }

        /// 一条请求行连同分隔线。
        var recentRowHeight: CGFloat { 35 }

        /// 定长请求表占用的高度。
        var recentCardHeight: CGFloat {
            recentChromeHeight + CGFloat(recentRequestLimit) * recentRowHeight
        }

        /// 曲线卡的最小可用高度；再矮就退回可滚动布局。
        var chartMinHeight: CGFloat { 220 }

        /// 主区上下两半（曲线 / 最近请求）共用的目标高度。
        func mainRowHeight(in viewportHeight: CGFloat) -> CGFloat {
            let reserved =
                topInset + bottomInset
                + topKpiHeight + sectionGap * 2
            return viewportHeight - reserved
        }

        /// 运行中的宽版能否固定一屏：两半各要放得下曲线和定长请求表。
        /// 放不下就退回可滚动布局，宁可滚动，也不把内容裁在窗口底边上。
        var fitsDashboardInViewport: Bool {
            let shared = max(chartMinHeight, recentCardHeight)
            let reserved =
                topInset + bottomInset
                + topKpiHeight + sectionGap * 2
            return viewportHeight >= reserved + shared * 2 + columnGap
        }
    }

    var body: some View {
        let canvas = CanvasMetrics(layout: layoutKey)
        Group {
            if canvas.isCompact {
                compactLayout(canvas)
            } else if isLiveDashboard && canvas.fitsDashboardInViewport {
                pinnedDashboard(canvas)
            } else if !isLiveDashboard && canvas.viewportHeight >= 760 {
                usageDashboard(canvas)
            } else {
                wideLayout(canvas)
            }
        }
        .onReceive(state.chat.$threads) { threads in
            usageThreads = threads
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: isLiveDashboard)
        .toolbar {
            ToolbarItem(id: DSToolbarSlot.title, placement: .navigation) {
                DSToolbarPageTitle(
                    title: "概览")
                    .padding(.leading, 15)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.anchor, placement: .principal) {
                DSToolbarAnchor()
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(id: DSToolbarSlot.actions, placement: .primaryAction) {
                DSToolbarActionRow(
                    state: state,
                    compact: layoutKey.isCompact,
                    showsSpeed: false
                ) {
                    overviewToolbarActions
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    @ViewBuilder
    private var overviewToolbarActions: some View {
        if layoutKey.isCompact {
            ModelPickerButton(state: state, kind: .secondary) { _ in
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.accent)
            }
            .disabled(state.isSwitchingModel)
            .help(L10n.t("切换模型"))

            Button {
                state.toggleService()
            } label: {
                if state.isRunning {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.dangerText)
                        .frame(width: 7, height: 7)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8.5, weight: .bold))
                }
            }
            .buttonStyle(
                OverviewTintActionStyle(tint: state.isRunning ? DS.dangerText : DS.ok))
            .disabled(engineToggleDisabled)
            .help(engineToggleHelp)
        } else {
            modelPickerButton
            engineButton
        }
    }

    func compactLayout(_ canvas: CanvasMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: canvas.sectionGap) {
                if showsChecklist { setupChecklist }
                if isLiveDashboard {
                    modelHeroCard
                    compactMetricsCard
                    decodeChart(cardPadding: canvas.cardPadding)
                        .frame(minHeight: 280)
                    gatewayCard(cardPadding: canvas.cardPadding)
                    runtimeCard(cardPadding: canvas.cardPadding)
                    recentRequestsCard(
                        maxRows: canvas.recentRequestLimit,
                        cardPadding: canvas.cardPadding)
                } else {
                    usageIdle(usageSummary, canvas: canvas, compact: true)
                }
            }
            .padding(.horizontal, canvas.horizontalPadding)
            .padding(.top, canvas.topInset)
            .padding(.bottom, canvas.bottomInset)
            .dsPageColumn(maxWidth: canvas.maxWidth)
        }
        .scrollIndicators(.never)
    }

    /// 宽版内容。`pinned` 为真时，主区左栏由「曲线 + 最近请求」上下五五分成，
    /// 右栏继续放接口与引擎状态，整页正好铺满一屏；否则保持自然高度，
    /// 由外层 `ScrollView` 兜底。
    @ViewBuilder
    func dashboardContent(_ canvas: CanvasMetrics, pinned: Bool, recentRows: Int) -> some View {
        if showsChecklist { setupChecklist }

        if isLiveDashboard {
            SplitRow(fraction: 5.0 / 12.0, spacing: canvas.columnGap) {
                modelHeroCard
            } trailing: {
                HStack(spacing: canvas.columnGap) {
                    averageMetricCard
                    ttftMetricCard
                    prefillMetricCard
                }
            }
            .frame(height: canvas.topKpiHeight)

            let mainHeight =
                pinned ? canvas.mainRowHeight(in: canvas.viewportHeight) : nil
            let halfHeight =
                mainHeight.map { max(canvas.chartMinHeight, ($0 - canvas.columnGap) / 2) }

            SplitRow(fraction: 0.64, spacing: canvas.columnGap) {
                VStack(spacing: canvas.columnGap) {
                    if let halfHeight {
                        decodeChart(cardPadding: canvas.cardPadding)
                            .frame(height: halfHeight)
                    } else {
                        decodeChart(cardPadding: canvas.cardPadding)
                            .frame(minHeight: canvas.chartMinHeight)
                    }
                    recentRequestsCard(
                        maxRows: recentRows,
                        cardPadding: canvas.cardPadding,
                        alwaysVisible: pinned)
                        .frame(height: halfHeight)
                }
            } trailing: {
                VStack(spacing: canvas.columnGap) {
                    gatewayCard(cardPadding: canvas.cardPadding)
                    runtimeCard(cardPadding: canvas.cardPadding)
                }
                .frame(maxHeight: pinned ? .infinity : nil, alignment: .top)
            }
            .frame(height: mainHeight)
        } else {
            usageIdle(usageSummary, canvas: canvas, compact: false)
        }
    }

    func wideLayout(_ canvas: CanvasMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: canvas.sectionGap) {
                dashboardContent(
                    canvas,
                    pinned: false,
                    recentRows: canvas.recentRequestLimit)
            }
            .padding(.horizontal, canvas.horizontalPadding)
            .padding(.top, canvas.topInset)
            .padding(.bottom, canvas.bottomInset)
            .dsPageColumn(maxWidth: canvas.maxWidth)
        }
        .scrollIndicators(.never)
    }

    /// 运行中的宽版：页头、顶部读数、主区刚好铺满一屏。
    /// 主区左栏上下五五分成：上半是 60 秒曲线，下半是定长最近请求表。
    func pinnedDashboard(_ canvas: CanvasMetrics) -> some View {
        VStack(alignment: .leading, spacing: canvas.sectionGap) {
            dashboardContent(
                canvas,
                pinned: true,
                recentRows: canvas.recentRequestLimit)
        }
        .padding(.horizontal, canvas.horizontalPadding)
        .padding(.top, canvas.topInset)
        .padding(.bottom, canvas.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsPageColumn(maxWidth: canvas.maxWidth)
    }
}
