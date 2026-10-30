import SwiftUI
import Charts
import AppKit
import FlashCatKit
import FlashCatKit

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var appeared = false

    private var samples: [ThroughputSample] { state.recentThroughput() }
    private var peak: Double { samples.map(\.value).max() ?? 0 }

    /// True while the engine is changing weights or the first live snapshot is
    /// still on its way. The cards swap their values for skeleton content so a
    /// blank "0.0 / —" never reads as a finished measurement.
    private var loading: Bool {
        if state.isSwitchingModel { return true }
        switch state.serverState {
        case .starting, .stopping: return true
        case .ready: return state.stats == nil
        case .stopped, .failed: return false
        }
    }

    var body: some View {
        // Header and hero stay pinned; only the cards below scroll.
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "概览",
                           subtitle: "本地推理引擎状态与实时指标",
                           eyebrow: "控制台")

                if let missing = state.runtimeMissing {
                    Card("运行时缺失",
                         subtitle: "应用找不到内置的 splash 运行时",
                         tint: Native.red) {
                        Text(missing)
                            .font(Native.bodyFont)
                            .foregroundStyle(Native.red)
                    }
                }

                ServiceHero(state: state,
                            samples: samples,
                            peak: peak,
                            loading: loading)
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .pageColumn()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: Native.gap) {
                        MetricsCard(state: state, loading: loading)
                            .frame(maxWidth: .infinity)
                        EndpointCard(state: state)
                            .frame(width: 336)
                    }
                }
                .padding(.horizontal, Native.pagePadding)
                .padding(.bottom, 30)
                .pageColumn()
            }
            .scrollIndicators(.never)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.34)) { appeared = true }
        }
    }
}

// MARK: - Hero

private struct ServiceHero: View {
    @ObservedObject var state: AppState
    let samples: [ThroughputSample]
    let peak: Double
    let loading: Bool

    /// The hero reflows instead of squeezing the 36 pt model title: at narrow
    /// widths the live panel moves under the identity block.
    @State private var heroWidth: CGFloat = 1000

    private var info: ModelInfo? { state.selectedModelInfo }
    private var rate: Double { state.stats?.decodeTokensPerSecond ?? 0 }
    private var wide: Bool { heroWidth >= 900 }

    private var title: String {
        info?.shortName ?? (state.selectedModel.isEmpty ? "未选择模型" : state.selectedModel)
    }

    private var loadingStage: String {
        if state.switchingModel != nil {
            return state.switchStage.isEmpty ? "切换模型" : state.switchStage
        }
        let stage = state.startupStage
        return stage == "就绪" ? "同步指标" : stage
    }

    private var heroColors: [Color] {
        switch state.serverState {
        case .ready: return [Color(hex: 0xFF9F0A), Color(hex: 0xFF375F), Color(hex: 0x7B2CBF)]
        case .starting, .stopping: return [Color(hex: 0xFFB020), Color(hex: 0xFF6A3D), Color(hex: 0x8B5CF6)]
        case .failed: return [Color(hex: 0xFF453A), Color(hex: 0x8B1E3F), Color(hex: 0x3A1030)]
        case .stopped: return [Color(hex: 0x9E9EB4), Color(hex: 0x64648A), Color(hex: 0x343452)]
        }
    }

    /// The hero title is now a plain label — model switching lives on the
    /// Models page, so the overview no longer offers a switcher (no menu, no
    /// chevron). Dropping the affordance keeps the big title from reading as
    /// clickable.
    private var modelTitle: some View {
        Text(title)
            .font(.system(size: 36, weight: .bold))
            .tracking(-0.9)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .truncationMode(.middle)
            .contentTransition(.opacity)
    }

