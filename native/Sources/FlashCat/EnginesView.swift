import SwiftUI
import AppKit
import FlashCatKit

/// Drives pack installs for the engine page: loads the release index once, then
/// runs one install at a time (they write into the same folder tree).
@MainActor
final class EngineInstallCenter: ObservableObject {
    @Published private(set) var releases: [EngineID: [EnginePackRelease]] = [:]
    @Published private(set) var phases: [EngineID: EngineInstallPhase] = [:]
    @Published private(set) var installed: [EngineID: [String]] = [:]
    @Published private(set) var indexError: String?
    @Published private(set) var indexLoaded = false

    private var installer: EngineInstaller?
    private var onChange: (() -> Void)?

    func configure(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let environment = EngineInstallEnvironment(
            packsDirectory: EnginePaths.enginesDirectory,
            indexURL: ProcessInfo.processInfo.environment["FLASHCAT_PACK_INDEX_URL"]
                .flatMap { $0.isEmpty ? nil : URL(string: $0) },
            bundledIndexPath: Bundle.main.url(forResource: "pack-index", withExtension: "json")?.path)
        installer = EngineInstaller(environment: environment)
    }

    func refreshInstalled() {
        var result: [EngineID: [String]] = [:]
        for id in EngineID.allCases where id != .splash {
            result[id] = EngineInstallations.installed(id).map(\.version)
        }
        installed = result
    }

    func loadIndexIfNeeded() async {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let installer else { return }
        do {
            let index = try await installer.loadIndex()
            var result: [EngineID: [EnginePackRelease]] = [:]
            for id in EngineID.allCases where id != .splash {
                result[id] = index.releases(for: id)
            }
            releases = result
            indexError = nil
        } catch {
            indexError = error.localizedDescription
        }
    }

    func install(_ release: EnginePackRelease, for id: EngineID) {
        guard phases[id]?.isBusy != true, let installer else { return }
        phases[id] = .resolving
        Task { [weak self] in
            do {
                _ = try await installer.install(release, for: id) { phase in
                    Task { @MainActor in self?.phases[id] = phase }
                }
                await MainActor.run {
                    self?.phases[id] = .installed(version: release.version)
                    self?.refreshInstalled()
                    self?.onChange?()
                }
            } catch {
                await MainActor.run {
                    self?.phases[id] = .failed(message: error.localizedDescription)
                }
            }
        }
    }

    func uninstall(_ id: EngineID, version: String) {
        guard let installer else { return }
        Task {
            try? await installer.uninstall(id, version: version)
            await MainActor.run {
                self.refreshInstalled()
                self.onChange?()
            }
        }
    }
}

// MARK: - Page

struct EnginesView: View {
    @ObservedObject var state: AppState
    @ObservedObject var installs: EngineInstallCenter

