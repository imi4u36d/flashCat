// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

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

    var averageMetricCard: some View {
        kpiCard(
            title: "平均解码",
            value: rateText(averageRate),
            unit: averageRate > 0 ? "tok/s" : nil
        ) {
            if let averageBadge {
                OverviewBadge(text: averageBadge, tint: DS.accent)
            }
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
        }
    }

    var prefillMetricCard: some View {
        let hasValue = prefillText != "—"
        let isLivePrefill = prefillReading.origin == .engineLive
        return kpiCard(
            title: "预填充",
            value: prefillText,
            unit: hasValue ? "tok/s" : nil
        ) {
            if hasValue {
                OverviewBadge(
                    text: isLivePrefill ? "LIVE" : "稳定",
                    tint: isLivePrefill ? DS.ok : DS.accentBlue,
                    dot: isLivePrefill,
                    icon: isLivePrefill ? nil : "arrow.up.right")
            }
        }
    }

    func kpiCard<Badge: View>(
        title: String,
        value: String,
        unit: String?,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(L10n.t(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge()
            }

            Spacer(minLength: 0)

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
            )
            DSDivider()
            compactMetricRow(
                title: "首字延迟",
                value: ttftText,
                unit: ttftText == "—" ? nil : "ms",
                badge: ttftText == "—" ? nil : ((ttftReading.milliseconds ?? 0) <= 250 ? "极速" : "正常"),
                badgeTint: DS.ok
            )
            DSDivider()
            compactMetricRow(
                title: "预填充",
                value: prefillText,
                unit: prefillText == "—" ? nil : "tok/s",
                badge: prefillText == "—" ? nil : (prefillReading.origin == .engineLive ? "LIVE" : "稳定"),
                badgeTint: prefillReading.origin == .engineLive ? DS.ok : DS.accentBlue
            )
        }
        .overviewCard(padding: 0)
    }

    func compactMetricRow(
        title: String,
        value: String,
        unit: String?,
        badge: String?,
        badgeTint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Text(L10n.t(title))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let badge {
                    OverviewBadge(text: badge, tint: badgeTint)
                        .padding(.trailing, 4)
                }
                Text(value)
                    .font(DS.Font.number(22, weight: .bold))
                    .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
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
