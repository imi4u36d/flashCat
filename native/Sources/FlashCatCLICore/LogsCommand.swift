import Foundation
import FlashCatKit

public enum LogsCommand {
    public static func run(_ context: CLIContext, engineOverride: EngineID? = nil) async throws -> Int32 {
        let (source, engine) = try resolveSource(context, override: engineOverride)
        guard let path = context.local.logPath(source: source, engine: engine) else {
            throw CLIError("未知日志来源：\(source)", exit: .usage)
        }
        let limit = max(Int(context.invocation.option("lines") ?? "") ?? 200, 1)
        let levels = parseLevels(context.invocation.option("level"))
        let follow = context.invocation.flag("follow")

        var document: ControlLogDocument?
        if !follow {
            do {
                let location = try context.control
                var query = [URLQueryItem(name: "source", value: source),
                             URLQueryItem(name: "lines", value: String(limit))]
                if source == "engine" {
                    query.append(URLQueryItem(name: "engine", value: engine.rawValue))
                }
                if let level = context.invocation.option("level") {
                    query.append(URLQueryItem(name: "level", value: level))
                }
                let online: ControlLogDocument = try await location.client.get("/v1/logs",
                                                                               query: query,
                                                                               timeout: context.timeout)
                document = online
            } catch let error as CLIError where ControlFallback.shouldFallBack(error) {
                // 应用没运行才退回读文件；401/504 说明应用在跑，静默读文件会让人误以为
                // 在线日志源已经查过了，而实际是令牌或网关出了问题。
                document = nil
            }
        }

        if let document, !follow {
            if context.output.json {
                context.output.json(document)
            } else {
                for line in document.lines {
                    printLine(line, context.output)
                }
            }
            return CLIExit.success.rawValue
        }

        // The file is the source of truth for follow mode: it keeps growing
        // even when the control request that started the tail has finished.
        guard FileManager.default.fileExists(atPath: path) else {
            throw CLIError("日志文件还不存在：\(path)", exit: .notFound,
                           hint: source == "engine" ? "引擎启动后才会写日志" : nil)
        }
        var lines = tailLines(path, limit: limit)
        if !levels.isEmpty { lines = lines.filter { levels.contains(classify($0).rawValue) } }
        // 格式化器只建一次：以前每行 new 一个 ISO8601DateFormatter 再序列化，--follow
        // 上千行时这笔开销比读日志本身还大。
        let timestamp = ISO8601DateFormatter()
        for line in lines {
            emit(line, source: source, engine: engine, context: context, timestamp: timestamp)
        }
        guard follow else { return CLIExit.success.rawValue }

        var offset = fileSize(path)
        var pending = Data()
        while true {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let size = fileSize(path)
            if size < offset {
                offset = 0
                pending.removeAll()
            }
            guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { continue }
            do {
                try handle.seek(toOffset: offset)
                let data = handle.readDataToEndOfFile()
                handle.closeFile()
                offset = size
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let chunk = Data(pending[..<newline])
                    pending.removeSubrange(...(newline))
                    guard let text = String(data: chunk, encoding: .utf8),
                          !text.isEmpty else { continue }
                    if !levels.isEmpty, !levels.contains(classify(text).rawValue) { continue }
                    emit(text, source: source, engine: engine, context: context, timestamp: timestamp)
                }
            } catch {
                // A rotated/truncated file: start over next tick.
                offset = 0
            }
        }
    }

    // MARK: Source

    private static func resolveSource(_ context: CLIContext,
                                      override: EngineID?) throws -> (String, EngineID) {
        if let engine = override { return ("engine", engine) }
        if let raw = context.invocation.option("engine") {
            guard let engine = EngineID(rawValue: raw) else {
                throw CLIError("未知引擎：\(raw)", exit: .usage)
            }
            return ("engine", engine)
        }
        switch context.invocation.subcommand {
        case "engine": return ("engine", context.local.activeEngine)
        case "gateway": return ("gateway", context.local.activeEngine)
        case "control": return ("control", context.local.activeEngine)
        case "app": return ("app", context.local.activeEngine)
        default: break
        }
        if context.invocation.flag("gateway") { return ("gateway", context.local.activeEngine) }
        if context.invocation.flag("control") { return ("control", context.local.activeEngine) }
        if context.invocation.flag("app") { return ("app", context.local.activeEngine) }
        return ("engine", context.local.activeEngine)
    }

    private static func parseLevels(_ raw: String?) -> Set<String> {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Set(raw.split(separator: ",").map { token in
            switch token.trimmingCharacters(in: .whitespaces).lowercased() {
            case "warn", "warning": return "warning"
            case "err", "error": return "error"
            case "info": return "info"
            case "system", "app": return "system"
            case "success", "ready": return "success"
            default: return token.trimmingCharacters(in: .whitespaces).lowercased()
            }
        })
    }

    // MARK: Output

    private static func emit(_ text: String,
                             source: String,
                             engine: EngineID,
                             context: CLIContext,
                             timestamp: ISO8601DateFormatter) {
        let parsed = parse(text)
        if context.output.json {
            struct Line: Encodable {
                let date: String
                let level: String
                let text: String
                let engine: String?
            }
            let encoder = ControlJSON.encoder(pretty: false)
            // 日志行自带的 HH:mm:ss 才是这条日志发生的时间；用 `Date()` 会让每批
            // 回放出来的日志都盖上「现在」，cross-reference 时间线就断了。没有时间
            // 前缀的行只能退回当前时刻。
            let stamp = parsed.clock ?? timestamp.string(from: Date())
            do {
                let data = try encoder.encode(Line(date: stamp,
                                                   level: classify(parsed.text).rawValue,
                                                   text: parsed.text,
                                                   engine: source == "engine" ? engine.rawValue : nil))
                if let line = String(data: data, encoding: .utf8) {
                    context.output.line(line)
                }
            } catch {
                // 纯字符串结构不该编码失败；真失败时也不能把这一行吞掉，退回正文至少不丢日志。
                context.output.line(parsed.text)
            }
            return
        }
        let level = classify(parsed.text)
        let clock = parsed.clock ?? "--:--:--"
        let prefix = context.output.dim(clock + " ")
        let body: String
        switch level {
        case .error: body = context.output.red(parsed.text)
        case .warning: body = context.output.yellow(parsed.text)
        case .success: body = context.output.green(parsed.text)
        case .system: body = context.output.cyan(parsed.text)
        case .info: body = parsed.text
        }
        context.output.line(prefix + body)
    }

    private static func printLine(_ line: ControlLogLine, _ output: CLIOutput) {
        let clock = line.date.formatted(date: .omitted, time: .standard)
        let color: (String) -> String
        switch line.level {
        case "error": color = output.red
        case "warning": color = output.yellow
        case "success": color = output.green
        case "system": color = output.cyan
        default: color = { $0 }
        }
        output.line(output.dim(clock + " ") + color(line.text))
    }

    // MARK: Files

    /// 只读文件尾：以前 `logs -n 200` 会把整份日志读进内存，遇到几个 G 的 engine 日志
    /// 直接打满内存。从文件尾按 64 KiB 块往回读取，够 limit+1 个换行就停（多要一个换行
    /// 是因为末尾的换行只结束最后一行、并不开启新行），总读取量再封顶 8 MiB。
    /// internal 是为了让 LogsTailTests 能直接覆盖这段边界逻辑。
    static func tailLines(_ path: String, limit: Int) -> [String] {
        guard limit > 0, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { handle.closeFile() }
        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return []
        }
        guard size > 0 else { return [] }
        let chunkSize: UInt64 = 64 * 1024
        let maxBytes = 8 * 1024 * 1024
        var collected = Data()
        var position = size
        var newlines = 0
        var reachedStart = false
        while position > 0, newlines < limit + 1, collected.count < maxBytes {
            let length = min(chunkSize, position)
            position -= length
            do {
                try handle.seek(toOffset: position)
                let chunk = handle.readData(ofLength: Int(length))
                newlines += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                collected = chunk + collected
            } catch {
                return []
            }
            reachedStart = position == 0
        }
        var text = String(decoding: collected, as: UTF8.self)
        if !reachedStart, let firstNewline = text.firstIndex(of: "\n") {
            // 从文件中间开始读时，第一行多半是被截断的：整行丢掉，别输出半行。
            text = String(text[text.index(after: firstNewline)...])
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return rows.count > limit ? Array(rows.suffix(limit)) : rows
    }

    private static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func parse(_ raw: String) -> (clock: String?, text: String) {
        // Files are written as `[HH:mm:ss] message`.
        guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else {
            return (nil, raw)
        }
        let clock = String(raw[raw.index(after: raw.startIndex)..<close])
        let text = String(raw[raw.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (clock.isEmpty ? nil : clock, text)
    }

    private static func classify(_ text: String) -> LogLevel {
        // 引擎自报的就绪行与 `error:` 前缀由 Kit 的 `EngineLogSignal` 统一判定，
        // CLI 不再维护第二份 marker 字符串（应用侧 `LogStore` 用的是同一个函数）。
        switch EngineLogSignal.detect(text) {
        case .ready: return .success
        case .error: return .error
        case .none: break
        }
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("错误") { return .error }
        if lower.contains("warning") || lower.contains("warn") || lower.contains("警告") { return .warning }
        if text.hasPrefix("==> ") { return .system }
        return .info
    }
}

private enum LogLevel: String {
    case info
    case system
    case warning
    case error
    case success
}
