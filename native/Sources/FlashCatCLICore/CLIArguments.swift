import Foundation

/// What a command line looked like after parsing. Grouped subcommands are
/// handled here (`engines start omlx` → command `engines`, subcommand `start`,
/// args `["omlx"]`) so every command implementation receives the same shape.
public struct CLIInvocation: Equatable, Sendable {
    public var command: String
    public var subcommand: String?
    public var arguments: [String]
    public var options: [String: String]
    public var flags: Set<String>
    /// False when the command is only the default (`status`). `--help` on a
    /// bare invocation should print the overview, not status help.
    public var explicitCommand: Bool

    public init(command: String,
                subcommand: String? = nil,
                arguments: [String] = [],
                options: [String: String] = [:],
                flags: Set<String> = [],
                explicitCommand: Bool = false) {
        self.command = command
        self.subcommand = subcommand
        self.arguments = arguments
        self.options = options
        self.flags = flags
        self.explicitCommand = explicitCommand
    }

    public func option(_ key: String) -> String? {
        options[key]
    }

    public func flag(_ key: String) -> Bool {
        flags.contains(key)
    }

    /// `--for a,b` and repeated `--for a --for b` both work.
    public func listOption(_ key: String) -> [String] {
        guard let raw = options[key] else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

public enum CLIUsageError: Error, LocalizedError, Equatable {
    case unknownOption(String)
    case missingValue(String)
    case missingCommand(String)
    case badValue(String)

    public var errorDescription: String? {
        switch self {
        case .unknownOption(let option): return "未知选项：\(option)"
        case .missingValue(let option): return "选项 \(option) 缺少值"
        case .missingCommand(let command): return "命令 \(command) 缺少参数"
        case .badValue(let message): return message
        }
    }
}

/// 参数解析。选项与子命令的事实全部来自 `CLICommandTable`，这里只做投影。
///
/// 为什么不留自己的表：解析器认识什么、`help` 写什么、退出码怎么映射，必须是
/// 同一份事实。以前这里是硬编码的第二份拷贝，「help 里没有、但解析器认识」的
/// 幽灵选项就是这么来的；`--engines` 至今还是这副样子（见 `unlistedOptions`）。
public enum CLIArguments {
    /// 吃值的选项：`--model x` 会把后面的词当值，其余按布尔开关处理，
    /// 所以 `--json status` 永远不会把 `status` 吞掉。
    public static let valueOptions: Set<String> = CLICommandTable.valueOptionNames

    /// 布尔开关。
    public static let booleanOptions: Set<String> = CLICommandTable.booleanOptionNames

    /// 可重复累积的选项。`--for omlx --for mtplx` 追加而不是只留最后一个；
    /// 其余取值选项是单值设置，最后一次出现覆盖前面（与 shell 里 `export` 的直觉一致）。
    public static let listOptions: Set<String> = CLICommandTable.listOptionNames

    /// 值必须是数字的选项。在这一层就拦住拼写错误，比三层之下悄悄回落默认值好：
    /// 后者会让 `--timeout 6O0` 看起来「生效了」。
    private static let numericOptions: Set<String> = CLICommandTable.numberOptionNames

    private static let shortAliases: [Character: String] = CLICommandTable.shortAliases

    private static let groups: [String: Set<String>] = CLICommandTable.commandGroups

    private static let commandAliases: [String: String] = CLICommandTable.commandAliases

    public static func parse(_ raw: [String]) throws -> CLIInvocation {
        let result = parseTolerant(raw)
        if let error = result.error { throw error }
        return result.invocation
    }

    /// 容错版本的解析：遇到第一个错误记下来，继续把剩下的参数扫完。
    ///
    /// `CLI.run` 需要它：`flashcat --json status --nope` 是用法错误，但错误提示也得
    /// 遵守「--json 时 stderr 出 JSON、--no-color 不加转义、--quiet 不刷提示」的约定，
    /// 而这几项只有扫完参数才知道。先宽容解析拿到 invocation，再把第一个错误报出去，
    /// 就不用在校验失败时重猜一遍 `--json`。
    static func parseTolerant(_ raw: [String]) -> (invocation: CLIInvocation, error: CLIUsageError?) {
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0
        var endOfOptions = false
        var firstError: CLIUsageError?
        func record(_ error: CLIUsageError) {
            if firstError == nil { firstError = error }
        }

        while index < raw.count {
            let token = raw[index]
            index += 1
            if endOfOptions {
                positionals.append(token)
                continue
            }
            if token == "--" {
                endOfOptions = true
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                guard !body.isEmpty else { continue }
                let key: String
                let inlineValue: String?
                if let equals = body.firstIndex(of: "=") {
                    key = String(body[..<equals])
                    inlineValue = String(body[body.index(after: equals)...])
                } else {
                    key = body
                    inlineValue = nil
                }
                if valueOptions.contains(key) {
                    let value: String
                    if let inlineValue {
                        value = inlineValue
                    } else if index < raw.count {
                        value = raw[index]
                        index += 1
                    } else {
                        record(.missingValue("--\(key)"))
                        continue
                    }
                    if let error = store(value, for: key, in: &options) { record(error) }
                } else if booleanOptions.contains(key) {
                    // 布尔选项的显式取值也要落进 flags：只写进 options 的话
                    // `--json=false` 会被 flag("json") 当成「没给」，`--wait=true`
                    // 会被当成「没开」，同一个开关出现两套判定。
                    let literal: Bool?
                    if let inlineValue {
                        guard let parsed = booleanLiteral(inlineValue) else {
                            record(.badValue("选项 --\(key) 只接受 true/false，收到：\(inlineValue)"))
                            continue
                        }
                        literal = parsed
                    } else {
                        // 只有 true/false 两个字面量会被当成取值，所以 `--json status`
                        // 不会把子命令吞成 json 的值；`--json true` 又能工作。
                        literal = index < raw.count ? booleanLiteral(raw[index]) : nil
                        if literal != nil { index += 1 }
                    }
                    guard let literal else {
                        flags.insert(key)
                        continue
                    }
                    if literal {
                        flags.insert(key)
                    } else {
                        flags.remove(key)
                    }
                } else {
                    record(.unknownOption("--\(key)"))
                }
                continue
            }
            if token.hasPrefix("-"), token != "-" {
                let body = token.dropFirst()
                // Combined boolean short flags (`-jq`) plus a single value flag
                // (`-m name`) cover the useful cases without a full getopt.
                for (offset, character) in body.enumerated() {
                    guard let mapped = shortAliases[character] else {
                        record(.unknownOption("-\(character)"))
                        continue
                    }
                    if valueOptions.contains(mapped) {
                        let rest = String(body.dropFirst(offset + 1))
                        let value: String
                        if !rest.isEmpty {
                            value = rest
                        } else if index < raw.count {
                            value = raw[index]
                            index += 1
                        } else {
                            record(.missingValue("-\(character)"))
                            break
                        }
                        if let error = store(value, for: mapped, in: &options) { record(error) }
                        break
                    }
                    flags.insert(mapped)
                }
                continue
            }
            positionals.append(token)
        }

        return (makeInvocation(options: options, flags: flags, positionals: positionals), firstError)
    }

    /// 布尔选项认得的字面量。故意只有 true/false：把 `1`/`yes` 也算上会更容易
    /// 把用户的提示词或文件名当成开关取值吞掉。
    private static func booleanLiteral(_ token: String) -> Bool? {
        switch token {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func makeInvocation(options: [String: String],
                                       flags: Set<String>,
                                       positionals: [String]) -> CLIInvocation {
        guard !positionals.isEmpty else {
            return CLIInvocation(command: "status", options: options, flags: flags,
                                 explicitCommand: false)
        }
        var command = positionals[0]
        var rest = Array(positionals.dropFirst())
        if let alias = commandAliases[command] {
            command = alias
        }
        // Top-level aliases that are really a subcommand of `engines`.
        if command == "start" || command == "stop" || command == "restart" || command == "use" {
            return CLIInvocation(command: "engines", subcommand: command,
                                arguments: rest, options: options, flags: flags,
                                explicitCommand: true)
        }
        if command == "ls" {
            return CLIInvocation(command: "models", subcommand: "list",
                                arguments: rest, options: options, flags: flags,
                                explicitCommand: true)
        }
        var subcommand: String?
        if let group = groups[command], let first = rest.first, group.contains(first) {
            subcommand = first
            rest.removeFirst()
        }
        return CLIInvocation(command: command, subcommand: subcommand,
                            arguments: rest, options: options, flags: flags,
                            explicitCommand: true)
    }

    /// Validate and record one value option. List options accumulate so a
    /// repeated `--for` is additive rather than a silent overwrite.
    private static func store(_ value: String,
                              for key: String,
                              in options: inout [String: String]) -> CLIUsageError? {
        if numericOptions.contains(key), Double(value) == nil {
            return .badValue("选项 --\(key) 需要数字，收到：\(value)")
        }
        if listOptions.contains(key), let existing = options[key], !existing.isEmpty {
            options[key] = existing + "," + value
        } else {
            options[key] = value
        }
        return nil
    }
}
