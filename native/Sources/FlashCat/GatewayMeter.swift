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

    /// 预填充读数的最小样本量（真正前向的 token）。
    ///
    /// 命中前缀缓存后往往只剩几十个 token 要算，耗时被缓存恢复的固定开销主导
    /// （实测 2195 个 token 里缓存 2164，31 个前向摊 92 ms → 334 tok/s）。
    /// 那个数字既不是这台机器算提示词的速度，也不是缓存的速度，报出来只是
    /// 让人怀疑整块指标。低于这个量就当这一路没有可读的预填充。
    static let prefillSampleTokens = 128

    private struct Session {
        let id: Int
        /// 这一路登记时所在的「代」。换引擎 / 换模型 / 引擎重启会开启新一代
        /// （`resetLifetime`），预填充读数只认当代的请求——上一台模型的
        /// 2300 tok/s 不该挂在新模型的卡片上。
        let epoch: Int
        let model: String
        let dialect: String
        var startedAt: Date
        var promptTokens: Int
        /// 小数累计，避免逐片四舍五入把短分片抹掉；末帧 usage 会覆盖它。
        var completionTokens: Double
        /// usage 里报告的「命中前缀缓存、没有真正前向」的提示词 token。
        /// 预填充速度的分子必须把它扣掉。
        var cachedPromptTokens: Int
        /// 末帧 usage 是否真的到过。没有它就没有 `cached_tokens`，分子只能
        /// 把整段上下文算成重新前向，预填充读数会随上下文长度虚高——这种
        /// 会话不参与网关侧的预填充读数。
        var usageKnown: Bool
        var firstTokenAt: Date?
        var finishedAt: Date?
        var failed: Bool
        /// 这一路是不是逐片流回来的。非流式响应的正文一口气到达，网关侧没有
        /// 任何可测的解码窗口——不能拿「到达间隔的下限」冒充解码耗时。
        var streamed: Bool
        /// 引擎自报的逐请求耗时（`timings`）。有它就以它为准：它量的正是
        /// 「这一路前向与生成花了多久」，非流式响应也有。
        var timings: RequestTimings?
        /// 会话的速率估计（指数遗忘 + 停顿宽限）。「最近请求」逐行与
        /// 曲线合计读同一个 `rate(at:)`，行相加就是合计。
        var meter: DecodeWindowMeter
    }

    /// 引擎在响应里自报的逐请求耗时（llama.cpp 口径的 `timings`）。
    ///
    /// mlx-serve 在流式末片和非流式正文里都带这一块：`prompt_n` / `cached_n` /
    /// `prompt_ms` 与 `predicted_n` / `predicted_ms`。它是唯一能同时覆盖两种
    /// 传输的诚实来源——非流式响应的正文一口气回来，网关连「首字」都看不到，
    /// 只靠到达时刻只能量出 0.35 秒的下限，那是虚构的速度（14K token 的回答
    /// 会被读成 37 769 tok/s）。没有 `timings` 的引擎照旧走网关自己的分片
    /// 计时，两条路都不猜。
    struct RequestTimings: Equatable, Sendable {
        var promptTokens: Int
        var cachedTokens: Int
        var promptMilliseconds: Double
        var predictedTokens: Int
        var predictedMilliseconds: Double

        /// 真正前向过的提示词 token。命中缓存的那部分只是被搬回来，没有算。
        var forwardedTokens: Int { max(0, promptTokens - cachedTokens) }

        /// 逐请求预填充吞吐。
        ///
        /// 样本太小就不报：命中缓存后只剩几十个 token 的前向，耗时由缓存恢复
        /// 的固定开销主导（实测 2195 个 token 里缓存 2164，31 个前向摊 92 ms =
        /// 334 tok/s），那既不是这台机器算提示词的速度，也不是缓存的速度。
        var prefillRate: Double? {
            guard forwardedTokens >= GatewayMeter.prefillSampleTokens,
                  promptMilliseconds >= 25 else { return nil }
            let rate = Double(forwardedTokens) / (promptMilliseconds / 1000)
            guard rate.isFinite, rate > 0 else { return nil }
            return rate
        }

        /// 逐请求解码吞吐。分子分母都只算「真正生成」的那一段，不含预填充、
        /// 排队与网络。一个 token 的回答也报不出速度，同样不猜。
        var decodeRate: Double? {
            guard predictedTokens >= 2, predictedMilliseconds >= 20 else { return nil }
            let rate = Double(predictedTokens) / (predictedMilliseconds / 1000)
            guard rate.isFinite, rate > 0 else { return nil }
            return rate
        }
    }

    private let lock = NSLock()
    private var sessions: [Session] = []
    private var nextID = 1
    /// 累计均值与预填充读数的「代」：换引擎、换模型、引擎重启都要翻一代。
    private var epoch = 0

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
        epoch += 1
    }

    // MARK: 生命周期

    @discardableResult
    func begin(model: String, dialect: String, promptTokens: Int,
               at now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        sessions.append(Session(id: id,
                                epoch: epoch,
                                model: model,
                                dialect: dialect,
                                startedAt: now,
                                promptTokens: promptTokens,
                                completionTokens: 0,
                                cachedPromptTokens: 0,
                                usageKnown: false,
                                firstTokenAt: nil,
                                finishedAt: nil,
                                failed: false,
                                streamed: false,
                                timings: nil,
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

    /// 把计时起点挪到「真正发出请求」的那一刻。
    ///
    /// 应用内对话会在 `prepareChatSession` 之前登记会话——那时引擎可能还在
    /// 加载几十 GB 权重。如果 TTFT 从登记时刻算起，冷启动后第一轮的预填充
    /// 速度会把模型加载时间摊进分母，读数低到没有意义。启动等待不算预填充，
    /// 与对话页「思考了 N 秒」的口径一致。
    func markStarted(_ id: Int, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].firstTokenAt == nil
        else { return }
        sessions[index].startedAt = now
    }

    func finish(_ id: Int, failed: Bool = false, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].finishedAt == nil {
            // 宽限期的锚 = **最后一个分片**（没有就退回收尾时刻）：曲线在
            // `lastToken + 2W` 之前就落地，收尾后的冻结窗从这一刻起算。
            sessions[index].finishedAt = sessions[index].meter.lastTokenAt ?? now
            // 结算进全程均值。优先用引擎自报的逐请求耗时：分子只算真正生成
            // 的 token，分母只算真正解码的那一段，不含 TTFT、排队和空闲——
            // 平均速度回答的是「模型吐字有多快」，不是「墙钟过了多久」。
            // 引擎没给 timings 时退回流式分片的到达窗口；**只有一个到达点**
            // 的会话不入账——它的跨度是 0，除以窗口下限 0.35 秒得到的是虚构
            // 的速度，混进来会把整台模型的均值抬到几万。
            if let timings = sessions[index].timings, timings.decodeRate != nil {
                lifetimeTokens += Double(timings.predictedTokens)
                lifetimeSeconds += timings.predictedMilliseconds / 1000
            } else if sessions[index].streamed, sessions[index].meter.observedDecodeSpan >= 0.2 {
                lifetimeTokens += sessions[index].completionTokens
                lifetimeSeconds += sessions[index].meter.decodingSeconds
            }
        }
        if failed { sessions[index].failed = true }
    }

    /// 喂一个流式分片。`count` 是小数权重的 token 估算（见
    /// `TokenEstimator.fractional`），一两个字符的分片也会留下贡献，
    /// 计数不再由 SSE 切分方式决定。首 token 时刻在这里顺带记下。
    ///
    /// 首 token 只认**真的产出了内容**的分片（正文 / 思考 / 工具参数）。
    /// role-only 首帧、finish_reason 帧、心跳空片都不是首字：mlx-serve 在
    /// 预填充开始前就先发一帧 `delta: {role: assistant}`，若把它当首字，
    /// TTFT 会被记成几毫秒，网关的预填充读数直接被顶到上限。旧实现曾在
    /// `guard count > 0` **之前**记时，理由却是「空帧也是流开始了」——
    /// 那是把「连接建立」误当成了「首字」。
    func addTokens(_ id: Int, _ count: Double, at now: Date = Date(),
                   streaming: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // 逐片回来才算「有解码窗口」。非流式走 `ingestResponse`，这里传 false。
        if streaming { sessions[index].streamed = true }
        guard count > 0 else { return }
        // 非流式响应要等正文全部回来才能打点，那段时长里混着解码，不能当
        // TTFT 用；这种会话不给首字时刻，也就不会参与 TTFT 口径的预填充读数。
        if streaming, sessions[index].firstTokenAt == nil {
            sessions[index].firstTokenAt = now
        }
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
                }
                // role-only 首帧、finish_reason 帧都不算首字：它们在预填充
                // 之前/之后出现，但没有产出任何内容（见 `addTokens`）。
            }
        }
        if let usage = chunk["usage"] as? [String: Any] { applyUsage(id, usage) }
        // 引擎把这一路的耗时放在分片顶层（mlx-serve 在末片里带 `timings`），
        // 不随 usage 的开关变化，所以单独接。
        if let timings = Self.requestTimings(chunk["timings"]) { noteTimings(id, timings) }
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
        if tokens > 0 { addTokens(id, tokens, streaming: false) }
        if let usage = object["usage"] as? [String: Any] { applyUsage(id, usage) }
        if let timings = Self.requestTimings(object["timings"]) { noteTimings(id, timings) }
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

    /// 从响应块里取 `timings`。字段名是 llama.cpp 的开放口径，缺哪个就当它
    /// 没给——绝不拿别的字段顶替，宁可这一路没有速度也不编一个。
    static func requestTimings(_ value: Any?) -> RequestTimings? {
        guard let json = value as? [String: Any] else { return nil }
        let prompt = Int(JSONValue.number(json["prompt_n"]) ?? 0)
        let cached = Int(JSONValue.number(json["cached_n"]) ?? 0)
        let promptMs = JSONValue.number(json["prompt_ms"]) ?? 0
        let predicted = Int(JSONValue.number(json["predicted_n"]) ?? 0)
        let predictedMs = JSONValue.number(json["predicted_ms"]) ?? 0
        guard prompt > 0 || predicted > 0 else { return nil }
        return RequestTimings(promptTokens: prompt,
                              cachedTokens: max(0, cached),
                              promptMilliseconds: max(0, promptMs),
                              predictedTokens: max(0, predicted),
                              predictedMilliseconds: max(0, predictedMs))
    }

    /// 记下引擎自报的逐请求耗时。
    ///
    /// 它同时是预填充与解码的权威读数，也顺手校正提示词 token 与缓存命中量：
    /// 客户端没开 `stream_options.include_usage` 时，末片里的 `usage` 是 null，
    /// 但 `timings` 照样带着这两个数——少了它，预填充就只能靠 TTFT 猜。
    func noteTimings(_ id: Int, _ timings: RequestTimings) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].timings = timings
        if timings.promptTokens > 0 {
            sessions[index].usageKnown = true
            sessions[index].promptTokens = timings.promptTokens
            sessions[index].cachedPromptTokens = min(timings.cachedTokens, timings.promptTokens)
        }
        if Double(timings.predictedTokens) > sessions[index].completionTokens {
            sessions[index].completionTokens = Double(timings.predictedTokens)
        }
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
        if prompt > 0 {
            sessions[index].usageKnown = true
            sessions[index].promptTokens = prompt
        }
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
    /// 引擎给了 `timings` 就用它——分子分母都是引擎量的，连非流式响应也有。
    /// 没给时退回网关自己的口径：`promptTokens` 是整段提示词（本轮上下文），
    /// 但同一会话的第二轮几乎全部命中了引擎的前缀缓存。用整段 token 除以首字
    /// 耗时，会把「缓存恢复」当成「预填充计算」，读数随上下文长度线性虚高
    /// （108K 上下文实测能到几十万 tok/s）。usage 里已经告诉我们多少 token 是
    /// 缓存命中的，扣掉它；全命中时没有可测的前向速度，返回 nil。
    ///
    /// 网关的口径只对**流式**响应成立：分母是请求真正发出到首 token 的墙钟。
    /// 非流式响应回来时预填充早就结束了，唯一的「首字时刻」其实是整段回答的
    /// 收尾，拿它当分母只会报一个偏低的假数。
    private static func prefillRate(_ session: Session) -> Double? {
        if let timings = session.timings, let rate = timings.prefillRate { return rate }
        guard session.streamed, session.usageKnown,
              let first = session.firstTokenAt, session.promptTokens > 0
        else { return nil }
        let ttft = first.timeIntervalSince(session.startedAt)
        guard ttft > 0.001 else { return nil }
        let forwarded = max(0, session.promptTokens - session.cachedPromptTokens)
        guard forwarded >= Self.prefillSampleTokens else { return nil }
        let rate = Double(forwarded) / ttft
        guard rate.isFinite else { return nil }
        return min(rate, 200_000)
    }

    /// 一条请求的全程解码速度（「最近请求」每一行读它）。
    ///
    /// 引擎的 `timings` 优先；流式响应退回网关自己的到达窗口；两者都没有就
    /// 返回 nil——非流式响应的正文一口气回来，网关手里只有一个到达点，
    /// 拿窗口下限（0.35 秒）去除会把 14 155 token 的回答读成 37 769 tok/s。
    private static func decodeRate(_ session: Session) -> Double? {
        if let timings = session.timings, let rate = timings.decodeRate { return rate }
        guard session.streamed, session.meter.observedDecodeSpan >= 0.2 else { return nil }
        let rate = session.meter.averageRate()
        guard rate > 0, rate.isFinite else { return nil }
        return rate
    }

    /// 最近一次完成预填充的实测吞吐（tok/s）。
    ///
    /// 概览的预填充格读这里，而不是引擎自报的 `latest.prefill_*` / `in_flight`
    /// ——换引擎不该让同一格时有时无。按收尾时刻排「最近一次」，并发时取真正的
    /// 最后一路；最新那一路的样本太小（缓存命中、只剩几十个 token 的前向）时
    /// 继续往前找，不把整格空掉。只认**当代**（`epoch`）的请求：换了引擎或模型，
    /// 上一台的 2300 tok/s 不该冒充新模型的开机读数——那时宁可画「—」或退回
    /// 引擎自己的均值。
    func recentPrefill() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let current = epoch
        let ordered = sessions
            .filter { $0.epoch == current }
            .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        for session in ordered {
            if let rate = Self.prefillRate(session) { return rate }
        }
        return nil
    }

    /// 一次缓存命中率的汇总。
    struct CacheHitSample: Equatable, Sendable {
        /// 0…1，按 token 加权（不是各请求命中率的算术平均）。
        let rate: Double
        /// 参与汇总的请求数：都有 usage，都报了提示词量。
        let requests: Int
    }

    /// 网关按代累计的缓存命中率（0…1）。
    ///
    /// 分子是 usage 报告的前缀缓存命中量，分母是同一批请求的提示词总量：
    /// 按 token 加权，而不是把每条请求的命中率做算术平均——一段 100K 的上下文
    /// 命中 95%，比十次 1K 的冷请求更能代表缓存效率。只统计真的收到 usage 的
    /// 请求：客户端没开 `include_usage` / `stream_options` 时没有 `cached_tokens`，
    /// 把整段上下文当成未命中会让读数凭客户端配置变低。会话表最多 32 条，
    /// 所以窗口是「最近 ≤32 次有 usage 的请求」；只认当代（`epoch`）的请求，
    /// 换引擎 / 换模型 / 引擎重启后从零开始。没有样本时返回 nil，界面画「—」
    /// 而不是 0%——「一次都没算过」与「算了但一次都没命中」是两件事。
    func cacheHit() -> CacheHitSample? {
        lock.lock()
        defer { lock.unlock() }
        let current = epoch
        var cached = 0
        var prompt = 0
        var requests = 0
        for session in sessions where session.epoch == current {
            guard session.usageKnown, session.promptTokens > 0 else { continue }
            cached += min(session.cachedPromptTokens, session.promptTokens)
            prompt += session.promptTokens
            requests += 1
        }
        guard requests > 0, prompt > 0 else { return nil }
        return CacheHitSample(rate: Double(cached) / Double(prompt), requests: requests)
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
        // 这里只聚合解码。预填充是一次性动作，聚合方式不同（最近一次完成的
        // 那一路，不是各路相加），见 `recentPrefill()`。
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
            // 与 `finish` 同一把尺：只有真的观测到解码跨度的在跑会话才摊进
            // 分母，单点（刚吐了第一片）会话不参与。
            if let timings = session.timings, timings.decodeRate != nil {
                tokens += Double(timings.predictedTokens)
                seconds += timings.predictedMilliseconds / 1000
            } else if session.streamed, session.meter.observedDecodeSpan >= 0.2 {
                tokens += session.completionTokens
                seconds += session.meter.decodingSeconds
            }
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
        /// 网关侧的逐请求预填充估算，仅作行内诊断；概览卡读 `recentPrefill()`，
        /// 两者共用同一套分子分母。
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
            // 活动请求读窗口速率；已结束的请求改报全程平均（引擎 timings 优先），
            // 这个终值会一直保留到它被新请求挤出列表。量不出速度的行留 0，
            // 界面画「—」——比编一个 37 769 tok/s 诚实。
            let rate = session.finishedAt == nil
                ? session.meter.rate(at: now)
                : (Self.decodeRate(session) ?? 0)
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
