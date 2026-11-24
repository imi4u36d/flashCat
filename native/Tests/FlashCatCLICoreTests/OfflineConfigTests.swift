// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation
import XCTest

@testable import FlashCatCLICore

/// `OfflineConfig` 的测试只碰临时 UserDefaults 域和临时 `engines.json`：
/// 它写的是「应用偏好」，用真实域跑测试会改坏开发机上的设置。
final class OfflineConfigTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var configurationFile = ""
    private var context: CLIContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "flashcat-offline-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = NSTemporaryDirectory() + "/flashcat-offline-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        configurationFile = directory + "/engines.json"
        context = makeContext()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        let directory = (configurationFile as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.removeItem(atPath: directory)
        }
        try super.tearDownWithError()
    }

    private func makeContext() -> CLIContext {
        let local = LocalState(
            environment: [:], defaults: defaults,
            engineConfigurationFile: configurationFile)
        return CLIContext(
            invocation: CLIInvocation(command: "config"),
            environment: [:],
            output: CLIOutput(),
            local: local,
            isTTY: false,
            stdinIsTTY: false,
            executable: "/usr/local/bin/flashcat")
    }

    private func writeEngines(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: URL(fileURLWithPath: configurationFile))
    }

    private func entry(_ entries: [ControlConfigEntry], _ key: String) throws -> ControlConfigEntry {
        try XCTUnwrap(entries.first { $0.key == key }, "缺少配置项 \(key)")
    }

    // MARK: 引擎端口

    func testUnconfiguredEnginePortFallsBackToItsOwnDefault() throws {
        // 没有 engines.json 时，omlx 必须显示 8100；旧实现统一写死 8000。
        let entries = OfflineConfig.entries(context)
        XCTAssertEqual(try entry(entries, "engines.omlx.port").value, "8100")
        XCTAssertEqual(try entry(entries, "engines.splash.port").value, "8000")
        XCTAssertEqual(try entry(entries, "engines.mlx-serve.port").value, "8300")
    }

    func testZeroConfiguredEnginePortIsTreatedAsUnset() throws {
        try writeEngines(["omlx": ["port": 0], "splash": ["port": 0]])
        let entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "engines.omlx.port").value, "8100")
        XCTAssertEqual(try entry(entries, "engines.splash.port").value, "8000")
    }

    func testConfiguredEnginePortIsReportedVerbatim() throws {
        try writeEngines(["omlx": ["port": 8123]])
        let entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "engines.omlx.port").value, "8123")
    }

    func testOfflineEnginePortMatchesKitDocument() throws {
        // 离线配置文档与引擎文档必须是同一个端口规则，不能各算一遍。
        try writeEngines(["omlx": ["port": 0]])
        let entries = OfflineConfig.entries(makeContext())
        let inputs = context.local.engineDocumentInputs()
        let omlx = try XCTUnwrap(inputs.first { $0.id == .omlx })
        XCTAssertEqual(
            try entry(entries, "engines.omlx.port").value,
            ControlConfigGrammar.format(.int(ControlEngineDocuments.port(omlx))))
    }

    // MARK: 内建接口

    func testInterfaceFlagsReportAlwaysOn() throws {
        let entries = OfflineConfig.entries(context)
        XCTAssertEqual(try entry(entries, "gatewayEnabled").value, "true")
        XCTAssertEqual(try entry(entries, "controlAPIEnabled").value, "true")
        XCTAssertFalse(try entry(entries, "gatewayEnabled").mutable)
        XCTAssertFalse(try entry(entries, "controlAPIEnabled").mutable)
    }

    func testInterfaceFlagsRejectWritesOffline() {
        for key in ["gatewayEnabled", "controlAPIEnabled"] {
            XCTAssertThrowsError(try OfflineConfig.set(key: key, value: "false", context: context)) {
                guard let error = $0 as? CLIError else {
                    return XCTFail("期望 CLIError，实际 \($0)")
                }
                XCTAssertEqual(error.exit, .usage)
                XCTAssertTrue(error.message.contains("始终启用"))
            }
        }
    }

    // MARK: 根端口

    func testRootPortNormalizesToDefault() throws {
        // 没写过 port 或写成 0 都按 8000 报；在线文档也是这个口径。
        var entries = OfflineConfig.entries(context)
        XCTAssertEqual(try entry(entries, "port").value, "8000")

        defaults.set(0, forKey: "port")
        entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "port").value, "8000")

        defaults.set(8123, forKey: "port")
        entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "port").value, "8123")
    }

    // MARK: thinkingMode

    func testThinkingModeNoneIsAcceptedOffline() throws {
        // 回归：离线解析器以前只认 off，`config set thinkingMode none` 在应用没开时失败。
        XCTAssertNoThrow(try OfflineConfig.set(key: "thinkingMode", value: "none", context: context))
        XCTAssertEqual(defaults.integer(forKey: "thinkingMode"), 1)
        let entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "thinkingMode").value, "off")
    }

    func testThinkingModeAutomaticIsAcceptedOffline() throws {
        XCTAssertNoThrow(try OfflineConfig.set(key: "thinkingMode", value: "automatic", context: context))
        XCTAssertEqual(defaults.integer(forKey: "thinkingMode"), 0)
        let entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "thinkingMode").value, "auto")
    }

    func testThinkingModeRejectsUnknownValueWithUsageExit() throws {
        XCTAssertThrowsError(try OfflineConfig.set(key: "thinkingMode", value: "sometimes", context: context)) {
            guard let error = $0 as? CLIError else {
                return XCTFail("期望 CLIError，实际 \($0)")
            }
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("thinkingMode"))
        }
    }

    // MARK: 值格式

    func testOfflineBoolRowsUseTrueFalseNotYesNo() throws {
        // 在线文档输出 true/false；离线以前输出 yes/no，脚本得写两套判断。
        var entries = OfflineConfig.entries(context)
        XCTAssertEqual(try entry(entries, "autoStart").value, "false")

        try OfflineConfig.set(key: "autoStart", value: "yes", context: context)
        entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "autoStart").value, "true")
    }

    func testOfflineDoublesAndEnumsUseDocumentFormat() throws {
        defaults.set(0.5, forKey: "chat.temperature")
        defaults.set(2, forKey: "appearance")
        defaults.set(1, forKey: "reasoningEffort")
        defaults.set(0, forKey: "chat.maxTokens")
        let entries = OfflineConfig.entries(makeContext())
        XCTAssertEqual(try entry(entries, "temperature").value, "0.50")
        XCTAssertEqual(try entry(entries, "appearance").value, "dark")
        XCTAssertEqual(try entry(entries, "reasoningEffort").value, "low")
        XCTAssertEqual(try entry(entries, "maxTokens").value, "0")
    }

    // MARK: 拒绝写入的键

    func testModelIsReadOnlyOffline() throws {
        XCTAssertThrowsError(try OfflineConfig.set(key: "model", value: "qwen3-8b", context: context)) {
            guard let error = $0 as? CLIError else {
                return XCTFail("期望 CLIError，实际 \($0)")
            }
            XCTAssertEqual(error.exit, .usage)
            XCTAssertTrue(error.message.contains("只读"))
        }
    }

    func testEnginePortSetOfflineConflictsWithHint() throws {
        XCTAssertThrowsError(try OfflineConfig.set(key: "engines.omlx.port", value: "8123", context: context)) {
            guard let error = $0 as? CLIError else {
                return XCTFail("期望 CLIError，实际 \($0)")
            }
            XCTAssertEqual(error.exit, .conflict)
            XCTAssertEqual(error.hint, "先 flashcat app open；或直接改 \(configurationFile)")
        }
    }

    func testUnknownKeyOfflineIsNotFound() throws {
        XCTAssertThrowsError(try OfflineConfig.set(key: "nope", value: "1", context: context)) {
            guard let error = $0 as? CLIError else {
                return XCTFail("期望 CLIError，实际 \($0)")
            }
            XCTAssertEqual(error.exit, .notFound)
            XCTAssertTrue(error.message.contains("nope"))
        }
    }
}
