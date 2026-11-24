// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 概览：线性/工作台风——顶部模型控制带、5 格连通 KPI 指标条、60 秒吞吐图表 + API 网关、底部最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    @ObservedObject var gateway = GatewayController.shared

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var hoveredSessionID: Int?
    @State var hoveredChartDate: Date?
    @State var checklistDismissed = false

    var stats: ServerStats? { state.stats }
    var samples: [ThroughputSample] { state.overviewThroughput(window: 60) }
    var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    var modelTitle: String {
        state.selectedModelInfo?.shortName
            ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    var modelTitleParts: (name: String, variant: String?) {
        let title = modelTitle
        guard let colon = title.lastIndex(of: ":") else { return (title, nil) }
        let name = String(title[title.startIndex..<colon])
        let variant = String(title[title.index(after: colon)...])
        guard !name.isEmpty, !variant.isEmpty, variant.count <= 16 else { return (title, nil) }
        return (name, variant)
    }

    /// 激活引擎的颜色是页面上唯一的数据色：曲线、上下文进度与
    /// 「引擎实测」角标都跟着它走，换引擎时整页的重心跟着换。
    var engineTint: Color { engineAccent(state.activeEngine) }

    var averageReading: MetricReading { state.averageDecodeReading }
    var averageRate: Double { averageReading.value ?? 0 }

    var chartRate: Double { samples.last?.value ?? 0 }
    var chartFrozen: Bool { state.throughputFrozenAt != nil }
    var speedOrigin: SpeedOrigin { state.speedOrigin }

    var prefillReading: MetricReading { state.prefillReading }
    var ttftReading: TTFTReading { state.ttftReading }
    var cacheHitReading: MetricReading { state.cacheHitReading }

    func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
    }

    var averageBadge: String? {
        switch averageReading.origin {
        case .gatewayLive, .engineLive: return "LIVE"
        case .gatewayMean, .engineMean: return "AVG"
        default: return nil
        }
    }

    let sectionGap: CGFloat = 20
    let sideColumnWidth: CGFloat = 336

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < Console.compactContentWidth {
                compactLayout
            } else {
                wideLayout(proxy)
            }
        }
    }

    var compactLayout: some View {
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

    func wideLayout(_ proxy: GeometryProxy) -> some View {
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
}
