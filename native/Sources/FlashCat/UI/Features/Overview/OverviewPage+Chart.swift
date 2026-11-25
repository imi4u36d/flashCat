// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Decode Chart

    func decodeChart(cardPadding: CGFloat = 14) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chartHeader
            Group {
                if samples.isEmpty {
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
                        .dsSubcard(radius: 8)
                    }
                } else {
                    Chart {
                        ForEach(samples) { sample in
                            AreaMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [engineTint.opacity(0.24), engineTint.opacity(0)],
                                        startPoint: .top, endPoint: .bottom)
                                )
                            LineMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                                .interpolationMethod(.monotone)
                                .foregroundStyle(engineTint)
                                .lineStyle(StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
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
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(DS.chartGrid)
                            AxisValueLabel()
                                .font(DS.Font.proseNumber(10.5))
                                .foregroundStyle(DS.text3)
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
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

                                if let hovered = hoveredSample, let plotAnchor = proxy.plotFrame {
                                    chartTooltipOverlay(
                                        hovered,
                                        plotFrame: geo[plotAnchor],
                                        proxy: proxy,
                                        size: geo.size)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overviewCard(padding: cardPadding)
    }

    var chartHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.t("总解码 · 最近 60 秒"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(L10n.t("悬停查看精确采样"))
                .font(.system(size: 11))
                .foregroundStyle(DS.text4)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(rateText(hoveredSample?.value ?? chartRate))
                    .font(DS.Font.number(16, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(DS.text)
                    .contentTransition(.numericText())
                Text("tok/s")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text3)
            }
            speedPill
        }
    }

    var speedPill: some View {
        HStack(spacing: 5) {
            DSStatusDot(color: speedChip.color, live: speedChip.live, size: 5)
            Text(L10n.t(speedChip.text))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(speedChip.live ? speedChip.color : DS.text2)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .dsGlassPill()
    }

    func chartTooltipOverlay(
        _ sample: ThroughputSample,
        plotFrame: CGRect,
        proxy: ChartProxy,
        size: CGSize
    ) -> some View {
        let x = proxy.position(forX: sample.at) ?? 0
        let y = proxy.position(forY: sample.value) ?? 0
        return chartTooltip(sample)
            .position(
                x: min(max(plotFrame.origin.x + x, 74), max(74, size.width - 74)),
                y: max(32, plotFrame.origin.y + y - 34))
    }

    func chartTooltip(_ sample: ThroughputSample) -> some View {
        let secondsAgo = max(0, Int(metrics.overviewChartEnd.timeIntervalSince(sample.at).rounded()))
        let clock = sample.at.formatted(date: .omitted, time: .standard)
        let age = secondsAgo == 0 ? L10n.t("刚刚") : "-\(secondsAgo)s"
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(clock) (\(age))")
                .font(DS.Font.mono(9.5))
                .foregroundStyle(DS.text3)
            HStack(spacing: 4) {
                Circle()
                    .fill(engineTint)
                    .frame(width: 4, height: 4)
                Text(rateText(sample.value))
                    .font(DS.Font.number(12, weight: .bold))
                    .foregroundStyle(DS.text)
                Text("tok/s")
                    .font(.system(size: 9.5))
                    .foregroundStyle(DS.text3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize()
        .dsFloating(radius: 10)
        .allowsHitTesting(false)
    }

    var hoveredSample: ThroughputSample? {
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

    var chartWindow: ClosedRange<Date> {
        let end = metrics.overviewChartEnd
        return end.addingTimeInterval(-60)...end
    }

    var speedChip: (text: String, color: Color, live: Bool) {
        if chartFrozen {
            return samples.isEmpty ? ("无样本", DS.text4, false) : ("已冻结", DS.text4, false)
        }
        switch speedOrigin {
        case .gatewayLive: return ("网关", DS.info, true)
        case .none: return (state.isRunning ? "等待" : "空闲", DS.text4, false)
        }
    }

    var chartEmptyText: String {
        if state.isSwitchingModel {
            return state.switchStage.isEmpty ? "正在加载模型…" : state.switchStage
        }
        guard state.isRunning else { return "引擎未运行" }
        if metrics.chartEmptyIsNonStreamed { return "非流式请求无逐秒曲线" }
        return "等待样本"
    }

    var chartGrid: some View {
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
}
