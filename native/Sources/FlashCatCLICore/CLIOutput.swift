import Darwin
import Foundation
import FlashCatKit

/// Process exit codes are part of the CLI contract: scripts can tell "app not
/// running" from "bad usage" without parsing stderr.
///
/// `CaseIterable` 是给测试和 `help` 用的：退出码的含义只在
/// `CLICommandTable.exitCodes` 里写一遍，遍历这里就能核对「每个码都有说明」。
public enum CLIExit: Int32, CaseIterable, Sendable {
    case success = 0
    case failure = 1
    case usage = 2
    case notRunning = 3
    case notFound = 4
    case timeout = 5
    case conflict = 6
    case unauthorized = 7
}

public struct CLIError: Error, LocalizedError, Sendable {
    public let message: String
    public let exit: CLIExit
    public let hint: String?

    public init(_ message: String, exit: CLIExit = .failure, hint: String? = nil) {
        self.message = message
        self.exit = exit
        self.hint = hint
    }

    public var errorDescription: String? { message }
}

/// 直接对文件描述符写，而不是 `FileHandle.write(_:)`：后者在 EPIPE 时抛的是
/// ObjC 异常，Swift 的 do/catch 接不住，会让 `flashcat chat … | head -1` 直接崩掉。
/// 入口忽略 SIGPIPE 之后 `write(2)` 只会返回 -1，把失败变成返回值就能安静收场。
public enum CLIStandardIO {
    /// 返回 false 表示这次没写成功（典型是下游关掉了管道），调用方应当放弃后续写入。
    @discardableResult
    public static func write(_ text: String, to descriptor: Int32) -> Bool {
        let bytes = Data(text.utf8)
        return bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                // EINTR 是被信号打断，重试即可；EPIPE 及其它错误都是不可恢复的。
                if written < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }
}

/// ANSI colour is opt-out: `--no-color`, a non-tty stdout, or `NO_COLOR` all
/// turn it off. Machine-readable `--json` output never contains escapes.
public final class CLIOutput {
    public var json: Bool
    public var quiet: Bool
    public var color: Bool
    public var verbose: Bool

    /// stdout 已被下游关闭（典型是 `flashcat chat … | head -1`）。EPIPE 不会自愈，
    /// 之后的每次写都只会再失败一次；命令据此提前收手，进程按 0 退出（coreutils 约定）。
    public private(set) var brokenPipe = false

    private let stdoutWrite: (String) -> Bool
    private let stderrWrite: (String) -> Bool

    public init(json: Bool = false,
                quiet: Bool = false,
                color: Bool = false,
                verbose: Bool = false,
                stdout: @escaping (String) -> Bool = {
                    CLIStandardIO.write($0, to: FileHandle.standardOutput.fileDescriptor)
                },
                stderr: @escaping (String) -> Bool = {
                    CLIStandardIO.write($0, to: FileHandle.standardError.fileDescriptor)
                }) {
        self.json = json
        self.quiet = quiet
        self.color = color && !json
        self.verbose = verbose
        self.stdoutWrite = stdout
        self.stderrWrite = stderr
    }

    // MARK: Basic writes

    public func write(_ text: String) {
        guard !brokenPipe else { return }
        if !stdoutWrite(text) { brokenPipe = true }
    }

    public func line(_ text: String = "") {
        write(text + "\n")
    }

    public func errorLine(_ text: String) {
        // stderr 断了没有恢复动作，也没有别的通道汇报这件事；忽略返回值，
        // 但不能因此连带上游把已经成功写出的 stdout 结果当成失败。
        _ = stderrWrite(text + "\n")
    }

    /// Partial stderr write for streaming reasoning; no forced newline.
    public func errorText(_ text: String) {
        _ = stderrWrite(text)
    }

    /// Status/progress messages go to stderr so `flashcat models download |
    /// jq` keeps stdout clean.
    public func note(_ text: String) {
        guard !quiet else { return }
        _ = stderrWrite(paint(text, "2") + "\n")
    }

