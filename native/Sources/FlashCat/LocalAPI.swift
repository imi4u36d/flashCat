import Foundation
import FlashCatKit

struct ServerStats: Equatable {
    var decodeTokensPerSecond: Double?
    var prefillTokensPerSecond: Double?
    /// 上面两个速率的粒度（见 `EngineRateKind`）。
    var decodeRateKind: EngineRateKind = .none
    var prefillRateKind: EngineRateKind = .none
    var draftAcceptance: Double?
    var ttftMilliseconds: Double?
    var activeRequests: Int = 0
    var queuedRequests: Int = 0
    var thermal: String?
    var memoryPressure: String?
    var memoryBytes: Int?
    var peakMemoryBytes: Int?
    /// 引擎自报的缓存命中率（0…1），只在引擎给出「命中量 / 提示词总量」两个
    /// 累计计数器时才有值（mlx-serve / MTPLX / oMLX）。其余引擎为 nil。
    var cacheHitRate: Double?
    var maximumContextTokens: Int?
    var model: String?
    var requestsCompleted: Int = 0
    var requestsFailed: Int = 0
    var deviceName: String?
    var physicalMemoryBytes: Int?
    var gpuCores: Int?
    var startedAt: Double?
    var vision: Bool?
    var kvFormat: String?
    var weightsReleased: Bool?
    var instancePid: Int?
    var instanceId: String?
    var buildId: String?

    var thermalText: String {
        switch thermal {
        case "nominal": return "正常"
        case "fair": return "偏热"
        case "serious": return "过热"
        case "critical": return "临界"
        default: return thermal ?? "—"
        }
    }

    var memoryPressureText: String {
        switch memoryPressure {
        case "normal": return "正常"
        case "warning": return "偏高"
        case "critical": return "紧张"
        default: return memoryPressure ?? "—"
        }
    }

    static func parse(_ json: [String: Any]) -> ServerStats {
        let metrics = dict(json["metrics"])
        let admission = dict(json["admission"])
        let instance = dict(json["instance"])
        let memory = dict(json["memory_actual"])
        let requests = dict(json["requests"])
        let plan = dict(json["memory_plan"])
        let device = dict(plan["device"])
        let kv = dict(json["kv"])
        let weights = dict(json["weights"])

        var stats = ServerStats()
        // 这里读到的是 splash 自己的累计比值，粒度如实标成 lifetimeMean：
        // 真·瞬时值在 `metrics.current_*_batch`，那条路径走 FlashCatKit 的解析器。
        stats.decodeTokensPerSecond = number(metrics["decode_tokens_per_second"])
        stats.decodeRateKind = (stats.decodeTokensPerSecond ?? 0) > 0 ? .lifetimeMean : .none
        stats.prefillTokensPerSecond = number(metrics["prefill_tokens_per_second"])
        stats.prefillRateKind = (stats.prefillTokensPerSecond ?? 0) > 0 ? .lifetimeMean : .none
        stats.draftAcceptance = number(metrics["draft_acceptance_rate"])
        stats.ttftMilliseconds = number(dict(metrics["ttft_ms"])["p50"])
        if let active = json["active_requests"] as? [Any] {
            stats.activeRequests = active.count
        } else {
            stats.activeRequests = Int(number(admission["restoring"]) ?? 0)
        }
        stats.queuedRequests = Int(number(admission["waiting"]) ?? 0)
        stats.thermal = metrics["thermal_state"] as? String ?? json["thermal_state"] as? String
        stats.memoryPressure = json["memory_pressure"] as? String
        stats.memoryBytes = Int(number(memory["current_bytes"]) ?? 0)
        stats.peakMemoryBytes = Int(number(memory["peak_bytes"]) ?? 0)
        stats.maximumContextTokens = Int(number(json["maximum_context_tokens"]) ?? 0)
        stats.model = instance["model"] as? String
        stats.requestsCompleted = Int(number(requests["completed"]) ?? 0)
        stats.requestsFailed = Int(number(requests["failed"]) ?? 0)
        stats.deviceName = device["device_name"] as? String
        stats.physicalMemoryBytes = Int(number(device["physical_memory_bytes"]) ?? 0)
        stats.gpuCores = Int(number(device["gpu_core_count"]) ?? 0)
        stats.startedAt = number(instance["started_at"])
        stats.vision = json["vision"] as? Bool
        stats.kvFormat = kv["format"] as? String
        stats.weightsReleased = weights["released"] as? Bool
        stats.instancePid = Int(number(instance["pid"]) ?? 0)
        stats.instanceId = instance["id"] as? String
        stats.buildId = dict(dict(json["identity"])["cache"])["build_id"] as? String
        return stats
    }

    private static func dict(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}
