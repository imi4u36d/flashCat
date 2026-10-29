import SwiftUI
import AppKit

struct ShellView: View {
    @ObservedObject var state: AppState

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
    }

    private var showsSidebar: Bool { state.sidebarVisibility == .all }

    var body: some View {
        content
            // No `preferredColorScheme` here on purpose: it sets a window-level
            // override that SwiftUI keeps once applied, so going back to
            // “跟随系统” left the window dark until the next activation change.
            // `ThemeController` drives AppKit, and SwiftUI's `colorScheme`
            // follows the window's effective appearance from there.
            // Switching weights unloads the resident model first, so the engine
            // has nothing to serve until the new ones are up. That gap is not
            // obvious from the picker, so it is confirmed — once, per switch.
            .alert("切换模型？", isPresented: switchConfirmation) {
                Button("取消", role: .cancel) { state.cancelModelSwitchRequest() }
                Button("停止并切换") { state.confirmModelSwitch() }
            } message: {
                Text(switchConfirmationMessage)
            }
    }

    @ViewBuilder private var content: some View {
        if state.isPresentingLaunchPage {
            // Nothing is bundled any more, so the first run is the launch page:
            // the console has no engine to show until one is chosen.
            OnboardingView(state: state, installs: state.installs)
                .tint(Native.accent)
                .transition(.opacity)
                .overlay(alignment: .bottom) {
                    if let message = state.toastMessage {
                        ToastView(message: message)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .onTapGesture { state.dismissToast() }
                    }
                }
        } else {
            console
        }
    }

    private var switchConfirmation: Binding<Bool> {
        Binding(get: { state.confirmingModelSwitch != nil },
                set: { if !$0 { state.cancelModelSwitchRequest() } })
    }

    private var switchConfirmationMessage: String {
        let next = state.shortModelName(state.confirmingModelSwitch ?? "")
        let running = state.shortModelName(state.selectedModel)
        return "会先停止 \(running) 并卸载它的权重，再加载 \(next)。卸载到新模型就绪之间引擎无法应答；失败时会回滚到 \(running)。"
    }

    private var console: some View {
        ZStack(alignment: .leading) {
            DetailView(state: state)
                .padding(.leading, showsSidebar ? Native.sidebarWidth : Native.railWidth)

            SidebarView(state: state)
                .frame(width: Native.sidebarWidth)
                .offset(x: showsSidebar ? 0 : -Native.sidebarWidth)
                .allowsHitTesting(showsSidebar)
                .accessibilityHidden(!showsSidebar)

            // Collapsed rail: navigation never fully disappears — the pages
            // stay reachable as icons, with the engine status parked below.
            if !showsSidebar {
                SidebarRail(state: state)
                    .frame(width: Native.railWidth)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsSidebar)
        .background(Native.surface.ignoresSafeArea())
        .tint(Native.accent)
        // The toggle rides the sidebar's trailing edge: parked at the rail's
        // top-right while open, gliding left beside the traffic lights as the
        // rail collapses, on the same row as the window buttons.
        .overlay {
            GeometryReader { _ in
                SidebarTopToggle(state: state)
                    .position(x: showsSidebar ? Native.sidebarWidth - 30 : 84,
                              y: 14)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            if let message = state.toastMessage {
                ToastView(message: message)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture { state.dismissToast() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toastMessage)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(state: state)
                .padding(.horizontal, 14)
                .padding(.top, 42)
                .padding(.bottom, 16)

            // 工作区菜单固定，只有最近对话列表滚动：
            // 在历史里翻找时导航不会被顶走。
            workspace
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView {
                recents
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            EngineCard(state: state)
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
        }
        .background {
            // Let the sidebar art run all the way into the titlebar so the
            // traffic lights sit on the same surface as the rest of the rail.
            SidebarBackdrop()
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: "工作区", color: Native.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)

            ForEach(Page.allCases) { page in
                SidebarNavRow(page: page, state: state)
            }
        }
    }

    @ViewBuilder
    private var recents: some View {
        if !state.threads.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Eyebrow(text: "最近对话", color: Native.tertiary)
                    Spacer()
                    Text(verbatim: "\(state.threads.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Native.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                ForEach(state.threads) { thread in
                    RecentRow(thread: thread, state: state)
                }
            }
        }
    }
}

/// Narrow icon-only column shown while the rail is collapsed, so page
/// navigation survives without the full sidebar.
struct SidebarRail: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            // Clear the traffic-light row before the first icon.
            Color.clear.frame(height: 52)

            ForEach(Page.allCases) { page in
                RailIcon(page: page, state: state)
            }

            Spacer(minLength: 12)

            StatusDot(color: statusColor(state.serverState),
                      diameter: 8,
                      pulsing: state.isRunning || state.isSwitchingModel)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Native.overlay(0.06)))
                .help(state.isReady ? "引擎在线" : "引擎待机")
                .padding(.bottom, 14)
        }
        .background {
            SidebarBackdrop()
                .ignoresSafeArea(.container, edges: .top)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Native.overlay(0.07))
                        .frame(width: 1)
                }
        }
    }
}

