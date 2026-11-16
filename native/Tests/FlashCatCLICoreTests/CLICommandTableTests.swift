// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation
import XCTest

@testable import FlashCatCLICore

/// 命令表是「命令 / 选项 / 退出码」的唯一来源，所以这里测的是**投影没漂**：
/// help 里列出的每个命令都有自己的帮助页、每个非零退出码都有说明、
/// 每条控制接口路由都知道归谁发起。
final class CLICommandTableTests: XCTestCase {
    /// 把 CLIOutput 的 stdout / stderr 收集到同一个缓冲区：这两条流都是人看的
    /// 文案，断言时不必区分。
    private final class Capture {
        var text = ""

        var lines: [String] { text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
    }

    private func makeContext(
        command: String,
        subcommand: String? = nil,
        arguments: [String] = [],
        explicitCommand: Bool = true,
        capture: Capture
    ) -> CLIContext {
        let output = CLIOutput(
            json: false,
            quiet: false,
            color: false,
            verbose: false,
            stdout: {
                capture.text += $0
                return true
            },
            stderr: {
                capture.text += $0
                return true
            })
        let local = LocalState(
            environment: [:],
            defaults: nil,
            engineConfigurationFile: NSTemporaryDirectory()
                + "/flashcat-table-\(UUID().uuidString).json")
        return CLIContext(
            invocation: CLIInvocation(
                command: command,
                subcommand: subcommand,
                arguments: arguments,
                explicitCommand: explicitCommand),
            environment: [:],
            output: output,
            local: local,
            isTTY: false,
            stdinIsTTY: false,
            executable: "/usr/local/bin/flashcat")
    }

    /// 概览表的一行：命令名打在行首（`table` 会补齐列宽后再 trim，所以名字后面是空格）。
    private func hasRow(_ lines: [String], name: String) -> Bool {
        lines.contains { $0 == name || $0.hasPrefix(name + " ") }
    }

    // MARK: help 覆盖命令表

    func testOverviewListsEveryCommand() {
        let capture = Capture()
        HelpCommand.run(makeContext(command: "help", capture: capture))
        for command in CLICommandTable.commands {
            XCTAssertTrue(
                hasRow(capture.lines, name: command.name),
                "help 概览里没有命令 \(command.name)")
            XCTAssertTrue(
                capture.text.contains(command.summary),
                "help 概览里 \(command.name) 的说明没跟上表")
        }
    }

    func testEveryCommandHasItsOwnHelpPage() {
        for command in CLICommandTable.commands {
            let capture = Capture()
            HelpCommand.run(
                makeContext(
                    command: "help",
                    arguments: [command.name],
                    capture: capture))
            XCTAssertTrue(
                capture.text.contains(command.usage),
                "\(command.name) 的帮助页没打印用法行")
            for detail in command.details where !detail.isEmpty {
                XCTAssertTrue(
                    capture.text.contains(detail),
                    "\(command.name) 的帮助页漏了说明：\(detail)")
            }
            for option in command.options {
                XCTAssertTrue(
                    capture.text.contains(option.usageLabel),
                    "\(command.name) 的帮助页漏了选项 \(option.usageLabel)")
            }
        }
    }

    /// 全局选项在概览与每个命令页里都由表生成；少一个，用户就查不到它。
    func testGlobalOptionsAppearEverywhere() {
        let overview = Capture()
        HelpCommand.run(makeContext(command: "help", capture: overview))
        for option in CLICommandTable.globalOptions {
            XCTAssertTrue(
                overview.text.contains(option.usageLabel),
                "概览的全局选项里没有 \(option.usageLabel)")
        }
        for command in CLICommandTable.commands {
            let capture = Capture()
            HelpCommand.run(
                makeContext(
                    command: "help",
                    arguments: [command.name],
                    capture: capture))
            XCTAssertTrue(
                capture.text.contains(CLICommandTable.globalOptions[0].compactLabel),
                "\(command.name) 的帮助页没列全局选项")
        }
    }

    /// 别名要能对着帮助页使用（`flashcat help ps` 与 `status` 同页）。
    func testAliasHelpPagesResolve() {
        for (alias, name) in CLICommandTable.commandAliases where alias != name {
            let capture = Capture()
            HelpCommand.run(makeContext(command: "help", arguments: [alias], capture: capture))
            guard let command = CLICommandTable.command(named: name) else {
                XCTFail("别名 \(alias) 指向了不存在的命令 \(name)")
                continue
            }
            XCTAssertTrue(
                capture.text.contains(command.usage),
                "flashcat help \(alias) 没打到 \(name) 的帮助页")
        }
    }

