import Foundation
import FlashCatKit

/// 网关侧的按请求打点。
///
/// 引擎那一层没有 per-session 指标可拿：splash 只上报累计的
/// `decode_output_tokens / decode_wall_ms`，oMLX 只给聚合吞吐和一个在跑计数，
/// MTPLX 更极端——串行到连「有几路在排队」都不报（排队被算进了在跑）。
/// 唯一知道每个请求什么时候进来、第一个 token 什么时候到、一共吐了多少字的地方
/// 就是网关本身，所以概览页的「会话」网格在这里取数。
///
/// 线程模型：网关转发跑在非主 actor 上，打点密度又是每 250ms 一格，所以这是个
/// 用 NSLock 保护的普通类，不是 @MainActor 的 ObservableObject。读侧
/// （概览页的会话网格）只做一次取数，不做增量订阅。
final class GatewayMeter: @unchecked Sendable {
    static let shared = GatewayMeter()

    /// 请求结束后再留一会儿，让「刚跑完」看得见，然后自然消失。
    private static let lingerAfterFinish: TimeInterval = 6
    /// 同时在追踪的请求上限，防止异常流量把内存吃掉。
    private static let sessionLimit = 32

    private struct Session {
        let id: Int
        let model: String
        let dialect: String
        let startedAt: Date
        var promptTokens: Int
        /// 小数累计，避免逐片四舍五入把短分片抹掉；末帧 usage 会覆盖它。
        var completionTokens: Double
        /// usage 里报告的「命中前缀缓存、没有真正前向」的提示词 token。
        /// 预填充速度的分子必须把它扣掉。
        var cachedPromptTokens: Int
        var firstTokenAt: Date?
        var finishedAt: Date?
        var failed: Bool
        /// 连续时间低通速率估计，与应用内对话共用同一个实现。
        var meter: DecodeRateMeter
    }

    private let lock = NSLock()
    private var sessions: [Session] = []
    private var nextID = 1

    /// 测试可以建独立实例；生产只用 `shared`，避免两份会话表。
    init() {}

    // MARK: 生命周期

    @discardableResult
    func begin(model: String, dialect: String, promptTokens: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        sessions.append(Session(id: id,
                                model: model,
                                dialect: dialect,
                                startedAt: Date(),
                                promptTokens: promptTokens,
                                completionTokens: 0,
                                cachedPromptTokens: 0,
                                firstTokenAt: nil,
                                finishedAt: nil,
                                failed: false,
                                meter: DecodeRateMeter()))
        if sessions.count > Self.sessionLimit {
            sessions.removeAll { $0.finishedAt != nil }
            if sessions.count > Self.sessionLimit {
                sessions.removeFirst(sessions.count - Self.sessionLimit)
            }
        }
        return id
    }