struct RailIcon: View {
    let page: Page
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var selected: Bool { state.section == page }

    var body: some View {
        Button {
            state.section = page
        } label: {
            ArcadeIcon(symbol: page.symbol,
                       colors: page.iconColors,
                       size: 32,
                       glyphScale: 0.45,
                       glow: selected)
                .frame(width: 36, height: 36)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selected ? Native.overlay(0.12)
                                       : Native.overlay(hovering ? 0.06 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Native.overlay(selected ? 0.12 : 0), lineWidth: 0.8)
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(page.rawValue)
        .accessibilityLabel(page.rawValue)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SidebarBackdrop: View {
    var body: some View {
        ZStack {
            Native.sidebar
            LinearGradient(colors: [Native.accent.opacity(0.10), .clear],
                           startPoint: .topLeading,
                           endPoint: .center)
            LinearGradient(colors: [Native.violet.opacity(0.06), .clear],
                           startPoint: .bottomLeading,
                           endPoint: .center)
            GrainOverlay(opacity: 0.035)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Native.overlay(0.07))
                .frame(width: 1)
        }
    }
}

struct BrandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 11) {
            BrandMark(size: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 17, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Native.label)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor(state.serverState))
                        .frame(width: 5, height: 5)
                        .shadow(color: statusColor(state.serverState).opacity(0.8), radius: 3)
                    Text(state.isReady ? "本地引擎在线" : "本地推理控制台")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(Native.tertiary)
                }
            }

            Spacer(minLength: 2)
        }
    }
}

/// Hosted in an `NSTitlebarAccessoryViewController` by `AppDelegate`, so the
/// control sits on the traffic-light row even though the window draws its own
/// chrome. Its position is fixed while the rail animates — nothing jumps.
/// Floating on the traffic-light row, above both columns. `ShellView` animates
/// its x position between the rail's trailing edge and the window buttons, so
/// the control travels with the collapse instead of jumping between rows.
struct SidebarTopToggle: View {
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var expanded: Bool { state.sidebarVisibility == .all }