    /// 未知主题打概览、不报错：帮助本身不该变成失败分支。
    func testUnknownTopicFallsBackToOverview() {
        let capture = Capture()
        HelpCommand.run(makeContext(command: "help", arguments: ["nope"], capture: capture))
        XCTAssertTrue(capture.text.contains("用法：flashcat <命令>"))
    }

    // MARK: 退出码

    func testEveryExitCodeHasExactlyOneSpec() {
        XCTAssertEqual(
            CLICommandTable.exitCodes.count, CLIExit.allCases.count,
            "退出码表与 CLIExit 的 case 数不一致")
        for code in CLIExit.allCases {
            guard let spec = CLICommandTable.exitCodeSpec(for: code) else {
                XCTFail("退出码 \(code.rawValue) 没有说明")
                continue
            }
            XCTAssertFalse(spec.summary.isEmpty, "退出码 \(code.rawValue) 的说明是空的")
        }
    }

    /// 脚本读的是码字，不是文案：非零码必须每一枚都有说明。
    func testEveryNonZeroExitCodeExplainsItself() {
        for code in CLIExit.allCases where code != .success {
            XCTAssertNotNil(
                CLICommandTable.summary(for: code),
                "非零退出码 \(code.rawValue) 在表里没有说明")
        }
    }

    func testOverviewPrintsEveryExitCode() {
        let capture = Capture()
        HelpCommand.run(makeContext(command: "help", capture: capture))
        for spec in CLICommandTable.exitCodes {
            XCTAssertTrue(
                hasRow(capture.lines, name: String(spec.code.rawValue)),
                "概览的退出码表里没有 \(spec.code.rawValue)")
            XCTAssertTrue(
                capture.text.contains(spec.summary),
                "概览的退出码表里没有 \(spec.code.rawValue) 的说明")
        }
    }

    /// 每个命令页只列自己可能出现的码，且都能查到说明。
    func testCommandPagesListOnlyKnownExitCodes() {
        for command in CLICommandTable.commands {
            XCTAssertFalse(command.exitCodes.isEmpty, "\(command.name) 没声明退出码")
            XCTAssertTrue(command.exitCodes.contains(.success), "\(command.name) 缺成功码")
            for code in command.exitCodes {
                XCTAssertNotNil(
                    CLICommandTable.summary(for: code),
                    "\(command.name) 列了没有说明的退出码 \(code.rawValue)")
            }
        }
    }

    /// HTTP 状态 → 退出码的映射也来自这张表：`ControlClient` 只负责查表。
    func testHTTPStatusMappingComesFromTheExitCodeTable() {
        for spec in CLICommandTable.exitCodes {
            for status in spec.httpStatuses {
                XCTAssertEqual(
                    ControlClient.exitCode(status: status, code: nil), spec.code,
                    "HTTP \(status) 应映射到退出码 \(spec.code.rawValue)")
            }
            for code in spec.controlErrorCodes {
                XCTAssertEqual(
                    ControlClient.exitCode(status: 500, code: code), spec.code,
                    "error.code=\(code) 应优先于 HTTP 状态")
            }
        }
        XCTAssertEqual(ControlClient.exitCode(status: 204, code: nil), .success)
        XCTAssertEqual(
            ControlClient.exitCode(status: 418, code: nil), .failure,
            "没有专门映射的状态应落到 .failure")
    }

    // MARK: 路由归属

    /// `ControlRoute` 全部 case。`sample(for:)` 的 switch 不写 `default`，
    /// 所以 Kit 里新增路由时这里**编译不过**，逼人先想清楚「谁发起它」。
    private static let allRoutes: [ControlRoute] = [
        .health, .status, .doctor, .config, .configSet, .downloads,
        .downloadPause, .downloadResume, .downloadCancel, .logs,
        .models, .modelUse, .modelDownload, .modelDelete,
        .gatewayStart, .gatewayStop, .appQuit, .appOpen,
        .engines, .enginesReload,
        .engineStart("omlx"), .engineStop("omlx"),
        .engineRestart("omlx"), .engineUse("omlx"),
    ]