    var body: some View {
        HeroPanel(colors: heroColors) {
            Group {
                if wide {
                    HStack(alignment: .center, spacing: 26) {
                        identity
                        Spacer(minLength: 16)
                        livePanel
                            .frame(width: 320)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        identity
                        livePanel
                    }
                }
            }
            .animation(.easeOut(duration: 0.16), value: wide)
            .animation(.easeOut(duration: 0.22), value: loading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { heroWidth = $0 }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                HStack(spacing: 6) {
                    if loading {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.8)
                    } else {
                        StatusDot(color: statusColor(state.serverState), diameter: 7, pulsing: state.isRunning)
                    }
                    Text(loading ? loadingStage : (state.isReady ? "运行中" : state.startupStage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.22)))
                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.8))

                Eyebrow(text: "本地推理引擎", color: .white.opacity(0.55))

                Spacer(minLength: 8)

                ServiceControlGroup(state: state, onHero: true)
                    .opacity(loading ? 0.6 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            modelTitle
                .help(info?.id ?? state.selectedModel)

            if state.serverState == .failed, let failure = state.failureMessage {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .help(failure)
            }

            HeroRuntimeDetails(state: state, loading: loading)
                .padding(.top, 2)
        }
    }

    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Eyebrow(text: "实时解码", color: .white.opacity(0.5))
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    Circle()
                        .fill(loading ? Native.orange : (state.isReady ? Native.green : Color.white.opacity(0.3)))
                        .frame(width: 5, height: 5)
                        .shadow(color: (loading ? Native.orange : Native.green).opacity(state.isReady || loading ? 0.8 : 0),
                                radius: 4)
                    Text(loading ? "SYNC" : (state.isReady ? "LIVE" : "IDLE"))
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.6))
                        .contentTransition(.opacity)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if loading {
                    SkeletonBar(width: 118, height: 44, radius: 10, opacity: 0.11)
                        .transition(.opacity)
                } else {
                    Text(rate > 0 ? String(format: "%.1f", rate) : "0.0")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(rate > 0 ? .white : Color.white.opacity(0.35))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("TOK/S")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                    Text("解码速度")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .foregroundStyle(.white.opacity(0.72))
            }

            if loading {
                SkeletonBar(width: 264, height: 40, radius: 8, opacity: 0.09)
                    .transition(.opacity)
            } else if samples.isEmpty {
                Text("启动并生成一次回复后，这里会显示吞吐曲线")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                HeroSparkline(samples: samples, peak: peak)
                    .frame(height: 40)
                    .transition(.opacity)
            }

            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(height: 1)

            HStack(spacing: 0) {
                if loading {
                    SkeletonMiniMetric(label: "首字延迟")
                    SkeletonMiniMetric(label: "活跃请求")
                    SkeletonMiniMetric(label: "上下文")
                } else {
                    MiniMetric(label: "首字延迟",
                               value: state.stats?.ttftMilliseconds.map { String(format: "%.0f", $0) } ?? "—",
                               unit: "ms")
                    MiniMetric(label: "活跃请求",
                               value: "\(state.stats?.activeRequests ?? 0)",
                               unit: (state.stats?.queuedRequests ?? 0) > 0 ? "排队 \(state.stats!.queuedRequests)" : nil)
                    MiniMetric(label: "上下文",
                               value: contextLabel,
                               unit: "tokens")
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.black.opacity(0.24))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8)
        }
        .animation(.easeOut(duration: 0.2), value: loading)
    }

    private var contextLabel: String {
        guard let tokens = state.stats?.maximumContextTokens, tokens > 0 else { return "—" }
        if tokens >= 1000 { return String(format: "%.0fK", Double(tokens) / 1000) }
        return "\(tokens)"
    }
}

