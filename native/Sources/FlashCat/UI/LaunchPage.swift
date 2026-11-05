import SwiftUI
import AppKit
import FlashCatKit

/// 首次启动页：先推荐这台 Mac 该跑哪台引擎 + 哪档模型，再让用户一键装好。
///
/// 两条路径共用一页：硬件推荐（`showsRecommendationPage`）与引擎安装
/// （没有可用运行时时）。安装完成由 `adoptEngine` 接管，页面自动让位给控制台。
struct LaunchPage: View {
    @ObservedObject var state: AppState

    @State private var busy: EngineID?

    private var installs: EngineInstallCenter { state.installs }
    private var recommendation: HardwareRecommendation? { state.hardwareRecommendation }
    private var isRecommendation: Bool { state.showsRecommendationPage }

    var body: some View {
        ZStack {
            Native.surface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brand
                    intro
                    if isRecommendation, let recommendation {
                        machineCard(recommendation)
                        picks(recommendation)
                    } else {
                        engineList
                    }
                    footer
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 46)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.never)
        }
        .task {
            installs.onInstalled = { id in
                state.adoptEngine(id)
            }
            installs.refreshInstalled()
            await installs.loadIndexIfNeeded()
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 18, weight: .semibold))
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
            Text(isRecommendation ? "先装一台引擎" : "选择一台引擎")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Native.label)
            Text(isRecommendation
                 ? "引擎运行时按 pack 分发，第一次打开需要下载（80 MB ~ 600 MB）。装好后控制台会自动接管。"
                 : "没有可用的引擎运行时。装一台就能开始；之后可以在引擎页随时加装其他引擎。")
                .font(.system(size: 12.5))
                .foregroundStyle(Native.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func machineCard(_ recommendation: HardwareRecommendation) -> some View {
        Card("这台 Mac", subtitle: "推荐结果按统一内存与可用磁盘计算") {
            HStack(spacing: 16) {
                Label(recommendation.chipName, systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
                Label("\(recommendation.memoryGB) GB 内存", systemImage: "memorychip")
                    .font(.system(size: 12, weight: .medium))
                if recommendation.freeDiskBytes > 0 {
                    Label("可用 \(Format.size(Int(recommendation.freeDiskBytes)))", systemImage: "internaldrive")
                        .font(.system(size: 12, weight: .medium))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Native.secondary)
        }
    }

    private func picks(_ recommendation: HardwareRecommendation) -> some View {
        VStack(spacing: 10) {
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                if let pick = recommendation.pick(for: id) {
                    pickRow(pick)
                }
            }
        }
    }

    private func pickRow(_ pick: HardwareRecommendation.Pick) -> some View {
        let id = pick.engineID
        return HStack(spacing: 14) {
            ArcadeIcon(symbol: id.map(engineSymbol) ?? "cpu",
                       colors: id.map { [engineAccent($0), engineAccent($0).opacity(0.6)] } ?? [Native.blue],
                       size: 36,
                       glyphScale: 0.44,
                       glow: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(id?.displayName ?? pick.engine)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Native.label)
                    Tag(text: fitLabel(pick.verdict), tone: fitTone(pick.verdict))
                }
                Text(pick.shortName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                Text(pick.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let id {
                installButton(id, recommended: pick)
            }
        }
        .padding(Native.cardPadding)
        .background { GlassSurface(radius: Native.radiusPanel) }
    }

    private var engineList: some View {
        VStack(spacing: 10) {
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                HStack(spacing: 14) {
                    ArcadeIcon(symbol: engineSymbol(id),
                               colors: [engineAccent(id), engineAccent(id).opacity(0.6)],
                               size: 36,
                               glyphScale: 0.44,
                               glow: false)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(id.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Native.label)
                            if state.engineIsInstalled(id) {
                                Tag(text: "已安装", tone: .success)
                            }
                        }
                        Text(id.descriptor.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(Native.tertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    installButton(id, recommended: nil)
                }
                .padding(Native.cardPadding)
                .background { GlassSurface(radius: Native.radiusPanel) }
            }
        }
    }

    private func installButton(_ id: EngineID, recommended: HardwareRecommendation.Pick?) -> some View {
        let installed = state.engineIsInstalled(id)
        let phase = installs.phases[id] ?? .idle
        let fraction = installs.progress[id]
        return Group {
            if installed {
                Button("完成") {
                    if recommended != nil { state.dismissRecommendation(engine: id) }
                    state.adoptEngine(id)
                }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            } else if phase.isBusy || busy == id {
                HStack(spacing: 7) {
                    ProgressRing(fraction: fraction ?? 0, tint: engineAccent(id), size: 22, lineWidth: 2.5)
                    Text(installs.progressStep[id] ?? phase.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 120, alignment: .leading)
                }
            } else {
                Button {
                    startInstall(id, recommended: recommended)
                } label: {
                    Text(recommended == nil ? "安装" : "安装并开始")
                }
                .buttonStyle(.arcadePill)
                .disabled(installs.building != nil || busy != nil)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isRecommendation {
                Button("先跳过推荐") {
                    state.dismissRecommendation(engine: nil)
                }
                .buttonStyle(.arcadeGlass)
            } else {
                Button("稍后再说") {
                    state.showsLaunchPage = false
                }
                .buttonStyle(.arcadeGlass)
            }
            Spacer(minLength: 0)
            if let error = installs.indexError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Native.orange)
                    .lineLimit(1)
            }
        }
    }

    private func startInstall(_ id: EngineID, recommended: HardwareRecommendation.Pick?) {
        busy = id
        if recommended != nil {
            state.dismissRecommendation(engine: id)
        }
        let center = installs
        center.onInstalled = { installed in
            state.adoptEngine(installed)
        }
        center.onInstallFailed = { failed in
            state.engineInstallFailed(failed)
            busy = nil
        }
        if let latest = center.releases[id]?.max(by: { EngineVersionOrder.isNewer($1.version, than: $0.version) }) {
            center.install(latest, for: id)
        } else if case .update(_, let release) = center.upstream[id] {
            _ = center.buildAndInstall(release, for: id)
        } else {
            busy = nil
            state.toast("暂时没有 \(id.displayName) 的可用安装版本")
        }
    }

    // MARK: Fit labels

    private func fitLabel(_ fit: DeviceFit) -> String {
        switch fit {
        case .good: return "适配本机"
        case .unknown: return "未知"
        case .tight: return "内存偏紧"
        case .diskShort: return "磁盘不足"
        }
    }

    private func fitTone(_ fit: DeviceFit) -> TagTone {
        switch fit {
        case .good: return .success
        case .unknown: return .neutral
        case .tight: return .warning
        case .diskShort: return .danger
        }
    }
}
