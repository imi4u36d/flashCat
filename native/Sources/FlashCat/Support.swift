import Foundation
import Darwin
import CryptoKit

/// Thin NSRegularExpression wrappers. Swift regex literals are not available in
/// the Swift 5 language mode this target is built with.
enum TextPattern {
    static func firstMatch(_ pattern: String, _ text: String) -> [String]? {
        allMatches(pattern, text).first
    }

    static func allMatches(_ pattern: String, _ text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(location: 0, length: text.utf16.count)
        var result: [[String]] = []
        for match in expression.matches(in: text, options: [], range: range) {
            var groups: [String] = []
            // NSTextCheckingResult raises (not NSNotFound) when the index is past
            // the pattern's capture-group count, so stay inside numberOfRanges.
            for index in 0..<min(8, match.numberOfRanges) {
                let groupRange = match.range(at: index)
                if groupRange.location == NSNotFound {
                    groups.append("")
                } else if let swiftRange = Range(groupRange, in: text) {
                    groups.append(String(text[swiftRange]))
                } else {
                    groups.append("")
                }
            }
            result.append(groups)
        }
        return result
    }

    static func test(_ pattern: String, _ text: String) -> Bool {
        firstMatch(pattern, text) != nil
    }

    static func replace(_ pattern: String, _ text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: text.utf16.count),
            withTemplate: replacement
        )
    }
}

/// Shared paths, formatting helpers and low-level probes used across the app.
enum Paths {
    static var home: String {
        let value = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return value.isEmpty ? NSHomeDirectory() : value
    }

    /// `FLASHCAT_SUPPORT_DIR` keeps tests and trial runs out of the real
    /// application-support folder.
    static var supportDirectory: String {
        if let override = ProcessInfo.processInfo.environment["FLASHCAT_SUPPORT_DIR"], !override.isEmpty {
            return override
        }
        return home + "/Library/Application Support/flashCat"
    }
    static var logsDirectory: String { home + "/Library/Logs/flashCat" }
    static var logFile: String { logsDirectory + "/server.log" }
    static var pidFile: String { supportDirectory + "/server.pid" }
    static var runtimesDirectory: String { supportDirectory + "/runtimes" }
    static var activeRuntimeFile: String { supportDirectory + "/active-runtime" }
    static var conversationFile: String { supportDirectory + "/conversation.json" }
    static var historyFile: String { supportDirectory + "/chat-history.json" }

    static var modelsDirectory: String {
        let override = ProcessInfo.processInfo.environment["FLASHCAT_MODELS_DIR"] ?? ""
        return override.isEmpty ? home + "/.flashcat/models" : override
    }

    static var legacyModelsDirectory: String { supportDirectory + "/models" }

    static var splashModelsDirectory: String {
        let override = ProcessInfo.processInfo.environment["FLASHCAT_DATA_DIR"] ?? ""
        if !override.isEmpty { return override + "/models" }
        return home + "/Library/Application Support/Splash/models"
    }

    static func ensureDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

enum Format {
    static func size(_ bytes: Int) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return "\(Int(round(Double(bytes) / 1_000_000))) MB"
    }

    static func bytes(_ bytes: Int) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1 { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.1f KB", Double(bytes) / 1024)
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1000 { return String(format: "%.1fK", Double(value) / 1000) }
        return "\(value)"
    }

    static func compact(_ value: Double) -> String {
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// TCP connect probe against 127.0.0.1. A local connect resolves instantly:
/// refused means free, accepted means somebody is already listening.
func portOpen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    inet_aton("127.0.0.1", &address.sin_addr)

    let connected = withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(fd, socketAddress, UInt32(MemoryLayout<sockaddr_in>.size))
        }
    }
    return connected == 0
}

func waitForPortFree(_ port: Int, _ seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !portOpen(port) { return true }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return !portOpen(port)
}

func sendSignal(_ pid: Int32, _ signal: Int32) -> Bool {
    kill(pid, signal) == 0
}

/// Foundation does not expose NSTask's pid; the child's pid is what the port
/// reclaim logic needs, so it comes from the process's own bookkeeping.
func processPid(_ process: Process) -> Int32? {
    if let value = process.value(forKey: "pid") as? Int, value > 0 { return Int32(value) }
    return nil
}

func sha256(of path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { handle.closeFile() }
    var hasher = SHA256()
    while true {
        let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
        if chunk.isEmpty { break }
        do {
            hasher.update(data: chunk)
        } catch {
            return nil
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
