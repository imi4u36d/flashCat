import SwiftUI
import AppKit
import FlashCatKit

/// 控制台根视图：悬浮玻璃导航列 + 浮层标题栏 + 六个原生页面 + 启动页。
/// 导航列不再贴边占满，而是以圆角玻璃卡片的形式浮在画布左侧。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var showFeedback = false
    @State private var islandExpanded = false

    /// 悬浮导航列的尺寸。列本身不再占满窗口高度到底，
    /// 而是留出左右与底部的空间，让主视口能透出来。
    private enum NavPanel {
        static let width: CGFloat = 208
        static let leadingInset: CGFloat = 12
        static let trailingGap: CGFloat = 12
        static var reservedWidth: CGFloat { width + leadingInset + trailingGap }
    }

    private var navReservedWidth: CGFloat {
        state.showsSidebar ? NavPanel.reservedWidth : 0
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 画布铺满整窗，导航列与主视口共享同一层渐变，
            // 玻璃下透出的颜色因此始终和右侧保持一致。
            ConsoleBackdrop(accent: state.section.keyColor)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    ConsoleNavigationPanel(state: state,
                                           chat: state.chat,
                                           openFeedback: { showFeedback = true })
                        .frame(width: NavPanel.width)
                        .padding(.leading, NavPanel.leadingInset)
                        .padding(.trailing, NavPanel.trailingGap)
                        .padding(.top, Console.titlebarHeight)
                        .padding(.bottom, 14)
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

            // 标题栏自己的安全背景层：先铺一层稳定的底色，再让悬浮的玻璃控件
            // 和灵动岛坐在上面。没有这层时，页面内容、玻璃高光和灵动岛会直接
            // 叠在一起互相透视，切页或滚动时会看到明显的层叠脏边。
            TitlebarBackdrop()
                .frame(height: Console.titlebarHeight)
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)

            ConsoleTitlebar(state: state,
                            navReservedWidth: navReservedWidth,
                            openCommand: { showCommand = true },
                            openDownloads: { showDownloads = true })
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
        }
    }

    private var modelSwitchShown: Binding<Bool> {
        Binding(get: { state.confirmingModelSwitch != nil },
                set: { if !$0 { state.cancelModelSwitchRequest() } })
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

// MARK: - Floating glass navigation

/// 悬浮导航列：取消传统侧栏的整块背景与分隔线，
/// 把页面导航、最近对话和底部工具合成一块垂直玻璃组件。
struct ConsoleNavigationPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    var openFeedback: () -> Void = {}

    @Namespace private var selection

    var body: some View {
        LiquidGlassPanel(radius: 26) {
            VStack(alignment: .leading, spacing: 0) {
                workspace

                recents
                    .padding(.top, 14)

                Spacer(minLength: 12)

                utilityRow
                    .padding(.top, 10)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(Motion.standard, value: state.section)
    }

    private var utilityRow: some View {
        HStack(spacing: 6) {
            GlassUtilityButton(symbol: "slider.horizontal.3",
                               title: "设置",
                               help: "设置",
                               active: state.section == .settings) {
                state.section = .settings
            }
            GlassUtilityButton(symbol: "bubble.left.and.bubble.right",
                               title: "反馈",
                               help: "反馈与交流",
                               active: false) {
                openFeedback()
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 4) {
            ForEach(Page.allCases.filter { $0 != .settings }) { page in
                GlassNavRow(page: page,
                            active: state.section == page,
                            badge: page == .models ? modelCount : 0,
                            namespace: selection) {
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
        VStack(alignment: .leading, spacing: 2) {
            Rectangle()
                .fill(Console.glassStroke)
                .frame(height: 0.5)
                .padding(.horizontal, 6)
                .padding(.bottom, 12)

            Text("最近对话")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Console.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            ForEach(chat.threads.prefix(6)) { thread in
                GlassRecentRow(title: thread.title,
                               date: recentDate(thread.updatedAt),
                               active: state.currentThreadID == thread.id) {
                    state.openThread(thread)
                    state.section = .chat
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GlassUtilityButton: View {
    let symbol: String
    let title: String
    let help: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 18)
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            }
            .foregroundStyle(active ? Console.text
                                    : (hovering ? Console.text : Console.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background {
                if active || hovering {
                    shape
                        .fill(active ? Console.glassSelected.opacity(0.72) : Console.glassGroup)
                        .overlay(shape.strokeBorder(Console.glassStroke, lineWidth: 0.7))
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plainHit)
        .help(help)
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

private struct GlassNavRow: View {
    let page: Page
    let active: Bool
    let badge: Int
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                Text(L10n.t(page.rawValue))
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Console.inset))
                }
            }
            .foregroundStyle(active ? Console.text
                                    : (hovering ? Console.text : Console.secondary))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                if active {
                    activeCapsule
                } else if hovering {
                    hoverCapsule
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
        .help(L10n.t(page.rawValue))
        .onHover { value in
            guard !reduceMotion else { hovering = value; return }
            withAnimation(Motion.quick) { hovering = value }
        }
    }

    /// 选中态：中性玻璃胶囊。只靠层次与描边区分，不再使用强调色填充。
    private var activeCapsule: some View {
        Capsule()
            .fill(Console.glassSelected)
            .overlay {
                Capsule().fill(.clear)
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
            .overlay {
                Capsule().strokeBorder(Console.glassStroke, lineWidth: 0.8)
            }
            .shadow(color: Console.shadow.opacity(scheme == .dark ? 0.35 : 0.10),
                    radius: 8, x: 0, y: 3)
            .matchedGeometryEffect(id: "nav.selection", in: namespace)
    }

    /// Hover：中性玻璃底，不做位移和缩放。
    private var hoverCapsule: some View {
        Capsule()
            .fill(Console.glassGroup)
            .overlay {
                Capsule().strokeBorder(Console.glassStroke, lineWidth: 0.8)
            }
    }
}

private struct GlassRecentRow: View {
    let title: String
    let date: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(active ? Console.accent : Console.tertiary.opacity(0.7))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(active ? Console.text : Console.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(date)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                shape.fill(active ? Console.inset
                                  : (hovering ? Console.inset.opacity(0.6) : .clear))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plainHit)
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

// MARK: - Titlebar

struct ConsoleTitlebar: View {
    @ObservedObject var state: AppState
    /// 导航列占用的横向总宽（含两侧留白）。折叠按钮跟着它走，
    /// 导航隐藏后回落到红绿灯右侧的最小安全位置。
    var navReservedWidth: CGFloat = 0
    var openCommand: () -> Void
    var openDownloads: () -> Void

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                // 按钮跟着悬浮导航列的右缘走；导航隐藏时退到红绿灯右侧，
                // 避免和窗口控制按钮重叠。
                sidebarToggle
                    .padding(.leading, max(84, navReservedWidth - 8))
                Spacer(minLength: 8)
                Button(action: openCommand) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                        Text("命令")
                            .font(.system(size: 11.5))
                    }
                    .foregroundStyle(Console.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background {
                        LiquidGlassSurface(shape: Capsule(), interactive: true)
                    }
                }
                .buttonStyle(.plainHit)

                IconAction(systemName: state.theme.mode.resolvedIsDark ? "sun.max" : "moon",
                           help: "切换外观") {
                    state.theme.set(state.theme.mode.resolvedIsDark ? .light : .dark)
                }

                Button(action: openDownloads) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Console.text.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background {
                                LiquidGlassSurface(shape: Circle(), interactive: true)
                            }
                        if downloadCount > 0 {
                            Text(verbatim: "\(downloadCount)")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Console.accent))
                                .offset(x: 3, y: -2)
                        }
                    }
                }
                .buttonStyle(.plainHit)
                .help("下载中心")
            }
            .padding(.horizontal, 16)
        }
        // 红绿灯整体下移 6pt 后，标题栏行也下移 6pt，二者仍然同轴，
        // 同时离窗口上沿留出一点距离。
        .frame(height: 32)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())
    }

    /// macOS 26 原生玻璃按钮：贴在侧栏右缘，和红绿灯同一水平线。
    private var sidebarToggle: some View {
        Button {
            // 动画统一由 AppState.toggleSidebar() 里的 withAnimation 驱动，
            // 菜单栏、命令面板和这个按钮走同一条路径。
            state.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Console.text.opacity(0.8))
                .frame(width: 30, height: 30)
                .background {
                    LiquidGlassSurface(shape: Circle(), interactive: true)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plainHit)
        .help(L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏"))
        .accessibilityLabel(L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏"))
    }

}

// MARK: - Titlebar backdrop

/// 标题栏的安全背景层。用一层柔和材质把标题栏和下面的页面内容隔开，
/// 下缘渐变淡出，避免出现一条硬边；所有悬浮控件都复用它，不再各自叠玻璃。
private struct TitlebarBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                // 材质本身会偏灰，补一层画布色让标题栏和页面保持在同一个色阶。
                LinearGradient(
                    colors: [Console.backgroundTop.opacity(scheme == .dark ? 0.55 : 0.45), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .mask {
                // 顶部完全覆盖，靠近下缘再收干净，不切出一条分隔线。
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.65),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
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
