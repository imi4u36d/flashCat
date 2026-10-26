import SwiftUI
import AppKit

struct ShellView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 222, ideal: Native.sidebarWidth, max: 300)
        } detail: {
            DetailView(state: state)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .background(Native.surface)
        .tint(Native.accent)
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
        .background(SidebarBackdrop())
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
            ArcadeIcon(symbol: "cat.fill",
                       colors: [Native.accent, Native.pink, Native.violet],
                       size: 38,
                       glyphScale: 0.5)

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

            Button {
                state.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.07)))
                    .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("折叠侧边栏（⌘\\）")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor(state.serverState), diameter: 7, pulsing: state.isRunning)
                Text(state.isRunning ? "引擎运行中" : state.startupStage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 4)
                Button(state.isRunning ? "停止" : "启动") {
                    state.toggleService()
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                .disabled(state.runtimeMissing != nil)
            }

            Text(state.selectedModel.isEmpty ? "未选择模型" : state.selectedModel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Native.label)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(state.selectedModel)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rate > 0 ? String(format: "%.1f", rate) : "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(rate > 0 ? Native.label : Color.white.opacity(0.35))
                    .monospacedDigit()
                Text("tok/s")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
                Spacer(minLength: 4)
                if let stats = state.stats, stats.memoryPressure != "nominal" {
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
                    Text(verbatim: "splash \(state.runtimeVersion) · \(state.port)")
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
                case .logs: LogsView(state: state)
                case .settings: SettingsView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background { ArcadeBackdrop(colors: state.section.keyColors) }
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.18), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            DetailTopBar(state: state)
        }
    }
}

// MARK: - Floating detail chrome

/// Floating glass controls in the top-right corner, mirroring the profile /
/// search cluster of the Games app.
private struct DetailTopBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            if state.sidebarVisibility != .all {
                glassButton("sidebar.left", help: "显示边栏") {
                    state.toggleSidebar()
                }
            }

            Spacer(minLength: 0)

            glassButton(state.isRunning ? "stop.fill" : "play.fill",
                        help: state.isRunning ? "停止本地推理服务" : "启动本地推理服务",
                        tint: state.isRunning ? Native.red : Native.green) {
                state.toggleService()
            }
            .disabled(state.runtimeMissing != nil)

            Menu {
                if state.catalog.machine.isEmpty {
                    Text("没有本地模型")
                }
                ForEach(state.catalog.machine, id: \.id) { model in
                    Button {
                        state.applyModel(model.id)
                    } label: {
                        if model.id == state.selectedModel {
                            Label(model.id, systemImage: "checkmark")
                        } else {
                            Text(model.id)
                        }
                    }
                }
                if !state.catalog.missingRecommendations.isEmpty {
                    Divider()
                    Menu("下载推荐模型") {
                        ForEach(state.catalog.missingRecommendations, id: \.self) { model in
                            Button(model) { state.downloadModel(model) }
                        }
                    }
                }
                Divider()
                Button("管理模型…") { state.section = .models }
            } label: {
                Image(systemName: "shippingbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换当前模型")
            .accessibilityLabel("切换当前模型")

            glassButton("arrow.clockwise", help: "重新扫描模型目录") {
                state.reloadModels()
            }
        }
        .padding(.leading, state.sidebarVisibility == .all ? 18 : 92)
        .padding(.trailing, 18)
        .padding(.top, 14)
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
