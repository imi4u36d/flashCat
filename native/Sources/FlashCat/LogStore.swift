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
}

/// One writer, one in-memory tail, one file. Shared by the engine and the 日志 page.
final class LogStore {
    private let lock = NSLock()
    private var lines: [LogLine] = []
    private var nextId = 0
    private var sink: FileHandle?
    private let limit = 20_000
    private var followOffset: UInt64 = 0

    func openFile() {
        Paths.ensureDirectory(Paths.logsDirectory)
        close()
        if !Paths.fileExists(Paths.logFile) {
            try? Data().write(to: URL(fileURLWithPath: Paths.logFile))
        }
        loadHistory()
        sink = FileHandle(forWritingAtPath: Paths.logFile)
        sink?.seekToEndOfFile()
        followOffset = Self.fileSize(Paths.logFile)
    }

    /// Seed the in-memory tail with what the engine already wrote, so attaching
    /// to a running service shows the session rather than an empty pane.
    private func loadHistory() {
        guard let text = try? String(contentsOfFile: Paths.logFile, encoding: .utf8) else { return }
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
        let size = Self.fileSize(Paths.logFile)
        guard size > followOffset else {
            if size < followOffset { followOffset = 0 }
            return
        }
        guard let handle = FileHandle(forReadingAtPath: Paths.logFile) else { return }
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
                if lines.count >= limit { lines.removeFirst(lines.count - limit) }
                lines.append(LogLine(id: nextId, time: parsed.time, text: parsed.text,
                                     level: Self.classify(parsed.text)))
            }
            lock.unlock()
        } catch {
            return
        }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// "[10:10:09] INFO Started" → (time, "INFO Started")
    private static func split(_ row: String) -> (time: Date, text: String) {
        guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else {
            return (Date(), row)
        }
        let stamp = String(row[row.index(after: row.startIndex)..<close])
        var text = String(row[row.index(after: close)...])
        if text.hasPrefix(" ") { text.removeFirst() }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return (formatter.date(from: stamp) ?? Date(), text)
    }

    func close() {
        sink?.closeFile()
        sink = nil
    }

    func append(_ text: String, level: LogLevel? = nil) {
        let resolved = level ?? Self.classify(text)
        lock.lock()
        if lines.count >= limit { lines.removeFirst(lines.count - limit) }
        nextId += 1
        lines.append(LogLine(id: nextId, time: Date(), text: text, level: resolved))
        sink?.write(("[" + Format.clock(Date()) + "] " + text + "\n").data(using: .utf8) ?? Data())
        lock.unlock()
    }

    /// Cheap change token: compare before copying the whole tail.
    var latestId: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextId
    }

    func snapshot() -> [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func tail(_ count: Int) -> [LogLine] {
        snapshot().suffix(count).reversed()
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
