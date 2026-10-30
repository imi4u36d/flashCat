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
                    startBar
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
            if let summary = installedSummary {
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Native.mint)
            } else if installs.indexLoaded {
                Text("尚未检测到已安装的引擎，选择下面任意一个下载安装即可。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.tertiary)
            }
        }
    }

    /// One line under the intro naming what the on-disk scan found, so the
    /// reader sees the check result instead of guessing from the buttons.
    private var installedSummary: String? {
        let entries: [String] = EngineID.allCases.compactMap { id in
            guard let version = newestInstalledVersion(id) else { return nil }
            return "\(id.displayName) v\(version)"
        }
        guard !entries.isEmpty else { return nil }
        return "检测到本机已安装：" + entries.joined(separator: " · ")
    }

    /// 已安装版本里最新的一个（扫描结果可能同时存在多个版本）。
    private func newestInstalledVersion(_ id: EngineID) -> String? {
        (installs.installed[id] ?? []).max { EngineVersionOrder.isNewer($1, than: $0) }
    }

    /// 只展示最新版本：一行只回答"最新是哪个、装没装、要不要装"。
    /// 最新版已在本机时安装按钮不可点，换用"已安装"状态提示。
    private func row(_ id: EngineID) -> some View {
        let installedVersions = installs.installed[id] ?? []
        let indexLatest = (installs.releases[id] ?? []).max {
            EngineVersionOrder.isNewer($1.version, than: $0.version)
        }
        let phase = installs.phases[id] ?? .idle
        let newestInstalled = newestInstalledVersion(id)
        // 本机构建的版本可能比发布索引还新："最新"取两者中较高的一个，
        // 否则装着 0.7.3rc1 还提示安装索引里的 0.7.2，看起来像在让用户降级。
        let latestVersion = [indexLatest?.version, newestInstalled]
            .compactMap { $0 }
            .max { EngineVersionOrder.isNewer($1, than: $0) }
        let latestInstalled = latestVersion.map { installedVersions.contains($0) } ?? false
        // 只有索引里真有这个版本时才能装；本机更新时按钮只做"已安装"占位。
        let latestRelease: EnginePackRelease? = indexLatest?.version == latestVersion ? indexLatest : nil

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
                        // What the on-disk scan found for this engine, right
                        // next to the name so the state is readable at a glance.
                        if let newestInstalled {
                            if state.activeEngine == id && !state.needsEngineSetup {
                                Tag(text: "当前引擎", tone: .accent)
                            } else {
                                Tag(text: "已安装 v\(newestInstalled)", tone: .neutral)
                            }
                        }
                    }
                    Text(blurb(id))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    if let latestVersion {
                        HStack(spacing: 5) {
                            Text(verbatim: "最新 v\(latestVersion)")
                                .font(Native.monoSmall)
                                .foregroundStyle(latestInstalled ? Native.tertiary : Native.secondary)
                            if let bytes = latestRelease?.bytes {
                                Text(verbatim: Format.bytes(bytes))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Native.tertiary)
                            }
                        }
                        // 最新版已装好时按钮禁用：只有一个版本可装，没有再点的意义。
                        // 本机版本比索引还新时同样只显示状态，不提供安装入口。
                        if let latestRelease {
                            Button(rowButtonLabel(phase, id: id, latestInstalled: latestInstalled)) {
                                installs.install(latestRelease, for: id)
                            }
                            .buttonStyle(ArcadePillStyle(tone: latestInstalled ? .glass : .accent, compact: false))
                            .disabled(phase.isBusy || latestInstalled)
                        } else {
                            Button("已安装") {}
                                .buttonStyle(ArcadePillStyle(tone: .glass, compact: false))
                                .disabled(true)
                        }
                    }
                    if latestVersion == nil && installedVersions.isEmpty {
                        Tag(text: "暂无可用版本", tone: .neutral)
                    }
                }
            }

            // 与引擎页同一套进度表达：环形百分比 + 当前步骤，运行中不再有第二行状态文字。
            if phase.isBusy, let fraction = installs.progress[id] {
                HStack(spacing: 9) {
                    ProgressRing(fraction: fraction, tint: Native.cyan, size: 30, lineWidth: 3.5)
                    Text(verbatim: installs.progressStep[id] ?? "准备安装")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Native.secondary)
                    Spacer(minLength: 0)
                }
            } else if phase != .idle {
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
            Text("安装包来自发布索引（`FLASHCAT_PACK_INDEX_URL`，或应用内置的 pack-index.json）。已在本机构建好的安装包也会直接被识别：把它们放进 `~/Library/Application Support/flashCat/engines/<引擎>/<版本>` 即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Replaces the old corner ✕: leaving the launch page is an explicit action
    /// at the end of the flow, and only once an engine exists to run.
    private var startBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                state.showsLaunchPage = false
            } label: {
                Text("开始使用")
            }
            .buttonStyle(ArcadePillStyle(tone: .accent, compact: false))
            .disabled(state.needsEngineSetup)
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func capabilityTags(_ id: EngineID) -> [String] {
        id.capabilities
            .filter { [.mtp, .draft, .multiModel, .hotLoad, .vision].contains($0) }
            .map(\.displayName)
    }

    /// Percent-only label while this engine installs, plain 安装/已安装 otherwise.
    private func rowButtonLabel(_ phase: EngineInstallPhase, id: EngineID, latestInstalled: Bool) -> String {
        if phase.isBusy, let fraction = installs.progress[id] {
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            return "\(percent)%"
        }
        return latestInstalled ? "已安装" : "安装"
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
