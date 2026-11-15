import SwiftUI
import AppKit
import FlashCatKit

/// 控制台根视图：贴着窗口左缘的纸色导航列 + 无底标题栏 + 七个原生页面。
/// 导航列只靠一条竖发丝线和画布分开，不再是一块浮起来的面板。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var showFeedback = false
    @State private var islandExpanded = false

    /// 导航列从窗口左缘铺到 `width`，上下不再留浮动的缝。
    private enum NavPanel {
        static let width: CGFloat = 208
        /// 导航列的右缘。标题栏的折叠按钮贴住这条竖线，两边读的是同一个值。
        static var trailingEdge: CGFloat { width }
    }

    private var navPanelTrailingEdge: CGFloat? {
        state.showsSidebar ? NavPanel.trailingEdge : nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 画布铺满整窗，导航列与主视口共享同一层渐变，
            // 导航列和主视口因此始终共享同一张纸色画布。
            ConsoleBackdrop()

            HStack(spacing: 0) {
                if state.showsSidebar {
                    ConsoleNavigationPanel(state: state,
                                           chat: state.chat)
                        .frame(width: NavPanel.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(Motion.standard, value: state.section)
            }

            ConsoleTitlebar(state: state,
                            navPanelTrailingEdge: navPanelTrailingEdge,
                            openDownloads: { showDownloads = true },
                            openFeedback: { showFeedback = true })
                .frame(height: Console.titlebarHeight)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        // 画布之下还有一层：没有自定义图片时它兜住桌面，毛玻璃强度跟着
        // 「背景模糊」走。放在这里而不是 App 的 scene body 里，保证它跟
        // ConsoleView 一起观察背景参数，不至于一整轮更新都收不到。
        .background { DesktopBackdrop().ignoresSafeArea() }
        .tint(Console.accent)
        .preferredColorScheme(preferredScheme)
        .overlay(alignment: .top) {
            DynamicIslandLayer(state: state, expanded: $islandExpanded)
        }
        .overlay {
            if isShowingOnboarding {
                LaunchPage(state: state)
                    .transition(.opacity.animation(Motion.pageCrossfade))
            }
        }
        .overlay {
            if showCommand {
                CommandPalette(state: state,
                               openDownloads: { showDownloads = true },
                               openHub: { showHub = true; state.section = .models },
                               dismiss: { showCommand = false })
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showDownloads) { DownloadCenterSheet(state: state) }
        .sheet(isPresented: $showHub) { HubSheet(state: state, engine: state.libraryEngine) }
        .sheet(isPresented: $showFeedback) { FeedbackSheet(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .flashCatOpenCommandPalette)) { _ in
            showCommand = true
        }
        .alert("切换模型？", isPresented: modelSwitchShown) {
            Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
            Button("停止并切换") { state.confirmModelSwitch() }
        } message: { Text(modelSwitchMessage) }
        .alert("\(state.pendingEngineInstall?.displayName ?? "该引擎") 还没安装",
               isPresented: engineInstallShown,
               presenting: state.pendingEngineInstall) { _ in
            Button("去安装") { state.confirmEngineInstall() }
            Button("取消", role: .cancel) { state.cancelEngineInstall() }
        } message: { engine in
            Text("这个模型由 \(engine.displayName) 引擎驱动，先安装 \(engine.displayName) 才能切换到它。")
        }
        .alert("切换引擎？", isPresented: libraryUseShown, presenting: state.pendingLibraryUse) { request in
            Button(L10n.t(request.needsDownload ? "切换并下载" : "切换并使用")) { state.confirmLibraryUse() }
            Button("取消", role: .cancel) { state.cancelLibraryUse() }
        } message: { request in
            Text("\(request.model) 属于 \(request.engine.displayName)，切换会先停掉 \(state.activeEngine.displayName)，再以这个模型启动 \(request.engine.displayName)。")
        }
        // 侧栏与对话页两处入口都挂到同一个挂起态上，确认只在壳层弹一次。
        .alert("删除这段对话？", isPresented: threadDeleteShown, presenting: state.pendingThreadDelete) { _ in
            Button("删除", role: .destructive) { state.confirmThreadDelete() }
            Button("取消", role: .cancel) { state.cancelThreadDelete() }
        } message: { thread in
            Text("「\(thread.title)」里的 \(thread.messages.count) 条消息会一并删除，无法恢复。")
        }
    }

    /// 引导页（首次推荐 / 引擎安装）是否盖住控制台。两个来源合成一个布尔，
    /// 让淡出动画在任意一条离开路径上都能触发。
    private var isShowingOnboarding: Bool {
        state.isPresentingLaunchPage || state.showsRecommendationPage
    }

    private var preferredScheme: ColorScheme? {
        switch theme.mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state, chat: state.chat)
        case .chat: ChatPage(state: state, chat: state.chat)
        case .models: ModelsPage(state: state,
                                 engine: state.libraryEngine,
                                 showingHub: $showHub,
                                 showingDownloads: $showDownloads)
        case .engines: EnginesPage(state: state, installs: state.installs)
        case .logs: LogsPage(state: state)
        case .settings: SettingsPage(state: state)
        case .lab: LabPage(state: state)
        }
    }

    private var modelSwitchShown: Binding<Bool> {
        Binding(get: { state.confirmingModelSwitch != nil },
                set: { if !$0 { state.cancelModelSwitchRequest() } })
    }

    private var threadDeleteShown: Binding<Bool> {
        Binding(get: { state.pendingThreadDelete != nil },
                set: { if !$0 { state.cancelThreadDelete() } })
    }

    private var modelSwitchMessage: String {
        let next = state.shortModelName(state.confirmingModelSwitch ?? "")
        let running = state.shortModelName(state.selectedModel)
        return L10n.format("将停止 %@ 并加载 %@，切换期间引擎暂时无法应答。", running, next)
    }

    private var engineInstallShown: Binding<Bool> {
        Binding(get: { state.pendingEngineInstall != nil },
                set: { if !$0 { state.cancelEngineInstall() } })
    }

    private var libraryUseShown: Binding<Bool> {
        Binding(get: { state.pendingLibraryUse != nil },
                set: { if !$0 { state.cancelLibraryUse() } })
    }
}

