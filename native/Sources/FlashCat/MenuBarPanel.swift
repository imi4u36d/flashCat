import SwiftUI
import AppKit
import FlashCatKit

// MARK: - 菜单栏图标

/// 系统菜单栏里的状态图标：**只画猫头轮廓，不带任何底色**。
///
/// 之前这里直接绘制 `BrandMark.artwork`（应用图标原画），那张 PNG 自带
/// 渐变圆角方块，缩到 18pt 放进菜单栏就成了一个彩色小色块 —— 也就是
/// 看起来"图标还有背景"的原因。菜单栏的惯例是单色剪影 + 模板渲染，
/// 由系统按菜单栏明暗自动上色，因此这里改成手绘贝塞尔路径：
///
///   · 运行中 → 实心猫头
///   · 启动/停止中 → 半透明实心（过渡态）
///   · 已停止 → 描边猫头
///   · 异常 → 描边猫头 + 右下角小圆点（告警标记）
///
/// `isTemplate = true` 是关键：系统只取 alpha 通道当蒙版，浅色菜单栏画黑、
/// 深色菜单栏画白，永远不会出现白底或彩底。
///
/// 另外注意：状态栏项的按钮活在一个内部 window 里，**不要**把主窗口的
/// `appearance` / 标题栏设置套到它身上（见 `AppDelegate.configure`）。一旦那个
/// window 被强制成浅色外观，系统会在图标背后补一块浅色底板，看起来又像"图标有背景"。
enum MenuBarIcon {
    static let pointSize: CGFloat = 18

    @MainActor private static var cache: [ServerState: NSImage] = [:]

    @MainActor
    static func statusImage(state: ServerState) -> NSImage {
        if let cached = cache[state] { return cached }

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [2.0, 3.0] {
            let pixel = Int(pointSize * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: pixel, pixelsHigh: pixel,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: pointSize, height: pointSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(state: state, in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }

    @MainActor
    private static func draw(state: ServerState, in rect: NSRect) {
        // 模板图只看 alpha，颜色取黑即可。
        let glyph = headPath(in: rect)
        let strokeWidth = rect.width * 0.082

        switch state {
        case .ready:
            NSColor.black.setFill()
            glyph.fill()

        case .starting, .stopping:
            // 过渡态：同一形状压暗，读作"正在变化"，不靠动画在菜单栏里闪烁。
            NSColor.black.withAlphaComponent(0.42).setFill()
            glyph.fill()

        case .stopped:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.92).setStroke()
            glyph.stroke()

        case .failed:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.5).setStroke()
            glyph.stroke()

            // 右下角告警点：先挖出一圈透明间隙，点才不会和描边粘在一起。
            let dot = rect.width * 0.27
            let dotRect = NSRect(x: rect.width - dot - rect.width * 0.03,
                                 y: rect.height * 0.03,
                                 width: dot, height: dot)
            let gap = dotRect.insetBy(dx: -rect.width * 0.075, dy: -rect.width * 0.075)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: gap).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    /// 猫头剪影：低耳、圆角、底部收圆，缩到 18pt 仍然是一个能认出的猫头。
    /// 单条闭合路径，填充和描边共用，描边时不会出现耳朵接缝。
    private static func headPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        let path = NSBezierPath()
        path.move(to: point(1.4, 6.8))
        path.line(to: point(1.4, 10.3))
        // 左耳外侧上坡
        path.curve(to: point(4.1, 16.3),
                   controlPoint1: point(1.4, 12.1),
                   controlPoint2: point(2.4, 15.1))
        // 左耳内侧下坡
        path.curve(to: point(6.9, 12.7),
                   controlPoint1: point(5.1, 16.9),
                   controlPoint2: point(6.4, 14.5))
        // 双耳之间的头顶
        path.line(to: point(11.1, 12.7))
        // 右耳内侧上坡
        path.curve(to: point(13.9, 16.3),
                   controlPoint1: point(11.6, 14.5),
                   controlPoint2: point(12.9, 16.9))
        // 右耳外侧下坡
        path.curve(to: point(16.6, 10.3),
                   controlPoint1: point(15.6, 15.1),
                   controlPoint2: point(16.6, 12.1))
        path.line(to: point(16.6, 6.8))
        // 右下角
        path.curve(to: point(13.1, 3.2),
                   controlPoint1: point(16.6, 4.8),
                   controlPoint2: point(15.1, 3.2))
        path.line(to: point(4.9, 3.2))
        // 左下角
        path.curve(to: point(1.4, 6.8),
                   controlPoint1: point(2.9, 3.2),
                   controlPoint2: point(1.4, 4.8))
        path.close()
        return path
    }
}

// MARK: - 菜单栏面板

/// 点击菜单栏图标弹出的面板：状态、当前模型、接口地址、实时指标与高频操作。
///
/// 设计取向与主界面「精密仪器」一致：面板里不放渐变卡片，改用排版层级 +
/// 发丝线分区，指标放在唯一一块凹槽面上，状态色只出现在状态胶囊和读数上。
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    /// 打开主窗口的出口。面板既可能挂在 SwiftUI 场景里，也可能被 NSPopover
    /// 承载，所以不依赖 `\.openWindow` 环境值。
    var onOpenMainWindow: () -> Void = { MainWindow.show() }

