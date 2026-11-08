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

public enum CLIArguments {
    /// Options that always consume the following token. Anything else is a
    /// boolean flag, so `--json status` can never swallow `status`.
    public static let valueOptions: Set<String> = [
        "model", "engine", "engines", "for", "system", "temperature", "top-p",
        "max-tokens", "timeout", "interval", "lines", "level", "control-port",
        "control-url", "control-token", "gateway-url", "index", "release",
    ]

    public static let booleanOptions: Set<String> = [
        "json", "quiet", "verbose", "help", "version", "all", "wait", "follow",
        "shared", "stream", "no-stream", "show-reasoning", "no-color", "system-wide",
        "force", "yes", "watch", "no-reload", "gateway", "control", "app",
    ]

    /// Options that may be repeated. `--for omlx --for mtplx` appends instead
    /// of silently keeping only the last value; every other value option is a
    /// single setting where the last occurrence wins.
    public static let listOptions: Set<String> = ["for"]

    /// Options whose value must parse as a number. Rejecting a typo here is
    /// better than silently falling back to the default three layers down.
    private static let numericOptions: Set<String> = [
        "temperature", "top-p", "max-tokens", "timeout", "interval", "lines", "control-port",
    ]

    private static let shortAliases: [Character: String] = [
        "j": "json",
        "q": "quiet",
        "h": "help",
        "V": "version",
        "v": "verbose",
        "f": "follow",
        "w": "wait",
        "y": "yes",
        "a": "all",
        "m": "model",
        "e": "engine",
        "n": "lines",
        "t": "timeout",
    ]

    private static let groups: [String: Set<String>] = [
        "engines": ["list", "start", "stop", "restart", "use", "install", "uninstall", "port", "logs"],
        "models": ["list", "use", "download", "delete", "path"],
        "gateway": ["status", "start", "stop"],
        "config": ["list", "get", "set", "unset", "path"],
        "app": ["status", "open", "quit", "restart", "path"],
        "cli": ["install", "uninstall", "path"],
        "completion": ["zsh", "bash", "fish"],
        "logs": ["engine", "gateway", "control"],
    ]

    private static let commandAliases: [String: String] = [
        "engine": "engines",
        "model": "models",
        "ask": "chat",
        "ps": "status",
        "info": "status",
        "help": "help",
        "version": "version",
    ]

    public static func parse(_ raw: [String]) throws -> CLIInvocation {
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var positionals: [String] = []
        var index = 0
        var endOfOptions = false

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
                        throw CLIUsageError.missingValue("--\(key)")
                    }
                    try store(value, for: key, in: &options)
                } else if booleanOptions.contains(key) {
                    if let inlineValue {
                        options[key] = inlineValue
                    } else {
                        flags.insert(key)
                    }
                } else {
                    throw CLIUsageError.unknownOption("--\(key)")
                }
                continue
            }
            if token.hasPrefix("-"), token != "-" {
                let body = token.dropFirst()
                // Combined boolean short flags (`-jq`) plus a single value flag
                // (`-m name`) cover the useful cases without a full getopt.
                for (offset, character) in body.enumerated() {
                    guard let mapped = shortAliases[character] else {
                        throw CLIUsageError.unknownOption("-\(character)")
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
                            throw CLIUsageError.missingValue("-\(character)")
                        }
                        try store(value, for: mapped, in: &options)
                        break
                    }
                    flags.insert(mapped)
                }
                continue
            }
            positionals.append(token)
        }

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
                              in options: inout [String: String]) throws {
        if numericOptions.contains(key), Double(value) == nil {
            throw CLIUsageError.badValue("选项 --\(key) 需要数字，收到：\(value)")
        }
        if listOptions.contains(key), let existing = options[key], !existing.isEmpty {
            options[key] = existing + "," + value
        } else {
            options[key] = value
        }
    }
}