    private static func sample(for route: ControlRoute) -> (method: String, path: String) {
        switch route {
        case .health: return ("GET", "/v1/health")
        case .status: return ("GET", "/v1/status")
        case .doctor: return ("GET", "/v1/doctor")
        case .config: return ("GET", "/v1/config")
        case .configSet: return ("POST", "/v1/config")
        case .downloads: return ("GET", "/v1/downloads")
        case .downloadPause: return ("POST", "/v1/downloads/pause")
        case .downloadResume: return ("POST", "/v1/downloads/resume")
        case .downloadCancel: return ("POST", "/v1/downloads/cancel")
        case .logs: return ("GET", "/v1/logs")
        case .models: return ("GET", "/v1/models")
        case .modelUse: return ("POST", "/v1/models/use")
        case .modelDownload: return ("POST", "/v1/models/download")
        case .modelDelete: return ("POST", "/v1/models/delete")
        case .gatewayStart: return ("POST", "/v1/gateway/start")
        case .gatewayStop: return ("POST", "/v1/gateway/stop")
        case .appQuit: return ("POST", "/v1/app/quit")
        case .appOpen: return ("POST", "/v1/app/open")
        case .engines: return ("GET", "/v1/engines")
        case .enginesReload: return ("POST", "/v1/engines/reload")
        case .engineStart(let id): return ("POST", "/v1/engines/\(id)/start")
        case .engineStop(let id): return ("POST", "/v1/engines/\(id)/stop")
        case .engineRestart(let id): return ("POST", "/v1/engines/\(id)/restart")
        case .engineUse(let id): return ("POST", "/v1/engines/\(id)/use")
        }
    }

    func testEveryControlRouteIsOwnedExactlyOnce() {
        let rows = CLICommandTable.routeOwnership
        XCTAssertEqual(
            rows.count, Self.allRoutes.count,
            "路由归属表缺行或多行（现在 \(rows.count) 行）")
        for route in Self.allRoutes {
            let matches = rows.filter { $0.route == route }
            XCTAssertEqual(matches.count, 1, "路由 \(route) 登记了 \(matches.count) 次")
            guard let row = matches.first else { continue }
            let expected = Self.sample(for: route)
            XCTAssertEqual(row.method, expected.method, "路由 \(route) 的方法写错了")
            XCTAssertEqual(row.path, expected.path, "路由 \(route) 的路径写错了")
            // 反查：表里的样例路径必须真的解析回这条路由，防止手抄错 id 或拼错段。
            XCTAssertEqual(
                ControlRoute.parse(method: row.method, path: row.path), route,
                "样例 \(row.method) \(row.path) 解析不回 \(route)")
            for command in row.commands {
                XCTAssertNotNil(
                    CLICommandTable.command(named: command),
                    "路由 \(route) 归属的命令 \(command) 不在命令表里")
            }
            XCTAssertFalse(row.summary.isEmpty, "路由 \(route) 没写归属说明")
        }
    }

    // MARK: 解析器投影

    func testParserTablesAreProjectionsOfTheCommandTable() {
        XCTAssertEqual(CLIArguments.valueOptions, CLICommandTable.valueOptionNames)
        XCTAssertEqual(CLIArguments.booleanOptions, CLICommandTable.booleanOptionNames)
        XCTAssertEqual(CLIArguments.listOptions, CLICommandTable.listOptionNames)
    }

    /// 表可以加东西，但不能丢东西：这些是 CLI 发布契约的一部分，
    /// 少一个，老脚本就从「能用」变成「未知选项 + 退出码 2」。
    func testLegacyOptionNamesAreAllStillAccepted() {
        let legacyValues: Set<String> = [
            "model", "engine", "engines", "for", "system", "temperature", "top-p",
            "max-tokens", "timeout", "interval", "lines", "level", "control-port",
            "control-url", "control-token", "gateway-url", "index", "release",
        ]
        let legacyFlags: Set<String> = [
            "json", "quiet", "verbose", "help", "version", "all", "wait", "follow",
            "shared", "stream", "no-stream", "show-reasoning", "no-color", "system-wide",
            "force", "yes", "watch", "no-reload", "gateway", "control", "app",
        ]
        XCTAssertTrue(
            legacyValues.isSubset(of: CLIArguments.valueOptions),
            "丢了取值选项：\(legacyValues.subtracting(CLIArguments.valueOptions))")
        XCTAssertTrue(
            legacyFlags.isSubset(of: CLIArguments.booleanOptions),
            "丢了布尔选项：\(legacyFlags.subtracting(CLIArguments.booleanOptions))")
        XCTAssertEqual(CLIArguments.listOptions, ["for"])
    }

