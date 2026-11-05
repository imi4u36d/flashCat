import SwiftUI
import AppKit
import FlashCatKit

/// 控制台根视图：玻璃侧栏 + 浮层标题栏 + 六个原生页面 + 启动页。
/// 版式按 WebUI 1:1：200 pt 侧栏、54 pt 浮层标题栏、24 pt 内容边距。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @State private var showFeedback = false
    @State private var islandExpanded = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200

    private var resolvedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, 180), 320))
    }

    /// 展开时用用户拖出来的宽度，收起时是 76pt 图标栏。
    /// 这里手写列宽而不是用 NavigationSplitView：系统侧栏列有最小宽度，
    /// 收不到 76pt，收起后会留下一条两百多点的空白栏。
    private var currentSidebarWidth: CGFloat {
        state.showsSidebar ? resolvedSidebarWidth : Native.railWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    ConsoleSidebar(state: state,
                                   collapsed: !state.showsSidebar,
                                   openFeedback: { showFeedback = true })
                    if state.showsSidebar {
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                }
                .frame(width: currentSidebarWidth)
                .background { SidebarMaterial() }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Console.sidebarEdge).frame(width: 1)
                }
                .clipped()

                ZStack {
                    // 画布只铺内容区，侧栏留给窗口背后的桌面透上来，
                    // 侧栏玻璃因此能采到真实背景而不是同色渐变。
                    ConsoleBackdrop(accent: state.section.keyColor)
                    pageContent
                        .id(state.section)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(Motion.standard, value: state.section)
            }

            ConsoleTitlebar(state: state,
                            sidebarWidth: currentSidebarWidth,
                            openCommand: { showCommand = true },
                            openDownloads: { showDownloads = true })
                .frame(height: Console.titlebarHeight)
                .frame(maxWidth: .infinity, alignment: .top)
        }
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
        .background {
            Group {
                Button("") { showCommand = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") {
                    let dark = state.theme.mode.resolvedIsDark
                    state.theme.set(dark ? .light : .dark)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
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
        case .overview: OverviewPage(state: state)
        case .chat: ChatPage(state: state)
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

// MARK: - Sidebar

struct ConsoleSidebar: View {
    @ObservedObject var state: AppState
    var collapsed: Bool = false
    var openFeedback: () -> Void = {}

    @Namespace private var selection
    @State private var feedbackHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspace
                .padding(.horizontal, 14)
                .padding(.top, 60)

            if !collapsed {
                recents
                    .padding(.top, 20)
            }

            Spacer(minLength: 12)

            feedbackRow
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.standard, value: state.section)
    }

    private var feedbackRow: some View {
        Button(action: openFeedback) {
            HStack(spacing: 11) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 24)
                    .symbolRenderingMode(.hierarchical)
                if !collapsed {
                    Text("反馈")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Console.secondary)
                    Spacer(minLength: 4)
                }
            }
            .padding(.horizontal, collapsed ? 0 : 12)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background {
                if feedbackHovering {
                    RoundedRectangle(cornerRadius: collapsed ? 20 : 13, style: .continuous)
                        .frame(width: collapsed ? 40 : nil, height: collapsed ? 40 : nil)
                        .glassEffect(.regular,
                                     in: RoundedRectangle(cornerRadius: collapsed ? 20 : 13, style: .continuous))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: collapsed ? 20 : 13, style: .continuous))
        }
        .buttonStyle(.plainHit)
        .help("反馈与交流")
        .onHover { value in withAnimation(Motion.quick) { feedbackHovering = value } }
    }

    private var workspace: some View {
        VStack(spacing: 4) {
            ForEach(Page.allCases) { page in
                SidebarNavRow(page: page,
                              active: state.section == page,
                              collapsed: collapsed,
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
            Text("最近对话")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Console.secondary)
                .padding(.leading, 16)
                .padding(.bottom, 8)
            ForEach(state.threads.prefix(6)) { thread in
                SidebarRecentRow(title: thread.title,
                                 date: recentDate(thread.updatedAt),
                                 active: state.currentThreadID == thread.id) {
                    state.openThread(thread)
                    state.section = .chat
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarNavRow: View {
    let page: Page
    let active: Bool
    let collapsed: Bool
    let badge: Int
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: page.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(active ? Console.text : Console.secondary)
                    .frame(width: 24)
                    .symbolRenderingMode(.hierarchical)
                if !collapsed {
                    Text(L10n.t(page.rawValue))
                        .font(.system(size: 14.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Console.text : Console.secondary)
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
            }
            .padding(.horizontal, collapsed ? 0 : 12)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background {
                if active {
                    // 选中态与设置页的分段按钮组保持一致：白色胶囊 + 细边 + 轻投影，
                    // 不再使用会发灰的玻璃材质。
                    Capsule()
                        .fill(Console.glassSelected)
                        .overlay(Capsule().strokeBorder(Console.glassStroke, lineWidth: 0.6))
                        .shadow(color: Console.shadow.opacity(0.7), radius: 6, y: 2)
                        .frame(width: collapsed ? 40 : nil, height: collapsed ? 40 : nil)
                        .matchedGeometryEffect(id: "nav.selection", in: namespace)
                } else if hovering {
                    Capsule()
                        .fill(Console.glassGroup)
                        .frame(width: collapsed ? 40 : nil, height: collapsed ? 40 : nil)
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
}

private struct SidebarRecentRow: View {
    let title: String
    let date: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Console.inset : (hovering ? Console.inset.opacity(0.6) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit)
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

// MARK: - Titlebar

struct ConsoleTitlebar: View {
    @ObservedObject var state: AppState
    /// 当前侧栏实际宽度。折叠按钮要贴在内容区左缘，而不是固定写在 x=82。
    var sidebarWidth: CGFloat = 200
    var openCommand: () -> Void
    var openDownloads: () -> Void

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                // 展开/收起时都让按钮跟着侧栏右缘走，只留 8pt 间距；
                // 收起时图标栏已加宽到 96pt，红绿灯右侧留白足够，
                // 折叠按钮不必再额外偏移。
                sidebarToggle
                    .padding(.leading, max(0, sidebarWidth - 8))
                Spacer(minLength: 8)
                Button(action: openCommand) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                        Text("命令")
                            .font(.system(size: 11.5))
                        Text("⌘K")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
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
                           help: "切换外观（⌘⇧A）") {
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
        .help(L10n.t(state.showsSidebar ? "隐藏边栏（⌘\\）" : "显示边栏（⌘\\）"))
        .accessibilityLabel(L10n.t(state.showsSidebar ? "隐藏边栏" : "显示边栏"))
    }

}

// MARK: - Window chrome helpers

/// 侧栏的原生 vibrancy 材质。窗口本身透明，用 `behindWindow` 让侧栏
/// 采到桌面背景，而不是盖一层不透明的同色渐变。
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        width = min(max(base + Double(value.translation.width), 180), 320)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("拖动调整边栏宽度")
    }
}
