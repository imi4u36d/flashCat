// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import Foundation
import SwiftUI

// MARK: - Sidebar presentation

/// 侧边栏形态。与 `showsSidebar` 分工：收起窄栏仍看得见导航，隐藏边栏则
/// 整列退出画面。悬浮与贴边是同一份内容的两种外壳，窄栏是 68pt 图标栏。
enum SidebarStyle: Int, CaseIterable, Identifiable, Hashable {
    case floating = 0
    case edge = 1
    case compact = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .floating: return "悬浮琉璃"
        case .edge: return "贴边毛玻璃"
        case .compact: return "折叠窄栏"
        }
    }

    var symbol: String {
        switch self {
        case .floating: return "rectangle.inset.filled"
        case .edge: return "sidebar.left"
        case .compact: return "rectangle.compress.vertical"
        }
    }
}

/// 侧栏顶部分段器：只看全部 / 对话相关 / 控制台相关。
/// 它只过滤侧栏自身的内容，不改当前页面。
enum SidebarScope: String, CaseIterable, Identifiable, Hashable {
    case all
    case chat
    case console

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部视图"
        case .chat: return "对话模式"
        case .console: return "控制台"
        }
    }
}

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
    /// 最近一条通知。灵动岛移除后暂时没有常驻展示面，数据仍留给后续出口。
    @Published private(set) var islandNotice: IslandNotice?
    /// 本次会话的通知历史，按时间倒序。
    @Published private(set) var islandNotices: [IslandNotice] = []
    /// 尚未查看过的通知数量。
    @Published private(set) var islandUnread = 0
    /// 悬浮导航列是否显示。隐藏后主视口铺满窗口，重新显示时恢复玻璃列；
    /// 状态落盘到 UserDefaults 的 `sidebarVisible`，重启后沿用上次的样子。
    @Published var showsSidebar: Bool
    /// 侧栏形态：悬浮玻璃卡 / 贴边 / 68pt 窄栏。落盘到 `sidebarStyle`。
    @Published var sidebarStyle: SidebarStyle
    /// 顶部分段器的过滤范围。只影响侧栏内容，不切换当前页。
    @Published var sidebarScope: SidebarScope = .all
    /// 窄栏展开时回到哪一副形态。窄栏自己不参与「上一次展开」，
    /// 否则会从窄栏永远回不到悬浮 / 贴边。
    private var lastExpandedSidebarStyle: SidebarStyle
    /// 会话搜索框的聚焦请求。每加一次，侧栏就把焦点送进搜索框；
    /// 计数而不是 Bool，连续按 ⌘F 也能再次聚焦。
    @Published private(set) var chatSearchFocusTick = 0

    /// 侧栏折叠/展开动画的截止时刻。动画每帧都在重排与合成，期间任何整表刷新
    /// （模型目录扫描、日志重排）都要推迟到收口之后，否则会吃掉 CA 提交的帧。
    /// 不进 objectWillChange：它只是调度信息。
    var sidebarAnimUntil = Date.distantPast

    private var toastWork: DispatchWorkItem?

    init() {
        // 侧栏的落盘状态在这里读出来：构造点就是「应用刚起来」那一刻，
        // 与当初放在 AppState.init 里读是同一时机、同一默认值。
        let defaults = UserDefaults.standard
        showsSidebar = defaults.object(forKey: "sidebarVisible") as? Bool ?? true
        let storedStyle =
            (defaults.object(forKey: "sidebarStyle") as? Int)
            .flatMap(SidebarStyle.init(rawValue:)) ?? .floating
        sidebarStyle = storedStyle
        lastExpandedSidebarStyle = storedStyle == .compact ? .floating : storedStyle
    }

    // MARK: toasts

    /// - Parameter transient: 一过性提示：模型加载、切换这类过程，以及复制和各
    ///   种入口的成功回执。结果在界面上立刻看得见（阶段行、选择器里的进度、
    ///   粘贴板、已经改好的设置），留在历史里只是噪音，所以只闪几秒，不占通知
    ///   历史与未读数。失败、阻塞、后台任务完成和破坏性操作仍然留存——那是读
    ///   者回头要看的。
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

    func toggleSidebar() {
        // 侧栏列宽、收起按钮的横向位置和图标栏的裁切共用这一个动画事务，
        // 从菜单栏、命令面板或标题栏按钮触发时表现一致。
        withAnimation(.smooth(duration: 0.25)) {
            showsSidebar.toggle()
        }
        sidebarAnimUntil = Date().addingTimeInterval(0.35)
        UserDefaults.standard.set(showsSidebar, forKey: "sidebarVisible")
    }

    /// 换一副侧栏形态。宽度、圆角与内边距都跟着这一个动画事务走，
    /// 和手动拖拽时的观感一致。
    func setSidebarStyle(_ style: SidebarStyle) {
        guard style != sidebarStyle else { return }
        if sidebarStyle != .compact {
            lastExpandedSidebarStyle = sidebarStyle
        }
        if style != .compact {
            lastExpandedSidebarStyle = style
        }
        withAnimation(.smooth(duration: 0.28)) {
            sidebarStyle = style
        }
        sidebarAnimUntil = Date().addingTimeInterval(0.4)
        UserDefaults.standard.set(style.rawValue, forKey: "sidebarStyle")
    }

    /// 头部那枚按钮：展开时收成窄栏，窄栏时回到上一次的展开形态。
    func toggleSidebarCompact() {
        if sidebarStyle == .compact {
            setSidebarStyle(lastExpandedSidebarStyle)
        } else {
            setSidebarStyle(.compact)
        }
    }

    func setSidebarScope(_ scope: SidebarScope) {
        guard scope != sidebarScope else { return }
        withAnimation(.smooth(duration: 0.24)) {
            sidebarScope = scope
        }
    }

    /// 把焦点送进「最近对话」搜索框。窄栏会先展开，控制台范围会切回全部，
    /// 侧栏被隐藏时也会重新出现——这个动作只服务一个目的：立刻能搜。
    func focusChatSearch() {
        if !showsSidebar {
            showsSidebar = true
            UserDefaults.standard.set(true, forKey: "sidebarVisible")
        }
        if sidebarStyle == .compact {
            setSidebarStyle(lastExpandedSidebarStyle)
        }
        if sidebarScope == .console {
            setSidebarScope(.all)
        }
        chatSearchFocusTick += 1
    }

    // MARK: clipboard

    /// 复制一段文字并给出一过性回执。放在这里是因为它只有界面意义：粘贴板
    /// 加一句 toast，不牵动任何引擎/下载状态。
    func copy(_ text: String, label: String = "已复制") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        // 回执：粘贴的时候就能看见结果，不必占一行历史。
        toast(label, transient: true)
    }
}