    /// `--engines` 只在历史脚本里出现过：解析器继续接受，但不进帮助。
    func testUnlistedOptionParsesButStaysOutOfHelp() throws {
        let invocation = try CLIArguments.parse(["--engines", "splash", "models", "list"])
        XCTAssertEqual(invocation.command, "models")
        XCTAssertEqual(invocation.option("engines"), "splash")

        let capture = Capture()
        HelpCommand.run(makeContext(command: "help", capture: capture))
        for option in CLICommandTable.unlistedOptions {
            XCTAssertFalse(
                capture.text.contains(option.dashedName),
                "\(option.dashedName) 是兼容保留项，不该出现在帮助里")
        }
    }

    func testShortAliasesSurviveTheProjection() throws {
        let invocation = try CLIArguments.parse(["-j", "-q", "-m", "Qwen3-4B", "chat", "hi"])
        XCTAssertTrue(invocation.flag("json"))
        XCTAssertTrue(invocation.flag("quiet"))
        XCTAssertEqual(invocation.option("model"), "Qwen3-4B")
        XCTAssertEqual(invocation.command, "chat")
    }

    func testEveryRegisteredSubcommandSplits() throws {
        for (name, subcommands) in CLICommandTable.commandSubcommands {
            for subcommand in subcommands {
                let invocation = try CLIArguments.parse([name, subcommand])
                XCTAssertEqual(invocation.command, name)
                XCTAssertEqual(
                    invocation.subcommand, subcommand,
                    "\(name) 的子命令 \(subcommand) 没被拆出来")
            }
        }
    }

    func testCommandAliasesResolve() throws {
        XCTAssertEqual(try CLIArguments.parse(["ps"]).command, "status")
        XCTAssertEqual(try CLIArguments.parse(["info"]).command, "status")
        XCTAssertEqual(try CLIArguments.parse(["ask", "hi"]).command, "chat")
        let engines = try CLIArguments.parse(["engine", "list"])
        XCTAssertEqual(engines.command, "engines")
        XCTAssertEqual(engines.subcommand, "list")
    }

    // MARK: 补全脚本

    /// 补全脚本以前是第三份手写清单，还漏了 logs 组（`flashcat logs <TAB>` 没候选）。
    func testCompletionScriptsAreProjectedFromTheTable() throws {
        for shell in ["zsh", "bash", "fish"] {
            let capture = Capture()
            let code = try CompletionCommand.run(
                makeContext(
                    command: "completion",
                    subcommand: shell,
                    capture: capture))
            XCTAssertEqual(code, CLIExit.success.rawValue)
            for command in CLICommandTable.commands {
                XCTAssertTrue(
                    capture.text.contains(command.name),
                    "\(shell) 补全里没有命令 \(command.name)")
            }
            for (name, subcommands) in CLICommandTable.commandSubcommands {
                for subcommand in subcommands {
                    XCTAssertTrue(
                        capture.text.contains(subcommand),
                        "\(shell) 补全里没有 \(name) 的子命令 \(subcommand)")
                }
            }
            for option in CLICommandTable.listedOptions {
                XCTAssertTrue(
                    capture.text.contains(option.dashedName),
                    "\(shell) 补全里没有选项 \(option.dashedName)")
            }
        }
    }

    /// logs 组要单独钉一次：它是「补全清单」与「命令表」脱钩时的受害者。
    func testZshCompletionIncludesLogsGroup() throws {
        let capture = Capture()
        _ = try CompletionCommand.run(
            makeContext(
                command: "completion",
                subcommand: "zsh",
                capture: capture))
        XCTAssertTrue(
            capture.text.contains("    logs)"),
            "zsh 补全里没有 logs 组")
        for subcommand in ["engine", "gateway", "control"] {
            XCTAssertTrue(capture.text.contains(subcommand), "zsh 补全里没有 logs \(subcommand)")
        }
    }
}
