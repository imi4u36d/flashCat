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
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 200

    private var resolvedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, 180), 320))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ConsoleBackdrop(accent: state.section.keyColor)

            HStack(spacing: 0) {
                if state.showsSidebar {
                    ZStack(alignment: .trailing) {
                        ConsoleSidebar(state: state, collapsed: false)
                            .frame(width: resolvedSidebarWidth)
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    ConsoleSidebar(state: state, collapsed: true)
                        .frame(width: 76)
                        .transition(.opacity)
                }

                ZStack {
                    pageContent
                        .id(state.section)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(Motion.standard, value: state.section)
            }
            .animation(.easeInOut(duration: 0.22), value: state.showsSidebar)

            ConsoleTitlebar(state: state,
                            openCommand: { showCommand = true },
                            openDownloads: { showDownloads = true })
                .frame(height: Console.titlebarHeight)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .tint(Console.accent)
        .preferredColorScheme(preferredScheme)
        .overlay(alignment: .bottom) {
            if let message = state.toastMessage {
                ToastView(message: message)
                    .transition(.opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96)))
                    .onTapGesture { state.dismissToast() }
            }
        }
        .animation(Motion.entrance, value: state.toastMessage)
        .overlay {
            if state.isPresentingLaunchPage || state.showsRecommendationPage {
                LaunchPage(state: state)
                    .transition(.opacity)
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
            Button(request.needsDownload ? "切换并下载" : "切换并使用") { state.confirmLibraryUse() }
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
        return "会先停止 \(running) 并卸载它的权重，再加载 \(next)。卸载到新模型就绪之间引擎无法应答；失败时会回滚到 \(running)。"
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

    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.leading, collapsed ? 22 : 28)
                .padding(.top, 60)
                .padding(.bottom, 4)

            workspace
                .padding(.horizontal, collapsed ? 8 : 14)

            if !collapsed {
                recents
                    .padding(.top, 20)
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Console.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Console.sidebarEdge).frame(width: 1)
        }
        .animation(Motion.standard, value: state.section)
    }

    private var brand: some View {
        ZStack(alignment: .bottomTrailing) {
            BrandMark(size: collapsed ? 30 : 36)
            Circle()
                .fill(Native.green)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Console.sidebar, lineWidth: 2))
                .offset(x: 3, y: 3)
        }
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
                    .foregroundStyle(active ? Console.accent : Console.secondary)
                    .frame(width: 24)
                    .symbolRenderingMode(.hierarchical)
                if !collapsed {
                    Text(page.rawValue)
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
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Console.cardStrong)
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Console.cardStroke, lineWidth: 0.8)
                        }
                        .shadow(color: Console.shadow, radius: 12, x: 0, y: 5)
                        .matchedGeometryEffect(id: "nav.selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Console.inset)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

// MARK: - Titlebar

struct ConsoleTitlebar: View {
    @ObservedObject var state: AppState
    var openCommand: () -> Void
    var openDownloads: () -> Void

    @State private var hoveringEngine = false

    private var rate: Double {
        state.liveDecodeRate ?? state.stats?.decodeTokensPerSecond ?? 0
    }

    private var downloadCount: Int {
        state.downloadTasks.count + (state.downloadingModel == nil ? 0 : 1)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                Color.clear.frame(width: 82, height: 1)
                sidebarToggle
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
                    .background(Capsule().fill(Console.card.opacity(0.7)))
                    .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))
                }
                .buttonStyle(.plain)

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
                            .background(Circle().fill(Console.card.opacity(0.7)))
                            .overlay(Circle().stroke(Console.cardStroke, lineWidth: 0.8))
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
                .buttonStyle(.plain)
                .help("下载中心")
            }
            .padding(.horizontal, 16)

            enginePill
        }
        .background(WindowDragArea())
    }

    /// macOS 26 原生玻璃按钮：系统 sidebar toggle 的样式与位置（红绿灯右侧 30pt）。
    private var sidebarToggle: some View {
        Button {
            withAnimation(.smooth(duration: 0.28)) {
                state.toggleSidebar()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(state.showsSidebar ? "隐藏边栏（⌘\\）" : "显示边栏（⌘\\）")
        .accessibilityLabel(state.showsSidebar ? "隐藏边栏" : "显示边栏")
    }

    private var enginePill: some View {
        Button {
            state.toggleService()
        } label: {
            HStack(spacing: 8) {
                if state.isRunning {
                    LiveDot(color: Console.ok, diameter: 6)
                } else {
                    Circle()
                        .fill(Console.tertiary)
                        .frame(width: 6, height: 6)
                        .padding(.horizontal, 3)
                }
                Text(state.activeEngine.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text(state.isRunning ? "运行中" : state.serverState == .starting ? "启动中" : "已停止")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Console.secondary)
                if state.isRunning {
                    Rectangle().fill(Console.cardStroke).frame(width: 1, height: 12)
                    Text("\(Format.compact(rate)) tok/s")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.secondary)
                }
                Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(state.isRunning ? Native.red : Console.secondary)
                    .opacity(hoveringEngine ? 1 : 0.45)
            }
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(Capsule().fill(Console.card.opacity(0.82)))
            .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            .shadow(color: Console.shadow.opacity(0.5), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(Motion.quick) { hoveringEngine = value } }
        .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
        .help(state.isRunning ? "停止引擎" : "启动引擎")
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
