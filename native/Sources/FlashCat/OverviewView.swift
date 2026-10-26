import SwiftUI
import Charts
import AppKit

struct OverviewView: View {
    @ObservedObject var state: AppState

    private var samples: [ThroughputSample] { state.throughput(in: state.throughputRange) }
    private var peak: Double { samples.map(\.value).max() ?? 0 }
    private var average: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.value).reduce(0, +) / Double(samples.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "概览", subtitle: "本地推理引擎状态与实时指标") {
                    Button {
                        state.restartService()
                    } label: {
                        Label("重启引擎", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(!state.isRunning)

                    Button {
                        state.toggleService()
                    } label: {
                        Label(state.isRunning ? "停止" : "启动",
                              systemImage: state.isRunning ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.runtimeMissing != nil)
                }

                if let missing = state.runtimeMissing {
                    Card("运行时缺失", subtitle: "应用找不到内置的 splash 运行时") {
                        Text(missing)
                            .font(Native.bodyFont)
                            .foregroundStyle(Native.red)
                    }
                }

                ServiceHero(state: state)

                HStack(alignment: .top, spacing: 14) {
                    ThroughputCard(state: state,
                                   samples: samples,
                                   peak: peak,
                                   average: average)
                        .frame(maxWidth: .infinity)

                    MetricColumn(state: state)
                        .frame(width: 342)
                }

                HStack(alignment: .top, spacing: 14) {
                    RuntimeDetails(state: state)
                        .frame(maxWidth: .infinity)
                    EndpointCard(state: state)
                        .frame(width: 342)
                }
            }
            .padding(Native.pagePadding)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Hero

private struct ServiceHero: View {
    @ObservedObject var state: AppState

    private var info: ModelInfo? { state.selectedModelInfo }
    private var rate: Double { state.stats?.decodeTokensPerSecond ?? 0 }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        StatusDot(color: statusColor(state.serverState))
                        Text(state.isReady ? "运行中" : state.startupStage)
                            .font(.system(size: 12, weight: .medium))
                        if rate > 0, state.isReady {
                            Text("· \(Format.compact(rate)) tok/s")
                                .font(Native.monoFont)
                                .foregroundStyle(Native.secondary)
                        }
                        if let active = state.stats?.activeRequests {
                            Text(verbatim: "· \(active) 个请求")
                                .font(Native.monoFont)
                                .foregroundStyle(Native.tertiary)
                        }
                    }

                    Text(info?.shortName ?? (state.selectedModel.isEmpty ? "未选择模型" : state.selectedModel))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(info?.id ?? state.selectedModel)

                    Text(info?.id ?? state.selectedModel)
                        .font(Native.monoFont)
                        .foregroundStyle(Native.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        if let info {
                            Tag(text: info.origin.rawValue,
                                tone: info.origin == .local ? .success : .accent)
                            if info.draftPath != nil {
                                Tag(text: "DFlash2 就绪", tone: .success, icon: "bolt.fill")
                            } else if state.catalog.draftRepository(info.id, family: info.family) != nil {
                                Tag(text: "DFlash2 可下载", tone: .neutral)
                            }
                            if info.mmprojPath != nil {
                                Tag(text: "视觉", tone: .accent, icon: "eye")
                            }
                            Tag(text: info.sizeText, tone: .neutral)
                        }
                        if let device = state.stats?.deviceName {
                            Tag(text: device, tone: .neutral, icon: "cpu")
                        }
                        Tag(text: "完全离线", tone: .neutral, icon: "lock")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)

                    HStack(spacing: 8) {
                        Button("重启引擎") { state.restartService() }
                            .disabled(!state.isRunning)
                        Button(state.isRunning ? "停止" : "启动") { state.toggleService() }
                            .disabled(state.runtimeMissing != nil)
                        Menu {
                            ForEach(state.catalog.machine, id: \.id) { model in
                                Button(model.id) { state.applyModel(model.id) }
                            }
                        } label: {
                            Label("切换模型", systemImage: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(maxWidth: 150)
                        .disabled(state.catalog.machine.isEmpty)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(rate > 0 ? String(format: "%.1f", rate) : "0.0")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(rate > 0 ? Native.label : Native.tertiary)
                        Text("TOK/S")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Native.tertiary)
                    }
                    Text("解码速度 · 实时")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)

                    Hairline()
                        .frame(width: 228)
                        .padding(.vertical, 8)

                    HStack(spacing: 0) {
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
                    .frame(width: 228)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(Native.tertiary)
                }
            }
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
                .frame(width: 130)
             )) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", samples.last?.value ?? 0))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tok/s")
                    .font(Native.calloutFont)
                    .foregroundStyle(Native.tertiary)
                Spacer()
                if !samples.isEmpty {
                    Text("峰值 \(String(format: "%.0f", peak)) · 均值 \(String(format: "%.0f", average))")
                        .font(.system(size: 11))
                        .foregroundStyle(Native.tertiary)
                    Tag(text: "实时", tone: .success, icon: "circle.fill")
                }
            }

            if samples.isEmpty {
                EmptyHint(icon: "chart.xyaxis.line",
                          title: "暂无吞吐数据",
                          detail: "启动服务并生成一次回复后，这里会显示实时解码速度")
                    .frame(height: 190)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("时间", sample.at),
                            y: .value("tok/s", sample.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(colors: [Native.accent.opacity(0.22), Native.accent.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom)
                        )

                        LineMark(
                            x: .value("时间", sample.at),
                            y: .value("tok/s", sample.value)
                        )
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Native.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
                .chartYScale(domain: 0...max(peak * 1.15, 10))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(Native.hairline.opacity(0.5))
                        AxisValueLabel(format: .dateTime.minute().second())
                            .font(.system(size: 9))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Native.hairline.opacity(0.5))
                        AxisValueLabel()
                            .font(.system(size: 9))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .frame(height: 190)
            }
        }
    }
}

