// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Charts
import FlashCatCore
import FlashCatKit
import SwiftUI

extension OverviewPage {
    // MARK: Controls

    var engineToggleDisabled: Bool {
        state.isSwitchingModel
            || state.serverState == .starting
            || state.serverState == .stopping
            || (!state.isRunning && (state.selectedModel.isEmpty || state.runtimeMissing != nil))
    }

    var engineToggleHelp: String {
        if !state.isRunning {
            if state.runtimeMissing != nil { return L10n.t("引擎尚未安装") }
            if state.selectedModel.isEmpty { return L10n.t("请先选择模型") }
            return L10n.t("启动引擎")
        }
        return L10n.t("停止引擎")
    }

    // MARK: KPI cards
    //
    // 三格回答「这台机器现在多快」：平均解码、首字延迟、预填充。
    // 上下文占用在模型卡里，缓存命中率在右栏的引擎事实里。

    var averageMetricCard: some View {
        kpiCard(
            title: "平均解码",
            value: rateText(averageRate),
            unit: averageRate > 0 ? "tok/s" : nil
        ) {
            if let averageBadge {
                OverviewBadge(text: averageBadge, tint: DS.accent)
            }
        } visual: {
            OverviewSparkline(
                values: Array(samples.suffix(16).map(\.value)),
                color: engineTint)
                .frame(height: 24)
        }
    }

    var ttftMetricCard: some View {
        kpiCard(
            title: "首字延迟",
            value: ttftText,
            unit: ttftText == "—" ? nil : "ms"
        ) {
            if ttftText != "—" {
                OverviewBadge(
                    text: (ttftReading.milliseconds ?? 0) <= 250 ? "极速" : "正常",
                    tint: DS.ok,
                    dot: true)
            }
        } visual: {
            OverviewLatencyBar(milliseconds: ttftReading.milliseconds ?? 0)
        }
    }

    var prefillMetricCard: some View {
        kpiCard(
            title: "预填充",
            value: prefillText,
            unit: prefillText == "—" ? nil : "tok/s"
        ) {
            OverviewBadge(text: "稳定", tint: DS.accentBlue, icon: "arrow.up.right")
        } visual: {
            OverviewMicroBars()
        }
    }

    func kpiCard<Badge: View, Visual: View>(
        title: String,
        value: String,
        unit: String?,
        @ViewBuilder badge: () -> Badge,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(L10n.t(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(DS.Font.number(28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)
            visual()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overviewCard()
    }

    // MARK: Compact stack

    var compactMetricsCard: some View {
        VStack(spacing: 0) {
            compactMetricRow(
                title: "平均解码",
                value: rateText(averageRate),
                unit: averageRate > 0 ? "tok/s" : nil,
                badge: averageBadge,
                badgeTint: DS.accent
            ) {
                OverviewSparkline(
                    values: Array(samples.suffix(12).map(\.value)),
                    color: engineTint)
                    .frame(width: 88, height: 22)
            }
            DSDivider()
            compactMetricRow(
                title: "首字延迟",
                value: ttftText,
                unit: ttftText == "—" ? nil : "ms",
                badge: ttftText == "—" ? nil : ((ttftReading.milliseconds ?? 0) <= 250 ? "极速" : "正常"),
                badgeTint: DS.ok
            ) {
                OverviewLatencyBar(milliseconds: ttftReading.milliseconds ?? 0)
                    .frame(width: 112)
            }
            DSDivider()
            compactMetricRow(
                title: "预填充",
                value: prefillText,
                unit: prefillText == "—" ? nil : "tok/s",
                badge: prefillText == "—" ? nil : "稳定",
                badgeTint: DS.accentBlue
            ) {
                OverviewMicroBars()
                    .frame(width: 88)
            }
        }
        .overviewCard(padding: 0)
    }

    func compactMetricRow<Visual: View>(
        title: String,
        value: String,
        unit: String?,
        badge: String?,
        badgeTint: Color,
        @ViewBuilder visual: () -> Visual
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.text3)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(DS.Font.number(24, weight: .bold))
                        .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.text3)
                    }
                    if let badge {
                        OverviewBadge(text: badge, tint: badgeTint)
                            .padding(.leading, 2)
                    }
                }
            }
            Spacer(minLength: 8)
            visual()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
    }

    // MARK: Metric formatting

    var contextProgress: Double {
        guard let ceiling = state.contextWindowCeiling, ceiling > 0 else { return 0 }
        return min(1, max(0, Double(state.overviewContextUsedTokens) / Double(ceiling)))
    }

    var ttftText: String {
        guard let value = ttftReading.milliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    var prefillText: String {
        guard let value = prefillReading.value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    var cacheHitText: String {
        guard let value = cacheHitReading.value else { return "—" }
        return "\(Int((value * 100).rounded()))"
    }
}
