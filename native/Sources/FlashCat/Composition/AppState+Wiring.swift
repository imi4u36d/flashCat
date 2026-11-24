// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Combine
import FlashCatKit
import Foundation

/// 装配期剩下的接线：store 发布桥与调音通知观察者。
///
/// 四个编排对象（对话 / 引擎 / 模型 / 下载）现在都通过
/// `Composition/AppState+Hosts.swift` 里的协议装配，不再需要闭包工厂。
extension AppState {
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