    var body: some View {
        Button {
            state.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Native.label.opacity(hovering ? 1 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Native.overlay(hovering ? 0.13 : 0.07)))
                .overlay(Circle().stroke(Native.overlay(hovering ? 0.18 : 0.10), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(expanded ? "收起边栏（⌘\\）" : "显示边栏（⌘\\）")
        .accessibilityLabel(expanded ? "收起边栏" : "显示边栏")
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct SidebarNavRow: View {
    let page: Page
    @ObservedObject var state: AppState
    @State private var hovering = false

    private var selected: Bool { state.section == page }

    var body: some View {
        Button {
            state.section = page
        } label: {
            HStack(spacing: 10) {
                ArcadeIcon(symbol: page.symbol,
                           colors: page.iconColors,
                           size: 26,
                           glyphScale: 0.45,
                           glow: selected)

                Text(page.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Native.label : Native.secondary.opacity(hovering ? 1 : 0.8))

                Spacer(minLength: 4)

                if page == .models, !state.catalog.machine.isEmpty {
                    Text(verbatim: "\(state.catalog.machine.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Native.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Native.overlay(0.08)))
                }

                if selected {
                    Circle()
                        .fill(Native.label)
                        .frame(width: 4, height: 4)
                        .shadow(color: Native.label.opacity(0.35), radius: 4)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? Native.overlay(0.10)
                                   : Native.overlay(hovering ? 0.055 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Native.overlay(selected ? 0.10 : 0), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct RecentRow: View {
    let thread: ChatThread
    @ObservedObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.openThread(thread)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Native.tertiary.opacity(hovering ? 1 : 0.72))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Native.label.opacity(hovering ? 1 : 0.8))
                        .lineLimit(1)
                    Text(Format.relative(thread.updatedAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Native.tertiary.opacity(0.85))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Native.overlay(hovering ? 0.05 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("删除对话", role: .destructive) { state.deleteThread(thread) }
        }
    }
}

struct EngineCard: View {
    @ObservedObject var state: AppState
    /// Collapsed to a one-line pill by default; hovering expands the full
    /// card. Stays open on its own while a download runs so the progress
    /// meter is never hidden underneath the pointer.
    @State private var expanded = false

    private var effectivelyExpanded: Bool {
        expanded || state.downloadingModel != nil
    }

    private var memoryFraction: Double {
        guard let used = state.stats?.memoryBytes,
              let total = state.stats?.physicalMemoryBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    private var rate: Double { state.stats?.decodeTokensPerSecond ?? 0 }

    private var switching: Bool { state.isSwitchingModel }

    private var statusText: String {
        if switching { return "正在加载新模型" }
        return state.isReady ? "引擎运行中" : state.startupStage
    }

    private var statusTint: Color {
        switching ? Native.orange : statusColor(state.serverState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if effectivelyExpanded {
                expandedContent
            } else {
                collapsedContent
            }
        }
        .padding(effectivelyExpanded ? 13 : 9)
        .background {
            GlassSurface(radius: 18,
                         tint: state.isRunning ? Native.mint : .clear,
                         elevated: false)
        }
        .animation(.easeOut(duration: 0.18), value: switching)
        .animation(.easeOut(duration: 0.2), value: effectivelyExpanded)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) { expanded = hovering }
        }
    }

    /// One-line idle pill: status dot, stage text, endpoint hint, and the
    /// service on/off controls so the engine stays reachable without hovering.
    private var collapsedContent: some View {
        HStack(spacing: 6) {
            StatusDot(color: statusTint, diameter: 6, pulsing: state.isRunning || switching)
            Text(statusText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Native.label.opacity(0.75))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: "\(state.activeEngine.displayName.lowercased()) \(state.port)")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary.opacity(0.8))
                .lineLimit(1)
            ServiceControlGroup(state: state)
        }
        .contentShape(Rectangle())
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                StatusDot(color: statusTint, diameter: 7, pulsing: state.isRunning || switching)
                Text(statusText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Native.label.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)

                if state.isRunning {
                    Button {
                        state.restartService()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Native.label.opacity(0.75))
                            .rotationEffect(.degrees(state.serverState == .starting ? 360 : 0))
                            .animation(state.serverState == .starting
                                       ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                       : .easeOut(duration: 0.2),
                                       value: state.serverState == .starting)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Native.overlay(0.07)))
                            .overlay(Circle().stroke(Native.overlay(0.10), lineWidth: 0.8))
                            .contentShape(Circle())
                    }
                    .buttonStyle(CircleIconButtonStyle())
                    .help("重启引擎")
                    .accessibilityLabel("重启引擎")
                    .disabled(switching)
                    .opacity(switching ? 0.35 : 1)
                }

                Button {
                    state.toggleService()
                } label: {
                    HStack(spacing: 4) {
                        if state.serverState == .starting || state.serverState == .stopping {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(height: 10)
                        } else {
                            Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(state.isRunning ? "停止" : "启动")
                    }
                    .animation(.easeOut(duration: 0.18), value: state.isRunning)
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                .disabled(state.runtimeMissing != nil || (switching && !state.isRunning))
            }

            ModelSwitcher(state: state, variant: .engine)

            if state.availableEngines.count > 1 {
                EngineSwitcherRow(state: state)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(switching ? "—" : (rate > 0 ? String(format: "%.1f", rate) : "—"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(rate > 0 && !switching ? Native.label : Native.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("tok/s")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 4)
                if switching {
                    Tag(text: "加载中", tone: .warning)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if let stats = state.stats, stats.memoryPressure != "nominal" {
                    Tag(text: stats.memoryPressureText, tone: .warning)
                } else if state.isReady {
                    Tag(text: "就绪", tone: .success)
                }
            }

            if let downloading = state.downloadingModel {
                Meter(fraction: state.downloadFraction ?? 0, tint: Native.cyan)
                Text("下载 \(downloading.split(separator: "/").last.map(String.init) ?? downloading)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            } else {
                Meter(fraction: memoryFraction,
                      tint: memoryFraction > 0.9 ? Native.red : (memoryFraction > 0.75 ? Native.orange : Native.cyan))
                HStack {
                    Text(verbatim: "\(state.activeEngine.displayName.lowercased()) \(state.engineVersion) · \(state.port)")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.tertiary.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let stats = state.stats, (stats.physicalMemoryBytes ?? 0) > 0 {
                        Text(verbatim: "\(Format.bytes(stats.memoryBytes ?? 0))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Native.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Service controls

/// 启动 / 停止（含重启）control group shared by the sidebar engine card and
/// the overview hero, so service control lives wherever the engine status is
/// read. `onHero` flips the palette to white-on-dark for the hero gradient.
struct ServiceControlGroup: View {
    @ObservedObject var state: AppState
    var onHero = false

    private var switching: Bool { state.isSwitchingModel }

    private var pending: Bool {
        state.serverState == .starting || state.serverState == .stopping
    }

    private var labelFill: Color {
        onHero ? Color.white.opacity(0.16) : Native.overlay(0.10)
    }

    private var labelStroke: Color {
        onHero ? Color.white.opacity(0.22) : Native.overlay(0.14)
    }

    private var labelText: Color {
        onHero ? Color.white.opacity(0.95) : Native.label.opacity(0.9)
    }

    var body: some View {
        HStack(spacing: 6) {
            if state.isRunning {
                Button {
                    state.restartService()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(labelText.opacity(0.8))
                        .rotationEffect(.degrees(state.serverState == .starting ? 360 : 0))
                        .animation(state.serverState == .starting
                                   ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                   : .easeOut(duration: 0.2),
                                   value: state.serverState == .starting)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(labelFill))
                        .overlay(Circle().stroke(labelStroke, lineWidth: 0.8))
                        .contentShape(Circle())
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("重启引擎")
                .accessibilityLabel("重启引擎")
                .disabled(switching)
                .opacity(switching ? 0.35 : 1)
                .transition(.opacity)
            }

            Button {
                state.toggleService()
            } label: {
                HStack(spacing: 4) {
                    if pending {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(height: 10)
                    } else {
                        Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(onHero
                                             ? Color.white.opacity(0.9)
                                             : (state.isRunning ? Native.red : Native.green).opacity(0.9))
                    }
                    Text(state.isRunning ? "停止" : "启动")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(labelText)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(labelFill))
                .overlay(Capsule().stroke(labelStroke, lineWidth: 0.8))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.18), value: state.isRunning)
            }
            .buttonStyle(.plain)
            .disabled(state.runtimeMissing != nil || (switching && !state.isRunning))
            .opacity(state.runtimeMissing != nil ? 0.35 : 1)
            .help(state.isRunning ? "停止本地推理服务" : "启动本地推理服务")
            .accessibilityLabel(state.isRunning ? "停止本地推理服务" : "启动本地推理服务")
        }
        .animation(.easeOut(duration: 0.18), value: state.isRunning)
    }
}

// MARK: - Detail

/// Circular icon button (重启 etc.): press feedback matches the pill buttons.
struct CircleIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && isEnabled ? 0.88 : 1)
            .opacity(!isEnabled ? 0.35 : (configuration.isPressed ? 0.75 : 1))
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct DetailView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let notice = state.notice {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Native.orange)
                    Text(notice)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        state.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Native.label.opacity(0.65))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Native.overlay(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Native.orange.opacity(0.10))
                .overlay(alignment: .bottom) { Hairline() }
            }

            Group {
                switch state.section {
                case .overview: OverviewView(state: state)
                case .chat: ChatView(state: state)
                case .models: ModelsView(state: state)
                case .engines: EnginesView(state: state, installs: state.installs)
                case .logs: LogsView(state: state)
                case .settings: SettingsView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            ArcadeBackdrop(colors: state.section.keyColors)
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .top) {
            DetailTopBar(state: state)
        }
    }
}

// MARK: - Floating detail chrome

/// Floating glass controls that only exist while the sidebar is collapsed —
/// with the sidebar visible, the engine card in it is the single place for
/// service control, so the detail pane stays free of duplicate chrome.
private struct DetailTopBar: View {
    @ObservedObject var state: AppState
    /// Collapsed: status dot + start/stop icon. Hovering slides out the status
    /// text and the labelled pill so the floating chrome stays minimal.
    @State private var hovering = false

    @ViewBuilder
    var body: some View {
        if state.sidebarVisibility != .all {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    StatusDot(color: statusColor(state.serverState),
                              diameter: 7,
                              pulsing: state.isRunning)

                    Button {
                        state.toggleService()
                    } label: {
                        HStack(spacing: 5) {
                            if state.serverState == .starting || state.serverState == .stopping {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(height: 10)
                            } else {
                                Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle((state.isRunning ? Native.red : Native.green).opacity(0.9))
                            }
                            if hovering {
                                Text(state.isRunning ? "停止" : "启动")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Native.label.opacity(0.9))
                                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                            }
                        }
                        .padding(.horizontal, hovering ? 12 : 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Native.overlay(hovering ? 0.12 : 0.08)))
                        .overlay(Capsule().stroke(Native.overlay(0.12), lineWidth: 0.8))
                        .contentShape(Capsule())
                        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: hovering)
                    }
                    .buttonStyle(.plain)
                    .disabled(state.runtimeMissing != nil)
                    .help(state.isRunning ? "停止本地推理服务" : "启动本地推理服务")
                    .accessibilityLabel(state.isRunning ? "停止本地推理服务" : "启动本地推理服务")
                }
                .onHover { hovering = $0 }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.top, 14)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