    public func success(_ text: String) {
        guard !quiet, !json else { return }
        line(paint(text, "32"))
    }

    public func warning(_ text: String) {
        guard !quiet else { return }
        errorLine(paint(text, "33"))
    }

    // MARK: JSON

    public func encode<T: Encodable>(_ value: T) -> String {
        do {
            let data = try ControlJSON.encoder(pretty: true).encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return #"{"error":"encode_failed"}"#
        }
    }

    public func json<T: Encodable>(_ value: T) {
        line(encode(value))
    }

    public func jsonError(_ error: CLIError) {
        struct Body: Encodable {
            let ok: Bool
            let error: ControlErrorBody
            let hint: String?
        }
        // JSON errors go to stderr like every other failure; stdout stays a
        // clean data channel.
        errorLine(encode(Body(ok: false,
                              error: ControlErrorBody(code: "cli_error", message: error.message),
                              hint: error.hint)))
    }

    // MARK: Tables

    public func table(headers: [String], rows: [[String]], empty: String? = nil) {
        guard !rows.isEmpty else {
            if let empty { line(empty) }
            return
        }
        // Header cells are measured with the same display-width rule as body
        // cells: `count` treats every CJK glyph as one column and pushes the
        // first row out of line.
        var widths = headers.map(displayWidth)
        for row in rows {
            if row.count > widths.count {
                widths.append(contentsOf: repeatElement(0, count: row.count - widths.count))
            }
            for (index, cell) in row.enumerated() {
                widths[index] = max(widths[index], displayWidth(cell))
            }
        }
        func render(_ cells: [String], bold: Bool) -> String {
            cells.enumerated().map { index, cell in
                let width = index < widths.count ? widths[index] : displayWidth(cell)
                let pad = String(repeating: " ", count: max(0, width - displayWidth(cell)))
                let text = cell + pad
                return bold ? paint(text, "1") : text
            }
            .joined(separator: "  ")
            .trimmingCharacters(in: .whitespaces)
        }
        line(render(headers, bold: true))
        line(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        for row in rows { line(render(row, bold: false)) }
    }

    /// CJK glyphs occupy two terminal cells; `count` would misalign every
    /// table containing a Chinese model name.
    private func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (scalar.value >= 0x1100 ? 2 : 1)
        }
    }

    // MARK: Colour

    public func paint(_ text: String, _ code: String) -> String {
        guard color else { return text }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    public func bold(_ text: String) -> String { paint(text, "1") }
    public func dim(_ text: String) -> String { paint(text, "2") }
    public func green(_ text: String) -> String { paint(text, "32") }
    public func yellow(_ text: String) -> String { paint(text, "33") }
    public func red(_ text: String) -> String { paint(text, "31") }
    public func cyan(_ text: String) -> String { paint(text, "36") }
}

public enum CLIFormat {
    public static func bytes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        let gigabytes = Double(value) / 1_073_741_824
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        let megabytes = Double(value) / 1_048_576
        if megabytes >= 1 { return String(format: "%.0f MB", megabytes) }
        return String(format: "%.0f KB", Double(value) / 1024)
    }

    public static func rate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        if value >= 1_048_576 { return String(format: "%.1f MB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }

    public static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        if seconds >= 3600 {
            return String(format: "%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
        }
        if seconds >= 60 { return String(format: "%dm%02ds", seconds / 60, seconds % 60) }
        return "\(seconds)s"
    }

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    public static func bool(_ value: Bool) -> String { value ? "yes" : "no" }

    /// One wording for `ControlEngineState.state` across `status` and
    /// `engines list`; two copies had already drifted before.
    public static func engineState(_ raw: String) -> String {
        switch raw {
        case "ready": return "运行中"
        case "starting": return "启动中"
        case "stopping": return "停止中"
        case "failed": return "异常"
        default: return "已停止"
        }
    }
}