private struct MiniMetric: View {
    let label: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SkeletonMiniMetric: View {
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            SkeletonBar(width: 44, height: 15, radius: 5, opacity: 0.11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hero sparkline

private struct HeroSparkline: View {
    let samples: [ThroughputSample]
    let peak: Double

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(x: .value("时间", sample.at),
                         y: .value("tok/s", sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                LineMark(x: .value("时间", sample.at),
                         y: .value("tok/s", sample.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: 0xFFD60A), Color(hex: 0xFF9F0A)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(peak * 1.2, 10))
    }
}

// MARK: - Metrics

private struct MetricsCard: View {
    @ObservedObject var state: AppState
    let loading: Bool

    /// The row follows whatever speculative head the active engine is set to
    /// run: DFlash2, MTP, or neither. Changing the knob on the engine's config
    /// page (or switching engines) renames the row right away.
    private var mode: SpeculativeMode { state.speculativeMode }

    private var draftLabel: String {
        switch mode {
        case .dflash: return "DFlash2 接受率"
        case .mtp: return "MTP 接受率"
        case .off: return "草稿接受率"
        }
    }

    private var draftDetail: String? {
        switch mode {
        case .dflash: return "当前引擎使用 DFlash2 草稿"
        case .mtp: return "当前引擎使用 MTP 投机解码"
        case .off: return "已在引擎设置中关闭投机解码"
        }
    }

    var body: some View {
        Card("实时指标",
             subtitle: mode == .off ? "prefill · 内存"
                                    : "prefill · \(mode.headName) 命中 · 内存") {
            VStack(spacing: 0) {
                MetricRow(label: "预填充",
                          value: state.stats?.prefillTokensPerSecond.map { Format.compact($0) } ?? "—",
                          unit: "tok/s",
                          loading: loading)
                Hairline()
                MetricRow(label: draftLabel,
                          value: draftValue,
                          unit: mode == .off ? nil : "%",
                          detail: draftDetail,
                          progress: mode == .off ? nil : state.stats?.draftAcceptance,
                          progressTint: Native.violet,
                          loading: loading)
                Hairline()
                MetricRow(label: "内存占用",
                          value: state.stats?.memoryBytes.map { Format.bytes($0) } ?? "—",
                          detail: state.stats?.peakMemoryBytes.map { "峰值 \(Format.bytes($0))" },
                          progress: memoryFraction,
                          progressTint: memoryFraction > 0.9 ? Native.red : Native.mint,
                          loading: loading)
            }
        }
        .animation(.easeOut(duration: 0.2), value: loading)
        .animation(.easeOut(duration: 0.2), value: mode)
    }

    private var draftValue: String {
        if mode == .off { return "未启用" }
        guard let acceptance = state.stats?.draftAcceptance else { return "—" }
        return String(format: "%.0f", acceptance * 100)
    }

    private var memoryFraction: Double {
        guard let used = state.stats?.memoryBytes,
              let total = state.stats?.physicalMemoryBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    var unit: String? = nil
    var detail: String? = nil
    var progress: Double? = nil
    var progressTint: Color = Native.accent
    var loading: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Native.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
            }
            Spacer(minLength: 12)
            if loading {
                SkeletonBar(width: 64, height: 14, radius: 6, opacity: 0.10)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Native.label)
                        .contentTransition(.numericText())
                    if let unit {
                        Text(unit)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Native.tertiary)
                    }
                }
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
                    .frame(width: 64)
            }
        }
        .padding(.vertical, 11)
    }
}

// MARK: - Runtime details (inside hero)

