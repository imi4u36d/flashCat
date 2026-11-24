// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatKit
import Foundation

/// `DownloadCenter` 需要外层提供的日志、提示与缓存失效。
///
/// 下载器只负责传输；「日志写哪一份、提示长什么样、哪些缓存该作废」是装配根的
/// 事。协议把这些收成一份清单，测试里可以只实现这五个成员。
@MainActor
package protocol DownloadHost: AnyObject {
    /// nil 表示当前引擎：退出清理发生在下载之外，该写哪一份日志只有外层知道。
    func log(_ line: String, engine: EngineID?)
    func toast(_ message: String, title: String?, kind: IslandNotice.Kind?, transient: Bool)
    var notice: String? { get set }
    func reloadModels()
    func modelInventoryChanged()
}

extension DownloadHost {
    package func toast(_ message: String, transient: Bool) {
        toast(message, title: nil, kind: nil, transient: transient)
    }

    /// 下载中心的既有调用点把「一过性」作为第二个位置参数传入。
    package func toast(_ message: String, _ transient: Bool) {
        toast(message, title: nil, kind: nil, transient: transient)
    }
}
