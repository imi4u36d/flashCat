import SwiftUI
import AppKit
import FlashCatKit

/// 控制台根视图：侧栏 + 六个原生页面 + 启动页。
///
/// 这里没有网页、没有快照桥：页面直接读 `AppState` 的 `@Published` 状态，
/// 用户动作直接调用 `AppState` 的方法。所有可变状态仍然只在一个 `@MainActor`
/// 对象上，视图是它的纯函数。
struct ConsoleView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var theme = AppState.shared.theme

    @State private var showCommand = false
    @State private var showDownloads = false
    @State private var showHub = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 216

    private var resolvedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, 180), 320))
    }

    var body: some View {
        VStack(spacing: 0) {
            ConsoleTitlebar(state: state,
                            openCommand: { showCommand = true },
                            openDownloads: { showDownloads = true })

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
        }
        .background(PageBackdrop(accent: state.section.keyColor))
        .tint(Native.accent)
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
        .sheet(isPresented: $showDownloads) {
            DownloadCenterSheet(state: state)
        }
        .sheet(isPresented: $showHub) {
            HubSheet(state: state, engine: state.libraryEngine)
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
        .animation(.easeOut(duration: 0.2), value: state.isPresentingLaunchPage || state.showsRecommendationPage)
        .alert("切换模型？", isPresented: modelSwitchShown) {
            Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
            Button("停止并切换") { state.confirmModelSwitch() }
        } message: {
            Text(modelSwitchMessage)
        }
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

    // MARK: Bindings

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
                .padding(.horizontal, collapsed ? 10 : 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            if !collapsed {
                Button {
                    state.newConversation()
                    state.section = .chat
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.arcadePillCompact)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                IconAction(systemName: "sidebar.left", help: "展开边栏（⌘\\）") {
                    state.toggleSidebar()
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
            }

            workspace
                .padding(.horizontal, collapsed ? 8 : 10)

            if !collapsed {
                recents
                    .padding(.top, 16)
            }

            Spacer(minLength: 12)

            engineCard
                .padding(.horizontal, collapsed ? 8 : 12)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            LinearGradient(colors: [Native.sidebar, Native.sidebar.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Native.hairline.opacity(0.8))
                .frame(width: 1)
        }
        .animation(Motion.standard, value: state.section)
    }

    private var brand: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Native.accent.opacity(0.22), .clear],
                                         center: .center, startRadius: 2, endRadius: 26))
                    .frame(width: 48, height: 48)
                BrandMark(size: collapsed ? 28 : 32)
            }
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("flashCat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Native.label)
                    Text("本地推理控制台")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 2) {
            if !collapsed {
                Eyebrow(text: "工作区")
                    .padding(.horizontal, 9)
                    .padding(.bottom, 5)
            }
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
        EngineCatalog.allIDs.reduce(0) { total, id in
            total + state.libraryEntries(for: id).filter(\.installed).count
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 1) {
            Eyebrow(text: "最近对话")
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            ForEach(state.threads.prefix(6)) { thread in
                SidebarRecentRow(title: thread.title,
                                 active: state.currentThreadID == thread.id) {
                    state.openThread(thread)
                    state.section = .chat
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if state.isRunning {
                    LiveDot(color: statusColor(state.serverState), diameter: 7)
                } else {
                    Circle()
                        .fill(statusColor(state.serverState))
                        .frame(width: 7, height: 7)
                        .padding(.horizontal, 3.5)
                }
                if !collapsed {
                    Text(state.activeEngine.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.isRunning ? "运行中" : state.serverState == .starting ? "启动中" : "已停止")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                } else {
                    Spacer(minLength: 0)
                }
            }

            if !collapsed {
                Text(verbatim: "\(state.engineVersion) · \(state.port)")
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Button {
                        state.toggleService()
                    } label: {
                        Text(state.isRunning ? "停止" : "启动")
                            .frame(minWidth: 42)
                    }
                    .buttonStyle(ArcadePillStyle(tone: state.isRunning ? .quietDanger : .light, compact: true))
                    .disabled(state.isSwitchingModel)

                    Menu {
                        ForEach(EngineCatalog.allIDs, id: \.self) { id in
                            Button {
                                Task { @MainActor in await state.switchEngine(id) }
                            } label: {
                                if id == state.activeEngine {
                                    Label(id.displayName, systemImage: "checkmark")
                                } else {
                                    Text(id.displayName)
                                }
                            }
                            .disabled(!state.engineIsInstalled(id))
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Native.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Native.overlay(0.07)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("切换引擎")
                }
            } else {
                Button {
                    state.toggleService()
                } label: {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(state.isRunning ? Native.red : Native.green)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Native.overlay(0.07)))
                }
                .buttonStyle(.plain)
                .help(state.isRunning ? "停止引擎" : "启动引擎")
            }
        }
        .padding(collapsed ? 9 : 11)
        .background {
            let shape = RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
            shape
                .fill(Native.canvas)
                .overlay {
                    shape.fill(statusColor(state.serverState).opacity(state.isRunning ? 0.055 : 0))
                }
                .overlay {
                    shape.strokeBorder(state.isRunning
                                       ? statusColor(state.serverState).opacity(0.28)
                                       : Native.hairline,
                                       lineWidth: 1)
                }
                .shadow(color: Native.panelShadow.opacity(state.isRunning ? 0.9 : 0),
                        radius: 10, y: 3)
        }
        .animation(Motion.standard, value: state.isRunning)
    }
}

