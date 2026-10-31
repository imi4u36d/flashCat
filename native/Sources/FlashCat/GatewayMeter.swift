import Foundation

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
/// （`WebViewShell.data(state:)` 打 payload）只做一次快照，不做增量订阅。
final class GatewayMeter: @unchecked Sendable {
    static let shared = GatewayMeter()

    /// 采样桶宽度：250ms 一格，够算「最近 2 秒」的瞬时速率，也够画曲线。
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
        var completionTokens: Int
        var firstTokenAt: Date?
        var finishedAt: Date?
        var failed: Bool
        /// (绝对桶序号, 该桶生成的 token 数)，末尾元素是当前桶。
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

    /// 记下第一批 token 到达的时刻——预填充速度就是 `promptTokens / ttft`。
    func markFirstToken(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].firstTokenAt == nil else { return }
        sessions[index].firstTokenAt = Date()
    }

    func addTokens(_ id: Int, _ count: Int) {
        guard count > 0 else { return }
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].firstTokenAt == nil { sessions[index].firstTokenAt = now }
        sessions[index].completionTokens += count
        let slot = Int(now.timeIntervalSinceReferenceDate / Self.bucketWidth)
        if var last = sessions[index].ticks.last, last.index == slot {
            last.count += Double(count)
            sessions[index].ticks[sessions[index].ticks.count - 1] = last
        } else {
            sessions[index].ticks.append((slot, Double(count)))
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
                    addTokens(id, TokenEstimator.estimate(text))
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
        let tokens = TokenEstimator.estimate(text)
        if tokens > 0 { addTokens(id, tokens) }
        if let usage = object["usage"] as? [String: Any] { applyUsage(id, usage) }
        finish(id)
    }

    private func applyUsage(_ id: Int, _ usage: [String: Any]) {
        let prompt = (usage["prompt_tokens"] as? Int) ?? (usage["input_tokens"] as? Int) ?? 0
        let completion = (usage["completion_tokens"] as? Int) ?? (usage["output_tokens"] as? Int) ?? 0
        guard prompt > 0 || completion > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if prompt > 0 { sessions[index].promptTokens = prompt }
        // 引擎报的 completion_tokens 含思考 token，比流式估算更准；
        // 只往上校正，避免最后一片把曲线拽回去。
        if completion > sessions[index].completionTokens {
            let extra = completion - sessions[index].completionTokens
            let slot = Int(Date().timeIntervalSinceReferenceDate / Self.bucketWidth)
            sessions[index].completionTokens = completion
            if var last = sessions[index].ticks.last, last.index == slot {
                last.count += Double(extra)
                sessions[index].ticks[sessions[index].ticks.count - 1] = last
            }
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
            let rate = Self.rate(ticks: session.ticks, nowSlot: nowSlot, elapsed: elapsed)
            let prefillRate: Double = {
                guard let ttft, ttft > 0.05, session.promptTokens > 0 else { return 0 }
                return Double(session.promptTokens) / ttft
            }()
            var bySlot: [Int: Double] = [:]
            for tick in session.ticks { bySlot[tick.index] = tick.count }
            // 每格换算成 tok/s（250ms 的桶 ×4），前端直接按数值画曲线。
            let history: [Double] = (0..<historyPoints).map { offset in
                let slot = nowSlot - (historyPoints - 1 - offset)
                return ((bySlot[slot] ?? 0) * 4 * 10).rounded() / 10
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
                "completionTokens": session.completionTokens,
                "decodeRate": rate,
                "prefillRate": prefillRate,
                "ctxTokens": session.promptTokens + session.completionTokens,
                "history": history,
            ] as [String: Any]
        }
    }

    private static func rate(ticks: [(index: Int, count: Double)], nowSlot: Int, elapsed: TimeInterval) -> Double {
        let window = min(2.0, max(elapsed, Self.bucketWidth))
        let from = nowSlot - Int((window / Self.bucketWidth).rounded()) + 1
        let sum = ticks.reduce(0.0) { $0 + ($1.index >= from ? $1.count : 0) }
        return sum / window
    }
}

/// 粗粒度 token 估算：中日韩字符按 1 token/字，其余按 4 字符/token。
/// 只用于「还没拿到 usage 的那几秒」把曲线画出来，末帧的 usage 会覆盖它。
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0x3000...0x303F, 0xFF00...0xFFEF:
                cjk += 1
            default:
                other += 1
            }
        }
        return cjk + (other + 3) / 4
    }

    /// 从 OpenAI 的 `messages` 里估出输入侧长度（含 system 和工具描述的量级）。
    static func promptTokens(messages: Any?) -> Int {
        guard let list = messages as? [[String: Any]] else { return 0 }
        var total = 0
        for message in list {
            if let text = message["content"] as? String {
                total += estimate(text)
            } else if let parts = message["content"] as? [[String: Any]] {
                for part in parts where (part["type"] as? String) == "text" {
                    if let text = part["text"] as? String { total += estimate(text) }
                }
            }
        }
        // 每条消息的角色/分隔开销，量级参考 OpenAI 的 4 token/条。
        return total + list.count * 4
    }
}
