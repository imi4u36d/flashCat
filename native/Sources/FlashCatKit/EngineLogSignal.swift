// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// 引擎日志里真正需要在应用侧「动作」的只有两种：就绪与报错。
///
/// 这段判定原来长在 `EngineController.appendLog` 里：`line.contains("Ready ·")`
/// 再配一次 `line.lowercased().hasPrefix("error:")`。引擎的每一行日志都要跑一遍，
/// 而 `lowercased()` 会为每一行复制一份整串——一次冷启动两三万行就是两三万次
/// 分配，还都落在主队列上。这里改成在 `line.utf8` 的字节视图上比较：只有命中
/// 「报错」的那一行才构造一次小小的正文子串，其余行零分配，也不经过 Foundation
/// 的 ICU 搜索（那条路会先把 String 桥接成 NSString）。
/// 放在 Kit 而不是壳层：应用（`EngineController`、`LogStore`）与 CLI
/// （`logs` 的着色）都要用同一份「什么算就绪、什么算报错」，而 marker 的
/// 字符串与位置是引擎侧的知识，属于 Kit 的 `StatusParsers` 那一层。
public enum EngineLogSignal: Equatable, Sendable {
    /// 引擎自报就绪。状态迁移由 `EngineController.markReady()` 统一做，那里
    /// 还要撤启动看门狗，所以这里只报告「看到就绪了」。
    case ready
    /// 引擎自报的错误正文。可以直接显示：失败提示用它，比只给一个退出码有用。
    case error(String)
    /// 普通日志，没有需要动作的信号。
    case none

    /// `Ready ·` / `Error ·` 是引擎控制台自己的格式，可能跟在时间戳或级别
    /// 后面，所以只能整行找；大小写不放宽——放宽会把正文里提到这两个词的行
    /// 也当成状态迁移（模型输出、报错原文里出现它们并非不可能）。
    private static let readyMarker = Array("Ready ·".utf8)
    private static let errorMarker = Array("Error ·".utf8)
    /// flashcat_serve.py 把准备失败写成 `error: <正文>`：行首固定，大小写不保证
    /// （python 的 stderr 是引擎脚本自己写的）。
    private static let errorPrefix = Array("error:".utf8)

    public static func detect(_ line: String) -> EngineLogSignal {
        let bytes = line.utf8
        // 就绪优先：原来就是 if / else if，同一行里两者都出现时以就绪为准。
        if bytes.firstRange(of: Self.readyMarker) != nil { return .ready }
        if let payload = errorPayload(in: bytes) { return .error(payload) }
        return .none
    }

    /// 报错正文。两种标记的差别只在位置与大小写：`error:` 是行首协议前缀，
    /// `Error ·` 是出现在行中间的固定格式。
    private static func errorPayload(in bytes: String.UTF8View) -> String? {
        if let end = prefixEnd(in: bytes, matching: Self.errorPrefix) {
            return payload(in: bytes, from: end)
        }
        guard let range = bytes.firstRange(of: Self.errorMarker) else { return nil }
        return payload(in: bytes, from: range.upperBound)
    }

    /// 标记之后到行尾就是给人看的正文。只在报错行调用，复制这一小段是值得的，
    /// 但要去掉首尾空白：CRLF 流按 `\n` 切行时行尾会留一个 `\r`。
    /// 正文为空时退回整行，否则失败提示会变成空字符串——读的人只剩退出码可看。
    private static func payload(in bytes: String.UTF8View, from start: String.UTF8View.Index) -> String {
        let text = String(decoding: bytes[start...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 行首前缀比较，ASCII 大小写无关。多字节 UTF-8 的字节都 ≥ 0x80，
    /// 折叠大小写不会碰到中文。
    private static func prefixEnd(in bytes: String.UTF8View,
                                  matching needle: [UInt8]) -> String.UTF8View.Index? {
        var index = bytes.startIndex
        for expected in needle {
            guard index < bytes.endIndex else { return nil }
            guard lowercase(bytes[index]) == expected else { return nil }
            index = bytes.index(after: index)
        }
        return index
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ? byte | 0x20 : byte
    }
}
