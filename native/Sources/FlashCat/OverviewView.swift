import SwiftUI
import Charts
import AppKit

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var appeared = false

    private var samples: [ThroughputSample] { state.throughput(in: state.throughputRange) }
    private var peak: Double { samples.map(\.value).max() ?? 0 }
    private var average: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.value).reduce(0, +) / Double(samples.count)
    }

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
        ScrollView {
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

                ServiceHero(state: state, loading: loading)

                HStack(alignment: .top, spacing: Native.gap) {
                    ThroughputCard(state: state,
                                   samples: samples,
                                   peak: peak,
                                   average: average,
                                   loading: loading)
                        .frame(maxWidth: .infinity)

                    MetricColumn(state: state, loading: loading)
                        .frame(width: 336)
                }

                HStack(alignment: .top, spacing: Native.gap) {
                    RuntimeDetails(state: state, loading: loading)
                        .frame(maxWidth: .infinity)
                    EndpointCard(state: state)
                        .frame(width: 336)
                }
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .padding(.bottom, 30)
            .frame(maxWidth: Native.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
        }
        .scrollIndicators(.never)
        .onAppear {
            guard !appeared else { return }
            withAnimation(.easeOut(duration: 0.34)) { appeared = true }
        }
    }
}

// MARK: - Hero