// MARK: - Paper navigation

/// 纸色导航列：页面导航、最近对话和底部工具共用一列，右缘一条发丝线。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspace

            recents
                .padding(.top, 18)
        }
        .padding(.horizontal, 12)
        .padding(.top, Console.contentTopInset)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Console.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Console.sidebarEdge).frame(width: 1)
        }
        .animation(Motion.standard, value: state.section)
    }

    /// 主工作区：概览到设置，最后一行是实验室。
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(L10n.t("工作区"))
                .font(Console.eyebrow)
                .tracking(0.8)
                .foregroundStyle(Console.tertiary)
                .padding(.leading, 9)
                .padding(.bottom, 7)

            ForEach(Page.workspace) { page in
                PaperNavRow(page: page,
                            active: state.section == page,
                            badge: page == .models ? modelCount : 0) {
                    state.section = page
                }
            }
        }
    }

    private var modelCount: Int {
        state.libraryEntries(for: state.libraryEngine).filter(\.installed).count
    }

    private func recentDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return Format.clock(date) }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private var recents: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 1) {
                Rectangle()
                    .fill(Console.hairline)
                    .frame(height: 1)
                    .padding(.bottom, 12)

                Text(L10n.t("最近对话"))
                    .font(Console.eyebrow)
                    .tracking(0.8)
                    .foregroundStyle(Console.tertiary)
                    .padding(.leading, 9)
                    .padding(.bottom, 6)

                ForEach(chat.threads.prefix(6)) { thread in
                    PaperRecentRow(title: thread.title,
                                   date: state.generatingThreadID == thread.id
                                       ? L10n.t("生成中")
                                       : recentDate(thread.updatedAt),
                                   active: state.currentThreadID == thread.id) {
                        state.openThread(thread)
                        state.section = .chat
                    } onDelete: {
                        state.requestThreadDelete(thread)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct PaperNavRow: View {
    let page: Page
    let active: Bool
    let badge: Int
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13.5, weight: .regular))
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(active ? Console.text : Console.tertiary)
                Text(L10n.t(page.rawValue))
                    .font(.system(size: 13, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? Console.text : Console.secondary)
                    .padding(.leading, 1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? Console.rowSelected : (hovering ? Console.rowHover : .clear))
            }
            .overlay(alignment: .leading) {
                if active {
                    Capsule()
                        .fill(Console.accent)
                        .frame(width: 2.5, height: 14)
                        .padding(.leading, 0)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plainHit)
        .help(L10n.t(page.rawValue))
        .onHover { value in
            withAnimation(Motion.quick) { hovering = value }
        }
    }
}

private struct PaperRecentRow: View {
    let title: String
    let date: String
    let active: Bool
    let action: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        // 删除按钮与整行是兄弟而不是父子：套在行按钮的 label 里，
        // 外层按钮会把点击整个吃掉，垃圾桶点不动。
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(active ? Console.accent : Console.quaternary.opacity(0.6))
                        .frame(width: 4, height: 4)
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(active ? Console.text : Console.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(date)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .lineLimit(1)
                        .opacity(hovering ? 0 : 1)
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background {
                    shape.fill(active ? Console.rowSelected : (hovering ? Console.rowHover : .clear))
                }
                .contentShape(shape)
            }
            .buttonStyle(.plainHit)

            RowDeleteButton(action: onDelete)
                .padding(.trailing, 6)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

// MARK: - Titlebar

struct ConsoleTitlebar: View {
    @ObservedObject var state: AppState
    /// 悬浮导航列的右缘；导航收起时为 nil。折叠按钮的右沿就落在这条竖线上，
    /// 导航隐藏后回落到红绿灯右侧的最小安全位置。
    var navPanelTrailingEdge: CGFloat?
    var openDownloads: () -> Void
    var openFeedback: () -> Void

    private enum Layout {
        /// 折叠按钮的直径。它和导航列的右缘对齐，改尺寸时两处一起看。
        static let toggleSize: CGFloat = 30
        /// 标题栏右侧留白，反馈入口贴住这条线。
        static let trailingInset: CGFloat = 16
        /// 导航列收起后折叠按钮的落点：红绿灯右侧第一个安全位。
        static let collapsedToggleLeading: CGFloat = 100
    }

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                sidebarToggle
                    .padding(.leading, toggleLeadingInset)
                Spacer(minLength: 8)

                ChromeIconButton(systemName: state.theme.mode.resolvedIsDark ? "sun.max" : "moon",
                                 help: L10n.t("切换外观")) {
                    state.theme.set(state.theme.mode.resolvedIsDark ? .light : .dark)
                }

                ChromeIconButton(systemName: "arrow.down.circle",
                                 help: L10n.t("下载中心"),
                                 badge: downloadCount) {
                    openDownloads()
                }

                ChromeIconButton(systemName: "bubble.left.and.bubble.right",
                                 help: L10n.t("反馈与交流")) {
                    openFeedback()
                }
            }
            .padding(.trailing, Layout.trailingInset)
        }
        .frame(height: 32)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())
    }

    /// 折叠按钮的左沿（从窗口左沿算起）。导航列展开时按钮的右缘和列右缘
    /// 共用一条竖线，读作列顶部的一颗控件，而不是浮在列与主视口之间的空隙里。
    private var toggleLeadingInset: CGFloat {
        guard let trailingEdge = navPanelTrailingEdge else {
            return Layout.collapsedToggleLeading
        }
        return trailingEdge - Layout.toggleSize
    }

    /// 折叠按钮：贴在导航列右缘，和红绿灯同一水平线。
    private var sidebarToggle: some View {
        ChromeIconButton(systemName: "sidebar.left",
                         help: L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏")) {
            state.toggleSidebar()
        }
    }

}

/// 标题栏上的图标按钮：没有玻璃圆底，只有悬停时的一块方形浅底。
struct ChromeIconButton: View {
    let systemName: String
    var help: String = ""
    var badge: Int = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(hovering ? Console.text : Console.secondary)
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hovering ? Console.rowHover : .clear)
                    }
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(Console.inkForeground)
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Console.accent))
                        .offset(x: 2, y: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { value in
            withAnimation(Motion.quick) { hovering = value }
        }
        .help(help)
        .accessibilityLabel(help)
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