    private var running: Bool { state.isRunning }
    private var accent: Color { statusColor(state.serverState) }
    private var busy: Bool { state.serverState == .starting || state.serverState == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.top, 11)

            modelBlock
                .padding(.top, 12)

            runtimeBlock
                .padding(.top, 12)

            actions
                .padding(.top, 12)
            Hairline().padding(.top, 11)

            footer
                .padding(.top, 9)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .frame(width: 336)
    }

    // MARK: 顶部状态行

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 21, glow: false)
            Text("flashCat")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Native.label)
            Text(verbatim: "\(state.activeEngine.displayName) \(state.engineVersion)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            StatusPill(text: state.serverState.rawValue, tint: accent, pulsing: busy)
        }
    }

    // MARK: 当前模型

    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("当前模型")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 4)
                if let info = state.selectedModelInfo {
                    Text(verbatim: info.sizeText)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Native.tertiary)
                        .lineLimit(1)
                }
            }

            Text(modelTitle)
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(state.selectedModel.isEmpty ? Native.tertiary : Native.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(modelTitle)

            endpointRow
        }
    }

    private var modelTitle: String {
        if let served = state.stats?.model, !served.isEmpty { return Self.displayName(served) }
        if let info = state.selectedModelInfo { return info.shortName }
        return state.selectedModel.isEmpty ? "未选择模型" : Self.displayName(state.selectedModel)
    }

    /// 引擎有时把 Hugging Face 缓存目录名当模型名报上来，形如
    /// `models--Org--Repo`。面板上只留仓库名，读起来才是一个模型。
    private static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("models--") { name.removeFirst("models--".count) }
        let parts = name.components(separatedBy: "--").filter { !$0.isEmpty }
        if let last = parts.last { name = last }
        return name.isEmpty ? raw : name
    }

    private var endpointRow: some View {
        Button {
            state.copy(state.endpointURL, label: "接口地址已复制")
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(state.isRunning ? 0.95 : 0.5))
                Text(state.endpointURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(Native.recess, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Native.hairline, lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点击复制接口地址")
    }

    // MARK: 运行区

    @ViewBuilder
    private var runtimeBlock: some View {
        switch state.serverState {
        case .ready:
            VStack(alignment: .leading, spacing: 8) {
                MetricStrip(stats: state.stats)
                if let peak = sparklinePeak {
                    Sparkline(values: state.recentThroughput(window: 300).map(\.value),
                              peak: peak,
                              tint: accent)
                }
            }
        case .starting, .stopping:
            NoticeRow(symbol: nil,
                      text: stageText,
                      tint: Native.yellow,
                      showsSpinner: true)
        case .failed:
            NoticeRow(symbol: "exclamationmark.triangle.fill",
                      text: state.failureMessage ?? "引擎异常，打开日志查看原因",
                      tint: Native.red,
                      showsSpinner: false)
        case .stopped:
            // 已停止且没选模型时才提示；正常停止态不再占一行横幅。
            if state.selectedModel.isEmpty {
                NoticeRow(symbol: "pause.circle",
                          text: "还没有选择模型，在模型页选一个即可启动",
                          tint: Native.secondary,
                          showsSpinner: false)
            }
        }
    }

    /// "启动中 · 预热 · 已等待 3:20". The state name is only followed by a stage
    /// that says something it does not — never as 「启动中 · 启动中」 — and a
    /// start always carries its elapsed time, because the engine can spend
    /// minutes warming up without printing a line.
    private var stageText: String {
        if state.isSwitchingModel {
            return state.switchStage.isEmpty ? "切换中" : "切换中 · \(state.switchStage)"
        }
        var parts = [state.serverState.rawValue]
        let stage = state.startupStage
        if !stage.isEmpty, stage != state.serverState.rawValue, stage != "就绪" {
            parts.append(stage)
        }
        if state.serverState == .starting {
            parts.append("已等待 " + Self.clock(state.startupSeconds))
        }
        return parts.joined(separator: " · ")
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var sparklinePeak: Double? {
        let samples = state.recentThroughput(window: 300).map(\.value)
        guard samples.count > 2, let peak = samples.max(), peak > 0 else { return nil }
        return peak
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                running ? state.stopService() : state.startService()
            } label: {
                Label(running ? "停止服务" : "启动服务",
                      systemImage: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(running ? .arcadeGlass : .arcadeAccent)
            .disabled(state.isSwitchingModel)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let stats = state.stats {
                Text(Self.countersText(stats))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出 flashCat", systemImage: "power")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Native.overlay(0.10), in: Capsule())
                    .overlay(Capsule().stroke(Native.overlay(0.14), lineWidth: 0.8))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("退出 flashCat")
        }
    }

    private static func countersText(_ stats: ServerStats) -> String {
        var parts = ["完成 \(stats.requestsCompleted)", "失败 \(stats.requestsFailed)"]
        if stats.activeRequests > 0 { parts.append("并发 \(stats.activeRequests)") }
        if stats.queuedRequests > 0 { parts.append("排队 \(stats.queuedRequests)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 状态胶囊

private struct StatusPill: View {
    let text: String
    let tint: Color
    var pulsing: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(pulsing ? 0.9 : 0.45),
                        radius: pulsing ? 4 : 0)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - 指标条

/// 三列读数：解码速度 / 首字延迟 / 内存占用。值用等宽数字，列间发丝线分隔。
private struct MetricStrip: View {
    let stats: ServerStats?

    var body: some View {
        HStack(spacing: 0) {
            cell("解码", value(stats?.decodeTokensPerSecond.map { Format.compact($0) }), unit: "tok/s")
            VHairline()
            cell("首字", value(stats?.ttftMilliseconds.map { "\(Int($0))" }), unit: "ms")
            VHairline()
            cell("内存", value(stats?.memoryBytes.map { Format.bytes($0) }), unit: nil)
        }
        .background(Native.recess, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Native.hairline, lineWidth: 0.8)
        )
        // 读数条高度锁死：窗口高度被撑开时它也不跟着变高。
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ label: String, _ value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Native.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Native.label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Native.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func value(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        return raw
    }
}

// MARK: - 吞吐曲线

/// 近 5 分钟解码速度：一条折线 + 渐隐面积，只在有足够样本时出现。
private struct Sparkline: View {
    let values: [Double]
    let peak: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("近 5 分钟吞吐")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
                Spacer(minLength: 4)
                Text(verbatim: "峰值 \(Format.compact(peak)) tok/s")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Native.tertiary)
            }
            GeometryReader { proxy in
                let size = proxy.size
                let maxValue = max(peak, 1)
                let points = points(in: size, maxValue: maxValue)

                ZStack(alignment: .bottomLeading) {
                    if let first = points.first, let last = points.last {
                        Path { path in
                            path.move(to: CGPoint(x: first.x, y: size.height))
                            path.addLine(to: first)
                            for point in points.dropFirst() { path.addLine(to: point) }
                            path.addLine(to: CGPoint(x: last.x, y: size.height))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.01)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                    }
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint.opacity(0.9),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 26)
        }
    }

    private func points(in size: CGSize, maxValue: Double) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = min(max(value / maxValue, 0), 1)
            return CGPoint(x: CGFloat(index) * step,
                           y: size.height * (1 - CGFloat(normalized)) * 0.92 + 1)
        }
    }
}

// MARK: - 单行提示

private struct NoticeRow: View {
    var symbol: String?
    let text: String
    var tint: Color = Native.secondary
    var showsSpinner: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.68)
                    .frame(width: 12, height: 12)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Native.recess, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Native.hairline, lineWidth: 0.8)
        )
    }
}
