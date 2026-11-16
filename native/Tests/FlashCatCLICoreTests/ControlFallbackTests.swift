// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import XCTest
@testable import FlashCatCLICore

/// 降级判据是「静默降级」这条修复的核心：只有应用真的没在运行才允许回退到离线视图。
/// 401（令牌过期）、504、超时都说明应用在跑、只是这次没答好，把它们折叠成离线视图
/// 会让用户看到一份陈旧的本地状态并且 exit 0 —— 故障被伪装成正常。
final class ControlFallbackTests: XCTestCase {
    func testOnlyNotRunningFallsBackToTheOfflineView() {
        XCTAssertTrue(ControlFallback.shouldFallBack(CLIError("找不到控制接口", exit: .notRunning)))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("控制令牌已过期", exit: .unauthorized)))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("等待响应超时", exit: .timeout)))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("控制接口请求失败")))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("未知选项", exit: .usage)))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("下载冲突", exit: .conflict)))
        XCTAssertFalse(ControlFallback.shouldFallBack(CLIError("找不到模型", exit: .notFound)))
    }
}
