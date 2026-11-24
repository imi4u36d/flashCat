// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// Streams a child process pipe line by line without blocking the main thread.
///
/// 缓冲区必须是引用类型：`readabilityHandler` 是 `@Sendable` 的，把 `var buffer`
/// 直接捕获进去，等于允许两条线程同时改同一块数据。锁只保护缓冲区，回调在锁外
/// 执行——`onLine` 里通常还要再跳一次主线程，持锁回调会把锁序搞乱。
package final class TailReader: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    package static func read(_ pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        let reader = TailReader()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reader.flush(onLine)
                return
            }
            reader.consume(chunk, onLine: onLine)
        }
    }

    private func consume(_ chunk: Data, onLine: @Sendable (String) -> Void) {
        lock.lock()
        let lines = splitter.consume(chunk)
        lock.unlock()
        // 回调在锁外：`onLine` 里通常还要再跳一次主线程，持锁回调会把锁序搞乱。
        for line in lines { onLine(line) }
    }

    private func flush(_ onLine: @Sendable (String) -> Void) {
        lock.lock()
        let rest = splitter.flush()
        lock.unlock()
        if let rest { onLine(rest) }
    }
}

/// 按行切分命令行输出。huggingface_hub 的 tqdm 用回车重画进度条，所以 Splash
/// 的下载在退出前只会吐 `\r`；两种换行都要切，空行（纯重画）丢掉。
package struct LineSplitter {
    private var buffer = Data()

    package mutating func consume(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = buffer.prefix(upTo: index)
            buffer.removeSubrange(...index)
            if !line.isEmpty, let text = String(data: line, encoding: .utf8) {
                lines.append(text)
            }
        }
        return lines
    }

    package mutating func flush() -> String? {
        defer { buffer = Data() }
        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else { return nil }
        return text
    }
}
