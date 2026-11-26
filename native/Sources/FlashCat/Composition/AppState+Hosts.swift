// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// 装配根对编排层协议的实现。
///
/// 大部分成员由 `AppState` 的转发面直接满足；这里只补那些「协议要的形状与现有
/// 签名不同」的适配。哪天某个成员删了，编译器会在这里报错，而不是等到运行时
/// 某个闭包默默变成 no-op。
extension AppState: EngineHost {
    func notifyObjectChanged() {
        objectWillChange.send()
    }

    /// 协议要的是三参数形状；`AppState` 的实现另有 `source` / `include`
    /// 两个带默认值的参数。带默认参数的函数不能充当协议见证，所以这里补一个
    /// 精确重载（下载中心仍可用扩展参数）。
    @discardableResult
    func downloadModel(_ id: String, engine: EngineID, family: String?) -> Bool {
        downloadModel(id, engine: engine, family: family, source: nil, include: [])
    }
}

extension AppState: ChatHost {
    /// `ChatHost` 只要非可选模型；`AppState` 的网关准备入口同时服务控制通道
    /// （那里可以传 nil 表示「当前模型」），所以在协议侧收窄成 `String`。
    func prepareModelForGateway(
        _ model: String, allowingGeneration: Bool
    ) async -> GatewayModelPreparationError? {
        await prepareModelForGateway(Optional(model), allowingGeneration: allowingGeneration)
    }

    func gatewayModelIsResident(_ model: String, in controller: EngineController) -> Bool {
        engineCoordinator.gatewayModelIsResident(model, in: controller)
    }

    func logWarning(_ line: String) {
        controller?.logs.append(line, level: .warning)
        logFeed.refreshLogs()
    }

    func showChat() {
        // 切会话本身由 `ChatSessionStore.currentThreadID` 发布，这里只负责
        // 「如果人还在别的页，跳到对话页」。以前无条件写 `section`，等于每次
        // 点会话都让整个控制台壳层白重绘一次。
        if section != .chat { section = .chat }
    }
}

extension AppState: DownloadHost {
    func log(_ line: String, engine: EngineID?) {
        logFeed.append(log: line, engine: engine ?? activeEngine)
    }

    func modelInventoryChanged() {
        invalidateModelCaches()
    }
}

extension AppState: ModelHost {
    func appendLog(_ line: String, engine: EngineID) {
        logFeed.append(log: line, engine: engine)
    }

    func stopBackends() {
        gateway.stop()
        control.stop()
    }
}