    var body: some View {
        GeometryReader { proxy in
            let usable = max(320, min(proxy.size.width, Native.contentMaxWidth) - Native.pagePadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PageHeader(title: "引擎",
                               subtitle: "同一时刻只运行一个推理引擎；每个引擎使用自己的端口与模型目录。",
                               eyebrow: "RUNTIME PACKS")
                        .padding(.bottom, 4)

                    ForEach(EngineID.allCases.filter { $0 != .splash }, id: \.self) { id in
                        card(id, width: usable)
                    }

                    footer
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.top, 30)
                .padding(.bottom, Native.pagePadding)
                .frame(maxWidth: Native.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .task {
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
        }
    }

    private func card(_ id: EngineID, width: CGFloat) -> some View {
        let isActive = state.activeEngine == id
        let versions = installs.installed[id] ?? []
        let phase = installs.phases[id] ?? .idle
        let available = (installs.releases[id] ?? []).filter { !versions.contains($0.version) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isActive ? statusColor(state.serverState) : Color.white.opacity(0.18))
                    .frame(width: 7, height: 7)
                Text(id.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Native.label)
                if isActive {
                    Tag(text: "当前引擎", tone: .success)
                }
                Text(verbatim: "端口 \(String(enginePort(id)))")
                    .font(Native.monoSmall)
                    .foregroundStyle(.white.opacity(0.34))
                Spacer(minLength: 6)
                if versions.isEmpty {
                    Tag(text: "未安装", tone: .neutral)
                } else {
                    Text(verbatim: "已装 \(versions.joined(separator: ", "))")
                        .font(Native.monoSmall)
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                if !isActive {
                    Button("设为当前") { state.switchEngine(id) }
                        .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                        .disabled(versions.isEmpty)
                }
            }

            portField(id)

            if phase.isBusy {
                Meter(fraction: phase.fraction ?? 0, tint: Native.cyan)
            }
            if phase != .idle {
                Text(phase.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(phase.isFailure ? Native.red.opacity(0.9) : .white.opacity(0.5))
                    .lineLimit(2)
            }

            if versions.contains(where: { $0 != version(id) }) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "已安装版本", color: .white.opacity(0.3))
                    ForEach(versions, id: \.self) { installedVersion in
                        HStack(spacing: 8) {
                            Text(installedVersion)
                                .font(Native.monoSmall)
                                .foregroundStyle(.white.opacity(0.62))
                            if installedVersion == version(id) {
                                Tag(text: "使用中", tone: .success)
                            }
                            Spacer(minLength: 4)
                            Button("删除") { installs.uninstall(id, version: installedVersion) }
                                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                                .disabled(isActive && state.isRunning)
                        }
                    }
                }
            }

            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "可安装", color: .white.opacity(0.3))
                    ForEach(available, id: \.version) { release in
                        HStack(spacing: 8) {
                            Text(release.version)
                                .font(Native.monoSmall)
                                .foregroundStyle(.white.opacity(0.62))
                            if let bytes = release.bytes {
                                Text(verbatim: Format.bytes(bytes))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.34))
                            }
                            if let notes = release.notes, !notes.isEmpty {
                                Text(notes)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.34))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button("安装") { installs.install(release, for: id) }
                                .buttonStyle(ArcadePillStyle(tone: .accent, compact: true))
                                .disabled(phase.isBusy)
                        }
                    }
                }
            } else if versions.isEmpty {
                Text(installs.indexError.map { "没有可安装的版本：\($0)" }
                     ?? "没有可安装的版本。用 scripts/engines/build-\(id.rawValue)-pack.sh 在本机构建，或配置 FLASHCAT_PACK_INDEX_URL。")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }

            HStack(spacing: 8) {
                Button("打开目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.enginesDirectory))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Button("查看日志") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.logFile(id)))
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: width, alignment: .leading)
        .background {
            GlassSurface(radius: 18, tint: isActive ? Native.mint : .clear, elevated: false)
        }
    }

    /// Editable port. Kept as a text field so the reader can type any free port;
    /// the value only lands in the store when it parses.
    private func portField(_ id: EngineID) -> some View {
        HStack(spacing: 8) {
            Text("端口")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.42))
            TextField("", text: portBinding(id))
                .textFieldStyle(.plain)
                .font(Native.monoSmall)
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 70)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white.opacity(0.06))
                }
                .disabled(state.activeEngine == id && state.isRunning)
            Text(verbatim: state.activeEngine == id && state.isRunning
                 ? "运行中不能改端口"
                 : "默认 \(id.defaultPort)，可顺延 \(id.portRange.count) 个")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.28))
            Spacer(minLength: 0)
        }
    }

    private func portBinding(_ id: EngineID) -> Binding<String> {
        Binding(
            get: { String(enginePort(id)) },
            set: { text in
                guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
                    return
                }
                EngineStore.shared.update(id) { $0.port = value }
                state.switchEnginePort(id, port: value)
            }
        )
    }

    private func enginePort(_ id: EngineID) -> Int {
        EngineStore.shared.configuration(for: id).port ?? id.defaultPort
    }

    private func version(_ id: EngineID) -> String? {
        state.engines?.controller(id)?.installation?.version
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "说明", color: .white.opacity(0.3))
            Text("运行时包是自管的 Python + 引擎依赖，和 Homebrew / 系统里已装的应用互不影响。安装走 SHA256 校验、解包到 .staging、验证 manifest 后才激活，失败不会动已装版本。模型不在这里下载：模型页显示的是你本机已有权重建立的符号链接。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

private extension EngineInstallPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
