import Foundation

enum LogLevel: String {
    case info = "info"
    case system = "system"
    case warning = "warning"
    case error = "error"
    case success = "success"

    var label: String {
        switch self {
        case .info: return "INFO"
        case .system: return "APP"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .success: return "READY"
        }
    }
}

struct LogLine: Identifiable {
    let id: Int
    let time: Date
    let text: String
    let level: LogLevel
    /// 行首时间在创建时格式化一次；日志页滚动/悬停会反复重建行视图，
    /// 每帧都跑 `DateFormatter` 没有必要。
    let clockText: String

    init(id: Int, time: Date, text: String, level: LogLevel) {
        self.id = id
        self.time = time
        self.text = text
        self.level = level
        self.clockText = Format.clock(time)
    }
}

/// One writer, one in-memory tail, one file. Shared by the engine and the 日志 page.
final class LogStore {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var nextId = 0
    private var sink: FileHandle?
    private let limit = 20_000
    /// 到达上限后批量裁剪，而不是每来一行 `removeFirst` 一次——后者每次都要
    /// 搬移两万个元素，日志密集时会明显占住写入线程。
    private let trimChunk = 512
    private var followOffset: UInt64 = 0
    /// Every engine keeps its own log file; splash uses the legacy path.
    let path: String

    init(path: String = Paths.logFile) {
        self.path = path
    }

    func openFile() {
        Paths.ensureDirectory(Paths.logsDirectory)
        close()
        if !Paths.fileExists(path) {
            try? Data().write(to: URL(fileURLWithPath: path))
        }
        loadHistory()
        sink = FileHandle(forWritingAtPath: path)
        sink?.seekToEndOfFile()
        followOffset = Self.fileSize(path)
    }

    /// Seed the in-memory tail with what the engine already wrote, so attaching
    /// to a running service shows the session rather than an empty pane.
    private func loadHistory() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)
        lock.lock()
        lines.removeAll(keepingCapacity: true)
        nextId = 0
        for row in rows {
            let raw = String(row)
            let parsed = Self.split(raw)
            nextId += 1
            lines.append(LogLine(id: nextId, time: parsed.time, text: parsed.text,
                                 level: Self.classify(parsed.text)))
        }
        lock.unlock()
    }

    /// Pick up lines another process appended to the shared log file.
    func pollFollow() {
        let size = Self.fileSize(path)
        guard size > followOffset else {
            if size < followOffset { followOffset = 0 }
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { handle.closeFile() }
        do {
            try handle.seek(toOffset: followOffset)
            let data = handle.readDataToEndOfFile()
            followOffset = size
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            lock.lock()
            for row in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let parsed = Self.split(String(row))
                nextId += 1
                lines.append(LogLine(id: nextId, time: parsed.time, text: parsed.text,
                                     level: Self.classify(parsed.text)))
            }
            trimIfNeededLocked()
            lock.unlock()
        } catch {
            return
        }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static let timeFormatterLock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// "[10:10:09] INFO Started" → (time, "INFO Started")
    private static func split(_ row: String) -> (time: Date, text: String) {
        guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else {
            return (Date(), row)
        }
        let stamp = String(row[row.index(after: row.startIndex)..<close])
        var text = String(row[row.index(after: close)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        timeFormatterLock.lock()
        let date = timeFormatter.date(from: stamp) ?? Date()
        timeFormatterLock.unlock()
        return (date, text)
    }

    func close() {
        sink?.closeFile()
        sink = nil
    }

    func append(_ text: String, level: LogLevel? = nil) {
        let resolved = level ?? Self.classify(text)
        let now = Date()
        lock.lock()
        nextId += 1
        lines.append(LogLine(id: nextId, time: now, text: text, level: resolved))
        trimIfNeededLocked()
        sink?.write(("[" + Format.clock(now) + "] " + text + "\n").data(using: .utf8) ?? Data())
        lock.unlock()
    }

    /// 调用方必须已持有 `lock`。
    private func trimIfNeededLocked() {
        guard lines.count >= limit else { return }
        let remove = min(lines.count, lines.count - limit + trimChunk)
        lines.removeFirst(remove)
    }

    /// Cheap change token: compare before copying the whole tail.
    var latestId: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextId
    }

    /// UI 只显示尾部即可，没必要每来一行就把两万行整表复制给 `@Published`。
    func snapshot(limit: Int? = nil) -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        guard let limit, lines.count > limit else { return lines }
        return Array(lines.suffix(limit))
    }

    /// Reverse tail for the stage line, which the snapshot reads once a second.
    /// Slicing inside the lock avoids copying the whole 20k-line buffer just to
    /// throw all but a handful away.
    func tail(_ count: Int) -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(count).reversed())
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    static func classify(_ text: String) -> LogLevel {
        if text.contains("Error ·") || text.lowercased().contains("error:") { return .error }
        if text.lowercased().contains("warning") || text.lowercased().contains("warn ·") { return .warning }
        if text.contains("Ready ·") { return .success }
        if text.hasPrefix("==> flashCat") || text.hasPrefix("==> ") { return .system }
        return .info
    }
}