private struct ServiceHero: View {
    @ObservedObject var state: AppState
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
        case .stopped: return [Color(hex: 0x3A3A46), Color(hex: 0x2A2A36), Color(hex: 0x16161F)]
        }
    }

    var body: some View {
        HeroPanel(colors: heroColors) {
            Group {
                if wide {
                    HStack(alignment: .center, spacing: 26) {
                        identity
                        Spacer(minLength: 16)
                        livePanel
                            .frame(width: 300)
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
            }

            Text(title)
                .font(.system(size: 36, weight: .bold))
                .tracking(-0.9)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .help(info?.id ?? state.selectedModel)

            Text(info?.id ?? state.selectedModel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)

            if state.serverState == .failed, let failure = state.failureMessage {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(2)
                    .help(failure)
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                if let info {
                    GlassChip(text: info.origin.rawValue,
                              tint: info.origin == .local ? Native.mint : Native.cyan)
                    if info.draftPath != nil {
                        GlassChip(icon: "bolt.fill", text: "DFlash2 就绪", tint: Native.mint)
                    } else if state.catalog.draftRepository(info.id, family: info.family) != nil {
                        GlassChip(text: "DFlash2 可下载")
                    }
                    if info.mmprojPath != nil {
                        GlassChip(icon: "eye", text: "视觉")
                    }
                    GlassChip(text: info.sizeText)
                }
                if let device = state.stats?.deviceName {
                    GlassChip(icon: "cpu", text: device)
                } else if loading {
                    SkeletonBar(width: 92, height: 22, radius: 11, opacity: 0.11)
                        .transition(.opacity)
                }
                GlassChip(icon: "lock", text: "完全离线")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            .animation(.easeOut(duration: 0.2), value: loading)
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

// MARK: - Throughput

private struct ThroughputCard: View {
    @ObservedObject var state: AppState
    let samples: [ThroughputSample]
    let peak: Double
    let average: Double
    let loading: Bool

    var body: some View {
        Card("解码吞吐",
             subtitle: "tokens / second · 最近 \(state.throughputRange.rawValue)",
             trailing: AnyView(
                Picker("", selection: $state.throughputRange) {
                    ForEach(ThroughputRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 138)
             )) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if loading {
                    SkeletonBar(width: 96, height: 28, radius: 8, opacity: 0.10)
                        .transition(.opacity)
                } else {
                    Text(String(format: "%.1f", samples.last?.value ?? 0))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Native.label)
                        .contentTransition(.numericText())
                        .transition(.opacity)
                }
                Text("tok/s")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
                Spacer()
                if loading {
                    SkeletonBar(width: 126, height: 9, radius: 4, opacity: 0.07)
                } else if !samples.isEmpty {
                    Text("峰值 \(String(format: "%.0f", peak)) · 均值 \(String(format: "%.0f", average))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.tertiary)
                    Tag(text: "实时", tone: .success, icon: "circle.fill")
                }
            }

            if loading {
                ThroughputSkeleton()
                    .transition(.opacity)
            } else if samples.isEmpty {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "暂无吞吐数据",
                          detail: "启动服务并生成一次回复后，这里会显示实时解码速度")
                    .frame(height: 196)
                    .transition(.opacity)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("时间", sample.at),
                            y: .value("tok/s", sample.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [Native.accent.opacity(0.42), Native.accent.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )

                        LineMark(
                            x: .value("时间", sample.at),
                            y: .value("tok/s", sample.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(LinearGradient(colors: [Native.accentSoft, Native.pink],
                                                        startPoint: .leading, endPoint: .trailing))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                .chartYScale(domain: 0...max(peak * 1.15, 10))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel(format: .dateTime.minute().second())
                            .font(.system(size: 9))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.06))
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .frame(height: 196)
            }
        }
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

private struct ThroughputSkeleton: View {
    var body: some View {
        ZStack {
            SkeletonBlock(height: 196, radius: 12, opacity: 0.045)
            VStack(spacing: 0) {
                Spacer()
                Hairline()
                Spacer()
                Hairline()
                Spacer()
                Hairline()
                Spacer()
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Metric column

private struct MetricColumn: View {
    @ObservedObject var state: AppState
    let loading: Bool

    var body: some View {
        VStack(spacing: 12) {
            StatTile(label: "预填充",
                     value: state.stats?.prefillTokensPerSecond.map { Format.compact($0) } ?? "—",
                     unit: "tok/s",
                     detail: "引擎 prefill 采样",
                     tint: Native.cyan,
                     loading: loading)

            StatTile(label: "草稿接受率",
                     value: state.stats?.draftAcceptance.map { String(format: "%.0f", $0 * 100) } ?? "—",
                     unit: "%",
                     detail: state.activeEngine == .mtplx ? "MTP 草稿命中" : "DFlash2 草稿命中",
                     badge: state.stats?.draftAcceptance.map { String(format: "%.0f%%", $0 * 100) },
                     tint: Native.violet,
                     progress: state.stats?.draftAcceptance,
                     progressTint: Native.violet,
                     loading: loading)

            StatTile(label: "内存占用",
                     value: state.stats?.memoryBytes.map { Format.bytes($0) } ?? "—",
                     detail: state.stats?.peakMemoryBytes.map { "峰值 \(Format.bytes($0))" },
                     tint: Native.mint,
                     progress: memoryFraction,
                     progressTint: memoryFraction > 0.9 ? Native.red : Native.mint,
                     loading: loading)
        }
    }

    private var memoryFraction: Double {
        guard let used = state.stats?.memoryBytes,
              let total = state.stats?.physicalMemoryBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}

// MARK: - Runtime details

private struct RuntimeDetails: View {
    @ObservedObject var state: AppState
    let loading: Bool

    var body: some View {
        Card("运行详情",
             subtitle: "引擎、设备与当前状态",
             trailing: AnyView(Tag(text: loading ? "同步中" : state.health.label,
                                   tone: loading ? .warning : state.health.tone,
                                   icon: "checkmark.seal"))) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 26) {
                    VStack(spacing: 0) {
                        KeyValueRow(label: "引擎", value: "\(state.activeEngine.rawValue) \(state.engineVersion)", mono: true)
                        Hairline()
                        KeyValueRow(label: "进程",
                                    value: state.stats?.instancePid.map { "pid \($0)" } ?? "未运行",
                                    mono: true,
                                    loading: loading)
                        Hairline()
                        KeyValueRow(label: "设备", value: deviceText, loading: loading)
                    }
                    VStack(spacing: 0) {
                        KeyValueRow(label: "热状态",
                                    value: state.stats?.thermalText ?? "—",
                                    valueColor: (state.stats?.thermal == nil || state.stats?.thermal == "nominal") ? Native.label : Native.orange,
                                    loading: loading)
                        Hairline()
                        KeyValueRow(label: "内存压力",
                                    value: state.stats?.memoryPressureText ?? "—",
                                    loading: loading)
                        Hairline()
                        KeyValueRow(label: "已运行", value: uptimeText, loading: loading)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                    Text("自动刷新 · 1s")
                    Spacer()
                    if loading {
                        SkeletonBar(width: 150, height: 8, radius: 4, opacity: 0.07)
                    } else {
                        Text("\(state.stats?.requestsCompleted ?? 0) 完成 · \(state.stats?.requestsFailed ?? 0) 失败 · \(state.stats?.queuedRequests ?? 0) 排队")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
                .padding(.top, 10)
            }
        }
        .animation(.easeOut(duration: 0.2), value: loading)
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

    private var baseURL: String { "http://127.0.0.1:\(state.port)" }

    var body: some View {
        Card("OpenAI 兼容接口", subtitle: "本地服务地址") {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.endpointURL)
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
                            .fill(.black.opacity(0.28))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.10), lineWidth: 0.8)
                    }

                HStack(spacing: 8) {
                    Button {
                        state.copy(state.endpointURL, label: "接口地址已复制")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.arcadeGlassCompact)

                    Button {
                        if let url = URL(string: baseURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("打开聊天页", systemImage: "safari")
                    }
                    .buttonStyle(.arcadeGlassCompact)
                    .disabled(!state.isRunning)

                    Spacer()
                }

                Hairline()

                KeyValueRow(label: "状态",
                            value: state.isReady ? "就绪" : state.startupStage,
                            detail: "端口 \(state.port)",
                            valueColor: state.isReady ? Native.green : Native.secondary)
            }
        }
    }
}