// MARK: - Metric column

private struct MetricColumn: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            StatTile(label: "预填充",
                     value: state.stats?.prefillTokensPerSecond.map { Format.compact($0) } ?? "—",
                     unit: "tok/s",
                     detail: "引擎 prefill 采样",
                     tint: Native.blue)

            HStack(spacing: 12) {
                StatTile(label: "草稿接受率",
                         value: state.stats?.draftAcceptance.map { String(format: "%.0f", $0 * 100) } ?? "—",
                         unit: "%",
                         detail: "DFlash2 草稿命中比例",
                         badge: state.stats?.draftAcceptance.map { String(format: "%.0f%%", $0 * 100) },
                         tint: Native.purple,
                         progress: state.stats?.draftAcceptance,
                         progressTint: Native.purple)

                StatTile(label: "内存占用",
                         value: state.stats?.memoryBytes.map { Format.bytes($0) } ?? "—",
                         detail: state.stats?.peakMemoryBytes.map { "峰值 \(Format.bytes($0))" },
                         tint: Native.teal,
                         progress: memoryFraction,
                         progressTint: memoryFraction > 0.9 ? Native.red : Native.teal)
            }

            StatTile(label: "上下文窗口",
                     value: state.stats?.maximumContextTokens.map { contextText($0) } ?? "—",
                     unit: "tokens",
                     detail: "传给引擎的最大上下文",
                     tint: Native.orange)

            StatTile(label: "请求",
                     value: "\(state.stats?.requestsCompleted ?? 0)",
                     unit: "完成",
                     detail: "失败 \(state.stats?.requestsFailed ?? 0) · 排队 \(state.stats?.queuedRequests ?? 0)",
                     tint: Native.green)
        }
    }

    private var memoryFraction: Double {
        guard let used = state.stats?.memoryBytes,
              let total = state.stats?.physicalMemoryBytes, total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    private func contextText(_ tokens: Int) -> String {
        if tokens >= 1000 { return String(format: "%.0fK", Double(tokens) / 1000) }
        return "\(tokens)"
    }
}

// MARK: - Runtime details

private struct RuntimeDetails: View {
    @ObservedObject var state: AppState

    var body: some View {
        Card("运行指标",
             subtitle: "引擎与设备信息",
             trailing: AnyView(Tag(text: state.health.label, tone: state.health.tone, icon: "checkmark.seal"))) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 0) {
                        KeyValueRow(label: "引擎", value: "splash \(state.runtimeVersion)", mono: true)
                        Hairline()
                        KeyValueRow(label: "进程",
                                    value: state.stats?.instancePid.map { "pid \($0)" } ?? "未运行",
                                    mono: true)
                        Hairline()
                        KeyValueRow(label: "设备", value: deviceText)
                        Hairline()
                        KeyValueRow(label: "请求",
                                    value: "\(state.stats?.requestsCompleted ?? 0) 完成 · \(state.stats?.requestsFailed ?? 0) 失败")
                    }
                    VStack(spacing: 0) {
                        KeyValueRow(label: "首字延迟",
                                    value: state.stats?.ttftMilliseconds.map { String(format: "%.0f ms", $0) } ?? "—",
                                    detail: "p50",
                                    mono: true)
                        Hairline()
                        KeyValueRow(label: "热状态",
                                    value: state.stats?.thermalText ?? "—",
                                    valueColor: (state.stats?.thermal == nil || state.stats?.thermal == "nominal") ? Native.label : Native.orange)
                        Hairline()
                        KeyValueRow(label: "内存压力",
                                    value: state.stats?.memoryPressureText ?? "—")
                        Hairline()
                        KeyValueRow(label: "解码速度",
                                    value: state.stats?.decodeTokensPerSecond.map { String(format: "平均 %.1f", $0) } ?? "—",
                                    mono: true)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(Native.tertiary)
                    Text("自动刷新 · 1s")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                    Spacer()
                    if let started = state.stats?.startedAt, started > 0 {
                        Text("已运行 \(uptimeText(started))")
                            .font(.system(size: 10))
                            .foregroundStyle(Native.tertiary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var deviceText: String {
        var parts: [String] = []
        if let device = state.stats?.deviceName { parts.append(device) }
        if let cores = state.stats?.gpuCores, cores > 0 { parts.append("\(cores) 核 GPU") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func uptimeText(_ started: Double) -> String {
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
            VStack(alignment: .leading, spacing: 8) {
                Text(state.endpointURL)
                    .font(Native.monoFont)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Native.raised, in: RoundedRectangle(cornerRadius: Native.radiusSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: Native.radiusSmall)
                            .stroke(Native.hairline, lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Button {
                        state.copy(state.endpointURL, label: "接口地址已复制")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)

                    Button {
                        if let url = URL(string: baseURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        Label("打开聊天页", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .disabled(!state.isRunning)

                    Spacer()
                }

                Hairline()

                KeyValueRow(label: "状态", value: state.isReady ? "就绪" : state.startupStage,
                            valueColor: state.isReady ? Native.green : Native.secondary)
                KeyValueRow(label: "模型", value: state.stats?.model ?? state.selectedModel, mono: true)
            }
        }
    }
}
