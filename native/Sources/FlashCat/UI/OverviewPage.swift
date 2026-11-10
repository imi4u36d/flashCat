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
    private var samples: [ThroughputSample] { state.overviewThroughput(window: 60) }
    private var peak: Double { max(samples.map(\.value).max() ?? 0, 1) }

    private var modelTitle: String {
        state.selectedModelInfo?.shortName ?? (state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel))
    }

    /// HERO 大数字：模型启动以来平均，而不是曲线上的实时值。
    private var averageReading: MetricReading { state.averageDecodeReading }
    private var averageRate: Double { averageReading.value ?? 0 }

    /// 曲线的实时读数：最后一个采样点。收尾冻结后它就停在收尾前的最后一段。
    private var chartRate: Double { samples.last?.value ?? 0 }

    /// 曲线是否已经冻结（请求已全部收尾）。
    private var chartFrozen: Bool { state.throughputFrozenAt != nil }

    /// 当前速度的来源（曲线右上角的角标）。只认 LIVE，没有 LAST。
    private var speedOrigin: SpeedOrigin { state.speedOrigin }

    /// 预填充格的取数来源（owner = 引擎；见 `AppState.prefillReading`）。
    private var prefillReading: MetricReading { state.prefillReading }

    /// 速率统一显示口径：没有值就留「—」，不拿 0.00 冒充读数。
    private func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
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
                    Text(rateText(averageRate))
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .foregroundStyle(Console.text)
                        .contentTransition(.numericText())
                    Text("tok/s")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                    if let badge = averageBadge {
                        Text(badge.text)
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .overlay(Capsule().stroke(badge.tint.opacity(0.55), lineWidth: 0.8))
                            .foregroundStyle(badge.tint)
                    }
                }
                Text("模型启动以来平均")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
                Spacer(minLength: 0)
            }
            .frame(width: 235, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleCardSurface(tint: Console.accent.opacity(0.10))
    }

    /// 引擎自己报的在跑请求数。速度走网关，但「几路在跑」是引擎的状态，
    /// 直连引擎端口的请求不会出现在网关会话表里。
    private var sessionCount: Int {
        state.stats?.activeRequests ?? 0
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
                   hint: contextHint,
                   badge: contextBadge)
        metricCard(icon: "timer", tint: Console.warn,
                   title: "首字延迟", tag: "TTFT",
                   value: ttftText,
                   unit: "ms",
                   hint: ttftHint)
        metricCard(icon: "arrow.up.circle.fill", tint: Color(console: 0x7C5CFF),
                   title: "预填充", tag: "PREFILL",
                   value: prefillText,
                   unit: "tok/s",
                   hint: prefillHint,
                   badge: prefillBadge)
        metricCard(icon: "memorychip", tint: Console.info,
                   title: "内存压力", tag: "MEM",
                   value: memoryPercentText,
                   unit: "%",
                   hint: memoryHint)
    }

    private func metricCard(icon: String, tint: Color, title: String, tag: String,
                            value: String, unit: String, hint: String,
                            badge: (text: String, tint: Color)? = nil) -> some View {
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
                    if let badge {
                        Text(badge.text)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.6)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .overlay(Capsule().stroke(badge.tint.opacity(0.55), lineWidth: 0.8))
                            .foregroundStyle(badge.tint)
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

    /// 上下文卡：生成期间是网关估算，结束后回落到引擎 usage。
    private var contextHint: String {
        guard state.isRunning else { return "引擎未运行" }
        return state.generating ? "网关估算 · 结束后用引擎 usage" : "引擎 usage · 本会话已用"
    }

    private var contextBadge: (text: String, tint: Color)? {
        state.generating && state.contextUsedTokens > 0 ? ("EST", Console.warn) : nil
    }

    private var ttftHint: String {
        guard state.isRunning else { return "引擎未运行" }
        return (stats?.ttftMilliseconds ?? 0) > 0 ? "引擎 p50 · 从请求到首个 token" : "引擎未上报"
    }

    private var memoryHint: String {
        guard state.isRunning else { return "引擎未运行" }
        return stats?.memoryBytes != nil ? "引擎 · 统一内存占用" : "引擎未上报"
    }

    private var ttftText: String {
        guard let value = stats?.ttftMilliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    private var prefillText: String {
        // 只显示引擎自己量过的数。网关那套「(整段提示词 − 缓存命中) / 首字耗时」
        // 已经废弃：分母是 TTFT，里面混着排队与缓存恢复，而分子只能在末帧
        // usage 到达后才知道命中量——请求进行中它算不出可靠的预填充速度。
        // 引擎没有报这个方向的速率时，宁可显示「—」。数值与粒度都走
        // owner 表（`AppState.prefillReading`），角标与说明同源。
        guard let value = prefillReading.value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    /// 预填充读数的粒度角标。LAST 已取消：空闲时不再把上一请求的实测值
    /// 挂成「当前速度」。只剩 LIVE（正在处理提示词）与 AVG（引擎真的累计过
    /// 的开机以来均值，文案会说明它不是实时值）。
    private var prefillBadge: (text: String, tint: Color)? {
        switch prefillReading.origin {
        case .engineLive: return ("LIVE", Console.accent)
        case .engineMean: return ("AVG", Console.tertiary)
        default: return nil
        }
    }

    /// hero 大数字的来源角标：它回答的是「模型启动以来平均」，不是曲线上的
    /// 实时速度。网关累计写 AVG，引擎自己的累计均值写「引擎 AVG」。
    private var averageBadge: (text: String, tint: Color)? {
        switch averageReading.origin {
        case .gatewayMean: return ("AVG", Console.tertiary)
        case .engineMean: return ("引擎 AVG", Console.tertiary)
        default: return nil
        }
    }

    /// 预填充卡下方那行说明。它必须随粒度一起变：把开机以来的均值说成
    /// 「长提示词处理速度」正是在撒谎。
    private var prefillHint: String {
        guard state.isRunning else { return "引擎未运行" }
        switch prefillReading.origin {
        case .engineLive: return "引擎 · 正在处理提示词"
        case .engineMean: return "引擎 · 开机以来均值"
        default: return "等待引擎的实时预填充值"
        }
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
                    Text(rateText(chartRate))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Console.text)
                    Text("tok/s")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                    Spacer(minLength: 0)
                    StatusChip(text: speedChip.text, color: speedChip.color, filled: true)
                        .help("速度来源：网关按请求估算 / 引擎实时计数；请求结束后曲线冻结")
                }

                if samples.isEmpty {
                    ZStack {
                        chartGrid
                        Text(chartEmptyText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Console.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Chart {
                        ForEach(samples) { sample in
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
                        // 一次只有 1~2 个点的短请求也要能看见落点——以前
                        // `samples.count < 2` 走空态，请求跑完曲线还是空的。
                        if samples.count == 1, let only = samples.first {
                            PointMark(x: .value("时间", only.at), y: .value("tok/s", only.value))
                                .foregroundStyle(Console.accent)
                                .symbolSize(28)
                        }
                    }
                    .chartXScale(domain: chartWindow)
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

    /// 固定 60 秒横轴。Swift Charts 默认按样本的时间范围铺满宽度，样本稀疏时
    /// 两三个点会被拉伸成一整条长线，看起来像「60 秒都在跑」，和标题的
    /// 「最近 60 秒」不是一回事。
    ///
    /// 右缘跟随 `overviewChartEnd`：请求进行中就是「现在」，收尾后冻结在
    /// 收尾时刻——横轴不再向前滑，曲线因此停在最后一帧。
    private var chartWindow: ClosedRange<Date> {
        let end = state.overviewChartEnd
        return end.addingTimeInterval(-60)...end
    }

    /// 曲线右上角只报来源，不再拿 `isRunning` 冒充「速率是实时的」。
    /// 请求收尾后曲线冻结，角标直接说「已冻结」。
    private var speedChip: (text: String, color: Color) {
        if chartFrozen { return ("已冻结", Console.tertiary) }
        switch speedOrigin {
        case .gatewayLive: return ("网关", Console.info)
        case .engineLive: return ("引擎", Console.accent)
        case .none: return (state.isRunning ? "等待" : "IDLE", Console.tertiary)
        }
    }

    /// 没有曲线点时，说清楚是「没在跑」还是「还在等首个样本」，
    /// 不要让空白图看起来像故障。
    private var chartEmptyText: String {
        guard state.isRunning else { return "引擎未运行 · 暂无解码数据" }
        if chartFrozen { return "本次请求已结束 · 曲线已冻结" }
        switch speedOrigin {
        case .gatewayLive, .engineLive: return "等待实时样本"
        case .none:
            switch state.stats?.decodeRateKind ?? .none {
            case .live: return "引擎有实时计数 · 等待首个样本"
            default: return "等待网关实时样本"
            }
        }
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
            let sessions = GatewayMeter.shared.snapshot(limit: 6).reversed()
            GlassCard(padding: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("最近请求")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Console.text)
                        Text("网关估算")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Console.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .overlay(Capsule().strokeBorder(Console.insetStroke, lineWidth: 0.8))
                        Spacer(minLength: 0)
                        Text("\(sessions.count) 条")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                    }
                    .help("速度与上下文由网关按流式分片估算，不是引擎上报；完成的行会保留到被后续请求挤出列表")
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
                            // 按请求 id 稳定身份：以前用枚举下标，新请求一进表
                            // 所有行整体下移一格，SwiftUI 把整列行重排、每秒重绘
                            // 出跳动——这也是「读数闪烁」里视觉上的那一半。
                            ForEach(sessions, id: \.id) { session in
                                requestRow(session)
                                if session.id != sessions.first?.id {
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

    private func requestRow(_ session: GatewayMeter.SessionSnapshot) -> some View {
        let decode = session.decodeRate
        let ctx = session.ctxTokens
        return HStack(spacing: 8) {
            StatusChip(text: stateLabel(session.state),
                       color: sessionColor(session.state),
                       filled: true)
            Text(state.shortModelName(session.model.isEmpty ? "未命名" : session.model))
                .font(.system(size: 11.5))
                .foregroundStyle(Console.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(decode > 0 ? "\(Format.compact(decode)) tok/s" : "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.secondary)
            Text(Format.tokens(ctx))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.tertiary)
        }
        .padding(.vertical, 7)
    }

    private func sessionColor(_ state: GatewayMeter.SessionSnapshot.State) -> Color {
        switch state {
        case .decode: return Console.ok
        case .prefill: return Console.info
        case .failed: return Console.danger
        case .done: return Console.tertiary
        }
    }

    private func stateLabel(_ state: GatewayMeter.SessionSnapshot.State) -> String {
        switch state {
        case .decode: return "解码"
        case .prefill: return "预填"
        case .failed: return "失败"
        case .done: return "完成"
        }
    }
}
