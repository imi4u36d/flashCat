// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import Foundation

/// 「这个模型能吃多少上下文」的全部推导：模型自身的上限、引擎本次加载收敛后
/// 的窗口、两者取小、以及把已知值记到 UserDefaults 以便引擎停着时仍能作答。
///
/// 单独成类是因为它有一套自己的缓存与持久化规则（20s 扫描缓存 + 两个
/// UserDefaults 键），和 AppState 里其它派生量没有耦合；聊天参数默认值、
/// 概览页的「已用 / 总量」都只读它的结果。
@MainActor
final class ContextWindowTracker {
    private let session: EngineSessionStore
    private let library: ModelLibraryStore
    private let engineCoordinator: EngineCoordinator

    /// 窗口是界面每一帧都要问的值，而取它要么重扫模型目录、要么读 config.json，
    /// 这里跟 EngineModelStore.meta 用同一档 20s 缓存，避免把扫描塞进推送热路径。
    private var cache: (key: String, value: Int?, at: Date)?

    init(session: EngineSessionStore, library: ModelLibraryStore, engineCoordinator: EngineCoordinator) {
        self.session = session
        self.library = library
        self.engineCoordinator = engineCoordinator
    }

    /// 模型**自身**支持的上下文（config.json 的 max_position_embeddings），
    /// 不是引擎本次加载收敛后的窗口。模型库扫盘结果对 omlx / mtplx 就带这一项；
    /// splash 的机型目录只有路径，得现读 config.json（仍走 20s TTL 缓存）。
    func window(of model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        let key = "\(engineCoordinator.activeEngine.rawValue)|\(model)"
        if let cache, cache.key == key, Date().timeIntervalSince(cache.at) < 20 {
            return cache.value
        }
        var window = engineCoordinator.engineModels(for: engineCoordinator.activeEngine)
            .first { $0.id == model }?.maximumContextTokens
        if window == nil || window == 0,
            let path = library.catalog.machineModel(model)?.path, !path.isEmpty
        {
            window = EngineModelStore.meta(of: path).maximumContextTokens
        }
        // GGUF 权重里没有 config.json，引擎停着时上面两条都拿不到值；记住上次
        // 真正拿到的窗口（落 UserDefaults），引擎停下或重开应用后概览「总量」
        // 才不会退成「—」。记忆只在「被告知」的那一刻写（`rememberModels`
        // 与 `syncController`）：读路径一旦有副作用，任何一次重绘都会改用户设置，
        // 既难推理也没法停。
        let value: Int?
        if let window, window > 0 {
            value = window
        } else {
            let remembered = UserDefaults.standard.integer(forKey: Self.modelKey(key))
            value = remembered > 0 ? remembered : nil
        }
        cache = (key, value, Date())
        return value
    }

    private static func modelKey(_ key: String) -> String { "contextWindow." + key }

    /// 引擎报告的窗口单独一层记忆：它是**本次加载**收敛后的值（splash 会被
    /// `--max-context` 和 KV 预算压低），不能拿去当模型自身上限。
    private static func reportedKey(_ key: String) -> String { "contextWindowEngine." + key }

    /// 模型库刚扫过（或选中模型刚变）：把已知的模型窗口落盘记住。
    ///
    /// 写入点放在「重新扫盘」这类真实的状态变化里，而不是 `window(of:)`
    /// 的读取路径上——那个方法每帧都会被界面问到，顺手写 UserDefaults 意味着
    /// 重绘即改用户设置。这里只在确实知道值时写，且值没变就不重复写。
    func rememberModels() {
        let engine = engineCoordinator.activeEngine
        for model in engineCoordinator.engineModels(for: engine) {
            guard let window = model.maximumContextTokens, window > 0 else { continue }
            let key = Self.modelKey("\(engine.rawValue)|\(model.id)")
            if UserDefaults.standard.integer(forKey: key) != window {
                UserDefaults.standard.set(window, forKey: key)
            }
        }
    }

    /// 引擎报出本次窗口的那一刻记下来。同样只在状态变化时写。
    func rememberReported() {
        guard let reported = session.stats?.maximumContextTokens, reported > 0,
            !session.selectedModel.isEmpty
        else { return }
        UserDefaults.standard.set(
            reported,
            forKey: Self.reportedKey("\(engineCoordinator.activeEngine.rawValue)|\(session.selectedModel)"))
    }

    /// 本次加载**实际可用**的上下文窗口：模型自身上限与引擎生效窗口取小。
    /// 聊天参数留空时用它封顶；两者都没报时为 nil。
    var tokens: Int? {
        var engineWindow: Int?
        if let reported = session.stats?.maximumContextTokens, reported > 0 { engineWindow = reported }
        switch (window(of: session.selectedModel), engineWindow) {
        case (let model?, let window?): return min(model, window)
        case (let model?, nil): return model
        case (nil, let window?): return window
        case (nil, nil): return nil
        }
    }

    /// 概览页「已用 / 总量」的右半边：**模型的上下文上限**。
    ///
    /// 引擎可能把窗口压低（splash 的 `--max-context`、KV 预算），那是「这次能用
    /// 多少」；这里回答的是「这个模型最多吃多少」，所以优先不看引擎窗口。GGUF
    /// 权重没有 config.json，引擎也没在跑的时候只能靠记忆（`rememberReported`
    /// 在引擎报出窗口时写、这里只读），停引擎/重启后依然显示 262K 而不是「—」。
    var ceiling: Int? {
        guard !session.selectedModel.isEmpty else { return nil }
        if let model = window(of: session.selectedModel) { return model }
        if let reported = session.stats?.maximumContextTokens, reported > 0 { return reported }
        let key = Self.reportedKey("\(engineCoordinator.activeEngine.rawValue)|\(session.selectedModel)")
        let remembered = UserDefaults.standard.integer(forKey: key)
        return remembered > 0 ? remembered : nil
    }
}
