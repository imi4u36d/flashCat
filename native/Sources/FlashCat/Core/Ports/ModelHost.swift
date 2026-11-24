// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// `ModelOps` 需要外层提供的选择状态、服务动作与界面回执。
///
/// 与 `ChatHost` 同一套做法：把闭包表收成协议，依赖清单可读、可测，漏实现会在
/// 编译期报错。
@MainActor
protocol ModelHost: AnyObject {
    var activeEngine: EngineID { get }
    var selectedModel: String { get set }
    var needsEngineSetup: Bool { get }
    var notice: String? { get set }

    func stopService()
    func adoptSavedModel(for engine: EngineID)
    func applyModel(_ model: String)
    func applyModelFromAnyEngine(_ model: String, engine: EngineID)

    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool)
    func appendLog(_ line: String, engine: EngineID)
    func stopBackends()
}

extension ModelHost {
    func toast(_ message: String, kind: IslandNotice.Kind? = nil, transient: Bool = false) {
        toast(message, title: nil, kind: kind, transient: transient)
    }
}