// MARK: - Sidebar rows

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
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? page.keyColor : Native.secondary)
                    .frame(width: 18)
                    .symbolRenderingMode(.hierarchical)
                if !collapsed {
                    Text(page.rawValue)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Native.label : Native.secondary)
                    Spacer(minLength: 4)
                    if badge > 0 {
                        Text(verbatim: "\(badge)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(active ? Native.accent : Native.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Native.overlay(active ? 0.08 : 0.05)))
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 9)
            .frame(height: 31)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [page.keyColor.opacity(0.16),
                                                      page.keyColor.opacity(0.05)],
                                             startPoint: .leading, endPoint: .trailing))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(page.keyColor.opacity(0.20), lineWidth: 0.8)
                        }
                        .matchedGeometryEffect(id: "nav.selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Native.overlay(0.05))
                }
            }
            .overlay(alignment: .leading) {
                if active {
                    Capsule()
                        .fill(page.keyColor)
                        .frame(width: 2.5, height: 15)
                        .padding(.leading, 1)
                        .shadow(color: page.keyColor.opacity(0.6), radius: 3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(page.rawValue)
        .onHover { value in
            guard !reduceMotion else { hovering = value; return }
            withAnimation(Motion.quick) { hovering = value }
        }
        .animation(Motion.quick, value: active)
    }
}

private struct SidebarRecentRow: View {
    let title: String
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(Native.tertiary.opacity(0.8))
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(active ? Native.label : Native.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Native.overlay(0.07)
                                 : (hovering ? Native.overlay(0.035) : Color.clear))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { value in
            withAnimation(Motion.quick) { hovering = value }
        }
    }
}


// MARK: - Window chrome

/// 拖拽空白处移动窗口：SwiftUI 的 hiddenTitleBar 窗口默认没有可拖区域。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// 标题栏：折叠边栏、当前引擎、外观与下载中心。对应 WebUI 的 titlebar 一行。
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
        HStack(spacing: 10) {
            Color.clear.frame(width: 66, height: 1)

            IconAction(systemName: "sidebar.left",
                       help: state.showsSidebar ? "折叠边栏（⌘\\）" : "展开边栏（⌘\\）",
                       active: false) {
                state.toggleSidebar()
            }

            engineControl

            Spacer(minLength: 8)

            Button(action: openCommand) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text("命令")
                        .font(.system(size: 11))
                    Text("⌘K")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Native.tertiary)
                }
                .foregroundStyle(Native.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Native.overlay(0.05)))
                .overlay(Capsule().strokeBorder(Native.hairline, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("命令面板（⌘K）")

            IconAction(systemName: state.theme.mode.resolvedIsDark ? "sun.max" : "moon",
                       help: "切换外观（⌘⇧A）") {
                state.theme.set(state.theme.mode.resolvedIsDark ? .light : .dark)
            }

            Button(action: openDownloads) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Native.label.opacity(0.82))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Native.overlay(0.07)))
                        .overlay(Circle().stroke(Native.hairline, lineWidth: 1))
                    if downloadCount > 0 {
                        Text(verbatim: "\(downloadCount)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Native.accent))
                            .offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("下载中心")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background {
            Rectangle()
                .fill(Native.surface.opacity(0.72))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Native.hairline.opacity(0.7)).frame(height: 1)
                }
                .background(WindowDragArea())
        }
    }

    private var engineControl: some View {
        Button {
            state.toggleService()
        } label: {
            HStack(spacing: 7) {
                if state.isRunning {
                    LiveDot(color: statusColor(state.serverState), diameter: 6)
                } else {
                    Circle()
                        .fill(statusColor(state.serverState))
                        .frame(width: 6, height: 6)
                        .padding(.horizontal, 3)
                }
                Text(state.activeEngine.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text(state.isRunning ? "运行中" : state.serverState == .starting ? "启动中" : "已停止")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                if state.isRunning {
                    Rectangle()
                        .fill(Native.hairline)
                        .frame(width: 1, height: 11)
                    Text("\(Format.compact(rate)) tok/s")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Native.accent)
                }
                if hoveringEngine {
                    Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(state.isRunning ? Native.red : Native.green)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Capsule().fill(Native.overlay(hoveringEngine ? 0.09 : 0.05)))
            .overlay(Capsule().strokeBorder(Native.hairline, lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { value in
            withAnimation(Motion.quick) { hoveringEngine = value }
        }
        .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
        .help(state.isRunning ? "停止引擎" : "启动引擎")
    }


}


/// 边栏右缘的拖拽手柄：宽度 180–320，落盘到 UserDefaults。
struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
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
