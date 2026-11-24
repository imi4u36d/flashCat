// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// `ModelOps` 对引擎编排的最小要求：查安装、扫模型、切引擎。真实实现是
/// `EngineCoordinator`；测试里给一个记录调用的假实现即可。
@MainActor
protocol EngineCataloging: AnyObject {
    var engines: EngineManager? { get }
    func reloadModels()
    func engineIsInstalled(_ id: EngineID) -> Bool
    func requestEngineInstall(_ id: EngineID)
    func engineModels(for id: EngineID) -> [EngineModel]
    func shortModelName(_ id: String) -> String
    func switchEngine(_ id: EngineID, start: Bool) async -> Bool
}

extension EngineCataloging {
    @discardableResult
    func switchEngine(_ id: EngineID) async -> Bool {
        await switchEngine(id, start: true)
    }
}

extension EngineCoordinator: EngineCataloging {}