/// Compact runtime details rendered inside the dark hero panel, where the
/// model parameter chips used to be.
private struct HeroRuntimeDetails: View {
    @ObservedObject var state: AppState
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                engineField
                field("设备", value: deviceText, skeleton: loading)
                field("进程",
                      value: state.stats?.instancePid.map { "pid \($0)" } ?? "未运行",
                      mono: true,
                      skeleton: loading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                field("热状态",
                      value: state.stats?.thermalText ?? "—",
                      color: (state.stats?.thermal == nil || state.stats?.thermal == "nominal") ? .white : Native.orange,
                      skeleton: loading)
                field("内存压力", value: state.stats?.memoryPressureText ?? "—", skeleton: loading)
                field("已运行", value: uptimeText, skeleton: loading)
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .semibold))
                Text("自动刷新 · 1s")
                Spacer()
                if loading {
                    SkeletonBar(width: 150, height: 8, radius: 4, opacity: 0.12)
                } else {
                    Text("\(state.stats?.requestsCompleted ?? 0) 完成 · \(state.stats?.requestsFailed ?? 0) 失败 · \(state.stats?.queuedRequests ?? 0) 排队")
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.white.opacity(0.45))
        }
        .animation(.easeOut(duration: 0.2), value: loading)
    }

    /// Engine name + version on the first row. With more than one runtime pack
    /// installed it becomes a pull-down for one-click switching; the switch
    /// itself stops the running engine and restarts it on the new one.
    private var engineField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("引擎")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)

            let label = Text("\(state.activeEngine.rawValue) \(state.engineVersion)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)

            if state.availableEngines.count > 1 {
                Menu {
                    ForEach(state.availableEngines, id: \.self) { id in
                        Button {
                            state.switchEngine(id)
                        } label: {
                            if state.activeEngine == id {
                                Label(id.displayName, systemImage: "checkmark")
                            } else {
                                Text(id.displayName)
                            }
                        }
                        .disabled(state.isSwitchingModel)
                    }
                } label: {
                    HStack(spacing: 4) {
                        label
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换引擎")
            } else {
                label
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentTransition(.opacity)
    }

    private func field(_ label: String,
                       value: String,
                       mono: Bool = false,
                       color: Color = .white,
                       skeleton: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            if skeleton {
                SkeletonBar(width: 64, height: 13, radius: 6, opacity: 0.12)
            } else {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: mono ? .monospaced : .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceText: String {
        var parts: [String] = []
        if let device = state.stats?.deviceName { parts.append(device) }
        if let cores = state.stats?.gpuCores, cores > 0 { parts.append("\(cores) 核 GPU") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var uptimeText: String {
        guard let started = state.stats?.startedAt, started > 0 else { return "—" }
        let seconds = max(0, Date().timeIntervalSince1970 - started)
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        return String(format: "%.1f 小时", seconds / 3600)
    }
}

private struct EndpointCard: View {
    @ObservedObject var state: AppState
    /// Observed directly: the gateway publishes its own run state, which the
    /// AppState pipeline does not forward.
    @ObservedObject private var gateway: GatewayController = .shared

    private var baseURL: String { "http://127.0.0.1:\(state.port)" }

    var body: some View {
        Card("API 接口",
             subtitle: "OpenAI + Claude 双格式 · 本地服务") {
            VStack(alignment: .leading, spacing: 10) {
                gatewayField
                Hairline()
                KeyValueRow(label: "引擎直连（OpenAI）",
                            value: state.endpointURL,
                            detail: "端口 \(state.port) · \(state.activeEngine.displayName) · 随引擎启停",
                            valueColor: Native.secondary)

                HStack(spacing: 8) {
                    Button {
                        state.copy(state.gatewayURL, label: "网关地址已复制")
                    } label: {
                        Label("复制网关地址", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.arcadeGlassCompact)

                    Spacer()
                }

                Hairline()

                KeyValueRow(label: "状态",
                            value: gateway.isRunning
                                ? "网关运行中" : (state.settings.gatewayEnabled ? "网关启动中" : "网关已停用"),
                            detail: gatewayDetail,
                            valueColor: gateway.isRunning ? Native.green : Native.secondary)
            }
        }
    }

    /// The gateway address is the one clients should pin: it survives engine
    /// switches and engine port changes.
    private var gatewayField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("网关（推荐）")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Native.tertiary)
                Tag(text: "OpenAI · Claude", tone: .neutral)
            }
            Text(state.gatewayURL)
                .font(Native.monoFont)
                .foregroundStyle(Native.label)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Native.recess)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Native.overlay(0.10), lineWidth: 0.8)
                }
            Text("OpenAI `/v1/chat/completions` · Claude `/v1/messages` · 模型列表 `/v1/models`")
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var gatewayDetail: String {
        if !state.settings.gatewayEnabled { return "可在设置中重新开启" }
        if gateway.isRunning { return "端口 \(gateway.port) · 转发到当前引擎" }
        if let failure = gateway.failureMessage { return failure }
        return "端口 \(gateway.port)"
    }
}
