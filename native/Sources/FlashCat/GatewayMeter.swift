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
/// 当前速度统一由 `DecodeWindowMeter`（指数遗忘 + 停顿宽限 + 窗口总量）
/// 按请求给出：总解码曲线与「最近请求」逐行读同一批估计器、同一个时间基，
/// 行相加就是曲线。它治闪烁的方式是**摊薄而不是保持**：窗口的 token 总量
/// 把成批到达平均进窗口（分布无关），指数遗忘把窗间的交接磨平成缓坡——
/// 旧低通 τ=2.5s 在分片间隔里衰减 18% 再加热，正是谷—峰波纹的来源；
/// `rate(at:)` 的取样时刻也不改变稳态输出。
///
/// hero 大数字不再读这里：它要的是「模型启动以来平均」，由 `lifetimeAverage`
/// 按会话的生成 token / 解码时长累计，和当前速度是两把尺。
///
/// 线程模型：网关转发跑在非主 actor 上，打点密度是每帧 SSE 一次，所以这是个
/// 用 NSLock 保护的普通类，不是 @MainActor 的 ObservableObject。读侧
/// （概览页的会话网格）只做一次取数，不做增量订阅。
final class GatewayMeter: @unchecked Sendable {
    static let shared = GatewayMeter()

    /// 保留的请求条数上限（含已完成），防止异常流量把内存吃掉。
    /// 已结束的请求不按时间清掉：概览要维持最后一次请求的信息，直到它被
    /// 后续请求挤出这张表。
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
        /// 会话的速率估计（指数遗忘 + 停顿宽限）。「最近请求」逐行与
        /// 曲线合计读同一个 `rate(at:)`，行相加就是合计。
        var meter: DecodeWindowMeter
    }

    private let lock = NSLock()
    private var sessions: [Session] = []
    private var nextID = 1

    /// 已完成请求的累计解码量，喂「模型启动以来平均速度」。只在 `finish`
    /// 时结算一次：会话表有上限，等它被挤出表再算就丢了历史；逐次读取时
    /// 再加在跑会话的部分，读数在请求进行中也能动。
    private var lifetimeTokens: Double = 0
    private var lifetimeSeconds: TimeInterval = 0

    /// 测试可以建独立实例；生产只用 `shared`，避免两份会话表。
    init() {}

    /// 模型 / 引擎换代时清空累计均值。会话表本身不动：概览的「最近请求」
    /// 仍要保留上一轮的最后一条，直到被新请求挤出。
    func resetLifetime() {
        lock.lock()
        defer { lock.unlock() }
        lifetimeTokens = 0
        lifetimeSeconds = 0
    }

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
                                meter: DecodeWindowMeter()))
        if sessions.count > Self.sessionLimit {
            // 先淘汰最早的已完成请求，再考虑在跑的会话：正在打点的请求不能
            // 因为历史太长而丢掉 finish/addTokens 的落点。
            var overflow = sessions.count - Self.sessionLimit
            sessions.removeAll { session in
                guard overflow > 0, session.finishedAt != nil else { return false }
                overflow -= 1
                return true
            }
            if sessions.count > Self.sessionLimit {
                sessions.removeFirst(sessions.count - Self.sessionLimit)
            }
        }
        return id
    }

    func finish(_ id: Int, failed: Bool = false, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].finishedAt == nil {
            // 宽限期的锚 = **最后一个分片**（没有就退回收尾时刻）：曲线在
            // `lastToken + 2W` 之前就落地，收尾后的冻结窗从这一刻起算。
            sessions[index].finishedAt = sessions[index].meter.lastTokenAt ?? now
            // 结算进全程均值。用会话自己的 token / 解码时长（首 token 到末
            // token），不含 TTFT、排队和空闲——平均速度回答的是「模型吐字
            // 有多快」，不是「墙钟过了多久」。失败请求同样计入：它确实解码过。
            lifetimeTokens += sessions[index].completionTokens
            lifetimeSeconds += sessions[index].meter.decodingSeconds
        }
        if failed { sessions[index].failed = true }
    }

    /// 喂一个流式分片。`count` 是小数权重的 token 估算（见
    /// `TokenEstimator.fractional`），一两个字符的分片也会留下贡献，
    /// 计数不再由 SSE 切分方式决定。首 token 时刻在这里顺带记下。
    ///
    /// 记账顺序是修好的：旧实现在 `guard count > 0` **之后**才记首字时刻，
    /// 一个空 delta（role-only 首帧、finish_reason 帧、心跳注释被解析成空片）
    /// 到达时不记，等第一个带文字的分片才记——TTFT 被记晚了，预填充读数
    /// 随之偏低。首字时刻问的是「文字什么时候开始回来」，与这一片估出多少
    /// token 无关。
    func addTokens(_ id: Int, _ count: Double, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].firstTokenAt == nil { sessions[index].firstTokenAt = now }
        guard count > 0 else { return }
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
                let generated = Self.generatedText(delta)
                if !generated.isEmpty {
                    addTokens(id, TokenEstimator.fractional(generated))
                } else if first["delta"] is [String: Any] {
                    // role-only 首帧：没有文字、估出 0 token，但它是「流开始回
                    // 东西」的第一个证据。旧实现只在 generatedText 非空时打点，
                    // 这种帧被完全忽略；现在让它记首字时刻（count=0 只记时、不
                    // 计入生成量）。只认 `delta` 键：非流式的 message 形状走
                    // `ingestResponse`，不该进这条路径。
                    addTokens(id, 0)
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
    /// 能按请求给出同一时间基的读数；这里把各会话的窗口估计器相加，
    /// 曲线和「最近请求」逐行才能真正对上。
    struct Overview {
        let decodeRate: Double
        /// true = 至少还有一个没收尾的会话。收尾即 false——概览不再挂
        /// LAST 终值，曲线也在这一刻冻结。
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

    /// 在跑会话的合计解码速率——各路窗口估计器读数之和。
    ///
    /// 「最近请求」逐行与曲线同源：行与合计都读同一个 `rate(at:)`，行相加
    /// 就是合计。收尾后不保留 LAST：`isLive == false`，上层不再把上一请求
    /// 的终值当成当前速度，也不会把它画进 60 秒曲线。请求还在跑但暂时没有
    /// 输出（思考块边界、工具调用间隙）时 `isLive` 仍为 true，速率会随
    /// 估计器的保持 / 遗忘段落到 0——「没有在吐字」和「请求结束」是两件事。
    func overview(now: Date = Date()) -> Overview {
        lock.lock()
        defer { lock.unlock() }
        // 这里**不算**预填充聚合。逐行读数留给「最近请求」；概览卡的口径见
        // `AppState.prefillReading`：网关侧只有 TTFT 口径，已废弃，走引擎自报值。
        let inFlight = sessions.filter { $0.finishedAt == nil }
        guard !inFlight.isEmpty else { return Overview(decodeRate: 0, isLive: false) }
        let value = inFlight.reduce(0) { $0 + $1.meter.rate(at: now) }
        return Overview(decodeRate: value, isLive: true)
    }

    /// 模型启动以来的平均解码速度：已完成请求的累计 + 在跑请求的当前部分。
    ///
    /// 分子只算生成出来的 token（含思考与工具参数），分母只算首 token 到
    /// 末 token 的解码时长——不把 TTFT、排队、空闲摊进去。在跑部分用同一
    /// 分子分母，请求收尾时整条从「在跑」挪进「累计」，读数连续、不跳变。
    /// 没有任何解码样本时返回 nil，界面画「—」而不是 0。
    func lifetimeAverage() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        var tokens = lifetimeTokens
        var seconds = lifetimeSeconds
        for session in sessions where session.finishedAt == nil {
            tokens += session.completionTokens
            seconds += session.meter.decodingSeconds
        }
        guard tokens > 0, seconds > 0 else { return nil }
        return tokens / seconds
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

    /// 最近 `limit` 条请求的快照；`nil` 表示全部。已结束的请求仍然在表里，
    /// 所以概览的「最近请求」在收尾后不会变空；上限由 `sessionLimit` 控制。
    /// 只构造概览真正用到的字段，不再为每行复制 180 点历史曲线。
    func snapshot(limit: Int? = nil, now: Date = Date()) -> [SessionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        let visible: ArraySlice<Session>
        if let limit {
            visible = sessions.suffix(max(0, limit))
        } else {
            visible = sessions[...]
        }
        return visible.map { session in
            // 已结束请求的耗时停在收尾那一刻；否则保留在列表里的旧行会
            // 跟着挂钟一直涨，看起来像还在跑。
            let elapsed = (session.finishedAt ?? now).timeIntervalSince(session.startedAt)
            let ttft = session.firstTokenAt.map { $0.timeIntervalSince(session.startedAt) }
            // 活动请求读窗口速率；已结束的请求改报全程平均，
            // 这个终值会一直保留到它被新请求挤出列表。
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
