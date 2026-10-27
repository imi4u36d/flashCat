import SwiftUI
import AppKit
import FlashCatKit

/// The launch page. No engine ships inside the app any more, so the first run
/// has to pick one: choosing here downloads the pack, installs it, and hands the
/// window over to the console.
struct OnboardingView: View {
    @ObservedObject var state: AppState
    /// Observed directly: the index and install phases land asynchronously, and
    /// reaching them through `state.installs` would not invalidate this view.
    @ObservedObject var installs: EngineInstallCenter
    @State private var selected: [EngineID: String] = [:]

    var body: some View {
        ZStack {
            ArcadeBackdrop(colors: [Native.cyan, Native.mint])
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    brand
                    intro
                    ForEach(EngineID.allCases, id: \.self) { id in
                        row(id)
                    }
                    footer
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 44)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.never)
        }
        .task {
            installs.onInstalled = { id in
                // Installed from the launch page: make it the engine we run, then
                // the console replaces this page.
                state.adoptEngine(id)
            }
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
        }
        .onDisappear { installs.onInstalled = nil }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Native.label)
                Text("本地推理控制台")
                    .font(.system(size: 11))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 0)
            if !state.needsEngineSetup {
                Button {
                    state.showsLaunchPage = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Native.tertiary)
                .accessibilityLabel("关闭启动页")
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择你的推理引擎")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Native.label)
            Text("引擎不再随应用打包，也不再有隐含的默认项。选一个下载安装，它就是你的默认引擎；之后可以随时从引擎页回到这里添加或切换到别的引擎。")
                .font(.system(size: 12.5))
                .foregroundStyle(Native.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ id: EngineID) -> some View {
        let installedVersions = installs.installed[id] ?? []
        let releases = (installs.releases[id] ?? []).filter { !installedVersions.contains($0.version) }
        let phase = installs.phases[id] ?? .idle
        let chosen = selected[id] ?? releases.first?.version
        let release = releases.first { $0.version == chosen }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(id.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Native.label)
                        ForEach(capabilityTags(id), id: \.self) { tag in
                            Tag(text: tag, tone: .neutral)
                        }
                    }
                    Text(blurb(id))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    if releases.count > 1 {
                        Picker("", selection: Binding(
                            get: { chosen ?? "" },
                            set: { selected[id] = $0 }
                        )) {
                            ForEach(releases, id: \.version) { item in
                                Text(item.version).tag(item.version)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 96)
                    }
                    if let release {
                        Button(phase.isBusy ? "安装中…" : "安装并开始使用") {
                            installs.install(release, for: id)
                        }
                        .buttonStyle(ArcadePillStyle(tone: .accent, compact: false))
                        .disabled(phase.isBusy)
                    } else if !installedVersions.isEmpty {
                        // Already on disk (built locally, or installed from an
                        // earlier visit): offer it as the engine instead of a
                        // download button that would do nothing.
                        if state.activeEngine == id && !state.needsEngineSetup {
                            Tag(text: "当前引擎", tone: .accent)
                        } else {
                            Button("使用 \(installedVersions.first ?? "")") {
                                state.adoptEngine(id)
                            }
                            .buttonStyle(ArcadePillStyle(tone: .glass, compact: false))
                        }
                    } else {
                        Tag(text: "暂无可用版本", tone: .neutral)
                    }
                }
            }

            if phase.isBusy {
                Meter(fraction: phase.fraction ?? 0, tint: Native.cyan)
            }
            if phase != .idle {
                Text(phase.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(phase.isFailure ? Native.red.opacity(0.9) : Native.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .background {
            GlassSurface(radius: 18, tint: .clear, elevated: false)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = installs.indexError {
                Text("无法读取发布索引：\(error)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.orange.opacity(0.9))
            }
            Text("安装包来自发布索引（`FLASHCAT_PACK_INDEX_URL`，或应用内置的 pack-index.json）。已在本机构建好的运行时包也会直接被识别：把它们放进 `~/Library/Application Support/flashCat/engines/<引擎>/<版本>` 即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func capabilityTags(_ id: EngineID) -> [String] {
        id.capabilities
            .filter { [.mtp, .draft, .multiModel, .hotLoad, .vision].contains($0) }
            .map(\.displayName)
    }

    private func blurb(_ id: EngineID) -> String {
        switch id {
        case .splash:
            return "Apple Silicon 上的自管运行时，专注单模型：DFlash2 投机解码、KV 缓存与视觉多模态都在同一个包里。下载约 250 MB。"
        case .omlx:
            return "多模型热切换：常驻多个模型，按请求路由，MTP / DFlash2 按模型开关。"
        case .mtplx:
            return "以 MTP 投机解码为主的引擎，量化与草稿参数通过命令行开关控制。"
        }
    }
}

private extension EngineInstallPhase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
