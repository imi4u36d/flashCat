import SwiftUI
import AppKit
import FlashCatKit

/// 首次启动页：先推荐这台 Mac 该跑哪台引擎 + 哪档模型，再让用户一键装好。
///
/// 两条路径共用一页：硬件推荐（`showsRecommendationPage`）与引擎安装
/// （没有可用运行时时）。安装完成由 `adoptEngine` 接管，页面自动让位给控制台。
///
/// 视觉上跟随控制台的 Liquid Glass 语言：画布取 `ConsoleBackdrop`，每一行是
/// 玻璃胶囊卡片，已安装用玻璃徽标表达，主按钮也是玻璃胶囊。进场与安装进度
/// 都走统一的 `Motion` 节奏，尊重「减少动态效果」。
struct LaunchPage: View {
    @ObservedObject var state: AppState

    @State private var busy: EngineID?
    @State private var appeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var installs: EngineInstallCenter { state.installs }
    private var recommendation: HardwareRecommendation? { state.hardwareRecommendation }
    private var isRecommendation: Bool { state.showsRecommendationPage }

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    var body: some View {
        ZStack {
            ConsoleBackdrop(accent: Console.accent)
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
            BrandMark(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text("本地推理控制台")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(isRecommendation ? "先装一台引擎" : "选择一台引擎"))
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Console.text)
            Text(isRecommendation
                 ? "引擎运行时按 pack 分发，第一次打开需要下载（80 MB ~ 600 MB）。装好后控制台会自动接管。"
                 : "没有可用的引擎运行时。装一台就能开始；之后可以在引擎页随时加装其他引擎。")
                .font(.system(size: 12.5))
                .foregroundStyle(Console.secondary)
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
            .foregroundStyle(Console.secondary)
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
                        .foregroundStyle(Console.text)
                    Tag(text: fitLabel(pick.verdict), tone: fitTone(pick.verdict))
                }
                Text(pick.shortName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                Text(pick.reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let id {
                installButton(id, recommended: pick)
            }
        }
        .padding(Native.cardPadding)
        .background {
            LiquidGlassSurface(shape: rowShape)
        }
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
            ArcadeIcon(symbol: engineSymbol(id),
                       colors: [accent, accent.opacity(0.6)],
                       size: 36,
                       glyphScale: 0.44,
                       glow: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(id.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text(id.descriptor.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            installButton(id, recommended: nil)
        }
        .padding(Native.cardPadding)
        .background {
            LiquidGlassSurface(shape: rowShape, tint: installed ? Console.ok.opacity(0.06) : nil)
        }
    }

    @ViewBuilder
    private func installButton(_ id: EngineID, recommended: HardwareRecommendation.Pick?) -> some View {
        let installed = state.engineIsInstalled(id)
        let phase = installs.phases[id] ?? .idle
        let fraction = installs.progress[id] ?? 0
        let label = installs.progressStep[id] ?? phase.label

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
                .buttonStyle(.consolePrimary)
                .disabled(installs.building != nil || busy != nil)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(Motion.standard, value: installed)
        .animation(Motion.standard, value: phase.isBusy)
        .animation(Motion.standard, value: busy)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if isRecommendation {
                Button("先跳过推荐") {
                    state.dismissRecommendation(engine: nil)
                }
                .buttonStyle(.consoleSecondary)
            } else {
                Button {
                    startUsing()
                } label: {
                    Text("开始使用")
                }
                .buttonStyle(LaunchActionStyle())
                .help(installedCandidate == nil
                      ? "直接进入控制台，稍后再装引擎"
                      : "以 \(installedCandidate?.displayName ?? "") 进入控制台")
            }

            if let error = installs.indexError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Console.warn)
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
            state.toast(L10n.format("暂时没有 %@ 的可用安装版本", id.displayName))
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
            .animation(reduceMotion ? nil : Motion.entrance.delay(delay), value: active)
    }
}

private extension View {
    func launchEntrance(_ active: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(LaunchEntrance(active: active, delay: delay, reduceMotion: reduceMotion))
    }
}

/// 已安装徽标：玻璃胶囊 + 勾选，替掉原来的「完成」按钮。
private struct InstalledBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("已安装")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(Console.ok)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background {
            LiquidGlassSurface(shape: Capsule(), tint: Console.ok.opacity(0.34))
        }
        .overlay(Capsule().strokeBorder(Console.ok.opacity(0.20), lineWidth: 0.8))
        .fixedSize()
        .accessibilityLabel("已安装")
    }
}

/// 安装中的连续动画：进度弧平滑补齐，外圈一道细弧缓慢旋转，
/// 步骤文字交叉淡入淡出，整体坐在一层玻璃胶囊上。
private struct LaunchProgressBadge: View {
    let fraction: Double
    let label: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(clamped, 0.06)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.45), value: clamped)
                if !reduceMotion {
                    Circle()
                        .trim(from: 0, to: 0.18)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false),
                                   value: spinning)
                }
            }
            .frame(width: 22, height: 22)

            Text(L10n.t(label))
                .font(.system(size: 11))
                .foregroundStyle(Console.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
                .contentTransition(.opacity)
                .animation(Motion.standard, value: label)
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background {
            LiquidGlassSurface(shape: Capsule(), tint: tint.opacity(0.16))
        }
        .onAppear { spinning = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// 引导页主按钮：比普通胶囊更大、居中，玻璃底 + 墨色 tint。
private struct LaunchActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Console.inkForeground)
            .padding(.horizontal, 42)
            .frame(height: 44)
            .background {
                LiquidGlassSurface(shape: Capsule(), tint: Console.ink, interactive: true)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
