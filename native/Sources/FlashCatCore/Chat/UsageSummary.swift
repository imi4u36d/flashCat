// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 概览「未启动模型」那一屏的用量盘点。
///
/// 全部从本机已保存的会话聚合：Token 来自每条 assistant 消息落盘的
/// `usage`，模型来自消息的 `model`，活跃日历来自 `createdAt`。不联网、
/// 不新增存储，也不碰运行时的 `MetricsStore`。
package struct UsageSummary: Equatable, Sendable {
    /// 统计窗口。`all` 仍然是「本机保留的会话」——`ChatHistory.limit`
    /// 之外的旧会话已经被裁掉，这里不会假装它们还在。
    package enum Window: String, CaseIterable, Identifiable, Sendable {
        case week
        case month
        case all

        package var id: String { rawValue }

        /// 含今天在内向前数多少天；`all` 不设截止。
        package var dayCount: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    /// 日历上的一天：当天有对话的会话数（一个会话一天只算一次）。
    package struct Day: Identifiable, Equatable, Sendable {
        package let date: Date
        package let sessions: Int
        package var id: Date { date }

        package init(date: Date, sessions: Int) {
            self.date = date
            self.sessions = sessions
        }
    }

    /// 一个模型的账目。`sessions` 是「归给它」的会话数：一个会话只算一次，
    /// 归给消息最多的模型；`tokens` 则按消息逐条累加，所以会话数与
    /// Token 占比不必成比例。
    package struct Model: Identifiable, Equatable, Sendable {
        package let name: String
        package let sessions: Int
        package let tokens: Int
        package let share: Double
        package let tokensPerSecond: Double?
        package var id: String { name }

        package init(
            name: String,
            sessions: Int,
            tokens: Int,
            share: Double,
            tokensPerSecond: Double?
        ) {
            self.name = name
            self.sessions = sessions
            self.tokens = tokens
            self.share = share
            self.tokensPerSecond = tokensPerSecond
        }
    }

    package var window: Window
    package var sessions: Int
    package var messages: Int
    package var userMessages: Int
    package var assistantMessages: Int
    package var promptTokens: Int
    package var completionTokens: Int
    /// 窗口内最长连续有对话的天数。
    package var longestStreak: Int
    package var activeDays: Int
    /// 最近 30 天的会话数。窗口切到 7 天时它仍是 30 天口径，
    /// 用来说明「这段用量在近一个月里占多少」。
    package var recentSessions: Int
    /// 按 completionTokens 加权的平均解码速度；没有打点时为 nil。
    package var averageTokensPerSecond: Double?
    package var firstActivity: Date?
    /// 全量模型账目，按 Token 降序；界面取前几行、其余合并。
    package var models: [Model]
    /// 本机保留的全部活跃日，升序。日历不随窗口切换，始终画这一段。
    package var days: [Day]

    package var totalTokens: Int { promptTokens + completionTokens }

    package var averageTokensPerSession: Int {
        sessions > 0 ? totalTokens / sessions : 0
    }

    package var hasSessions: Bool { sessions > 0 }

    /// 一条消息都没有：首启或只下载了模型还没聊过。
    package var isEmpty: Bool { sessions == 0 }

    package static func make(
        threads: [ChatThread],
        window: Window,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> UsageSummary {
        let today = calendar.startOfDay(for: now)
        let cutoff: Date? = window.dayCount.flatMap {
            calendar.date(byAdding: .day, value: -($0 - 1), to: today)
        }
        let recentCutoff = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        var userMessages = 0
        var assistantMessages = 0
        var promptTokens = 0
        var completionTokens = 0
        var activeDayKeys: Set<Date> = []
        var allDaySessions: [Date: Set<String>] = [:]
        var windowSessions: Set<String> = []
        var recentSessions: Set<String> = []
        var firstActivity: Date?

        var threadModelCounts: [String: [String: Int]] = [:]
        var modelTokens: [String: Int] = [:]
        var modelRateSum: [String: Double] = [:]
        var modelRateWeight: [String: Double] = [:]
        var rateSum = 0.0
        var rateWeight = 0.0

        for thread in threads {
            for message in thread.messages {
                let isChat = message.role == "user" || message.role == "assistant"
                guard isChat else { continue }

                let createdAt = message.createdAt
                if let createdAt {
                    if firstActivity == nil || createdAt < firstActivity! {
                        firstActivity = createdAt
                    }
                    let day = calendar.startOfDay(for: createdAt)
                    allDaySessions[day, default: []].insert(thread.id)
                    if createdAt >= recentCutoff {
                        recentSessions.insert(thread.id)
                    }
                }

                let inWindow: Bool
                switch window {
                case .all:
                    inWindow = true
                case .week, .month:
                    if let cutoff, let createdAt {
                        inWindow = createdAt >= cutoff
                    } else {
                        inWindow = false
                    }
                }
                guard inWindow else { continue }
                windowSessions.insert(thread.id)

                if message.role == "user" {
                    userMessages += 1
                    if let createdAt {
                        activeDayKeys.insert(calendar.startOfDay(for: createdAt))
                    }
                    continue
                }

                assistantMessages += 1
                if let createdAt {
                    activeDayKeys.insert(calendar.startOfDay(for: createdAt))
                }

                let model = message.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hasModel = !model.isEmpty
                if hasModel {
                    threadModelCounts[thread.id, default: [:]][model, default: 0] += 1
                }

                guard let usage = message.usage else { continue }
                let tokens = usage.promptTokens + usage.completionTokens
                promptTokens += usage.promptTokens
                completionTokens += usage.completionTokens
                if hasModel {
                    modelTokens[model, default: 0] += tokens
                }

                // 速度只在有输出 token 时才有意义：图片轮的 usage 可能只
                // 有估算值、没有真正的解码过程，拿它进加权会把均值拉偏。
                guard usage.completionTokens > 0,
                    let tokensPerSecond = message.tokensPerSecond,
                    tokensPerSecond > 0
                else { continue }
                let weight = Double(usage.completionTokens)
                rateSum += tokensPerSecond * weight
                rateWeight += weight
                if hasModel {
                    modelRateSum[model, default: 0] += tokensPerSecond * weight
                    modelRateWeight[model, default: 0] += weight
                }
            }
        }

        var modelSessions: [String: Int] = [:]
        for counts in threadModelCounts.values {
            // 会话归给消息最多的模型；计数相同按名字定序，避免每次刷新
            // 排行在并列项之间跳动。
            let dominant = counts.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }?.key
            guard let dominant else { continue }
            modelSessions[dominant, default: 0] += 1
        }

        let totalTokens = promptTokens + completionTokens
        let names = Set(modelTokens.keys).union(modelSessions.keys)
        var models: [Model] = names.map { name in
            let tokens = modelTokens[name] ?? 0
            let rate: Double?
            if let sum = modelRateSum[name], let weight = modelRateWeight[name], weight > 0 {
                rate = sum / weight
            } else {
                rate = nil
            }
            return Model(
                name: name,
                sessions: modelSessions[name] ?? 0,
                tokens: tokens,
                share: totalTokens > 0 ? Double(tokens) / Double(totalTokens) : 0,
                tokensPerSecond: rate)
        }
        models.sort { lhs, rhs in
            if lhs.tokens != rhs.tokens { return lhs.tokens > rhs.tokens }
            if lhs.sessions != rhs.sessions { return lhs.sessions > rhs.sessions }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let days = allDaySessions
            .map { Day(date: $0.key, sessions: $0.value.count) }
            .sorted { $0.date < $1.date }

        return UsageSummary(
            window: window,
            sessions: windowSessions.count,
            messages: userMessages + assistantMessages,
            userMessages: userMessages,
            assistantMessages: assistantMessages,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            longestStreak: longestStreak(in: activeDayKeys, calendar: calendar),
            activeDays: activeDayKeys.count,
            recentSessions: recentSessions.count,
            averageTokensPerSecond: rateWeight > 0 ? rateSum / rateWeight : nil,
            firstActivity: firstActivity,
            models: models,
            days: days)
    }

    private static func longestStreak(in days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        var best = 0
        var run = 0
        var previous: Date?
        for day in days.sorted() {
            if let previous,
                calendar.dateComponents([.day], from: previous, to: day).day == 1
            {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }
}

/// 用量面板的读数格式：Token 走 M / B，计数带千分位，速度保留一位小数。
package enum UsageFormat {
    package static func tokens(_ value: Int) -> String {
        let amount = Double(value)
        if amount >= 1_000_000_000 {
            return String(format: "%.1fB", amount / 1_000_000_000)
        }
        if amount >= 1_000_000 {
            return String(format: "%.1fM", amount / 1_000_000)
        }
        if amount >= 1_000 {
            return String(format: "%.1fK", amount / 1_000)
        }
        return "\(value)"
    }

    package static func count(_ value: Int) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .locale(Locale(identifier: "en_US")))
    }

    package static func percent(_ value: Double) -> String {
        if value <= 0 { return "0%" }
        if value < 0.001 { return "<0.1%" }
        return String(format: "%.1f%%", value * 100)
    }

    package static func rate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.1f", value)
    }

}
