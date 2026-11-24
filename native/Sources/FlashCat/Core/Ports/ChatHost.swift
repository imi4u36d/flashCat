// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// `ChatRunner` 需要外层提供的引擎状态、网关准备与界面回执。
///
/// 以前是 15 个带默认实现的闭包：漏接一个不会编译失败，只会在运行时变成
/// no-op。协议把同一份依赖写成必须实现的成员，测试里给一个假 host 就能跑完
/// 一轮流式生成。
@MainActor
protocol ChatHost: AnyObject {
    var controller: EngineController? { get }
    var activeEngine: EngineID { get }
    func engineModels(for engine: EngineID) -> [EngineModel]
    var selectedModelInfo: ModelInfo? { get }
    var effectiveMaxTokens: Int { get }
    var canChat: Bool { get }
    var engineStageText: String { get }
    var port: Int { get }
    var needsEngineSetup: Bool { get }
    var notice: String? { get set }

    func prepareModelForGateway(
        _ model: String, allowingGeneration: Bool
    ) async -> GatewayModelPreparationError?
    func gatewayModelIsResident(_ model: String, in controller: EngineController) -> Bool

    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool)
    func logWarning(_ line: String)
    func showChat()
}

extension ChatHost {
    func toast(_ message: String, kind: IslandNotice.Kind? = nil, transient: Bool = false) {
        toast(message, title: nil, kind: kind, transient: transient)
    }
}
