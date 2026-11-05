import SwiftUI
import Charts
import AppKit
import FlashCatKit

/// 概览：按 WebUI 版式——左 hero + 右 API 网关，中间四张指标卡，底部总解码与最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject private var gateway = GatewayController.shared

    private var stats: ServerStats? { state.stats }
    private var samples: [ThroughputSample] { state.recentThroughput(window: 0) }
    private var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    private var modelTitle: String {
        state.selectedModelInfo?.shortName ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    private var decodeRate: Double {
        state.liveDecodeRate ?? stats?.decodeTokensPerSecond ?? 0
    }

    private var runningText: String {
        state.isRunning ? "运行中" : state.serverState == .starting ? "启动中" : state.serverState == .failed ? "启动失败" : "已停止"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    hero
                    gatewayCard
                        .frame(width: 340)
                }
                metricsRow
                HStack(alignment: .top, spacing: 18) {
                    decodeChart
                    recentRequests
                        .frame(width: 340)
                }
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, 78)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.isRunning ? Console.ok : Console.tertiary)
                        .frame(width: 6, height: 6)
                    Text("\(state.activeEngine.displayName) · \(runningText)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Console.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Console.inset))

                Text(modelTitle)
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Console.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .truncationMode(.middle)
                    .padding(.top, 14)

                HStack(spacing: 10) {
                    Menu {
                        modelMenuContent
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("切换模型")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background {
                            Capsule().fill(
                                LinearGradient(colors: [Console.accent, Console.accentDeep],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .shadow(color: Console.accent.opacity(0.30), radius: 12, y: 5)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(state.isSwitchingModel)

                    Button {
                        state.toggleService()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(state.isRunning ? "停止引擎" : "启动引擎")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.consoleSecondary)
                    .disabled(state.isSwitchingModel)
                }
                .padding(.top, 20)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text(state.isRunning ? "ENGINE LIVE" : "ENGINE IDLE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Console.tertiary)
                    Text("\(sessionCount) SESSIONS")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Console.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(Format.compact(decodeRate))
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(Console.text)
                        .contentTransition(.numericText())
                    Text("tok/s")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }
                Sparkline(samples: Array(samples.suffix(60)), color: Console.accent)
                    .frame(width: 200, height: 34)
                    .opacity(samples.isEmpty ? 0.25 : 1)
                Spacer(minLength: 0)
            }
            .frame(width: 235, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Console.heroRadius, style: .continuous)
            shape
                .fill(LinearGradient(colors: [Color(console: 0xFFFBFE), Color(console: 0xFDF0F7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RadialGradient(colors: [Color(console: 0xFFE3EF).opacity(0.65), .clear],
                                   center: UnitPoint(x: 0.9, y: 0.1),
                                   startRadius: 0, endRadius: 460)
                }
                .overlay { shape.strokeBorder(Console.cardStroke, lineWidth: 1) }
                .shadow(color: Console.shadow, radius: 24, y: 10)
        }
    }

    private var sessionCount: Int {
        GatewayMeter.shared.snapshot().count
    }

    @ViewBuilder private var modelMenuContent: some View {
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
    }

    // MARK: Gateway

    private var gatewayCard: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconTile(symbol: "point.3.connected.trianglepath.dotted", color: Console.info, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("API 网关")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Console.text)
                        Text("OpenAI + Claude")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Console.tertiary)
                    }
                    Spacer(minLength: 0)
                    StatusChip(text: gateway.isRunning ? "ONLINE" : "OFFLINE",
                               color: gateway.isRunning ? Console.ok : Console.tertiary,
                               filled: true)
                }

                endpointRow(brand: "circle.hexagongrid.fill", color: Color(console: 0x111114),
                            name: "OpenAI", url: state.gatewayURL, style: .openAI)
                endpointRow(brand: "sun.max.fill", color: Color(console: 0xE07A3F),
                            name: "Claude", url: state.gatewayClaudeURL, style: .claude)

                if let failure = gateway.failureMessage, !gateway.isRunning {
                    Text(failure)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Console.warn)
                }
            }
        }
    }

    private enum EndpointStyle { case openAI, claude }

    private func endpointRow(brand: String, color: Color, name: String, url: String,
                             style: EndpointStyle) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color)
                Image(systemName: brand)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Console.text)
                Text(url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                state.copy(url, label: "\(name) 接口地址已复制")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Console.inset))
            }
            .buttonStyle(.plain)
            .help("复制地址")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Console.inset)
        }
    }

    // MARK: Metrics

    private var metricsRow: some View {
        HStack(spacing: 18) {
            metricCard(icon: "square.stack.3d.up.fill", tint: Console.accent,
                       title: "当前上下文", tag: "CTX",
                       value: Format.tokens(state.contextUsedTokens),
                       unit: state.contextWindowCeiling.map { "/ \(shortTokens($0))" } ?? "/ —",
                       hint: state.isRunning ? "本会话已用" : "引擎未运行",
                       bars: nil)
            metricCard(icon: "timer", tint: Console.warn,
                       title: "首字延迟", tag: "TTFT",
                       value: ttftText,
                       unit: "ms",
                       hint: state.isRunning ? "从请求到首个 token" : "引擎未运行",
                       bars: [0.12, 0.16, 0.14, 0.18, 0.15, 0.17, 0.13, 0.16, 0.14, 0.18])
            metricCard(icon: "arrow.up.circle.fill", tint: Color(console: 0x7C5CFF),
                       title: "预填充", tag: "PREFILL",
                       value: prefillText,
                       unit: "tok/s",
                       hint: state.isRunning ? "长提示词处理速度" : "引擎未运行",
                       bars: [0.10, 0.14, 0.12, 0.16, 0.13, 0.15, 0.11, 0.16, 0.12, 0.14])
            metricCard(icon: "memorychip", tint: Console.info,
                       title: "内存压力", tag: "MEM",
                       value: memoryPercentText,
                       unit: "%",
                       hint: state.isRunning ? "统一内存占用" : "引擎未运行",
                       bars: [0.08, 0.10, 0.09, 0.11, 0.10, 0.12, 0.09, 0.11, 0.10, 0.08])
        }
    }

    private func metricCard(icon: String, tint: Color, title: String, tag: String,
                            value: String, unit: String, hint: String, bars: [Double]?) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconTile(symbol: icon, color: tint, size: 30)
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Console.text)
                    Spacer(minLength: 0)
                    Text(tag)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Console.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                    Spacer(minLength: 0)
                    if let bars {
                        MiniBars(levels: bars, tint: tint)
                    }
                }
                Text(hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var ttftText: String {
        guard let value = stats?.ttftMilliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    private var prefillText: String {
        guard let value = stats?.prefillTokensPerSecond, value > 0 else { return "—" }
        return Format.compact(value)
    }

    private var memoryPercentText: String {
        guard let bytes = stats?.memoryBytes, let total = stats?.physicalMemoryBytes, total > 0 else { return "—" }
        return "\(Int((Double(bytes) / Double(total) * 100).rounded()))"
    }

    private func shortTokens(_ value: Int) -> String {
        if value >= 1000 { return "\(Int((Double(value) / 1000).rounded()))K" }
        return "\(value)"
    }

    // MARK: Charts

    private var decodeChart: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("总解码 · 最近 60 秒")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Console.text)
                    Text(Format.compact(decodeRate))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Console.text)
                    Text("tok/s")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                    Spacer(minLength: 0)
                    StatusChip(text: state.isRunning ? "LIVE" : "IDLE",
                               color: state.isRunning ? Console.ok : Console.tertiary,
                               filled: true)
                }

                if samples.isEmpty {
                    ZStack {
                        chartGrid
                        Text("引擎未运行 · 暂无解码数据")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Console.tertiary)
                    }
                    .frame(height: 300)
                } else {
                    Chart(samples) { sample in
                        AreaMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [Console.accent.opacity(0.18), .clear],
                                               startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Console.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    .chartYScale(domain: 0...(peak * 1.2))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(Console.insetStroke)
                            AxisValueLabel()
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Console.tertiary)
                        }
                    }
                    .frame(height: 300)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var chartGrid: some View {
        GeometryReader { proxy in
            let step: CGFloat = 96
            Path { path in
                var x: CGFloat = 0
                while x <= proxy.size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= proxy.size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    y += step / 2
                }
            }
            .stroke(Console.insetStroke, lineWidth: 1)
        }
    }

    private var recentRequests: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let sessions = GatewayMeter.shared.snapshot().suffix(6).reversed()
            GlassCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近请求")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Console.text)
                        Spacer(minLength: 0)
                        Text("\(sessions.count) 条")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                    }
                    if sessions.isEmpty {
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Text("还没有经过网关的请求")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Console.tertiary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 250)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.offset) { index, session in
                                requestRow(session)
                                if index != sessions.count - 1 {
                                    Rectangle().fill(Console.insetStroke).frame(height: 1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(minHeight: 330, alignment: .top)
            }
        }
    }

    private func requestRow(_ session: [String: Any]) -> some View {
        let stateName = session["state"] as? String ?? "decode"
        let model = (session["model"] as? String) ?? "未命名"
        let decode = session["decodeRate"] as? Double ?? 0
        let ctx = session["ctxTokens"] as? Int ?? 0
        return HStack(spacing: 8) {
            StatusChip(text: stateLabel(stateName), color: sessionColor(stateName), filled: true)
            Text(state.shortModelName(model))
                .font(.system(size: 11.5))
                .foregroundStyle(Console.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(Format.compact(decode)) tok/s")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.secondary)
            Text(Format.tokens(ctx))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.tertiary)
        }
        .padding(.vertical, 7)
    }

    private func sessionColor(_ state: String) -> Color {
        switch state {
        case "decode": return Console.ok
        case "prefill": return Console.info
        case "failed": return Console.danger
        default: return Console.tertiary
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "decode": return "解码"
        case "prefill": return "预填"
        case "failed": return "失败"
        default: return "完成"
        }
    }
}

// MARK: - Parts

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
            .stroke(color.opacity(samples.isEmpty ? 0.3 : 0.9),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: samples.isEmpty ? [3, 5] : []))
        }
        .accessibilityHidden(true)
    }
}

private struct MiniBars: View {
    let levels: [Double]
    var tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint.opacity(0.28))
                    .frame(width: 3, height: max(4, 22 * level * 4))
            }
        }
        .frame(height: 24, alignment: .bottom)
    }
}
