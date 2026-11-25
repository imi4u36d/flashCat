// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 控制台根视图：左侧 ZCode 风格实体导航边栏 + 1px 发丝分隔线 + 七个原生页面。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    /// 重命名弹窗里的输入。线程本身挂在 `pendingThreadRename` 上，壳层只负责
    /// 把输入框和落点接起来。
    @State private var renameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 壁纸铺满 AppKit 窗口；玻璃窗口以 10pt 留白浮在上面。
            GlassWallpaper(skin: theme.skin)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    ConsoleNavigationPanel(state: state, chat: state.chat) {
                        state.toggleSidebarCompact()
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(reduceMotion ? .opacity : .dsPage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.section)
                .clipped()
            }
            .background { GlassWindowBackground(skin: theme.skin) }
            .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.showsSidebar)
        }
        // 换肤不在这里做。`.preferredColorScheme` 会让 SwiftUI 去改窗口外观，
        // 而深色窗口那条系统投影明显更重（见 ThemeController.apply(to:)）；
        // 皮肤改由窗口的 contentView 外观承担，SwiftUI 的 colorScheme 也跟着
        // 那一层解析，切换时和窗口一起重画，不必等激活事件。
        // 侧栏展开时折叠按钮活在侧栏头里；隐藏时退回红绿灯右侧，与各页顶栏精确对齐。
        .overlay(alignment: .topLeading) {
            if !state.showsSidebar && !isShowingOnboarding {
                DSIconButton(
                    systemName: "sidebar.left",
                    help: "显示边栏",
                    size: 28,
                    style: .outlined
                ) {
                    state.toggleSidebar()
                }
                .padding(.leading, 82)
                .padding(.top, 10)
            }
        }
        .overlay {
            if isShowingOnboarding {
                LaunchPage(state: state, installs: state.installs)
                    .transition(.opacity.animation(Motion.pageCrossfade))
            }
        }
        .overlay {
            if showCommand {
                CommandPalette(
                    state: state,
                    openDownloads: { showDownloads = true },
                    openHub: {
                        showHub = true
                        state.section = .models
                    },
                    dismiss: { showCommand = false }
                )
                .transition(.opacity)
            }
        }
        // 侧栏收起时窗口左下角常驻一枚紧凑状态；通知到达时原地换成 toast。
        // 侧栏展开时没有状态脊柱，通知同样浮在左下角，不再有第二个出口。
        .overlay(alignment: .bottomLeading) {
            if !isShowingOnboarding {
                if let notice = state.islandNotice {
                    FloatingNoticeToast(notice: notice) { state.dismissToast() }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !state.showsSidebar {
                    CompactStatusPill(state: state)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.islandNotice?.id)
        .sheet(isPresented: $showDownloads) { DownloadCenterSheet(state: state) }
        .sheet(isPresented: $showHub) { HubSheet(state: state, engine: state.libraryEngine) }
        .onReceive(NotificationCenter.default.publisher(for: .flashCatOpenCommandPalette)) { _ in
            guard !isShowingOnboarding else { return }
            showCommand.toggle()
        }
        .alert("切换模型？", isPresented: modelSwitchShown) {
            Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
            Button("停止并切换") { state.confirmModelSwitch() }
        } message: {
            Text(modelSwitchMessage)
        }
        .alert(
            L10n.format(
                "%@ 还没安装",
                state.pendingEngineInstall?.displayName ?? L10n.t("该引擎")),
            isPresented: engineInstallShown,
            presenting: state.pendingEngineInstall
        ) { _ in
            Button("去安装") { state.confirmEngineInstall() }
            Button("取消", role: .cancel) { state.cancelEngineInstall() }
        } message: { engine in
            Text("这个模型由 \(engine.displayName) 引擎驱动，先安装 \(engine.displayName) 才能切换到它。")
        }
        .alert("切换引擎？", isPresented: libraryUseShown, presenting: state.pendingLibraryUse) { request in
            Button(L10n.t(request.needsDownload ? "切换并下载" : "切换并使用")) { state.confirmLibraryUse() }
            Button("取消", role: .cancel) { state.cancelLibraryUse() }
        } message: { request in
            Text(
                "\(request.model) 属于 \(request.engine.displayName)，切换会先停掉 \(state.activeEngine.displayName)，再以这个模型启动 \(request.engine.displayName)。"
            )
        }
        .alert("删除这段对话？", isPresented: threadDeleteShown, presenting: state.pendingThreadDelete) { _ in
            Button("删除", role: .destructive) { state.confirmThreadDelete() }
            Button("取消", role: .cancel) { state.cancelThreadDelete() }
        } message: { thread in
            Text("「\(thread.title)」里的 \(thread.messages.count) 条消息会一并删除，无法恢复。")
        }
        .alert("重命名对话", isPresented: threadRenameShown, presenting: state.pendingThreadRename) { _ in
            TextField("名称", text: $renameText)
            Button("重命名") { state.confirmThreadRename(renameText) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { state.cancelThreadRename() }
        } message: { thread in
            Text("给「\(thread.title)」换一个名字。")
        }
        .onChange(of: state.pendingThreadRename) { _, thread in
            if let thread { renameText = thread.title }
        }
        .onChange(of: isShowingOnboarding) { _, _ in
            NotificationCenter.default.post(name: .flashCatSidebarLayoutChanged, object: nil)
        }
    }

    private var isShowingOnboarding: Bool {
        state.isPresentingLaunchPage || state.showsRecommendationPage
    }

    @ViewBuilder private var pageContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state, chat: state.chat)
        case .chat: ChatPage(state: state, chat: state.chat)
        case .models:
            ModelsPage(
                state: state,
                showingHub: $showHub,
                showingDownloads: $showDownloads)
        case .engines: EnginesPage(state: state, installs: state.installs)
        case .logs: LogsPage(state: state)
        case .settings: SettingsPage(state: state)
        case .lab: LabPage(state: state)
        }
    }

    private var modelSwitchShown: Binding<Bool> {
        Binding(
            get: { state.confirmingModelSwitch != nil },
            set: { if !$0 { state.cancelModelSwitchRequest() } })
    }

    private var threadDeleteShown: Binding<Bool> {
        Binding(
            get: { state.pendingThreadDelete != nil },
            set: { if !$0 { state.cancelThreadDelete() } })
    }

    private var threadRenameShown: Binding<Bool> {
        Binding(
            get: { state.pendingThreadRename != nil },
            set: { if !$0 { state.cancelThreadRename() } })
    }

    private var modelSwitchMessage: String {
        let next = state.shortModelName(state.confirmingModelSwitch ?? "")
        let running = state.shortModelName(state.selectedModel)
        return L10n.format("将停止 %@ 并加载 %@，切换期间引擎暂时无法应答。", running, next)
    }

    private var engineInstallShown: Binding<Bool> {
        Binding(
            get: { state.pendingEngineInstall != nil },
            set: { if !$0 { state.cancelEngineInstall() } })
    }

    private var libraryUseShown: Binding<Bool> {
        Binding(
            get: { state.pendingLibraryUse != nil },
            set: { if !$0 { state.cancelLibraryUse() } })
    }
}

// MARK: - Window chrome helpers

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
