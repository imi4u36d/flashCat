// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatKit
import Foundation

/// 装配期接线：把各编排对象需要回问 AppState 的闭包造出来。
///
/// 闭包一律 `[weak self]`——编排对象由 AppState 持有，强着回指就是一个环；
/// 而它们只该在 AppState 还活着的时候被调用，弱引用拿到 nil 正是「不用再管」。
///
/// 这些工厂单独一页只是为了让 `AppState.init` 读起来还是「建对象 → 接线 →
/// 交出 self」三步，而不是被三段各几十行的闭包列表埋掉。
extension AppState {
    /// 对话编排搬进 `ChatRunner`：依赖交过去，要回到 AppState 办的事用闭包接上。
    func makeRunnerHooks() -> ChatRunner.Hooks {
        ChatRunner.Hooks(
            controller: { [weak self] in self?.controller },
            activeEngine: { [weak self] in self?.activeEngine ?? .splash },
            engineModels: { [weak self] engine in self?.engineModels(for: engine) ?? [] },
            selectedModelInfo: { [weak self] in self?.selectedModelInfo },
            effectiveMaxTokens: { [weak self] in self?.effectiveMaxTokens ?? 0 },
            canChat: { [weak self] in self?.canChat ?? false },
            engineStageText: { [weak self] in self?.engineStageText ?? "" },
            port: { [weak self] in self?.port ?? 0 },
            needsEngineSetup: { [weak self] in self?.needsEngineSetup ?? true },
            prepareModel: { [weak self] model, allowing in
                guard let self else { return .unavailable("flashCat 状态不可用") }
                return await self.prepareModelForGateway(model, allowingGeneration: allowing)
            },
            modelIsResident: { [weak self] model, controller in
                self?.engineCoordinator.gatewayModelIsResident(model, in: controller) ?? false
            },
            setNotice: { [weak self] message in self?.notice = message },
            toast: { [weak self] message, kind, transient in
                self?.toast(message, kind: kind, transient: transient)
            },
            logWarning: { [weak self] line in
                self?.controller?.logs.append(line, level: .warning)
                self?.logFeed.refreshLogs()
            },
            showChat: { [weak self] in self?.section = .chat }
        )
    }

    /// 下载中心只负责传输：写日志、弹提示、重扫模型目录这些它不该知道细节的
    /// 事用闭包注入，收尾（要不要选中新模型、公共目录的授权表怎么写）走事件
    /// 回调。这样两边谁都不持有对方，少一个环。
    func makeDownloadHooks() -> DownloadCenter.Hooks {
        DownloadCenter.Hooks(
            log: { [weak self] line, engine in
                guard let self else { return }
                self.logFeed.append(log: line, engine: engine ?? self.activeEngine)
            },
            toast: { [weak self] message, transient in
                self?.toast(message, transient: transient)
            },
            setNotice: { [weak self] message in self?.notice = message },
            reloadModels: { [weak self] in self?.reloadModels() },
            modelInventoryChanged: { [weak self] in self?.invalidateModelCaches() }
        )
    }

    /// 模型/下载编排搬进 `ModelOps`：状态仍在 store 里，要回到 AppState 办的
    /// 事（停引擎、切模型、弹提示、写日志、退出前收后端）用闭包接上，谁也不
    /// 持有对方。
    func makeModelOpsHooks() -> ModelOps.Hooks {
        ModelOps.Hooks(
            activeEngine: { [weak self] in self?.activeEngine ?? .splash },
            selectedModel: { [weak self] in self?.selectedModel ?? "" },
            setSelectedModel: { [weak self] model in self?.selectedModel = model },
            needsEngineSetup: { [weak self] in self?.needsEngineSetup ?? true },
            stopService: { [weak self] in self?.stopService() },
            adoptSavedModel: { [weak self] engine in self?.adoptSavedModel(for: engine) },
            applyModel: { [weak self] model in self?.applyModel(model) },
            applyModelFromAnyEngine: { [weak self] model, engine in
                self?.applyModelFromAnyEngine(model, engine: engine)
            },
            notice: { [weak self] in self?.notice },
            setNotice: { [weak self] message in self?.notice = message },
            toast: { [weak self] message, kind, transient in
                self?.toast(message, kind: kind, transient: transient)
            },
            appendLog: { [weak self] line, engine in self?.logFeed.append(log: line, engine: engine) },
            stopBackends: { [weak self] in
                self?.gateway.stop()
                self?.control.stop()
            }
        )
    }

    /// 把一个 store 的发布桥回 AppState：视图只订阅 AppState，不桥回来会出现
    /// 数值在变而页面不重绘。返回的 `AnyCancellable` 由 AppState 持有，订阅活到
    /// 应用退出；`[weak self]` 保证桥本身不会把 AppState 拖住。
    func makeBridge(_ object: some ObservableObject) -> AnyCancellable {
        object.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// 调音（引擎参数）保存后自增 `tuningRevision`，让显示推测解码模式的视图重画。
    func makeTuningObserver() {
        NotificationCenter.default.addObserver(
            forName: EngineStore.tuningDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tuningRevision += 1 }
        }
    }
}
