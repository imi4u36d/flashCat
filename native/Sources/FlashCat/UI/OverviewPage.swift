import SwiftUI
import Charts
import AppKit
import FlashCatKit

/// 概览：按 WebUI 版式——左 hero + 右 API 网关，中间四张指标卡，底部总解码与最近请求。
struct OverviewPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var chat: ChatStore
    @ObservedObject private var gateway = GatewayController.shared

    private var stats: ServerStats? { state.stats }
    /// 图表标题是「最近 60 秒」，数据也应按 60 秒取。以前传 0 会把 30 分钟的
    /// 全部样本（生成中约 3600 个点）交给 Swift Charts，每秒整图重绘一次。
    private var samples: [ThroughputSample] { state.recentThroughput(window: 60) }
    private var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    private var modelTitle: String {
        state.selectedModelInfo?.shortName ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    private var decodeRate: Double {
        // 概览要的是「所有请求合起来」的解码速度，不是某一路：应用内对话生成时，
        // 外部客户端可能正同时经网关跑请求。这里统一读聚合值（网关按请求打点，
        // 已包含应用内这一路），曲线采样也来自同一个口径。
        state.totalDecodeRate
    }

    private var runningText: String {
        state.engineStageText
    }

    private let columnGap: CGFloat = 18
    private let sideColumnWidth: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            // 窄窗口下双栏会把两侧压到不可读，改为可滚动的单栏布局。
            if proxy.size.width < Console.compactContentWidth {
                compactLayout
            } else {
                wideLayout(proxy)
            }
        }
    }

    /// 窄窗口：所有分区纵向排列，由滚动承载高度。
    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: columnGap) {
                hero
                gatewayCard
                metricsRow(compact: true)
                decodeChart
                    .frame(height: 260)
                recentRequests
                    .frame(height: 340)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, 78)
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
    }

    /// 宽窗口：保持原本刚好铺满一屏的版式。
    private func wideLayout(_ proxy: GeometryProxy) -> some View {
        let topInset: CGFloat = 78
        let bottomInset: CGFloat = 26
        let availableHeight = max(proxy.size.height - topInset - bottomInset, 0)
        // 概览要刚好铺满一屏：首屏区占约 30%，指标行保持固定高度，
        // 底部图表行吃掉剩余空间，窗口变矮时也只有图表行收缩。
        let heroHeight = min(max(availableHeight * 0.30, 220), 300)

        return VStack(alignment: .leading, spacing: columnGap) {
            HStack(alignment: .top, spacing: columnGap) {
                hero
                gatewayCard
                    .frame(width: sideColumnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: heroHeight)

            metricsRow(compact: false)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: columnGap) {
                decodeChart
                recentRequests
                    .frame(width: sideColumnWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Console.contentPadding)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.canChat ? Console.ok
                              : state.isModelBusy ? Console.warn : Console.tertiary)
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
                    ModelPickerButton(state: state) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("切换模型")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Console.inkForeground)
                        .padding(.horizontal, 15)
                        .frame(height: 34)
                        .background(Capsule().fill(Console.ink))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
                        .shadow(color: Console.shadow.opacity(0.6), radius: 8, y: 3)
                    }
                    .disabled(state.isSwitchingModel)

                    Button {
                        state.toggleService()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: state.isRunning ? "stop.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleCardSurface(tint: Console.accent.opacity(0.10))
    }

    private var sessionCount: Int {
        GatewayMeter.shared.sessionCount()
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

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            .buttonStyle(.plainHit)
            .help("复制地址")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Console.inset)
        }
    }

    // MARK: Metrics

    @ViewBuilder
    private func metricsRow(compact: Bool) -> some View {
        if compact {
            // 自适应列宽：常见窄窗口下是两列，再窄自动落成一列。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18, alignment: .top)],
                      alignment: .leading,
                      spacing: 18) {
                metricCards
            }
        } else {
            HStack(spacing: 18) {
                metricCards
            }
        }
    }

    @ViewBuilder
    private var metricCards: some View {
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

    private func metricCard(icon: String, tint: Color, title: String, tag: String,
                            value: String, unit: String, hint: String, bars: [Double]?) -> some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconTile(symbol: icon, color: tint, size: 30)
                    Text(L10n.t(title))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Console.text)
                    Spacer(minLength: 0)
                    Text(tag)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Console.tertiary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L10n.t(value))
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
        // 引擎真的按「本轮前向过的 token」量过的数优先，其次才是网关的
        // 按请求聚合。应用自己按「整段提示词 / 首字耗时」估出来的口径已经废弃：
        // 第二轮几乎全命中前缀缓存，分子里大部分 token 根本没被前向，
        // 两者一除能把读数放大两个数量级。
        let engine = stats.flatMap { $0.prefillRateIsLive ? $0.prefillTokensPerSecond : nil }
        let value = engine ?? state.gatewayPrefillRate ?? stats?.prefillTokensPerSecond
        guard let value, value > 0 else { return "—" }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let sessions = GatewayMeter.shared.snapshot(historyPoints: 0, limit: 6).reversed()
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity)
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
