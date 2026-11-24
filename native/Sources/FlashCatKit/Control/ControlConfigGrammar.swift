// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 配置写入的错误分类。`Kind` 只在这里定义一次：HTTP 层把它映射成状态码、CLI
/// 层映射成退出码；否则「未知键」会在一个实现里是 404、在另一个实现里是
/// `exit 1`，同一条命令的在线与离线行为对不上。
public struct ControlConfigError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// 值不合法：调用方应该重写参数，不是去查环境。
        case usage
        /// 现在改不了（应用没在跑、要重启监听），重试也没用，得换路径。
        case conflict
        /// 键不存在。
        case notFound
        /// 键存在但只能由应用写。
        case readOnly
    }

    public let message: String
    public let kind: Kind
    /// 只有 CLI 会打印补充提示；HTTP 响应只取 `message`，所以这里可以为空。
    public let hint: String?

    public init(_ message: String, kind: Kind = .usage, hint: String? = nil) {
        self.message = message
        self.kind = kind
        self.hint = hint
    }

    public var errorDescription: String? { message }
}

/// 配置值的落盘形态。文档里显示的是字符串，但「显示成什么」不该由每个调用点
/// 各写一遍——`String(value)`、`String(format:)`、`value ? "true" : "false"`
/// 正是两份文档实现开始分叉的地方，所以统一交给 `ControlConfigGrammar.format`。
public enum ControlConfigValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
}

/// 配置项的纯规则层：解析、范围校验、端口归一、显示格式。
///
/// 在线文档（App 的 `ControlServer`）与离线文档（CLI 的 `OfflineConfig`）都读同一份
/// UserDefaults，任何一条「接受哪些别名 / 0 算不算配置 / 0.5 显示成什么」的规则
/// 如果各写一份，就一定会漂移；此前 `thinkingMode` 缺 `none`、每引擎端口把
/// `omlx` 的 8100 显示成 8000，都是这么来的。
public enum ControlConfigGrammar {
    public static let portRange = 1024...65535
    public static let maxTokensRange = 0...1_000_000
    /// `none` 与 `off`、`automatic` 与 `auto` 是同义写法：旧文档和社区脚本两种
    /// 都用过，写入口只认一种就会让「本来能用的命令」突然失败。
    public static let thinkingModeTokens = ["auto", "automatic", "none", "off", "on"]
    public static let appearanceTokens = ["system", "light", "dark", "studio", "studioDark"]
    public static let reasoningEffortTokens = ["low", "medium", "high", "xhigh"]

    // MARK: 解析

    public static func bool(_ raw: String, key: String) throws -> Bool {
        switch normalized(raw) {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: throw ControlConfigError("\(key) 需要 true / false")
        }
    }

    public static func int(_ raw: String, key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(normalized(raw)), range.contains(value) else {
            throw ControlConfigError("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的整数")
        }
        return value
    }

    public static func double(_ raw: String, key: String, range: ClosedRange<Double>) throws -> Double {
        guard let value = Double(normalized(raw)), range.contains(value) else {
            throw ControlConfigError("\(key) 需要 \(range.lowerBound)…\(range.upperBound) 的数字")
        }
        return value
    }

    /// 返回落盘用的原始值（0 / 1 / 2），不是文档 token；读方向见 `appearanceToken`。
    public static func appearance(_ raw: String) throws -> Int {
        guard let index = appearanceTokens.firstIndex(where: { normalized($0) == normalized(raw) }) else {
            throw ControlConfigError("appearance 只能是 \(appearanceTokens.joined(separator: " / "))")
        }
        return index
    }

    public static func thinkingMode(_ raw: String) throws -> Int {
        switch normalized(raw) {
        case "auto", "automatic": return 0
        case "off", "none": return 1
        case "on": return 2
        default: throw ControlConfigError("thinkingMode 只能是 \(thinkingModeTokens.joined(separator: " / "))")
        }
    }

    public static func reasoningEffort(_ raw: String) throws -> Int {
        guard let index = reasoningEffortTokens.firstIndex(of: normalized(raw)) else {
            throw ControlConfigError("reasoningEffort 只能是 \(reasoningEffortTokens.joined(separator: " / "))")
        }
        return index + 1
    }

    /// `0` 与负数都表示「没配置」：老版本把「没点过保存」写成 0，同一个端口如果
    /// 一处按 0 显示、另一处按默认端口显示，在线与离线文档就会差一个值。
    public static func port(_ value: Int?, fallback: Int) -> Int {
        guard let value, value > 0 else { return fallback }
        return value
    }

    // MARK: 显示

    public static func format(_ value: ControlConfigValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        // 固定用 POSIX 小数点是刻意的：配置文档是给脚本读的，0.70 不能因为用户
        // 所在地区变成 0,70；旧实现用 String(format:) 就埋着这个地区差异。
        case .double(let number): return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
        }
    }

    /// 落盘值 → 文档 token。读方向也只有这一份映射：在线与离线文档不会对同一个
    /// 整数解释出两个字符串；未知值沿用历史口径回落到默认项。
    public static func appearanceToken(_ raw: Int) -> String {
        guard appearanceTokens.indices.contains(raw) else { return appearanceTokens[0] }
        return appearanceTokens[raw]
    }

    public static func thinkingModeToken(_ raw: Int) -> String {
        switch raw {
        case 1: return "off"
        case 2: return "on"
        default: return "auto"
        }
    }

    public static func reasoningEffortToken(_ raw: Int) -> String {
        let index = min(max(raw - 1, 0), reasoningEffortTokens.count - 1)
        return reasoningEffortTokens[index]
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
