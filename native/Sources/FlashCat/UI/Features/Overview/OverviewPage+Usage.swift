// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - 未启动模型：本机用量盘点
//
// 引擎没跑的时候，概览不再摆一张空的实时仪表盘，而是回答三个问题：
// 一共用了多少（Token / 会话 / 消息）、哪些模型在干活、最近哪天还在用。
// 数据全部来自本机已保存的会话（`UsageSummary`），不联网、不写盘。
// 引擎一启动，页面仍回到原来的实时仪表盘。

extension OverviewPage {
    // MARK: Container

    @ViewBuilder
    func usageIdle(_ summary: UsageSummary, canvas: CanvasMetrics, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: canvas.sectionGap) {
            usageTopRow(summary, window: $usageRange)

            if let failure = state.failureMessage, !failure.isEmpty, !state.isRunning {
                failureBanner(failure)
            }

            if summary.sessions == 0 {
                if hasAnyChatHistory {
                    usageWindowEmptyCard()
                } else {
                    usageEmptyCard(compact: compact)
                }
            } else {
                usageHero(summary, compact: compact)
                if compact {
                    usageLedgerCard(summary, cardPadding: canvas.cardPadding)
                    usageHeatCard(summary, cardPadding: canvas.cardPadding)
                    usageInterfaceCard(cardPadding: canvas.cardPadding)
                } else {
                    SplitRow(fraction: 0.62, spacing: canvas.columnGap) {
                        usageLedgerCard(summary, cardPadding: canvas.cardPadding)
                    } trailing: {
                        VStack(spacing: canvas.columnGap) {
                            usageHeatCard(summary, cardPadding: canvas.cardPadding)
                            usageInterfaceCard(cardPadding: canvas.cardPadding)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
    }

    /// 宽版未启动态的「铺满一屏」布局：页头、读数、账本/日历按窗口高度
    /// 分配，内容直接铺到窗口底缘。窗口太矮时退回 `wideLayout` 的滚动版，
    /// 宁可滚动也不裁掉内容。
    func usageDashboard(_ canvas: CanvasMetrics) -> some View {
        let summary = usageSummary
        return VStack(alignment: .leading, spacing: canvas.sectionGap) {
            if showsChecklist { setupChecklist }

            usageTopRow(summary, window: $usageRange)

            if let failure = state.failureMessage, !failure.isEmpty, !state.isRunning {
                failureBanner(failure)
            }

            if summary.sessions == 0 {
                Spacer(minLength: 0)
                if hasAnyChatHistory {
                    usageWindowEmptyCard()
                } else {
                    usageEmptyCard(compact: false)
                }
                Spacer(minLength: 0)
            } else {
                usageHero(summary, compact: false)

                GeometryReader { proxy in
                    SplitRow(fraction: 0.62, spacing: canvas.columnGap) {
                        usageLedgerCard(summary, cardPadding: canvas.cardPadding)
                    } trailing: {
                        VStack(spacing: canvas.columnGap) {
                            usageHeatCard(summary, cardPadding: canvas.cardPadding)
                            usageInterfaceCard(cardPadding: canvas.cardPadding)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .padding(.horizontal, canvas.horizontalPadding)
        .padding(.top, canvas.topInset)
        .padding(.bottom, canvas.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dsPageColumn(maxWidth: canvas.maxWidth)
    }

    // MARK: Top row

    func usageTopRow(
        _ summary: UsageSummary,
        window: Binding<UsageSummary.Window>
    ) -> some View {
        let title = HStack(spacing: 8) {
            Text(L10n.t("本机用量"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(verbatim: usageScopeText(summary))
                .font(.system(size: 11))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
        }

        let range = NativeSegmented(
            selection: window,
            options: UsageSummary.Window.allCases,
            labels: ["7 天", "30 天", "全部"],
            width: 172
        )
        .disabled(summary.sessions == 0)
        .opacity(summary.sessions == 0 ? 0.55 : 1)

        return HStack(spacing: 12) {
            title
            Spacer(minLength: 12)
            range
        }
        .frame(minHeight: 28)
    }

    func usageScopeText(_ summary: UsageSummary) -> String {
        switch summary.window {
        case .week:
            return L10n.t("近 7 天")
        case .month:
            return L10n.t("近 30 天")
        case .all:
            guard let first = summary.firstActivity else { return L10n.t("还没有记录") }
            return L10n.format("自 %@ 起累计", usageDayText(first))
        }
    }

    func usageDayText(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Hero

    func usageHero(_ summary: UsageSummary, compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 16) {
                    usageHeroLeft(summary)
                    DSDivider()
                    usageReadouts(summary)
                }
            } else {
                HStack(alignment: .top, spacing: 22) {
                    usageHeroLeft(summary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    DSDivider(vertical: true)
                    usageReadouts(summary)
                        .frame(width: 420)
                        .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: compact ? nil : 160, alignment: .topLeading)
        .dsSurface(radius: DS.Radius.card)
    }

    func usageHeroLeft(_ summary: UsageSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: UsageFormat.tokens(summary.totalTokens))
                .font(DS.Font.number(46, weight: .semibold))
                .tracking(-1.4)
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: "tokens")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.text3)
        }
    }

    func usageReadouts(_ summary: UsageSummary) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                usageReadout(
                    "会话",
                    value: UsageFormat.count(summary.sessions),
                    unit: nil)
                DSDivider(vertical: true)
                    .padding(.vertical, 6)
                usageReadout(
                    "消息",
                    value: UsageFormat.count(summary.messages),
                    unit: nil
                )
                .padding(.leading, 20)
            }

            DSDivider()
                .padding(.vertical, 12)

            HStack(alignment: .top, spacing: 0) {
                usageReadout(
                    "活跃天数",
                    value: UsageFormat.count(summary.activeDays),
                    unit: nil)
                DSDivider(vertical: true)
                    .padding(.vertical, 6)
                usageReadout(
                    "平均解码",
                    value: UsageFormat.rate(summary.averageTokensPerSecond),
                    unit: summary.averageTokensPerSecond == nil ? nil : "tok/s"
                )
                .padding(.leading, 20)
            }
        }
    }

    func usageReadout(
        _ title: String,
        value: String,
        unit: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t(title))
                .font(DS.Font.mono(9.5, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(DS.text3)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(DS.Font.number(21, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(value == "—" ? DS.text3 : DS.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let unit {
                    Text(verbatim: unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.text3)
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Model ledger

    func usageLedgerCard(_ summary: UsageSummary, cardPadding: CGFloat) -> some View {
        let engines = usageModelEngines()
        let dominant = summary.models.filter { $0.sessions > 0 }
        let leaders = Array((dominant.isEmpty ? summary.models : dominant).prefix(3))
        let leaderNames = Set(leaders.map(\.name))
        let rest = summary.models.filter { !leaderNames.contains($0.name) }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.t("模型用量"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 6)
                Text(
                    verbatim: summary.models.isEmpty
                        ? L10n.t("还没有记录")
                        : L10n.format("%@ 个模型 · 按 Token 排序", "\(summary.models.count)")
                )
                .font(.system(size: 11))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
            }
            .padding(.bottom, 8)

            if summary.models.isEmpty {
                Text(L10n.t("这段会话里还没有落盘的 token 用量。"))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.text3)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(leaders.enumerated()), id: \.element.id) { index, model in
                    if index > 0 {
                        DSDivider()
                    }
                    UsageModelRow(
                        model: model,
                        displayName: state.shortModelName(model.name),
                        isCurrent: state.selectedModel == model.name,
                        isSelectable: engines[model.name] != nil
                            && state.selectedModel != model.name,
                        barOpacity: [1.0, 0.55, 0.34][min(index, 2)],
                        action: {
                            if let engine = engines[model.name] {
                                state.applyModelFromAnyEngine(model.name, engine: engine)
                            }
                        })
                }

                if !rest.isEmpty {
                    DSDivider()
                    UsageModelRow(
                        model: usageAggregate(rest),
                        displayName: L10n.format("其他 %@ 个模型", "\(rest.count)"),
                        isCurrent: false,
                        isSelectable: false,
                        barOpacity: 0.20,
                        action: {})
                }

                Rectangle()
                    .fill(DS.line2)
                    .frame(height: 1)
                    .padding(.top, 2)

                HStack(spacing: 12) {
                    Text(L10n.t("合计"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: L10n.format("%@ 段", "\(summary.sessions)"))
                        .frame(width: 52, alignment: .trailing)
                    Text(verbatim: UsageFormat.tokens(summary.totalTokens))
                        .frame(width: 72, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: UsageFormat.rate(summary.averageTokensPerSecond))
                            .font(DS.Font.number(12, weight: .semibold))
                            .foregroundStyle(DS.text)
                        Text(verbatim: "tok/s")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.text3)
                    }
                    .frame(width: 56, alignment: .trailing)
                }
                .font(DS.Font.number(12, weight: .semibold))
                .foregroundStyle(DS.text)
                .padding(.top, 12)
            }

        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .overviewCard(padding: cardPadding)
    }

    /// 账本行能不能点，取决于模型是否还装在某个已安装引擎里；
    /// 和模型选择菜单用同一份来源，跨引擎的模型也能切过去。
    func usageModelEngines() -> [String: EngineID] {
        var map: [String: EngineID] = [:]
        for engine in EngineCatalog.allIDs where state.engineIsInstalled(engine) {
            for model in state.engineModels(for: engine)
            where !model.hidden && !model.helper && !ModelLibraryEntry.isDraftModel(model.id) {
                map[model.id] = engine
            }
        }
        return map
    }

    func usageAggregate(_ models: [UsageSummary.Model]) -> UsageSummary.Model {
        UsageSummary.Model(
            name: "other",
            sessions: models.reduce(0) { $0 + $1.sessions },
            tokens: models.reduce(0) { $0 + $1.tokens },
            share: models.reduce(0) { $0 + $1.share },
            tokensPerSecond: nil)
    }

    // MARK: Heatmap

    func usageHeatCard(_ summary: UsageSummary, cardPadding: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("活跃日历"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.text)
            UsageHeatmap(days: summary.days)
            UsageHeatLegend()
                .padding(.leading, 20)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overviewCard(padding: cardPadding)
    }

    // MARK: Gateway card

    func usageInterfaceCard(cardPadding: CGFloat) -> some View {
        let copied = copiedKey == "usage-endpoint"
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("本机接口"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DS.text)

            Text(verbatim: usageGatewayAddress)
                .font(DS.Font.mono(11))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                UsageBadge(text: "未启动", tint: DS.text3)
                Spacer(minLength: 8)
                Button {
                    state.copy(state.gatewayURL)
                    flashCopied("usage-endpoint")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9.5, weight: .medium))
                        Text(copied ? L10n.t("已复制") : L10n.t("复制地址"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(copied ? DS.ok : DS.text2)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(DS.rect(7).fill(DS.surface))
                    .overlay(DS.rect(7).strokeBorder(DS.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(L10n.t("复制接口地址"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overviewCard(padding: cardPadding)
    }

    var usageGatewayAddress: String {
        state.gatewayURL.replacingOccurrences(of: "http://", with: "")
    }

    // MARK: Empty state

    /// 本机有历史，但当前时间窗里没有会话：不要退回首启文案，
    /// 只说明这个窗口是空的，并给一个切回「全部」的入口。
    func usageWindowEmptyCard() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("这个时间窗里还没有对话"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(L10n.t("把范围切回「全部」，就能看到更早的本机用量。"))
                .font(.system(size: 12.5))
                .foregroundStyle(DS.text3)
            Button {
                usageRange = .all
            } label: {
                Text(L10n.t("查看全部"))
            }
            .buttonStyle(.dsSecondary)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overviewCard(padding: 22)
    }

    func usageEmptyCard(compact: Bool) -> some View {
        let copy: String =
            state.selectedModel.isEmpty
            ? L10n.t("先在模型库下载一个模型；启动引擎后，这里会按消息落盘的 Token 用量、模型与时间聚合出整页统计。全部在本机计算，不上传任何内容。")
            : L10n.t("启动引擎后，这里会按消息落盘的 Token 用量、模型与时间聚合出整页统计。全部在本机计算，不上传任何内容。")

        let actions = HStack(spacing: 8) {
            Button {
                state.section = .models
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.accent)
                    Text(L10n.t("去模型库"))
                }
            }
            .buttonStyle(.dsSecondary)
            engineButton
        }

        let copyBlock = VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.format("%@ 段会话 · %@ 条消息", "0", "0"))
                .font(DS.Font.mono(9.5, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(DS.text3)
            Text(L10n.t("从第一段对话开始累计"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(verbatim: copy)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.text3)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            actions
                .padding(.top, 8)
        }

        let stats = usageEmptyStats()

        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 18) {
                    copyBlock
                    stats
                }
            } else {
                HStack(alignment: .center, spacing: 22) {
                    copyBlock
                    Spacer(minLength: 12)
                    stats
                        .frame(width: 300)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overviewCard(padding: 22)
    }

    func usageEmptyStats() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("启动后统计"))
                .font(DS.Font.mono(9.5, weight: .medium))
                .tracking(0.9)
                .foregroundStyle(DS.text3)
                .padding(.bottom, 8)
            ForEach(Array(["会话", "消息", "Token 总量", "活跃天数", "平均解码"].enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    DSDivider()
                }
                HStack(spacing: 8) {
                    Text(L10n.t(title))
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.text3)
                    Spacer(minLength: 8)
                    Text(verbatim: "—")
                        .font(DS.Font.number(12, weight: .medium))
                        .foregroundStyle(DS.text4)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsWell(radius: 12)
    }
}

// MARK: - Heat legend

private struct UsageHeatLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text(L10n.t("少"))
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color(level))
                    .frame(width: 9, height: 9)
            }
            Text(L10n.t("多"))
        }
        .font(.system(size: 9.5))
        .foregroundStyle(DS.text3)
    }

    private func color(_ level: Int) -> Color {
        switch level {
        case 0: return DS.pillFill
        case 1: return DS.accent.opacity(0.16)
        case 2: return DS.accent.opacity(0.34)
        case 3: return DS.accent.opacity(0.58)
        default: return DS.accent
        }
    }
}

// MARK: - Small badge

private struct UsageBadge: View {
    var text: String
    var tint: Color

    var body: some View {
        Text(L10n.t(text))
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(DS.rect(5).fill(tint.opacity(0.10)))
            .fixedSize()
    }
}

// MARK: - Ledger row

/// 模型账本的一行。装在当前引擎里的模型行可点，直接切过去；
/// 已经不在这台机器上的历史模型只留账目，不做成死按钮。
private struct UsageModelRow: View {
    let model: UsageSummary.Model
    let displayName: String
    let isCurrent: Bool
    let isSelectable: Bool
    let barOpacity: Double
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        if isSelectable {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .help(L10n.format("切到 %@", displayName))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(verbatim: displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isCurrent {
                        UsageBadge(text: "当前", tint: DS.accent)
                    }
                }
                OverviewMiniBar(value: model.share, tint: DS.accent.opacity(barOpacity))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: L10n.format("%@ 段", "\(model.sessions)"))
                .font(.system(size: 11))
                .foregroundStyle(DS.text3)
                .frame(width: 52, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: UsageFormat.tokens(model.tokens))
                    .font(DS.Font.number(12, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: UsageFormat.percent(model.share))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 72, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: UsageFormat.rate(model.tokensPerSecond))
                    .font(DS.Font.number(12, weight: .semibold))
                    .foregroundStyle(model.tokensPerSecond == nil ? DS.text3 : DS.text)
                Text(verbatim: "tok/s")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(DS.rect(8).fill(hovering && isSelectable ? DS.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Heatmap

/// 20 周 × 7 天的小日历。格子的深浅只表示「当天有几段对话」，
/// 不按 Token 加权——同一天里一段长回答和一段短问答看起来一样深。
private struct UsageHeatmap: View {
    let days: [UsageSummary.Day]
    var weeks = 20
    var cell: CGFloat = 12
    var gap: CGFloat = 3

    private var calendar: Calendar { .current }

    private struct MonthMark: Identifiable {
        let week: Int
        let month: Int
        var id: Int { week }
    }

    var body: some View {
        let today = calendar.startOfDay(for: Date())
        let weekdayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let weekStart = calendar.date(byAdding: .day, value: -weekdayOffset, to: today) ?? today
        let start = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: weekStart) ?? weekStart
        let sessionCounts = Dictionary(
            days.map { (calendar.startOfDay(for: $0.date), $0.sessions) },
            uniquingKeysWith: { first, _ in first })
        let marks = monthMarks(from: start)
        let gridWidth = CGFloat(weeks) * cell + CGFloat(weeks - 1) * gap
        let visibleDays = sessionCounts.keys.filter { $0 >= start && $0 <= today }.count

        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(verbatim: weekdayLabel(row))
                        .font(.system(size: 9))
                        .foregroundStyle(DS.text3)
                        .frame(width: 12, height: cell)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(width: gridWidth, height: 14)
                    ForEach(marks) { mark in
                        Text(verbatim: "\(mark.month) 月")
                            .font(.system(size: 9.5))
                            .foregroundStyle(DS.text3)
                            .offset(x: CGFloat(mark.week) * (cell + gap))
                    }
                }

                HStack(spacing: gap) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                cellView(
                                    date(start, week: week, row: row),
                                    today: today,
                                    sessionCounts: sessionCounts)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("近 20 周活跃日历，%@ 天有记录", "\(visibleDays)"))
    }

    private func date(_ start: Date, week: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: week * 7 + row, to: start) ?? start
    }

    private func weekdayLabel(_ row: Int) -> String {
        switch row {
        case 0: return "一"
        case 2: return "三"
        case 4: return "五"
        default: return ""
        }
    }

    @ViewBuilder
    private func cellView(
        _ date: Date,
        today: Date,
        sessionCounts: [Date: Int]
    ) -> some View {
        let count = sessionCounts[calendar.startOfDay(for: date)] ?? 0
        let square = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(heatColor(count))
            .frame(width: cell, height: cell)

        if date > today {
            square.opacity(0)
        } else if count > 0 {
            square.help(heatHelp(date, count: count))
        } else {
            square
        }
    }

    private func heatColor(_ count: Int) -> Color {
        switch count {
        case 0: return DS.pillFill
        case 1: return DS.accent.opacity(0.16)
        case 2: return DS.accent.opacity(0.34)
        case 3: return DS.accent.opacity(0.58)
        default: return DS.accent
        }
    }

    private func heatHelp(_ date: Date, count: Int) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return L10n.format("%@ 月 %@ 日 · %@ 段对话", "\(parts.month ?? 0)", "\(parts.day ?? 0)", "\(count)")
    }

    private func monthMarks(from start: Date) -> [MonthMark] {
        var marks: [MonthMark] = []
        var lastMonth = -1
        var lastWeek = -10
        for week in 0..<weeks {
            guard let monday = calendar.date(byAdding: .day, value: week * 7, to: start) else {
                continue
            }
            let month = calendar.component(.month, from: monday)
            if month != lastMonth {
                lastMonth = month
                if week == 0 || week - lastWeek >= 3 {
                    marks.append(MonthMark(week: week, month: month))
                    lastWeek = week
                }
            }
        }
        return marks
    }
}
