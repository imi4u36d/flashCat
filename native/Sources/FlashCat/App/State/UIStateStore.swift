// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import Foundation
import SwiftUI

// MARK: - Sidebar presentation
//
// 侧栏交由原生 NavigationSplitView 驱动：只维护可见性 `showsSidebar`。

/// 界面上「现在在哪一页、要不要响一声」的状态：当前页、启动页、侧栏折叠与通知流。
///
/// 这些字段只服务视图，不参与引擎启停与模型装卸的任何判断，所以从装配根里
/// 分出来单独持有。视图仍然只订阅 AppState（`@ObservedObject var state`），
/// 因此本对象的 `objectWillChange` 必须在 AppState 的 `init` 里桥回去——桥断
/// 了状态照变，页面就是不重画。
@MainActor
final class UIStateStore: ObservableObject {
    @Published var section: Page = .overview
    /// 设置页当前分区。放在这里是为了让命令面板能「跳到设置 · 模型来源」，
    /// 而不是只打开设置的第一屏。
    @Published var settingsSection: SettingsSection = .general
    /// Re-open the launch page from the engines tab; the page is also shown
    /// automatically while no engine is installed.
    @Published var showsLaunchPage = false
    /// 用户主动跳过首次无引擎启动页，进入控制台。
    @Published var dismissedInitialLaunch = false
    /// Persistent banner for errors that need the reader's attention.
    /// Assigning a non-empty error also routes into the notice stream.
    @Published var notice: String? {
        didSet {
            guard let message = notice?.trimmingCharacters(in: .whitespacesAndNewlines),
                !message.isEmpty
            else { return }
            toast(message, kind: .error, transient: false)
        }
    }
    /// 最近一条阻塞通知（错误 / 非一过性警告）。成功回执不经过这里，
    /// 由动作控件自己的 `ActionFlashState` 承担。
    @Published private(set) var islandNotice: IslandNotice?
    /// 本次会话的通知历史，按时间倒序。
    @Published private(set) var islandNotices: [IslandNotice] = []
    /// 尚未查看过的通知数量。
    @Published private(set) var islandUnread = 0
    /// 下载中心弹层。原来由 `ConsoleView` 的局部 `@State` 持有；顶栏全局状态簇
    /// 也要能打开它，所以收进这里，壳层只负责把 sheet 绑上。
    @Published var showsDownloadCenter = false
    /// 侧栏是否显示（交由原生 `NavigationSplitView` 驱动展开与收起）。
    /// 状态落盘到 UserDefaults 的 `sidebarVisible`，重启后沿用上次的样子。
    @Published var showsSidebar: Bool
    /// 会话搜索框的聚焦请求。每加一次，侧栏就把焦点送进搜索框；
    /// 计数而不是 Bool，连续按 ⌘F 也能再次聚焦。
    @Published private(set) var chatSearchFocusTick = 0

    /// 侧栏折叠/展开动画的截止时刻。不进 objectWillChange：它只是调度信息。
    var sidebarAnimUntil = Date.distantPast

    private var toastWork: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        showsSidebar = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
    }

    // MARK: toasts

    /// 只有真正的失败和「现在不能做」的阻塞还走浮层；成功、信息、过程回执
    /// 一律由动作控件的图标承担（`ActionFlashState` + `ActionFlashIcon`），
    /// 不再弹卡片。
    ///
    /// 留在这一层兜底而不是逐个删调用点：编排层（下载、模型装载、引擎切换）
    /// 的 `toast` 调用和视图不在同一文件，漏掉一处就会在读者刚点完按钮时又
    /// 冒出一张成功卡片。错误与阻塞仍然需要文字，浮层是它们唯一的出口。
    func toast(
        _ message: String,
        title: String? = nil,
        kind: IslandNotice.Kind? = nil,
        transient: Bool = false
    ) {
        // Classify from the source text (the kind rules are written against
        // Chinese phrases) before swapping in the localized message. Callers
        // that already know the lifecycle phase pass an explicit kind so a
        // model-ready notice reads as success and a still-loading notice stays
        // warning, regardless of how the message happens to be worded.
        let kind = kind ?? IslandNotice.Kind(message: message)
        guard kind == .error || (kind == .warning && !transient) else { return }
        let notice = IslandNotice(
            title: L10n.t(title ?? kind.defaultTitle),
            message: L10n.t(message),
            kind: kind,
            transient: transient
        )
        islandNotice = notice
        // 一过性提示只占胶囊那一格：3 秒后自己回到引擎状态，不写历史、不加未读。
        if !transient {
            islandNotices.insert(notice, at: 0)
            if islandNotices.count > 30 {
                islandNotices.removeLast(islandNotices.count - 30)
            }
            islandUnread += 1
        }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.islandNotice?.id == notice.id else { return }
            self.islandNotice = nil
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// 收起灵动岛时清掉短暂通知，历史仍留在通知列表里。
    func dismissToast() {
        toastWork?.cancel()
        islandNotice = nil
    }

    /// 展开灵动岛即视为读过了所有通知。
    func markIslandNoticesRead() {
        islandUnread = 0
    }

    func clearIslandNotices() {
        toastWork?.cancel()
        islandNotice = nil
        islandNotices.removeAll()
        islandUnread = 0
    }

    // MARK: sidebar

    func setShowsSidebar(_ visible: Bool) {
        guard showsSidebar != visible else { return }
        showsSidebar = visible
        sidebarAnimUntil = Date().addingTimeInterval(0.35)
        UserDefaults.standard.set(visible, forKey: "sidebarVisible")
    }

    func toggleSidebar() {
        setShowsSidebar(!showsSidebar)
    }

    /// 把焦点送进侧栏「工作区」的搜索框，搜索框收着时会先展开。
    /// 侧栏被隐藏时也会重新出现——这个动作只服务一个目的：立刻能搜。
    func focusChatSearch() {
        setShowsSidebar(true)
        chatSearchFocusTick += 1
    }

    // MARK: clipboard

    /// 只换粘贴板内容，不弹回执。
    ///
    /// 复制的结果在粘贴那一刻就会显现；控件自己的图标（代码块、接口行、消息
    /// 操作行）在这一下短暂变成对勾，比一张浮层卡片更近、更不打断连续复制。
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
