// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 控制台根视图：原生 `NavigationSplitView` 边栏 + 七个原生页面。
struct ConsoleView: View {
    @ObservedObject var state: AppState

    @State private var showDownloads = false
    @State private var showHub = false
    /// 重命名弹窗里的输入。线程本身挂在 `pendingThreadRename` 上，壳层只负责
    /// 把输入框和落点接起来。
    @State private var renameText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { state.showsSidebar ? .all : .detailOnly },
            set: { visibility in
                state.setShowsSidebar(visibility != .detailOnly)
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            ConsoleNavigationPanel(state: state, chat: state.chat)
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            if isShowingOnboarding {
                LaunchPage(state: state, installs: state.installs)
                    .transition(.opacity.animation(Motion.pageCrossfade))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !isShowingOnboarding, let notice = state.islandNotice {
                FloatingNoticeToast(notice: notice) { state.dismissToast() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: state.islandNotice?.id)
        .sheet(isPresented: $showDownloads) { DownloadCenterSheet(state: state) }
        .sheet(isPresented: $showHub) {
            HubSheet(state: state, hub: state.hub, engine: state.libraryEngine)
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
    }

    private var isShowingOnboarding: Bool {
        state.isPresentingLaunchPage || state.showsRecommendationPage
    }

    @ViewBuilder private var detailContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state, metrics: state.metrics)
        case .chat:
            ChatPage(
                state: state,
                chat: state.chat,
                isActive: !isShowingOnboarding)
        case .models:
            ModelsPage(
                state: state,
                showingHub: $showHub,
                showingDownloads: $showDownloads)
        case .engines: EnginesPage(state: state, installs: state.installs)
        case .logs: LogsPage(state: state, logFeed: state.logFeed)
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
