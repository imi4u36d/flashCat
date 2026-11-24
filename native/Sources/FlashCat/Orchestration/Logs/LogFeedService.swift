// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatCore
import FlashCatKit
import Foundation

/// 日志页读的那一份尾巴，以及「清空」「合并多引擎」这些只跟日志有关的动作。
///
/// 引擎自己的日志流在 `EngineController.logs` 里，这里保存的是**当前引擎**的
/// 一份快照（动态岛、日志页、写盘失败提示都读它）。之所以不是纯视图层：写盘
/// 失败的回调在后台队列上触发，必须有东西能接住并落进日志页，所以它需要一个
/// 长期存在的 owner，而不是每次现算。
///
/// 视图仍只订阅 AppState，所以本对象的 `objectWillChange` 要在 AppState 的
/// `init` 里桥回去，否则日志在涨而页面不动。
@MainActor
final class LogFeedService: ObservableObject {
    @Published var logs: [LogLine] = []
    /// 日志页读它：合并视图覆盖所有引擎，别的引擎写新行时 `logs` 不会发布，
    /// 靠这一拍让页面重新取一份。活动引擎的写入仍走 `logs`。
    @Published var logsRevision = 0

    private let engine: EngineCoordinator
    private let gateway: GatewayController

    init(engine: EngineCoordinator, gateway: GatewayController) {
        self.engine = engine
        self.gateway = gateway
    }

    func refreshLogs() { logs = engine.controller?.logs.snapshot(limit: 4000) ?? [] }

    /// 日志页要的行。`.all` 把每台已装引擎的尾巴并成一份（最新在前），
    /// 单引擎来源只取它自己的；行里带着来源，页面据此决定要不要显示来源列。
    func logEntries(for source: LogFeedSource, limit: Int = 4000) -> [LogFeedEntry] {
        switch source {
        case .all:
            let groups = (engine.engines?.available ?? []).map { controller in
                LogFeed.Group(
                    key: controller.id.rawValue,
                    tag: controller.id.rawValue,
                    lines: controller.logs.snapshot(limit: limit))
            }
            return LogFeed.entries(from: groups, limit: limit)
        case .engine(let id):
            let lines = engine.engines?.controller(id)?.logs.snapshot(limit: limit) ?? []
            return LogFeed.entries(
                from: [LogFeed.Group(key: id.rawValue, tag: nil, lines: lines)],
                limit: limit)
        }
    }

    func clearLogs() {
        engine.controller?.logs.clear()
        refreshLogs()
        logsRevision &+= 1
    }

    func clearLogs(for engineID: EngineID) {
        engine.engines?.controller(engineID)?.logs.clear()
        if engineID == engine.activeEngine { refreshLogs() }
        // 清空不改变 `latestId`，指纹看不出这一拍，得自己通知日志页。
        logsRevision &+= 1
    }

    /// 清空当前正在读的那一份：`全部日志` 要清掉每台引擎的内存尾巴。
    func clearLogs(for source: LogFeedSource) {
        switch source {
        case .all:
            for controller in engine.engines?.available ?? [] { controller.logs.clear() }
            refreshLogs()
            logsRevision &+= 1
        case .engine(let id):
            clearLogs(for: id)
        }
    }

    /// Engine logs are per engine; only the running engine's copy is on screen.
    /// 历史写盘失败在 ChatHistory 的后台串行队列上触发，要回到主 actor 才能
    /// 写日志流。写成静态入口是为了让 `history` 的构造闭包不必捕获 `self`
    ///（init 期间不允许），代价是只对单例有效——而 AppState 本来就是单例。
    nonisolated static func recordHistoryWriteFailure(_ message: String) {
        Task { @MainActor in
            AppState.shared.logFeed.reportHistoryWriteFailure(message)
        }
    }

    /// 日志页读的就是当前引擎的日志流，失败优先落在那里。引擎还没挂上时退到
    /// 网关日志：两条都是会落盘的真实文件，反正不许让失败凭空消失。
    func reportHistoryWriteFailure(_ message: String) {
        if let store = engine.controller?.logs {
            store.append(message, level: .error)
            logs = store.snapshot(limit: 4000)
        } else {
            gateway.logs.append(message, level: .error)
        }
    }

    func append(log line: String, engine engineID: EngineID) {
        engine.engines?.controller(engineID)?.logs.append(line, level: .system)
        if engineID == engine.activeEngine { logs = engine.controller?.logs.snapshot(limit: 4000) ?? [] }
    }
}
