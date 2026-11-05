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

                heroRow
                metricsGrid
                HStack(alignment: .top, spacing: Native.gap) {
                    throughputCard
                    acceptanceCard
                }

                HStack(alignment: .top, spacing: Native.gap) {
                    sessionsCard
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

    private var statusText: String {
        if state.isSwitchingModel {
            return "切换模型中 · \(state.switchStage.isEmpty ? "准备中" : state.switchStage)"
        }
        switch state.serverState {
        case .ready: return "运行中"
        case .starting:
            let stage = state.startupStage
            return stage == "启动中" || stage.isEmpty ? "启动中" : "启动中 · \(stage)"
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
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    if state.isRunning {
                        LiveDot(color: statusColor(state.serverState), diameter: 7)
                    } else {
                        Circle()
                            .fill(statusColor(state.serverState))
                            .frame(width: 7, height: 7)
                            .padding(.horizontal, 3.5)
                    }
                    Text(statusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Native.secondary)
                        .contentTransition(.opacity)
                    Text(verbatim: "·")
                        .foregroundStyle(Native.tertiary.opacity(0.6))
                    Text(verbatim: "\(state.activeEngine.displayName) \(state.engineVersion)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Native.tertiary)
                }

                HStack(spacing: 8) {
                    Text(modelTitle)
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                    modelMenu
                }

                Text(state.selectedModel.isEmpty ? "在模型页选择一个本机权重" : state.selectedModel)
                    .font(Native.monoFont)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Tag(text: "端口 \(state.port)", tone: .neutral, icon: "number")
                    Tag(text: state.speculativeMode.headName.isEmpty ? "无投机解码" : state.speculativeMode.headName,
                        tone: state.speculativeMode.headName.isEmpty ? .neutral : .accent,
                        icon: "bolt.fill")
                    if let window = state.contextWindowCeiling {
                        Tag(text: "窗口 \(Format.tokens(window))", tone: .neutral)
                    }
                    if let started = stats?.startedAt, started > 0, state.isRunning {
                        Tag(text: "已运行 \(elapsedText(since: started))", tone: .neutral, icon: "clock")
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Format.compact(decodeRate))
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(Native.metricNum)
                        .contentTransition(.numericText())
                        .animation(Motion.standard, value: decodeRate)
                    Text("tok/s")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Native.tertiary)
                }
                Sparkline(samples: Array(samples.suffix(48)),
                          color: Native.accent)
                    .frame(width: 132, height: 30)
                    .opacity(samples.isEmpty ? 0.25 : 1)
                Text("当前解码速度")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .background {
            let shape = RoundedRectangle(cornerRadius: Native.radiusHero, style: .continuous)
            shape
                .fill(LinearGradient(colors: [Native.canvas, Native.accentSoft.opacity(0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RadialGradient(colors: [Native.accent.opacity(0.10), .clear],
                                   center: UnitPoint(x: 0.92, y: 0.05),
                                   startRadius: 0, endRadius: 360)
                }
                .overlay {
                    shape.fill(LinearGradient(colors: [.white.opacity(AppAppearance.isDark ? 0.03 : 0.5), .clear],
                                              startPoint: .top, endPoint: .center))
                }
                .overlay {
                    shape.strokeBorder(Native.hairline, lineWidth: 1)
                }
                .shadow(color: Native.panelShadow, radius: 18, y: 6)
        }
        .animation(Motion.standard, value: state.isRunning)
        .overlay(alignment: .bottomLeading) {
            if let failure = state.failureMessage {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Native.red)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(EngineCatalog.allIDs.filter { state.engineIsInstalled($0) }, id: \.self) { id in
                let models = state.engineModels(for: id)
                    .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                if !models.isEmpty {
                    Section(id.displayName) {
                        ForEach(models) { model in
                            Button {
                                state.applyModelFromAnyEngine(model.id, engine: id)
                            } label: {
                                if model.id == state.selectedModel, id == state.activeEngine {
                                    Label(state.shortModelName(model.id), systemImage: "checkmark")
                                } else {
                                    Text(state.shortModelName(model.id))
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Native.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Native.overlay(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换模型")
        .disabled(state.isSwitchingModel)
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

    private var acceptanceCard: some View {
        let samples = state.recentAcceptance(window: 0)
        let latest = samples.last?.value
        return Card("DFlash2 接受率",
                    subtitle: "最近两分钟的草稿接受率；没有采样时保持空态",
                    trailing: latest.map { AnyView(
                        Text("\(Int(($0 * 100).rounded()))%")
                            .font(Native.monoSmall)
                            .foregroundStyle(Native.secondary)
                    ) }) {
            if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "percent")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Native.tertiary.opacity(0.8))
                    Text("生成一次带草稿加速的回复后，这里会显示接受率曲线")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Native.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 168)
            } else {
                Chart(samples) { sample in
                    AreaMark(x: .value("时间", sample.at),
                             y: .value("接受率", sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [Native.mint.opacity(0.22), .clear],
                                           startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("时间", sample.at),
                             y: .value("接受率", sample.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Native.mint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 0.5, 1]) { value in
                        AxisGridLine().foregroundStyle(Native.hairline)
                        AxisValueLabel {
                            if let raw = value.as(Double.self) {
                                Text(verbatim: "\(Int(raw * 100))%")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Native.tertiary)
                            }
                        }
                    }
                }
                .frame(height: 168)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionsCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sessions = GatewayMeter.shared.snapshot().suffix(6).reversed()
            Card("会话", subtitle: "网关侧按请求打点：解码、首字与上下文") {
                if sessions.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 13))
                            .foregroundStyle(Native.tertiary)
                        Text("通过接口发送请求后，这里会逐条显示会话")
                            .font(.system(size: 11))
                            .foregroundStyle(Native.tertiary)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 34)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                            sessionRow(session)
                            if index != sessions.count - 1 { Hairline() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func sessionRow(_ session: [String: Any]) -> some View {
        let state = session["state"] as? String ?? "decode"
        let model = (session["model"] as? String) ?? "未命名"
        let decode = session["decodeRate"] as? Double ?? 0
        let prefill = session["prefillRate"] as? Double ?? 0
        let ttft = session["ttft"] as? Double
        let ctx = session["ctxTokens"] as? Int ?? 0
        return HStack(spacing: 9) {
            Circle()
                .fill(sessionColor(state))
                .frame(width: 6, height: 6)
            Text(stateLabel(state))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(sessionColor(state))
                .frame(width: 52, alignment: .leading)
            Text(shortModel(model))
                .font(.system(size: 11.5))
                .foregroundStyle(Native.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(Format.compact(decode)) tok/s")
                .font(Native.monoSmall)
                .foregroundStyle(Native.secondary)
            Text("预 \(Format.compact(prefill))")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .frame(width: 62, alignment: .trailing)
            Text(ttft.map { String(format: "首字 %.0f ms", $0) } ?? "首字 —")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .frame(width: 82, alignment: .trailing)
            Text("\(Format.tokens(ctx)) ctx")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func sessionColor(_ state: String) -> Color {
        switch state {
        case "decode": return Native.green
        case "prefill": return Native.blue
        case "failed": return Native.red
        default: return Native.gray
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "decode": return "解码中"
        case "prefill": return "预填充"
        case "failed": return "失败"
        default: return "已完成"
        }
    }

    private func shortModel(_ id: String) -> String {
        state.shortModelName(id)
    }

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


// MARK: - Sparkline

/// 极小的趋势线：最近 48 个采样，没有数据时就是一条平线。
private struct Sparkline: View {
    let samples: [ThroughputSample]
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let peak = max(samples.map(\.value).max() ?? 1, 1)
            let step = samples.count > 1 ? width / CGFloat(samples.count - 1) : width
            Path { path in
                for (index, sample) in samples.enumerated() {
                    let x = CGFloat(index) * step
                    let y = height - CGFloat(sample.value / peak) * (height - 4) - 2
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color.opacity(samples.isEmpty ? 0.35 : 0.9),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
