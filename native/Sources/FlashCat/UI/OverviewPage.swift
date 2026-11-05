import SwiftUI
import Charts
import AppKit
import FlashCatKit

/// 概览：引擎状态、当前模型、实时指标、吞吐曲线与对外接口。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject private var gateway = GatewayController.shared

    private var stats: ServerStats? { state.stats }
    private var samples: [ThroughputSample] { state.recentThroughput(window: 0) }
    private var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    private var loading: Bool {
        if state.isSwitchingModel { return true }
        switch state.serverState {
        case .starting, .stopping: return true
        case .ready: return stats == nil
        case .stopped, .failed: return false
        }
    }

    private var modelTitle: String {
        if let info = state.selectedModelInfo { return info.shortName }
        return state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel)
    }

    private var decodeRate: Double {
        state.liveDecodeRate ?? stats?.decodeTokensPerSecond ?? 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "概览",
                           subtitle: "本地推理引擎的状态、指标与对外接口",
                           eyebrow: "控制台") {
                    Button {
                        state.toggleService()
                    } label: {
                        Label(state.isRunning ? "停止引擎" : "启动引擎",
                              systemImage: state.isRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(state.isRunning ? ArcadePillStyle(tone: .quietDanger) : .arcadePill)
                    .disabled(state.isSwitchingModel || state.runtimeMissing != nil)
                }
                .padding(.top, 30)

                if let missing = state.runtimeMissing {
                    Card("运行时缺失", subtitle: "应用找不到这台引擎的可执行文件", tint: Native.red) {
                        Text(missing)
                            .font(Native.bodyFont)
                            .foregroundStyle(Native.red)
                            .textSelection(.enabled)
                    }
                }

                statusStrip
                heroRow
                metricsGrid
                HStack(alignment: .top, spacing: Native.gap) {
                    throughputCard
                    VStack(spacing: Native.gap) {
                        contextCard
                        endpointCard
                    }
                    .frame(width: 330)
                }
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.bottom, 30)
            .pageColumn()
        }
        .scrollIndicators(.never)
    }

    // MARK: Status

    private var statusStrip: some View {
        StatusStrip(
            dotColor: statusColor(state.serverState),
            statusText: statusText,
            pulsing: state.serverState == .starting || state.serverState == .stopping,
            meta: statusMeta,
            hint: state.isSwitchingModel ? state.switchStage : nil,
            failure: state.failureMessage
        )
    }

    private var statusText: String {
        if state.isSwitchingModel {
            return "切换模型中 · \(state.switchStage.isEmpty ? "准备中" : state.switchStage)"
        }
        switch state.serverState {
        case .ready: return "运行中"
        case .starting: return "启动中 · \(state.startupStage)"
        case .stopping: return "停止中"
        case .failed: return "启动失败"
        case .stopped: return "已停止"
        }
    }

    private var statusMeta: [String] {
        var items = ["\(state.activeEngine.displayName) \(state.engineVersion)", "端口 \(state.port)"]
        if let started = stats?.startedAt, started > 0 {
            items.append("已运行 \(elapsedText(since: started))")
        }
        if let pressure = stats?.memoryPressureText, pressure != "—" {
            items.append("内存压力 \(pressure)")
        }
        return items
    }

    private func elapsedText(since epoch: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - epoch)
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }

    // MARK: Hero

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "CURRENT MODEL")
                Text(modelTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(state.selectedModel.isEmpty ? "在模型页选择一个本机权重" : state.selectedModel)
                    .font(Native.monoFont)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Format.compact(decodeRate))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(Native.metricNum)
                        .contentTransition(.numericText())
                    Text("tok/s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Native.tertiary)
                }
                Text("当前解码速度")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
        }
        .padding(16)
        .background { GlassSurface(radius: Native.radiusHero) }
    }

    // MARK: Metrics

    private var metricsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Native.gap), count: 3),
                  spacing: Native.gap) {
            MetricCard(label: "解码速度",
                       tag: "DECODE",
                       value: loading ? "—" : Format.compact(decodeRate),
                       unit: "tok/s",
                       hint: decodeHint,
                       loading: loading)
            MetricCard(label: "首字延迟",
                       tag: "TTFT",
                       value: ttftText,
                       unit: "ms",
                       hint: "从请求到第一个 token",
                       loading: loading)
            MetricCard(label: "预填充速度",
                       tag: "PREFILL",
                       value: prefillText,
                       unit: "tok/s",
                       hint: "长提示词的处理速度",
                       loading: loading)
            MetricCard(label: "DFlash2 接受率",
                       tag: "DRAFT",
                       value: acceptanceText,
                       unit: "%",
                       hint: draftHint,
                       loading: loading)
            MetricCard(label: "内存占用",
                       tag: "MEMORY",
                       value: memoryText,
                       unit: nil,
                       hint: memoryHint,
                       loading: loading)
            MetricCard(label: "活跃请求",
                       tag: "SESSION",
                       value: loading ? "—" : "\(stats?.activeRequests ?? 0)",
                       unit: nil,
                       hint: "排队 \(stats?.queuedRequests ?? 0) · 完成 \(stats?.requestsCompleted ?? 0)",
                       loading: loading)
        }
    }

    private var draftHint: String {
        let head = state.speculativeMode.headName
        return head.isEmpty ? "未启用投机解码" : "\(head) 草稿"
    }

    private var decodeHint: String {
        state.liveDecodeRate != nil ? "本次生成的本地测速" : "引擎自报"
    }

    private var ttftText: String {
        guard let value = stats?.ttftMilliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    private var prefillText: String {
        guard let value = stats?.prefillTokensPerSecond, value > 0 else { return "—" }
        return Format.compact(value)
    }

    private var acceptanceText: String {
        guard let value = stats?.draftAcceptance, value > 0 else { return "—" }
        return String(format: "%.0f", value * 100)
    }

    private var memoryText: String {
        guard let bytes = stats?.memoryBytes, bytes > 0 else { return "—" }
        return Format.bytes(bytes)
    }

    private var memoryHint: String {
        guard let peak = stats?.peakMemoryBytes, peak > 0 else {
            return stats?.deviceName ?? "引擎未上报内存"
        }
        return "峰值 \(Format.bytes(peak)) · \(stats?.deviceName ?? "")"
    }

    // MARK: Throughput

    private var throughputCard: some View {
        Card("吞吐",
             subtitle: "最近两分钟的本地测速；没有采样时保持空态",
             trailing: samples.isEmpty ? nil : AnyView(
                Text("峰值 \(Format.compact(peak)) tok/s")
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
             )) {
            if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Native.tertiary.opacity(0.8))
                    Text("启动并生成一次回复后，这里会显示吞吐曲线")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 168)
            } else {
                Chart(samples) { sample in
                    AreaMark(x: .value("时间", sample.at),
                             y: .value("tok/s", sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [Native.accent.opacity(0.28), .clear],
                                           startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("时间", sample.at),
                             y: .value("tok/s", sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Native.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...(peak * 1.2))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Native.hairline)
                        AxisValueLabel()
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .frame(height: 168)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Context + endpoint

    private var contextCard: some View {
        let used = state.contextUsedTokens
        let total = state.contextWindowCeiling ?? 0
        let fraction = total > 0 ? min(1, Double(used) / Double(total)) : 0
        return Card("当前会话上下文", subtitle: "本会话已用 / 模型窗口") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.tokens(used))
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Native.metricNum)
                    Text(total > 0 ? "/ \(Format.tokens(total))" : "/ —")
                        .font(Native.monoFont)
                        .foregroundStyle(Native.tertiary)
                    Spacer(minLength: 0)
                    if total > 0 {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.tertiary)
                    }
                }
                Meter(fraction: fraction, tint: fraction > 0.85 ? Native.orange : Native.accent)
                Text(total > 0
                     ? "窗口取模型上限与引擎生效窗口的较小值"
                     : "引擎还没上报上下文窗口")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }
        }
    }

    private var endpointCard: some View {
        Card("本地接口", subtitle: "固定地址，OpenAI 与 Claude 双格式") {
            VStack(alignment: .leading, spacing: 10) {
                endpointRow(title: "网关（推荐）",
                            url: state.gatewayURL,
                            running: gateway.isRunning,
                            detail: gateway.failureMessage ?? "OpenAI / Claude 两种方言共用这一个端口")
                Divider().overlay(Native.hairline)
                endpointRow(title: "引擎直连",
                            url: state.endpointURL,
                            running: state.isRunning,
                            detail: "\(state.activeEngine.displayName) · 随引擎启停")
                if let failure = gateway.failureMessage, !gateway.isRunning {
                    Text(failure)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Native.orange)
                }
            }
        }
    }

    private func endpointRow(title: String, url: String, running: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.secondary)
                Spacer(minLength: 4)
                StatusDot(color: running ? Native.green : Native.gray, diameter: 5)
                Text(running ? "可用" : "未启动")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Native.tertiary)
            }
            HStack(spacing: 6) {
                Text(url)
                    .font(Native.monoFont)
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    state.copy(url, label: "\(title)地址已复制")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Native.secondary)
                .help("复制地址")
            }
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Native.tertiary)
                .lineLimit(2)
        }
    }
}