    func finish(_ id: Int, failed: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].finishedAt == nil {
            sessions[index].finishedAt = Date()
        }
        if failed { sessions[index].failed = true }
    }

    /// 喂一个流式分片。`count` 是小数权重的 token 估算（见
    /// `TokenEstimator.fractional`），一两个字符的分片也会留下贡献，
    /// 计数不再由 SSE 切分方式决定。首 token 时刻在这里顺带记下，
    /// 预填充速度就是 `promptTokens / ttft`。
    func addTokens(_ id: Int, _ count: Double, at now: Date = Date()) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].firstTokenAt == nil { sessions[index].firstTokenAt = now }
        sessions[index].completionTokens += count
        sessions[index].meter.add(tokens: count, at: now)
    }

    // MARK: 上报解码

    /// 吃一个 OpenAI 形状的 SSE 分片：`delta.content` / `delta.reasoning*` 都算生成，
    /// 工具调用（`delta.tool_calls[*].function.arguments`）也算——agent 客户端的
    /// 回复大头就是工具参数，不数它的话 agent 会话在概览里永远是 0 tok/s。
    /// 末尾带 `usage` 的那一片用来校正估算值。
    func ingest(_ id: Int, chunk: [String: Any]) {
        if let choices = chunk["choices"] as? [[String: Any]], let first = choices.first {
            let delta = first["delta"] as? [String: Any] ?? first["message"] as? [String: Any]
            if let delta {
                let text = Self.generatedText(delta)
                if !text.isEmpty {
                    addTokens(id, TokenEstimator.fractional(text))
                }
            }
        }
        if let usage = chunk["usage"] as? [String: Any] { applyUsage(id, usage) }
    }

    /// 非流式响应：一次性拿到 message 和 usage。
    func ingestResponse(_ id: Int, body: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            finish(id, failed: true)
            return
        }
        var text = ""
        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            let message = first["message"] as? [String: Any] ?? [:]
            text = Self.generatedText(message)
        }
        let tokens = TokenEstimator.fractional(text)
        if tokens > 0 { addTokens(id, tokens) }
        if let usage = object["usage"] as? [String: Any] { applyUsage(id, usage) }
        finish(id)
    }

    /// 一段增量里所有「模型真的生成出来的文字」：正文、思考、工具调用名与参数。
    /// 内部可见，便于在没有引擎的测试里钉住工具调用这一类分片。
    static func generatedText(_ payload: [String: Any]) -> String {
        var text = ""
        for key in ["content", "reasoning_content", "reasoning", "thinking"] {
            if let value = payload[key] as? String { text += value }
        }
        if let calls = payload["tool_calls"] as? [[String: Any]] {
            for call in calls {
                guard let function = call["function"] as? [String: Any] else { continue }
                if let name = function["name"] as? String { text += name }
                if let arguments = function["arguments"] as? String { text += arguments }
            }
        }
        return text
    }

    private func applyUsage(_ id: Int, _ usage: [String: Any]) {
        let prompt = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
        let completion = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        noteUsage(id,
                  promptTokens: prompt,
                  completionTokens: completion,
                  cachedPromptTokens: Self.cachedTokens(usage))
    }

    /// 前缀缓存命中量。OpenAI 方言是 `prompt_tokens_details.cached_tokens`，
    /// Anthropic 方言是 `input_tokens_details.cached_tokens`；网关拿到的是
    /// 引擎的 OpenAI 形状响应，两种都读一遍以防中间层换皮。
    static func cachedTokens(_ usage: [String: Any]) -> Int {
        for key in ["prompt_tokens_details", "input_tokens_details"] {
            if let details = usage[key] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                return max(0, cached)
            }
        }
        return 0
    }

    /// 应用内对话直接连引擎端口、不经过网关，但概览页的「最近请求」统一读
    /// 这里，所以对话结束时把结构化 usage 也送进来校正计数。
    func noteUsage(_ id: Int,
                   promptTokens prompt: Int,
                   completionTokens completion: Int,
                   cachedPromptTokens cached: Int = 0) {
        guard prompt > 0 || completion > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if prompt > 0 { sessions[index].promptTokens = prompt }
        if cached > 0 { sessions[index].cachedPromptTokens = min(cached, sessions[index].promptTokens) }
        // 引擎报的 completion_tokens 含思考 token，比流式估算更准，所以用来
        // 校正「一共吐了多少字」。但它绝不能回灌到速率估计或历史曲线里：
        // 旧实现把差额一次性塞进当前 250ms 桶，末帧必然炸出一个尖峰，
        // 而且只许往上校正，估算偏高时永远拉不回来。
        if Double(completion) > sessions[index].completionTokens {
            sessions[index].completionTokens = Double(completion)
        }
    }

    // MARK: 概览聚合

    /// 概览大数字与总解码曲线要的是「所有请求合起来」的读数，而不是某一路。
    /// 各引擎的实时速率口径不一（最近批次 / 滚动均值 / 累计均值），只有网关
    /// 能按请求给出同一时间基的读数；这里把各会话的低通估计器相加，hero、
    /// 曲线和「最近请求」逐行才能真正对上。
    struct Overview {
        let decodeRate: Double
        /// true = 数值来自在跑会话的实时低通；false = 没有在跑会话，
        /// 数值只是刚结束会话的全程均值（linger 内），必须标成 LAST。
        let isLive: Bool
    }

    /// 单条请求的预填充速度：分子只算真正前向过的 token。
    ///
    /// `promptTokens` 是整段提示词（本轮上下文），但同一会话的第二轮几乎全部
    /// 命中了引擎的前缀缓存。用整段 token 除以首字耗时，会把「缓存恢复」当成
    /// 「预填充计算」，读数随上下文长度线性虚高（108K 上下文实测能到几十万
    /// tok/s）。引擎在 usage 里已经告诉我们多少 token 是缓存命中的，扣掉它；
    /// 全命中时没有可测的前向速度，返回 nil 让上层回落到引擎的真实计数。
    private static func prefillRate(_ session: Session) -> Double? {
        guard let first = session.firstTokenAt, session.promptTokens > 0 else { return nil }
        let ttft = first.timeIntervalSince(session.startedAt)
        guard ttft > 0.05 else { return nil }
        let forwarded = session.cachedPromptTokens > 0
            ? session.promptTokens - session.cachedPromptTokens
            : session.promptTokens
        guard forwarded > 0 else { return nil }
        return Double(forwarded) / ttft
    }

    /// 在跑会话的合计解码速率；没有在跑的就用刚结束（linger 内）的会话
    /// 全程均值，避免收尾瞬间读数突然归零。
    func overview() -> Overview {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll { session in
            guard let finishedAt = session.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) > Self.lingerAfterFinish
        }
        let active = sessions.filter { $0.finishedAt == nil }
        let decodeRate: Double
        if active.isEmpty {
            decodeRate = sessions.reduce(0) { $0 + $1.meter.averageRate() }
        } else {
            decodeRate = active.reduce(0) { $0 + $1.meter.rate(at: now) }
        }
        // 这里**不算**预填充聚合。概览只显示引擎自报的预填充速率：网关这套
        // 「(整段提示词 − 缓存命中) / 首字耗时」的分母是 TTFT，混着排队与
        // 缓存恢复，而分子要等末帧 usage 才知道命中量——两害叠加能把读数放大
        // 两个数量级，正是过去那个虚高数字的来源。逐行读数留给「最近请求」。
        return Overview(decodeRate: decodeRate, isLive: !active.isEmpty)
    }

    // MARK: 快照

    /// 一条请求的只读快照。用结构体而不是 `[String: Any]`：概览每秒刷新一次，
    /// 字典装箱、字符串键和 `as?` 转换都是白花的分配；字段固定后 UI 也不会
    /// 因为拼错键悄悄拿到 0。
    struct SessionSnapshot: Sendable {
        enum State: String, Sendable {
            case prefill, decode, done, failed
        }

        let id: Int
        let model: String
        let dialect: String
        let state: State
        let elapsed: TimeInterval
        let ttftMilliseconds: Double?
        let promptTokens: Int
        let completionTokens: Int
        let decodeRate: Double
        /// 网关侧的逐请求预填充估算，仅作诊断；概览卡不读它。
        let prefillRate: Double
        let ctxTokens: Int
    }

    /// 最近 `limit` 条请求的快照；`nil` 表示全部。只构造概览真正用到的字段，
    /// 不再为每行复制 180 点历史曲线（那段数据没有任何界面在读）。
    func snapshot(limit: Int? = nil) -> [SessionSnapshot] {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll { session in
            guard let finishedAt = session.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) > Self.lingerAfterFinish
        }
        let visible: ArraySlice<Session>
        if let limit {
            visible = sessions.suffix(max(0, limit))
        } else {
            visible = sessions[...]
        }
        return visible.map { session in
            let elapsed = now.timeIntervalSince(session.startedAt)
            let ttft = session.firstTokenAt.map { $0.timeIntervalSince(session.startedAt) }
            // 活动请求读低通后的瞬时速率；已结束的请求改报全程平均，
            // 否则 linger 的 6 秒里读数会一路衰减到 0，看起来像引擎卡死。
            let rate = session.finishedAt == nil
                ? session.meter.rate(at: now)
                : session.meter.averageRate()
            let completion = Int(session.completionTokens.rounded())
            let state: SessionSnapshot.State
            if session.finishedAt != nil {
                state = session.failed ? .failed : .done
            } else if session.firstTokenAt == nil {
                state = .prefill
            } else {
                state = .decode
            }
            return SessionSnapshot(id: session.id,
                                   model: session.model,
                                   dialect: session.dialect,
                                   state: state,
                                   elapsed: elapsed,
                                   ttftMilliseconds: ttft.map { $0 * 1000 },
                                   promptTokens: session.promptTokens,
                                   completionTokens: completion,
                                   decodeRate: rate,
                                   prefillRate: Self.prefillRate(session) ?? 0,
                                   ctxTokens: session.promptTokens + completion)
        }
    }

}
