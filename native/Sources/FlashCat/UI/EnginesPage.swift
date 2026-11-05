import SwiftUI
import AppKit
import FlashCatKit

/// 引擎页：按 WebUI 版式——顶部运行时统计，下面是整行引擎卡。
struct EnginesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter

    @State private var configuring: EngineID?
    @State private var pendingRemoval: EngineID?

    private var installedCount: Int {
        EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }.count
    }

    private var runningCount: Int {
        state.isRunning ? 1 : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(EngineCatalog.allIDs, id: \.self) { id in
                    engineRow(id)
                }
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, 78)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
            await installs.checkUpstream(force: false)
        }
        .sheet(item: $configuring) { id in
            EngineConfigSheet(state: state, engine: id)
        }
        .alert("删除 \(pendingRemoval?.displayName ?? "") 运行时？",
               isPresented: Binding(get: { pendingRemoval != nil },
                                    set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除", role: .destructive) {
                guard let id = pendingRemoval else { return }
                pendingRemoval = nil
                Task { @MainActor in
                    if await installs.removeRuntime(id) {
                        state.toast("\(id.displayName) 运行时已删除")
                    } else {
                        state.toast("\(id.displayName) 没有可删除的运行时")
                    }
                }
            }
            Button("取消", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("会删除 \(pendingRemoval.map(removableVersionsText) ?? "可删除的运行时")，模型与配置不受影响。")
        }
    }

    private func removableVersionsText(_ id: EngineID) -> String {
        let versions = EngineInstallations.removableVersions(id)
        guard !versions.isEmpty else { return "可删除的运行时" }
        return versions.sorted().joined(separator: "、")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("运行时")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Console.text)
            Circle()
                .fill(runningCount > 0 ? Console.ok : Console.tertiary)
                .frame(width: 6, height: 6)
            Text("\(runningCount) 运行中")
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
            Rectangle().fill(Console.cardStroke).frame(width: 1, height: 14)
            Text("\(installedCount) / \(EngineCatalog.allIDs.count) 已安装")
                .font(.system(size: 12))
                .foregroundStyle(Console.secondary)
            Spacer(minLength: 0)
            Button {
                Task { @MainActor in
                    installs.refreshInstalled()
                    await installs.loadIndexIfNeeded(force: true)
                    await installs.checkUpstream(force: true)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Console.card.opacity(0.75)))
                    .overlay(Circle().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("检查更新")
        }
    }

    private func engineRow(_ id: EngineID) -> some View {
        let installed = state.engineIsInstalled(id)
        let isActive = state.activeEngine == id
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle
        let busy = phase.isBusy || installs.building == id
        let accent = engineAccent(id)
        let port = EngineStore.shared.configuration(for: id).port ?? id.defaultPort

        return GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 18) {
                    LetterTile(letter: String(id.displayName.prefix(1)).uppercased(),
                               color: accent, size: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(id.displayName)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Console.text)
                            statusChip(installed: installed, active: isActive, busy: busy)
                        }
                        Text(verbatim: "v\(versions.last ?? "—")  ·  :\(port)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                        Text(id.descriptor.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(Console.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                        HStack(spacing: 6) {
                            ForEach(id.descriptor.capabilities.prefix(3), id: \.rawValue) { capability in
                                ConsoleTag(text: capability.displayName)
                            }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 16)

                    column("当前", value: currentText(id, installed: installed, isActive: isActive))
                    column("接口", value: installed ? "127.0.0.1:\(port)" : "端口 \(port)")
                    column("状态", value: statusText(installed: installed, busy: busy))
                }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if busy {
                        ProgressRing(fraction: installs.progress[id] ?? 0, tint: accent, size: 24, lineWidth: 3)
                        Text(installs.progressStep[id] ?? phase.label)
                            .font(.system(size: 11))
                            .foregroundStyle(Console.secondary)
                    } else if !installed {
                        Button {
                            install(id)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.consolePrimary)
                    } else if isActive {
                        Button {
                            state.toggleService()
                        } label: {
                            Label(state.isRunning ? "停止" : "启动",
                                  systemImage: state.isRunning ? "stop.fill" : "play.fill")
                        }
                        .buttonStyle(.consolePrimary)
                        .disabled(state.isSwitchingModel)
                    } else {
                        Button {
                            Task { @MainActor in await state.switchEngine(id) }
                        } label: {
                            Label("启动", systemImage: "play.fill")
                        }
                        .buttonStyle(.consolePrimary)
                        .disabled(state.isSwitchingModel || busy)
                    }

                    Button("配置") { configuring = id }
                        .buttonStyle(.consoleSecondary)
                        .disabled(versions.isEmpty)

                    Button {
                        pendingRemoval = id
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .buttonStyle(.consoleDanger)
                    .disabled(busy || versions.isEmpty || (isActive && state.isRunning))
                }
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, 22)
                    .padding(.leading, 2)
            }
        }
    }

    private func column(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Console.tertiary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Console.text)
                .lineLimit(1)
        }
        .frame(width: 112, alignment: .leading)
    }

    private func statusChip(installed: Bool, active: Bool, busy: Bool) -> some View {
        if busy {
            return StatusChip(text: "安装中", color: Console.warn, filled: true)
        }
        if !installed {
            return StatusChip(text: "未安装", color: Console.tertiary)
        }
        if active && state.isRunning {
            return StatusChip(text: "运行中", color: Console.ok, filled: true)
        }
        return StatusChip(text: "已停止", color: Console.tertiary)
    }

    private func currentText(_ id: EngineID, installed: Bool, isActive: Bool) -> String {
        guard installed else { return "等待安装" }
        if isActive, state.isRunning {
            return state.serverState == .ready ? "进程已就绪" : (state.startupStage.isEmpty ? "启动中" : state.startupStage)
        }
        return "进程未启动"
    }

    private func statusText(installed: Bool, busy: Bool) -> String {
        if busy { return "安装中" }
        guard installed else { return "未下载" }
        return "待机"
    }

    private func install(_ id: EngineID) {
        if let latest = installs.releases[id]?.max(by: { EngineVersionOrder.isNewer($1.version, than: $0.version) }) {
            installs.install(latest, for: id)
            return
        }
        if case .update(_, let release) = installs.upstream[id] {
            guard installs.building == nil else {
                state.toast("正在构建 \(installs.building?.displayName ?? "引擎")，完成后再试")
                return
            }
            _ = installs.buildAndInstall(release, for: id)
            return
        }
        state.toast("暂时没有 \(id.displayName) 的可用安装版本")
    }
}

// MARK: - Engine identity

func engineAccent(_ id: EngineID) -> Color {
    switch id {
    case .splash: return Color(console: 0xE0893F)
    case .omlx: return Color(console: 0x2F8C99)
    case .mtplx: return Color(console: 0x5B57C9)
    case .mlxServe: return Color(console: 0x2F7CF6)
    case .strata: return Color(console: 0x3FAE7A)
    default: return Console.accent
    }
}

func engineSymbol(_ id: EngineID) -> String {
    switch id {
    case .splash: return "bolt.fill"
    case .omlx: return "cpu"
    case .mtplx: return "square.stack.3d.up.fill"
    case .mlxServe: return "shippingbox.fill"
    case .strata: return "externaldrive.fill"
    default: return "cpu"
    }
}
