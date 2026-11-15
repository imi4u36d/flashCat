import SwiftUI
import Charts
import AppKit
import FlashCatKit

/// 概览：整页落在纸色画布上，只靠发丝线分区——页眉（状态、模型、动作与两颗
/// 读数）、四列指标、总解码曲线与最近请求。没有一张卡片。
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

    /// 把 "{{SECRET_ab12}}" 拆成名字 + 量化档位：整串 28pt 一行放不下，
    /// 硬折行会断在 "-" 上，读起来像两个模型。档位单独做成小胶囊更好认。
    private var modelTitleParts: (name: String, variant: String?) {
        let title = modelTitle
        guard let colon = title.lastIndex(of: ":") else { return (title, nil) }
        let name = String(title[title.startIndex..<colon])
        let variant = String(title[title.index(after: colon)...])
        guard !name.isEmpty, !variant.isEmpty, variant.count <= 16 else { return (title, nil) }
        return (name, variant)
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

    /// 预填充格的取数来源（owner = 网关实测值，引擎 LIVE 只在预填充进行中补位；
    /// 见 `AppState.prefillReading`）。
    private var prefillReading: MetricReading { state.prefillReading }
    /// 首字格与菜单栏同源：引擎 status 优先，引擎没有这个字段时退回网关实测。
    private var ttftReading: TTFTReading { state.ttftReading }

    /// 速率统一显示口径：没有值就留「—」，不拿 0.00 冒充读数。
    private func rateText(_ value: Double) -> String {
        value > 0 ? Format.compact(value) : "—"
    }

    /// 换权重的空窗里阶段行会短暂为空，那时只留引擎名，不留一个孤零零的分隔点。
    private var runningText: String {
        let stage = state.engineStageText
        guard !stage.isEmpty else { return state.activeEngine.displayName }
        return "\(state.activeEngine.displayName) · \(stage)"
    }

    private let columnGap: CGFloat = 18
    private let sideColumnWidth: CGFloat = 340

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width < Console.compactContentWidth {
                compactLayout
            } else {
                wideLayout(proxy)
            }
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 22)
                horizontalRule
                compactMetrics
                    .padding(.vertical, 20)
                horizontalRule
                decodeChart
                    .frame(height: 260)
                    .padding(.vertical, 20)
                horizontalRule
                recentRequests
                    .frame(height: 340)
                    .padding(.top, 20)
            }
            .padding(.horizontal, Console.contentPadding)
            .padding(.top, Console.contentTopInset)
            .padding(.bottom, Console.contentBottomInset)
        }
        .scrollIndicators(.never)
    }

    private func wideLayout(_ proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 22)

            horizontalRule

            metricsRow
                .padding(.vertical, 20)

            horizontalRule

            HStack(alignment: .top, spacing: 0) {
                decodeChart
                    .padding(.trailing, 24)
                verticalRule
                recentRequests
                    .frame(width: 320)
                    .padding(.leading, 24)
            }
            .padding(.top, 20)
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Console.contentPadding)
        .padding(.top, Console.contentTopInset)
        .padding(.bottom, Console.contentBottomInset)
    }

    // MARK: Header

    /// 页眉不是一张卡：状态、模型名、动作和右侧两颗读数直接落在画布上。
    private var header: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.canChat ? Console.ok
                              : state.isModelBusy ? Console.warn : Console.tertiary)
                        .frame(width: 6, height: 6)
                    Text(runningText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Console.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(modelTitleParts.name)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .truncationMode(.tail)
                    if let variant = modelTitleParts.variant {
                        Text(variant)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                            .fixedSize()
                    }
                }
                .padding(.top, 10)

                HStack(spacing: 8) {
                    ModelPickerButton(state: state) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 11, weight: .medium))
                            Text(L10n.t("切换模型"))
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Console.secondary)
                        .padding(.horizontal, 13)
                        .frame(height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Console.cardStroke, lineWidth: 1)
                        }
                    }
                    .disabled(state.isSwitchingModel)

                    Button {
                        state.toggleService()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: state.isRunning ? "stop" : "play")
                                .font(.system(size: 10, weight: .semibold))
                            Text(L10n.t(state.isRunning ? "停止引擎" : "启动引擎"))
                                .font(.system(size: 12.5))
                        }
                    }
                    .buttonStyle(ConsolePillStyle(tone: state.isRunning ? .secondary : .primary))
                    .disabled(state.isSwitchingModel)
                }
                .padding(.top, 18)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            gatewaySummary
                .frame(width: 290, alignment: .leading)

            averageSummary
                .frame(width: 168, alignment: .trailing)
        }
    }

    private var averageSummary: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(L10n.t("平均解码"))
                .font(Console.eyebrow)
                .tracking(0.8)
                .foregroundStyle(Console.tertiary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(rateText(averageRate))
                    .font(.system(size: 38, weight: .medium, design: .monospaced))
                    .foregroundStyle(Console.text)
                    .contentTransition(.numericText())
                Text("tok/s")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Console.tertiary)
            }

            Text(L10n.t("模型启动以来平均"))
                .font(.system(size: 10.5))
                .foregroundStyle(Console.tertiary)

            if let badge = averageBadge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(badge.tint)
            }
        }
    }

    /// 引擎自己报的在跑请求数。速度走网关，但「几路在跑」是引擎的状态，
    /// 直连引擎端口的请求不会出现在网关会话表里。
    private var sessionCount: Int {
        state.stats?.activeRequests ?? 0
    }

    // MARK: Gateway

    private var gatewaySummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Text(L10n.t("API 网关"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Console.text)
                Circle()
                    .fill(gateway.isRunning ? Console.ok : Console.tertiary)
                    .frame(width: 5, height: 5)
                Text(gateway.isRunning ? "在线" : "离线")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
            }

            endpointRow(name: "OpenAI", url: state.gatewayURL)
            endpointRow(name: "Claude", url: state.gatewayClaudeURL)

            if let failure = gateway.failureMessage, !gateway.isRunning {
                Text(failure)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.warn)
                    .lineLimit(2)
            }
        }
    }

    private func endpointRow(name: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 10.5))
                .foregroundStyle(Console.secondary)
                .frame(width: 46, alignment: .leading)
            Text(url)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            Button {
                state.copy(url, label: "\(name) 接口地址已复制")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Console.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.t("复制地址"))
        }
    }

    // MARK: Metrics

    private var metricsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            metricColumn(title: "当前上下文", tag: "CTX",
                         value: Format.tokens(state.contextUsedTokens),
                         unit: state.contextWindowCeiling.map { "/ \(Format.tokensShort($0))" } ?? "/ —",
                         hint: contextHint, badge: contextBadge)
                .frame(maxWidth: .infinity, alignment: .leading)
            metricDivider
            metricColumn(title: "首字延迟", tag: "TTFT",
                         value: ttftText, unit: "ms",
                         hint: ttftHint, badge: ttftBadge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
            metricDivider
            metricColumn(title: "预填充", tag: "PREFILL",
                         value: prefillText, unit: "tok/s",
                         hint: prefillHint, badge: prefillBadge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
            metricDivider
            metricColumn(title: "缓存命中率", tag: "CACHE",
                         value: cacheHitText, unit: "%",
                         hint: cacheHitHint, badge: cacheHitBadge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 20)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var compactMetrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 24, alignment: .top)],
                  alignment: .leading, spacing: 24) {
            metricColumn(title: "当前上下文", tag: "CTX",
                         value: Format.tokens(state.contextUsedTokens),
                         unit: state.contextWindowCeiling.map { "/ \(Format.tokensShort($0))" } ?? "/ —",
                         hint: contextHint, badge: contextBadge)
            metricColumn(title: "首字延迟", tag: "TTFT",
                         value: ttftText, unit: "ms",
                         hint: ttftHint, badge: ttftBadge)
            metricColumn(title: "预填充", tag: "PREFILL",
                         value: prefillText, unit: "tok/s",
                         hint: prefillHint, badge: prefillBadge)
            metricColumn(title: "缓存命中率", tag: "CACHE",
                         value: cacheHitText, unit: "%",
                         hint: cacheHitHint, badge: cacheHitBadge)
        }
    }

    private func metricColumn(title: String, tag: String, value: String, unit: String,
                              hint: String,
                              badge: (text: String, tint: Color)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L10n.t(title))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Console.secondary)
                Spacer(minLength: 4)
                Text(tag)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(Console.quaternary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(L10n.t(value))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(Console.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                if value != "—" {
                    Text(unit)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }
                if let badge {
                    Text(badge.text)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(badge.tint)
                }
            }
            Text(L10n.t(hint))
                .font(.system(size: 10.5))
                .foregroundStyle(Console.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: Rules

    private var horizontalRule: some View {
        Rectangle().fill(Console.hairline).frame(height: 1)
    }

    private var verticalRule: some View {
        Rectangle().fill(Console.hairline).frame(width: 1)
    }

    /// 指标行里的短竖线：必须锁死高度，否则会跟着 VStack 的剩余空间一起拉长。
    private var metricDivider: some View {
        Rectangle().fill(Console.hairline).frame(width: 1, height: 46)
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
        switch ttftReading.source {
        case .engine: return "引擎 p50 · 从请求到首个 token"
        case .gateway: return "网关实测 · 最近一次首字"
        case .none: return "引擎未上报"
        }
    }

    private var ttftText: String {
        guard let value = ttftReading.milliseconds, value > 0 else { return "—" }
        return String(format: "%.0f", value)
    }

    /// 首字读数的来源角标：网关那一档不是引擎的统计分布，标 LAST 说明它是
    /// 最近一次实测，不冒充 p50。
    private var ttftBadge: (text: String, tint: Color)? {
        ttftReading.source == .gateway ? ("LAST", Console.tertiary) : nil
    }

    private var prefillText: String {
        // 网关按请求量：分子是 usage 里的提示词 token 减去前缀缓存命中量，
        // 分母是请求发出到首 token 的墙钟。比「整段提示词 / 首字耗时」诚实，
        // 也不依赖任何一家引擎自报的预填充字段——换引擎不会让这格变空。
        // 数值与粒度都走 owner 表（`AppState.prefillReading`），角标与说明同源。
        guard let value = prefillReading.value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    /// 预填充读数的粒度角标。LIVE = 正在处理提示词；LAST = 最近一次完成的
    /// 预填充实测值（预填充太短、1 秒采样常常抓不到 LIVE，这是常态而不是
    /// 异常）；AVG = 引擎真的累计过的开机以来均值，文案会说明它不是实时值。
    private var prefillBadge: (text: String, tint: Color)? {
        switch prefillReading.origin {
        case .engineLive: return ("LIVE", Console.accent)
        case .gatewayLast, .engineLast: return ("LAST", Console.tertiary)
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
    /// 「长提示词处理速度」正是在撒谎；最近一次请求的值也必须说清它的来源
    /// 与时间性。
    private var prefillHint: String {
        guard state.isRunning else { return "引擎未运行" }
        switch prefillReading.origin {
        case .engineLive: return "引擎 · 正在处理提示词"
        case .gatewayLast: return "网关 · 最近一次预填充实测"
        case .engineLast: return "引擎 · 上一请求实测值"
        // 引擎的均值是「真正前向的 token ÷ 每个请求的 prompt_ms」，缓存命中时
        // 分母里还算着缓存恢复的耗时，于是这个数会被拖到几百——比模型的真实
        // 预填充能力低一个量级。标清楚它含什么，别让人以为机器退化了。
        case .engineMean: return "引擎 · 开机以来均值（含缓存恢复开销）"
        default: return "等待引擎或网关的预填充读数"
        }
    }

    // MARK: Cache hit

    /// 缓存命中率格的取数来源（owner = 网关按代累计，引擎开机以来兜底；
    /// 见 `AppState.cacheHitReading`）。
    private var cacheHitReading: MetricReading { state.cacheHitReading }

    /// 命中率是 0…1 的比例，卡片按整数百分比显示：这一格是让人一眼判断
    /// 前缀缓存有没有生效，小数位没有信息量。
    private var cacheHitText: String {
        guard let value = cacheHitReading.value else { return "—" }
        return "\(Int((value * 100).rounded()))"
    }

    /// 两个口径都是累计平均：网关按代累计（按 token 加权），引擎开机以来。
    /// 没有样本时画「—」，不把「没算过」说成 0%。
    private var cacheHitBadge: (text: String, tint: Color)? {
        switch cacheHitReading.origin {
        case .gatewayMean: return ("AVG", Console.tertiary)
        case .engineMean: return ("引擎 AVG", Console.tertiary)
        default: return nil
        }
    }

    /// 缓存命中率卡下方那行说明：说清这个百分比覆盖了多少请求、来自谁。
    /// 网关的样本量写出来，是因为 1 条与 32 条的「平均」可信度差很多。
    private var cacheHitHint: String {
        guard state.isRunning else { return "引擎未运行" }
        switch cacheHitReading.origin {
        case .gatewayMean:
            return "网关 · 最近 \(state.gatewayCacheHitRequests) 次请求合计"
        case .engineMean: return "引擎 · 开机以来缓存复用"
        default: return "等待带 usage 的请求"
        }
    }

    // MARK: Charts

    private var decodeChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.t("总解码 · 最近 60 秒"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Console.text)
                Text(rateText(chartRate))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Console.text)
                Text("tok/s")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Console.tertiary)
                Spacer(minLength: 0)
                StatusChip(text: speedChip.text, color: speedChip.color)
                    .help("速度来源：网关按请求估算 / 引擎实时计数；请求结束后曲线冻结")
            }

            if samples.isEmpty {
                ZStack {
                    chartGrid
                    Text(chartEmptyText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Console.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(
                                LinearGradient(colors: [Console.accent.opacity(0.12), .clear],
                                               startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", sample.at), y: .value("tok/s", sample.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Console.accent)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                    if samples.count == 1, let only = samples.first {
                        PointMark(x: .value("时间", only.at), y: .value("tok/s", only.value))
                            .foregroundStyle(Console.accent)
                            .symbolSize(24)
                    }
                }
                .chartXScale(domain: chartWindow)
                .chartYScale(domain: 0...(peak * 1.2))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Console.hairline)
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
        // 冻结且空：这一轮根本没采到样本，说「已冻结」会让人以为图上还有东西。
        if chartFrozen { return samples.isEmpty ? ("无样本", Console.tertiary) : ("已冻结", Console.tertiary) }
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
        // 冻结了却一个点都没有：这一段流量是非流式响应，正文整段回来，
        // 网关连「此刻多快」都无从采样。速度仍然在右侧逐行给。
        if chartFrozen { return "非流式响应整段返回 · 没有逐秒曲线（每行速度见右侧）" }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(L10n.t("最近请求"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Console.text)
                    Spacer(minLength: 0)
                    Text("\(sessions.count) 条")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                }
                .help("速度优先用引擎按请求上报的 timings（含非流式），没有时由网关按流式分片估算；量不出速度的行画「—」。完成的行会保留到被后续请求挤出列表")

                if sessions.isEmpty {
                    VStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Text(L10n.t("还没有经过网关的请求"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Console.tertiary)
                        Text(L10n.t("把客户端指向 127.0.0.1:8000 后，这里按条显示速度与上下文"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Console.quaternary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 190)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.id) { session in
                            requestRow(session)
                            if session.id != sessions.first?.id {
                                Rectangle().fill(Console.hairline).frame(height: 1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
