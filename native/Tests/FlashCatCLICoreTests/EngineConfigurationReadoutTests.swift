// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation
import XCTest

@testable import FlashCatCLICore

/// `engines.json` 读不出来时，CLI 以前用 `try?` 把它折成空配置：`status` /
/// `config list` 会打出一份看起来完全正常、其实全由默认值拼出来的文档。
/// 这几个测试钉住「说得清原因」以及「原因不影响退出码」。
final class EngineConfigurationReadoutTests: XCTestCase {
    private var directory = ""
    private var file = ""
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = NSTemporaryDirectory() + "/flashcat-readout-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        file = directory + "/engines.json"
        suiteName = "flashcat-readout-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        if FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.removeItem(atPath: directory)
        }
        try super.tearDownWithError()
    }

    private func local() -> LocalState {
        LocalState(environment: [:], defaults: defaults, engineConfigurationFile: file)
    }

    private func write(_ text: String) throws {
        try text.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// 文件不存在是首次启动的正常状态，不该被报成问题。
    func testMissingFileIsNotAWarning() {
        let readout = local().engineConfigurationReadout()
        XCTAssertNil(readout.warning)
        XCTAssertNil(readout.configuration.active)
        XCTAssertTrue(readout.configuration.lastModel.isEmpty)
        XCTAssertFalse(local().engineConfigurationIsUnreadable())
    }

    func testValidFileParsesWithoutWarning() throws {
        try write(#"{"active": {"version": "omlx"}, "omlx": {"lastModel": "Qwen3-4B", "port": 8101}}"#)
        let readout = local().engineConfigurationReadout()
        XCTAssertNil(readout.warning)
        XCTAssertEqual(readout.configuration.active, "omlx")
        XCTAssertEqual(readout.configuration.lastModel["omlx"], "Qwen3-4B")
        XCTAssertEqual(readout.configuration.port["omlx"], 8101)
        // 老入口行为不变：它只是这次读盘的 `.configuration`。
        XCTAssertEqual(local().engineConfiguration, readout.configuration)
        XCTAssertFalse(local().engineConfigurationIsUnreadable())
    }

    func testBrokenJSONReportsWhy() throws {
        try write("{ 这不是 JSON")
        let readout = local().engineConfigurationReadout()
        let warning = try XCTUnwrap(readout.warning, "解析失败必须给出原因，不能静默折成空配置")
        XCTAssertTrue(warning.contains("engines.json"))
        XCTAssertTrue(warning.contains(file), "原因里要带上具体路径，用户才知道去修哪一份")
        XCTAssertTrue(local().engineConfigurationIsUnreadable())
        // 失败时的**取值**保持不变：仍然是一份空配置，只是这次说得出为什么。
        XCTAssertEqual(readout.configuration, LocalState.EngineConfiguration())
    }

    func testNonObjectTopLevelReportsWhy() throws {
        try write("[1, 2, 3]")
        let warning = try XCTUnwrap(local().engineConfigurationReadout().warning)
        XCTAssertTrue(warning.contains("顶层不是对象"))
        XCTAssertEqual(local().engineConfiguration, LocalState.EngineConfiguration())
    }

    /// 文件在、但读不动（拿目录占住路径）：这是 `try?` 曾经连原因一起吞掉的分支。
    func testUnreadableFileReportsWhy() throws {
        try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: true)
        let warning = try XCTUnwrap(local().engineConfigurationReadout().warning)
        XCTAssertTrue(warning.contains("读不出来"))
        XCTAssertTrue(local().engineConfigurationIsUnreadable())
        XCTAssertEqual(local().engineConfiguration, LocalState.EngineConfiguration())
    }

    /// 记账行（`active` / `default`）不是引擎：不能出现在 per-engine 表里。
    func testBookkeepingKeysAreNotEngines() throws {
        try write(
            #"""
            {"active": {"version": "omlx"}, "default": {"port": 9000},
             "splash": {"lastModel": "Qwen3-4B", "port": 8300}}
            """#)
        let configuration = local().engineConfiguration
        XCTAssertEqual(Set(configuration.lastModel.keys), ["splash"])
        XCTAssertEqual(Set(configuration.port.keys), ["splash"])
    }
}
