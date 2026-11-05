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

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                if state.showsSidebar {
                    ConsoleSidebar(state: state, collapsed: false)
                        .frame(width: 216)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    ConsoleSidebar(state: state, collapsed: true)
                        .frame(width: 76)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(Native.surface)
            }
            .animation(.easeInOut(duration: 0.22), value: state.showsSidebar)
        }
        .background(Native.surface.ignoresSafeArea())
        .tint(Native.accent)
        .overlay(alignment: .bottom) {
            if let message = state.toastMessage {
                ToastView(message: message)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture { state.dismissToast() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.toastMessage)
        .overlay {
            if state.isPresentingLaunchPage || state.showsRecommendationPage {
                LaunchPage(state: state)
                    .transition(.opacity)
            }
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

    @ViewBuilder private var pageContent: some View {
        switch state.section {
        case .overview: OverviewPage(state: state)
        case .chat: ChatPage(state: state)
        case .models: ModelsPage(state: state, engine: state.libraryEngine)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, collapsed ? 12 : 14)
                .padding(.top, 42)
                .padding(.bottom, 14)

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
                    .padding(.top, 14)
            }

            Spacer(minLength: 12)

            engineCard
                .padding(.horizontal, collapsed ? 8 : 12)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Native.sidebar.ignoresSafeArea())
    }

    private var brand: some View {
        HStack(spacing: 9) {
            BrandMark(size: collapsed ? 30 : 34)
            if !collapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("flashCat")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Native.label)
                    Text("本地推理控制台")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
            }
            Spacer(minLength: 0)
            if !collapsed {
                IconAction(systemName: "sidebar.left", help: "收起边栏（⌘\\）") {
                    state.toggleSidebar()
                }
            }
        }
        .overlay(alignment: .leading) {
            if collapsed {
                EmptyView()
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 2) {
            if !collapsed {
                Eyebrow(text: "工作区")
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            ForEach(Page.allCases) { page in
                navRow(page)
            }
        }
    }

    private func navRow(_ page: Page) -> some View {
        let active = state.section == page
        return Button {
            state.section = page
        } label: {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Native.accent : Native.secondary)
                    .frame(width: 18)
                if !collapsed {
                    Text(page.rawValue)
                        .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Native.label : Native.secondary)
                    Spacer(minLength: 4)
                    if page == .models, modelCount > 0 {
                        Text(verbatim: "\(modelCount)")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Native.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Native.overlay(0.06)))
                    }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 8)
            .frame(height: 30)
            .frame(maxWidth: collapsed ? .infinity : .infinity, alignment: collapsed ? .center : .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? Native.overlay(0.08) : Color.clear)
            }
            .overlay(alignment: .leading) {
                if active {
                    Capsule()
                        .fill(Native.accent)
                        .frame(width: 2.5, height: 14)
                        .padding(.leading, 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(page.rawValue)
    }

    private var modelCount: Int {
        EngineCatalog.allIDs.reduce(0) { total, id in
            total + state.libraryEntries(for: id).filter(\.installed).count
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: "最近对话")
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(state.threads.prefix(6)) { thread in
                Button {
                    state.openThread(thread)
                    state.section = .chat
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(Native.tertiary.opacity(0.8))
                        Text(thread.title)
                            .font(.system(size: 11.5))
                            .foregroundStyle(state.currentThreadID == thread.id ? Native.label : Native.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.currentThreadID == thread.id ? Native.overlay(0.06) : .clear)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(thread.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor(state.serverState),
                          diameter: 7,
                          pulsing: state.isRunning)
                if !collapsed {
                    Text(state.activeEngine.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(state.isRunning ? "运行中" : state.serverState == .starting ? "启动中" : "已停止")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
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
        .padding(collapsed ? 8 : 10)
        .background {
            RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                .fill(Native.canvas)
                .overlay {
                    RoundedRectangle(cornerRadius: Native.radiusTile, style: .continuous)
                        .strokeBorder(Native.hairline, lineWidth: 1)
                }
        }
    }
}
