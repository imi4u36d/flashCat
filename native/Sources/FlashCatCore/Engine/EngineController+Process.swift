// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Darwin
import FlashCatKit
import Foundation

extension EngineController {
    // MARK: process plumbing

    func processExited(_ finished: Process) {
        // A restart installs a new `process` while the old one's
        // terminationHandler is still queued. Trusting any callback would let
        // the old engine's exit tear down the new one: pollTimer invalidated,
        // `process` cleared, state forced to `.failed` — and no handle left to
        // stop the engine that is actually holding the weights.
        guard finished === process else { return }
        startupWatchdog?.cancel()
        startupWatchdog = nil
        removePidFile()
        pollTimer?.invalidate()
        pollTimer = nil
        process = nil
        flushBuffers()
        logs.close()
        stats = nil
        status = nil
        liveRates.reset()
        // 停止要先读一次：三行之后 `transition` 就把阶段改掉了，那时候再问
        // 「是不是读者点的停止」已经没人记得。
        let wasStopping = isStopping
        if wasStopping {
            logs.append("==> 服务已停止", level: .system)
            transition(to: .stopped)
        } else if finished.terminationStatus == 0 {
            transition(to: .stopped)
        } else {
            let message = lastError ?? "服务异常退出（退出码 \(finished.terminationStatus)）"
            failureMessage = message
            logs.append("==> \(message)", level: .system)
            transition(to: .failed(reason: message))
        }
        onChange()
    }

    func startReader(_ pipe: Pipe, index: Int) {
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        Thread {
            var scratch = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = read(descriptor, &scratch, scratch.count)
                if count <= 0 { break }
                let chunk = Data(scratch[0..<count])
                DispatchQueue.main.async { self.ingest(chunk, index: index) }
            }
        }.start()
    }

    func ingest(_ chunk: Data, index: Int) {
        lineBuffers[index].append(chunk)
        while let newline = lineBuffers[index].firstIndex(of: 0x0A) {
            let segment = lineBuffers[index].prefix(upTo: newline)
            lineBuffers[index].removeSubrange(lineBuffers[index].startIndex...newline)
            let line = String(data: segment, encoding: .utf8) ?? ""
            appendLog(line)
        }
    }

    func flushBuffers() {
        for index in 0..<2 {
            if !lineBuffers[index].isEmpty {
                appendLog(String(data: lineBuffers[index], encoding: .utf8) ?? "")
                lineBuffers[index] = Data()
            }
        }
    }

    func appendLog(_ line: String) {
        switch EngineLogSignal.detect(line) {
        case .ready:
            lastError = nil
            // 不再自己判断「是不是在启动中」：判定收进 `markReady` 的守卫与迁移
            // 表，停止中、已停止的迟到就绪也会走同一条路留一条告警，而重复就绪
            // 因为阶段没变被静默吞掉。
            markReady()
        case .error(let message):
            // flashcat_serve.py 的准备失败走 stderr 的 "error: ..."，留作失败提示，
            // 比只给一个退出码有用。存正文而不是整行：提示框里不该带 "error:" 前缀。
            lastError = message
        case .none:
            break
        }
        logs.append(line)
    }

    func note(_ line: String) {
        // Never open/close the sink here: `openFile()` reloads history from
        // disk and `close()` drops the handle, so a note written while the
        // engine was running used to stop every later line from reaching the
        // log file — which is the one place a reader looks when something
        // breaks. `append` already writes through the sink when one is open.
        logs.append(line, level: .system)
    }
}
