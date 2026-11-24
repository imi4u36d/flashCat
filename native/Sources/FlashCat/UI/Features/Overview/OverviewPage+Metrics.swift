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

    // MARK: KPI strip
    //
    // 只留三格回答「这台机器现在多快」：平均解码、首字延迟、预填充。
    // 上下文占用搬进模型条（它说的是「装了多少」，不是速度），缓存命中率
    // 搬进右栏的运行时事实表——五格等宽指标里它和 hero 抢同一层注意力。

    @ViewBuilder
    func metricsRow(compact: Bool) -> some View {
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

    func compactMetricRow(
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

    var averageMetricCell: some View {
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

    var ttftMetricCell: some View {
        kpiCell(
            title: "首字延迟",
            value: ttftText,
            unit: ttftText == "—" ? nil : "ms")
    }

    var prefillMetricCell: some View {
        kpiCell(
            title: "预填充",
            value: prefillText,
            unit: prefillText == "—" ? nil : "tok/s")
    }

    func kpiCell<Trailing: View, Bottom: View>(
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
