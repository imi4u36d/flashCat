import SwiftUI
import AppKit

struct ShellView: View {
    @ObservedObject var state: AppState

    private var showsSidebar: Bool { state.sidebarVisibility == .all }

    var body: some View {
        ZStack(alignment: .leading) {
            DetailView(state: state)
                .padding(.leading, showsSidebar ? Native.sidebarWidth : 0)

            SidebarView(state: state)
                .frame(width: Native.sidebarWidth)
                .offset(x: showsSidebar ? 0 : -Native.sidebarWidth)
                .allowsHitTesting(showsSidebar)
                .accessibilityHidden(!showsSidebar)
        }
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workspace
                    recents
                }
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
            Eyebrow(text: "工作区", color: .white.opacity(0.34))
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
                    Eyebrow(text: "最近对话", color: .white.opacity(0.34))
                    Spacer()
                    Text(verbatim: "\(state.threads.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
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

struct SidebarBackdrop: View {
    var body: some View {
        ZStack {
            Color(hex: 0x0B0B11)
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
                .fill(.white.opacity(0.07))
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
                        .foregroundStyle(.white.opacity(0.45))
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
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.58))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.13 : 0.07)))
                .overlay(Circle().stroke(.white.opacity(hovering ? 0.18 : 0.10), lineWidth: 0.8))
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
                    .foregroundStyle(selected ? Native.label : Color.white.opacity(hovering ? 0.86 : 0.62))

                Spacer(minLength: 4)

                if page == .models, !state.catalog.machine.isEmpty {
                    Text(verbatim: "\(state.catalog.machine.count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }

                if selected {
                    Circle()
                        .fill(Native.label)
                        .frame(width: 4, height: 4)
                        .shadow(color: .white.opacity(0.6), radius: 4)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.10)
                                   : Color.white.opacity(hovering ? 0.055 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.white.opacity(selected ? 0.10 : 0), lineWidth: 0.8)
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
                    .foregroundStyle(.white.opacity(hovering ? 0.5 : 0.28))
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.68))
                        .lineLimit(1)
                    Text(Format.relative(thread.updatedAt))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.30))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.05 : 0))
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

    private var memoryFraction: Double {
        guard let used = state.stats?.memoryBytes,
              let total = state.stats?.physicalMemoryBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    private var rate: Double { state.stats?.decodeTokensPerSecond ?? 0 }

    private var switching: Bool { state.isSwitchingModel }

    private var statusText: String {
        if switching { return "正在加载新模型" }
        return state.isRunning ? "引擎运行中" : state.startupStage
    }

    private var statusTint: Color {
        switching ? Native.orange : statusColor(state.serverState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                StatusDot(color: statusTint, diameter: 7, pulsing: state.isRunning || switching)
                Text(statusText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 4)

                if state.isRunning {
                    Button {
                        state.restartService()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.white.opacity(0.07)))
                            .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.8))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("重启引擎")
                    .accessibilityLabel("重启引擎")
                    .disabled(switching)
                    .opacity(switching ? 0.35 : 1)
                }

                Button(state.isRunning ? "停止" : "启动") {
                    state.toggleService()
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
                    .foregroundStyle(rate > 0 && !switching ? Native.label : Color.white.opacity(0.35))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("tok/s")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                Spacer(minLength: 4)
                if switching {
                    Tag(text: "加载中", tone: .warning)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if let stats = state.stats, stats.memoryPressure != "nominal" {
                    Tag(text: stats.memoryPressureText, tone: .warning)
                } else {
                    Tag(text: state.isReady ? "就绪" : "待机", tone: state.isReady ? .success : .neutral)
                }
            }

            if let downloading = state.downloadingModel {
                Meter(fraction: state.downloadFraction ?? 0, tint: Native.cyan)
                Text("下载 \(downloading.split(separator: "/").last.map(String.init) ?? downloading)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            } else {
                Meter(fraction: memoryFraction,
                      tint: memoryFraction > 0.9 ? Native.red : (memoryFraction > 0.75 ? Native.orange : Native.cyan))
                HStack {
                    Text(verbatim: "\(state.activeEngine.displayName.lowercased()) \(state.engineVersion) · \(state.port)")
                        .font(Native.monoSmall)
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let stats = state.stats, (stats.physicalMemoryBytes ?? 0) > 0 {
                        Text(verbatim: "\(Format.bytes(stats.memoryBytes ?? 0))")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                }
            }
        }
        .padding(13)
        .background {
            GlassSurface(radius: 18, tint: state.isRunning ? Native.mint : .clear, elevated: false)
        }
        .animation(.easeOut(duration: 0.18), value: switching)
    }
}

// MARK: - Detail

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
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(.white.opacity(0.08)))
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

    @ViewBuilder
    var body: some View {
        if state.sidebarVisibility != .all {
            HStack(spacing: 8) {
                Spacer(minLength: 0)

                glassButton(state.isRunning ? "stop.fill" : "play.fill",
                            help: state.isRunning ? "停止本地推理服务" : "启动本地推理服务",
                            tint: state.isRunning ? Native.red : Native.green) {
                    state.toggleService()
                }
                .disabled(state.runtimeMissing != nil)
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.top, 14)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func glassButton(_ symbol: String,
                             help: String,
                             tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.08)))
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
