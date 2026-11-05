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

    /// 曲线桶宽度：250ms 一格。速率本身不再由这些桶计算（改用连续时间
    /// 低通），桶只留给前端画历史曲线。
    private static let bucketWidth: TimeInterval = 0.25
    /// 每路保留 120 秒（480 格），45 秒曲线和 5 分钟曲线都够用。
    private static let ringSize = 480
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
        var firstTokenAt: Date?
        var finishedAt: Date?
        var failed: Bool
        /// 连续时间低通速率估计，与应用内对话共用同一个实现。
        var meter: DecodeRateMeter
        /// (绝对桶序号, 该桶生成的 token 数)，只用于历史曲线。
        var ticks: [(index: Int, count: Double)]
    }

    private let lock = NSLock()
    private var sessions: [Session] = []
    private var nextID = 1

    private init() {}

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
                                firstTokenAt: nil,
                                finishedAt: nil,
                                failed: false,
                                meter: DecodeRateMeter(),
                                ticks: []))
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
        let slot = Int(now.timeIntervalSinceReferenceDate / Self.bucketWidth)
        if var last = sessions[index].ticks.last, last.index == slot {
            last.count += count
            sessions[index].ticks[sessions[index].ticks.count - 1] = last
        } else {
            sessions[index].ticks.append((slot, count))
            if sessions[index].ticks.count > Self.ringSize {
                sessions[index].ticks.removeFirst(sessions[index].ticks.count - Self.ringSize)
            }
        }
    }

    // MARK: 上报解码

    /// 吃一个 OpenAI 形状的 SSE 分片：`delta.content` / `delta.reasoning*` 都算生成，
    /// 末尾带 `usage` 的那一片用来校正估算值。
    func ingest(_ id: Int, chunk: [String: Any]) {
        if let choices = chunk["choices"] as? [[String: Any]], let first = choices.first {
            let delta = first["delta"] as? [String: Any] ?? first["message"] as? [String: Any]
            if let delta {
                var text = ""
                for key in ["content", "reasoning_content", "reasoning"] {
                    if let value = delta[key] as? String { text += value }
                }
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
            for key in ["content", "reasoning_content", "reasoning"] {
                if let value = message[key] as? String { text += value }
            }
        }
        let tokens = TokenEstimator.fractional(text)
        if tokens > 0 { addTokens(id, tokens) }
        if let usage = object["usage"] as? [String: Any] { applyUsage(id, usage) }
        finish(id)
    }

    private func applyUsage(_ id: Int, _ usage: [String: Any]) {
        let prompt = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
        let completion = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        noteUsage(id, promptTokens: prompt, completionTokens: completion)
    }

    /// 应用内对话直接连引擎端口、不经过网关，但概览页的「最近请求」统一读
    /// 这里，所以对话结束时把结构化 usage 也送进来校正计数。
    func noteUsage(_ id: Int, promptTokens prompt: Int, completionTokens completion: Int) {
        guard prompt > 0 || completion > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if prompt > 0 { sessions[index].promptTokens = prompt }
        // 引擎报的 completion_tokens 含思考 token，比流式估算更准，所以用来
        // 校正「一共吐了多少字」。但它绝不能回灌到速率估计或历史曲线里：
        // 旧实现把差额一次性塞进当前 250ms 桶，末帧必然炸出一个尖峰，
        // 而且只许往上校正，估算偏高时永远拉不回来。
        if Double(completion) > sessions[index].completionTokens {
            sessions[index].completionTokens = Double(completion)
        }
    }

    // MARK: 快照

    /// 供 payload 使用的快照：只留最近 `historyPoints` 格的速率曲线。
    func snapshot(historyPoints: Int = 180) -> [[String: Any]] {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll { session in
            guard let finishedAt = session.finishedAt else { return false }
            return now.timeIntervalSince(finishedAt) > Self.lingerAfterFinish
        }
        let nowSlot = Int(now.timeIntervalSinceReferenceDate / Self.bucketWidth)
        return sessions.map { session in
            let elapsed = now.timeIntervalSince(session.startedAt)
            let ttft = session.firstTokenAt.map { $0.timeIntervalSince(session.startedAt) }
            // 活动请求读低通后的瞬时速率；已结束的请求改报全程平均，
            // 否则 linger 的 6 秒里读数会一路衰减到 0，看起来像引擎卡死。
            let rate = session.finishedAt == nil
                ? session.meter.rate(at: now)
                : session.meter.averageRate()
            let prefillRate: Double = {
                guard let ttft, ttft > 0.05, session.promptTokens > 0 else { return 0 }
                return Double(session.promptTokens) / ttft
            }()
            var bySlot: [Int: Double] = [:]
            for tick in session.ticks { bySlot[tick.index] = tick.count }
            // 历史曲线：以每格为中心的 5 格三角加权，再换算成 tok/s。
            // 原来直接 `count * 4`，一格 1 token 就是 4 tok/s 的硬台阶；
            // 加权后相邻格共享样本，曲线不会因分片落在不同桶而锯齿化。
            let weights: [Double] = [1, 2, 3, 2, 1]
            let history: [Double] = (0..<historyPoints).map { offset in
                let slot = nowSlot - (historyPoints - 1 - offset)
                var numerator = 0.0
                var denominator = 0.0
                for (index, weight) in weights.enumerated() {
                    let key = slot + index - 2
                    guard key <= nowSlot else { continue }
                    numerator += (bySlot[key] ?? 0) * weight
                    denominator += weight
                }
                let value = denominator > 0 ? numerator / denominator * 4 : 0
                return (value * 10).rounded() / 10
            }
            let state: String
            if session.finishedAt != nil {
                state = session.failed ? "failed" : "done"
            } else if session.firstTokenAt == nil {
                state = "prefill"
            } else {
                state = "decode"
            }
            return [
                "id": session.id,
                "model": session.model,
                "dialect": session.dialect,
                "state": state,
                "elapsed": elapsed,
                "ttft": ttft.map { $0 * 1000 } ?? NSNull(),
                "promptTokens": session.promptTokens,
                "completionTokens": Int(session.completionTokens.rounded()),
                "decodeRate": rate,
                "prefillRate": prefillRate,
                "ctxTokens": session.promptTokens + Int(session.completionTokens.rounded()),
                "history": history,
            ] as [String: Any]
        }
    }

}
