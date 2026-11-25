// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 概览：页头、当前模型与上下文、实时指标与 60 秒解码曲线、接口与运行状态、最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var metrics: MetricsStore
    @ObservedObject var gateway = GatewayController.shared

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var hoveredSessionID: Int?
    @State var hoveredChartDate: Date?
    @State var checklistDismissed = false
    /// 最近请求的筛选：0 全部 / 1 仅 chat / 2 仅 openai。
    @State var requestFilterIndex = 0
    @State private var layoutKey = LayoutKey(
        isCompact: false, isSpacious: false, isExtraWide: false, height: 800)

    struct LayoutKey: Equatable {
        var isCompact: Bool
        var isSpacious: Bool
        var isExtraWide: Bool
        var height: CGFloat
    }

    var isLiveDashboard: Bool {
        state.isRunning || state.isSwitchingModel
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
    var speedOrigin: SpeedOrigin { metrics.currentSpeedOrigin(isRunning: state.isRunning) }

    var prefillReading: MetricReading { metrics.prefillReading(isRunning: state.isRunning) }
    var ttftReading: TTFTReading { metrics.ttftReading(isRunning: state.isRunning) }
    var cacheHitReading: MetricReading { metrics.cacheHitReading(isRunning: state.isRunning) }

    func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
    }

    var averageBadge: String? {
        switch averageReading.origin {
        case .gatewayMean: return "AVG"
        default: return nil
        }
    }

    struct CanvasMetrics {
        let layout: LayoutKey
        let sidebarShown: Bool

        var isCompact: Bool { layout.isCompact }
        var isSpacious: Bool { layout.isSpacious }
        var maxWidth: CGFloat { 1480 }
        var horizontalPadding: CGFloat {
            if isCompact { return Console.compactContentPadding }
            return layout.isExtraWide ? 28 : Console.contentPadding
        }
        var topInset: CGFloat {
            let base = Console.scrollTopInset(sidebarShown: sidebarShown)
            return (sidebarShown && isSpacious) ? max(base, 20) : base
        }
        var bottomInset: CGFloat { isSpacious ? 24 : Console.contentBottomInset }
        var sectionGap: CGFloat { isSpacious ? 16 : Console.pageSectionGap }
        var columnGap: CGFloat { isSpacious ? 14 : 12 }
        var cardPadding: CGFloat { isSpacious ? 16 : 14 }
        var topKpiHeight: CGFloat { isSpacious ? 148 : 140 }

        var liveMiddleMinHeight: CGFloat {
            let reserved = topInset + bottomInset + Console.pageHeaderHeight + topKpiHeight + sectionGap * 3 + 110
            let dynamic = layout.height - reserved
            return min(460, max(320, dynamic))
        }

        var recentRequestLimit: Int { isSpacious ? 8 : 6 }
    }

    var body: some View {
        let canvas = CanvasMetrics(layout: layoutKey, sidebarShown: state.showsSidebar)
        Group {
            if canvas.isCompact {
                compactLayout(canvas)
            } else {
                wideLayout(canvas)
            }
        }
        .onGeometryChange(for: LayoutKey.self) { proxy in
            LayoutKey(
                isCompact: proxy.size.width < Console.compactContentWidth,
                isSpacious: proxy.size.width >= 1340,
                isExtraWide: proxy.size.width >= 1440,
                height: (proxy.size.height / 8).rounded() * 8)
        } action: { newKey in
            layoutKey = newKey
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: isLiveDashboard)
    }

    func compactLayout(_ canvas: CanvasMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: canvas.sectionGap) {
                pageHeader(compact: true)
                if showsChecklist { setupChecklist }
                modelHeroCard
                if isLiveDashboard {
                    compactMetricsCard
                    decodeChart(cardPadding: canvas.cardPadding)
                        .frame(minHeight: 280)
                    gatewayCard(cardPadding: canvas.cardPadding)
                    runtimeCard(cardPadding: canvas.cardPadding)
                } else {
                    gatewayCard(cardPadding: canvas.cardPadding)
                }
                recentRequestsIfPresent(maxRows: canvas.recentRequestLimit, cardPadding: canvas.cardPadding)
            }
            .padding(.horizontal, canvas.horizontalPadding)
            .padding(.top, canvas.topInset)
            .padding(.bottom, canvas.bottomInset)
            .dsPageColumn(maxWidth: canvas.maxWidth)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    func wideLayout(_ canvas: CanvasMetrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: canvas.sectionGap) {
                pageHeader(compact: false)
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

                    SplitRow(fraction: 0.64, spacing: canvas.columnGap) {
                        decodeChart(cardPadding: canvas.cardPadding)
                    } trailing: {
                        VStack(spacing: canvas.columnGap) {
                            gatewayCard(cardPadding: canvas.cardPadding)
                            runtimeCard(cardPadding: canvas.cardPadding)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(minHeight: canvas.liveMiddleMinHeight)
                } else {
                    modelHeroCard
                    gatewayCard(cardPadding: canvas.cardPadding)
                }

                recentRequestsIfPresent(maxRows: canvas.recentRequestLimit, cardPadding: canvas.cardPadding)
            }
            .padding(.horizontal, canvas.horizontalPadding)
            .padding(.top, canvas.topInset)
            .padding(.bottom, canvas.bottomInset)
            .dsPageColumn(maxWidth: canvas.maxWidth)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }
}
