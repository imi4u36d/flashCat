// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 概览：macOS Liquid Glass 的 12 栏 bento——页头、当前模型 + 三格读数、
/// 60 秒解码曲线 + 接口 / 引擎双卡、底部最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    @ObservedObject var gateway = GatewayController.shared

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var hoveredSessionID: Int?
    @State var hoveredChartDate: Date?
    @State var checklistDismissed = false
    /// 最近请求的筛选：0 全部 / 1 仅 chat / 2 仅 openai。
    @State var requestFilterIndex = 0

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

    let sectionGap: CGFloat = 14
    let contentPadding: CGFloat = 20

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
                modelHeroCard
                compactMetricsCard
                decodeChart
                    .frame(minHeight: 300)
                gatewayCard
                runtimeCard
                recentRequests
                    .frame(minHeight: 200)
            }
            .padding(.horizontal, 16)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, 20)
            .dsPageColumn()
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }

    func wideLayout(_ proxy: GeometryProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: sectionGap) {
                pageHeader(compact: false)
                if showsChecklist { setupChecklist }

                SplitRow(fraction: 5.0 / 12.0, spacing: 12) {
                    modelHeroCard
                } trailing: {
                    HStack(spacing: 12) {
                        averageMetricCard
                        ttftMetricCard
                        prefillMetricCard
                    }
                }
                .frame(height: 152)

                SplitRow(fraction: 0.64, spacing: 12) {
                    decodeChart
                } trailing: {
                    VStack(spacing: 12) {
                        gatewayCard
                        runtimeCard
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(minHeight: 372)

                recentRequests
                    .frame(minHeight: 196)
            }
            .padding(.horizontal, contentPadding)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .padding(.bottom, 20)
            .dsPageColumn()
        }
        .scrollIndicators(.never)
        .overlay(alignment: .top) {
            WindowDragArea().frame(height: state.showsSidebar ? DS.Space.lg : DS.Layout.titlebarHeight)
        }
    }
}
