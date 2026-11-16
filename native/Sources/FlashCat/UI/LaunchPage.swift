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
    @State private var appeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var installs: EngineInstallCenter { state.installs }
    private var recommendation: HardwareRecommendation? { state.hardwareRecommendation }
    private var isRecommendation: Bool { state.showsRecommendationPage }

    var body: some View {
        ZStack {
            DS.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brand
                        .launchEntrance(appeared, delay: 0, reduceMotion: reduceMotion)
                    intro
                        .launchEntrance(appeared, delay: 0.04, reduceMotion: reduceMotion)
                    if isRecommendation, let recommendation {
                        machineCard(recommendation)
                            .launchEntrance(appeared, delay: 0.08, reduceMotion: reduceMotion)
                        picks(recommendation)
                    } else {
                        engineList
                    }
                    footer
                        .launchEntrance(appeared, delay: 0.16, reduceMotion: reduceMotion)
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 46)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.never)
        }
        .onAppear { appeared = true }
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
            BrandMark(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("本地推理控制台")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 0)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(isRecommendation ? "先装一台引擎" : "选择一台引擎"))
                .font(DS.Font.display)
                .foregroundStyle(DS.text)
            Text(isRecommendation
                 ? "引擎运行时按 pack 分发，第一次打开需要下载（80 MB ~ 600 MB）。装好后控制台会自动接管。"
                 : "没有可用的引擎运行时。装一台就能开始；之后可以在引擎页随时加装其他引擎。")
                .font(DS.Font.md)
                .foregroundStyle(DS.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func machineCard(_ recommendation: HardwareRecommendation) -> some View {
        Card("这台 Mac", subtitle: "推荐结果按统一内存与可用磁盘计算") {
            HStack(spacing: 16) {
                Label(recommendation.chipName, systemImage: "cpu")
                    .font(DS.Font.sm.weight(.medium))
                Label("\(recommendation.memoryGB) GB 内存", systemImage: "memorychip")
                    .font(DS.Font.sm.weight(.medium))
                if recommendation.freeDiskBytes > 0 {
                    Label("可用 \(Format.size(Int(recommendation.freeDiskBytes)))", systemImage: "internaldrive")
                        .font(DS.Font.sm.weight(.medium))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(DS.text2)
        }
    }

    private func picks(_ recommendation: HardwareRecommendation) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(EngineCatalog.allIDs.enumerated()), id: \.element) { index, id in
                if let pick = recommendation.pick(for: id) {
                    pickRow(pick)
                        .launchEntrance(appeared,
                                        delay: 0.12 + Double(index) * 0.045,
                                        reduceMotion: reduceMotion)
                }
            }
        }
    }

    private func pickRow(_ pick: HardwareRecommendation.Pick) -> some View {
        let id = pick.engineID
        let installed = id.map { state.engineIsInstalled($0) } ?? false
        return HStack(spacing: 14) {
            IconTile(symbol: id.map(engineSymbol) ?? "cpu",
                     color: id.map(engineAccent) ?? DS.info,
                     size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(id?.displayName ?? pick.engine)
                        .font(DS.Font.md.weight(.semibold))
                        .foregroundStyle(DS.text)
                    Tag(text: fitLabel(pick.verdict), tone: fitTone(pick.verdict))
                }
                Text(pick.shortName)
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                Text(pick.reason)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let id {
                installButton(id, recommended: pick)
            }
        }
        .padding(14)
        .dsSurface(
            radius: DS.Radius.lg,
            fill: DS.surface,
            stroke: installed ? DS.ok.opacity(0.35) : DS.line
        )
    }

    private var engineList: some View {
        VStack(spacing: 10) {
            ForEach(Array(EngineCatalog.allIDs.enumerated()), id: \.element) { index, id in
                engineRow(id)
                    .launchEntrance(appeared,
                                    delay: 0.10 + Double(index) * 0.045,
                                    reduceMotion: reduceMotion)
            }
        }
    }

    private func engineRow(_ id: EngineID) -> some View {
        let accent = engineAccent(id)
        let installed = state.engineIsInstalled(id)
        return HStack(spacing: 14) {
            IconTile(symbol: engineSymbol(id), color: accent, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName)
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text(id.descriptor.summary)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            installButton(id, recommended: nil)
        }
        .padding(14)
        .dsSurface(
            radius: DS.Radius.lg,
            fill: DS.surface,
            stroke: installed ? DS.ok.opacity(0.35) : DS.line
        )
    }

    @ViewBuilder
    private func installButton(_ id: EngineID, recommended: HardwareRecommendation.Pick?) -> some View {
        let installed = state.engineIsInstalled(id)
        let phase = installs.phases[id] ?? .idle
        let fraction = installs.progress[id] ?? 0
        let label = L10n.t(installs.progressStep[id] ?? phase.label)

        Group {
            if installed {
                // 已安装不再给按钮：状态本身就是答案，用户从底部「开始使用」进入控制台。
                InstalledBadge()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else if phase.isBusy || busy == id {
                LaunchProgressBadge(fraction: fraction,
                                    label: label,
                                    tint: engineAccent(id))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                Button {
                    startInstall(id, recommended: recommended)
                } label: {
                    Text(L10n.t(recommended == nil ? "安装" : "安装并开始"))
                }
                .buttonStyle(.ds(.primary, size: .regular))
                .disabled(installs.building != nil || busy != nil)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(DS.Motion.smooth, value: installed)
        .animation(DS.Motion.smooth, value: phase.isBusy)
        .animation(DS.Motion.smooth, value: busy)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if isRecommendation {
                Button("先跳过推荐") {
                    state.dismissRecommendation(engine: nil)
                }
                .buttonStyle(.ds(.secondary, size: .regular))
            } else {
                Button {
                    startUsing()
                } label: {
                    Text("开始使用")
                }
                .buttonStyle(.ds(.primary, size: .large))
                .help(installedCandidate == nil
                      ? "直接进入控制台，稍后再装引擎"
                      : "以 \(installedCandidate?.displayName ?? "") 进入控制台")
            }

            if let error = installs.indexError, !error.isEmpty {
                Text(error)
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.warn)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    /// 页面上已经装好的引擎里，进入控制台时优先用哪一台。
    private var installedCandidate: EngineID? {
        if state.engineIsInstalled(state.activeEngine) { return state.activeEngine }
        if let recommended = recommendation?.picks.compactMap(\.engineID)
            .first(where: { state.engineIsInstalled($0) }) {
            return recommended
        }
        return EngineCatalog.allIDs.first(where: { state.engineIsInstalled($0) })
    }

    private func startUsing() {
        if let id = installedCandidate {
            state.adoptEngine(id)
        } else {
            // 淡出动画由 ConsoleShell 的 transition 统一驱动，这里不再各自 withAnimation。
            state.showsLaunchPage = false
        }
    }

    private func startInstall(_ id: EngineID, recommended: HardwareRecommendation.Pick?) {
        guard installs.building == nil else {
            state.toast(L10n.format("正在构建 %@，完成后再试", installs.building?.displayName ?? L10n.t("引擎")))
            return
        }
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
        // Build from the engine's newest GitHub release; this page never had an
        // upstream check, so `installFromUpstream` fetches it on demand.
        Task { @MainActor in
            let started = await center.installFromUpstream(id)
            if !started { busy = nil }
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

// MARK: - Onboarding parts

/// 进场：内容从下方 12 pt 处淡入，按行错开，用同一套弹簧节奏。
private struct LaunchEntrance: ViewModifier {
    let active: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .offset(y: active ? 0 : 12)
            .animation(reduceMotion ? nil : DS.Motion.smooth.delay(delay), value: active)
    }
}

private extension View {
    func launchEntrance(_ active: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(LaunchEntrance(active: active, delay: delay, reduceMotion: reduceMotion))
    }
}

/// 已安装徽标：勾选状态标签，替掉原来的「完成」按钮。
private struct InstalledBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("已安装")
                .font(DS.Font.xs.weight(.semibold))
        }
        .foregroundStyle(DS.ok)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            DS.rect(DS.Radius.md).fill(DS.ok.opacity(0.12))
        }
        .overlay(DS.rect(DS.Radius.md).strokeBorder(DS.ok.opacity(0.25), lineWidth: 1))
        .fixedSize()
        .accessibilityLabel("已安装")
    }
}

/// 安装中的连续动画：进度弧平滑补齐，外圈一道细弧缓慢旋转，
/// 步骤文字交叉淡入淡出。
private struct LaunchProgressBadge: View {
    let fraction: Double
    let label: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(clamped, 0.06)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(DS.Motion.smooth, value: clamped)
                if !reduceMotion {
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false),
                                   value: spinning)
                }
            }
            .frame(width: 20, height: 20)

            Text(L10n.t(label))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
                .contentTransition(.opacity)
                .animation(DS.Motion.smooth, value: label)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            DS.rect(DS.Radius.md).fill(DS.raised)
        }
        .overlay {
            DS.rect(DS.Radius.md).strokeBorder(DS.line, lineWidth: 1)
        }
        .onAppear { spinning = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
