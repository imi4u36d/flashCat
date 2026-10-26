import SwiftUI
import AppKit

struct ShellView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $state.sidebarVisibility) {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 210, ideal: Native.sidebarWidth, max: 300)
        } detail: {
            DetailView(state: state)
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .bottom) {
            if let message = state.toastMessage {
                ToastView(message: message)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .onTapGesture { state.dismissToast() }
            }
        }
        .animation(.easeOut(duration: 0.16), value: state.toastMessage)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader(state: state)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            List(selection: $state.section) {
                Section("工作区") {
                    ForEach(Page.allCases) { page in
                        SidebarRow(page: page, state: state)
                            .tag(page)
                    }
                }

                if !state.threads.isEmpty {
                    Section("最近对话") {
                        ForEach(state.threads) { thread in
                            RecentRow(thread: thread, state: state)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            EngineCard(state: state)
                .padding(10)
        }
        .background(.thinMaterial)
    }
}

struct BrandHeader: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Native.accent.opacity(0.14))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Native.accent)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text("flashCat")
                    .font(.system(size: 13, weight: .semibold))
                Text("本地推理控制台")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                state.toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Native.tertiary)
            .help("折叠侧边栏（⌘\\）")
        }
    }
}

struct SidebarRow: View {
    let page: Page
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Label(page.rawValue, systemImage: page.symbol)
                .labelStyle(.titleAndIcon)
                .font(Native.bodyFont)
            Spacer(minLength: 4)
            if page == .models, !state.catalog.machine.isEmpty {
                Text(verbatim: "\(state.catalog.machine.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Native.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecentRow: View {
    let thread: ChatThread
    @ObservedObject var state: AppState

    var body: some View {
        Button {
            state.openThread(thread)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(thread.title)
                    .font(Native.bodyFont)
                    .lineLimit(1)
                Text(Format.relative(thread.updatedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(color: statusColor(state.serverState))
                Text(state.startupStage)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                if let rate = state.stats?.decodeTokensPerSecond, rate > 0, state.isReady {
                    Text(verbatim: "\(Format.compact(rate)) tok/s")
                        .font(Native.monoSmall)
                        .foregroundStyle(Native.secondary)
                }
                Button(state.isRunning ? "停止" : "启动") {
                    state.toggleService()
                }
                .controlSize(.mini)
                .disabled(state.runtimeMissing != nil)
            }

            Text(state.selectedModel.isEmpty ? "未选择模型" : state.selectedModel)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(state.selectedModel)

            Text(verbatim: "splash \(state.runtimeVersion) · 端口 \(state.port)")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)

            if let downloading = state.downloadingModel {
                Meter(fraction: state.downloadFraction ?? 0, tint: Native.accent)
                Text("下载 \(downloading.split(separator: "/").last.map(String.init) ?? downloading)")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            } else if state.isRunning {
                Meter(fraction: memoryFraction,
                      tint: memoryFraction > 0.9 ? Native.red : (memoryFraction > 0.75 ? Native.orange : Native.teal))
                if let stats = state.stats, (stats.physicalMemoryBytes ?? 0) > 0 {
                    Text(verbatim: "内存 \(Format.bytes(stats.memoryBytes ?? 0)) / \(Format.bytes(stats.physicalMemoryBytes ?? 0))")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Native.panel.opacity(0.65),
                    in: RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous)
                .stroke(Native.hairline.opacity(0.8), lineWidth: 1)
        )
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let notice = state.notice {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.orange)
                    Text(notice)
                        .font(Native.bodyFont)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        state.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Native.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Native.orange.opacity(0.08))
                Hairline()
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.toggleService()
                } label: {
                    Label(state.isRunning ? "停止服务" : "启动服务",
                          systemImage: state.isRunning ? "stop.circle" : "play.circle")
                }
                .help(state.isRunning ? "停止本地推理服务" : "启动本地推理服务")
                .disabled(state.runtimeMissing != nil)
            }

            ToolbarItem(placement: .primaryAction) {
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
                    Label("模型", systemImage: "shippingbox")
                }
                .help("切换当前模型")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.reloadModels()
                } label: {
                    Label("刷新模型", systemImage: "arrow.clockwise")
                }
                .help("重新扫描模型目录")
            }
        }
    }
}
