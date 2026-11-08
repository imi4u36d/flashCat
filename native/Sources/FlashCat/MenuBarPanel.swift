import SwiftUI
import AppKit
import FlashCatKit

// MARK: - 菜单栏图标

/// 系统菜单栏里的状态图标：**只画猫头轮廓，不带任何底色**。
///
/// 造型取自应用图标：宽脸颊、尖耳朵的猫头，额头留一道闪电负形。
/// 菜单栏的惯例是单色剪影 + 模板渲染，由系统按菜单栏明暗自动上色，
/// 因此这里用手绘贝塞尔路径而不是 `BrandMark.artwork`（那张 PNG 自带
/// 渐变，缩到 18pt 会变成一个彩色小色块）。
///
///   · 运行中 → 实心猫头 + 闪电镂空
///   · 启动/停止中 → 半透明实心（过渡态）
///   · 已停止 → 描边猫头（闪电同样描边）
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
        // 造型在 18 单位画布里的垂直范围是 2.9…16.9（下巴到耳尖），重心偏上 0.9，
        // 直接铺满会让耳尖顶到菜单栏上沿，看起来比系统图标高一截。
        // 整体下移，让剪影在画布里垂直居中；告警点用绝对坐标，不受影响。
        let glyphRect = rect.offsetBy(dx: 0, dy: -rect.width * 0.05)

        // 模板图只看 alpha，颜色取黑即可。
        let glyph = glyphPath(in: glyphRect)
        let strokeWidth = rect.width * 0.075

        switch state {
        case .ready:
            NSColor.black.setFill()
            glyph.fill()

        case .starting, .stopping:
            // 过渡态：同一形状压暗，读作"正在变化"，不靠动画在菜单栏里闪烁。
            NSColor.black.withAlphaComponent(0.40).setFill()
            glyph.fill()

        case .stopped:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            glyph.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.92).setStroke()
            glyph.stroke()

        case .failed:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            glyph.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.50).setStroke()
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

    /// 猫头 + 额头的闪电。两条子路径用 even-odd 规则合成，
    /// 实心态下闪电是透明镂空，描边态下则和猫头一起被勾出轮廓。
    private static func glyphPath(in rect: NSRect) -> NSBezierPath {
        let path = headPath(in: rect)
        path.append(boltPath(in: rect))
        path.windingRule = .evenOdd
        return path
    }

    /// 猫头剪影：低耳、圆润宽脸颊、底部收圆，缩到 18pt 仍然是一个能认出的猫头。
    /// 单条闭合路径，填充和描边共用，描边时不会出现耳朵接缝。
    private static func headPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        let path = NSBezierPath()
        path.move(to: point(1.2, 6.9))
        path.line(to: point(1.2, 10.5))
        // 左耳外侧上坡，收在尖耳尖上
        path.curve(to: point(3.9, 16.9),
                   controlPoint1: point(1.2, 12.4),
                   controlPoint2: point(2.4, 15.5))
        // 左耳内侧下坡（直线让耳尖保持锐利，和应用图标一致）
        path.line(to: point(7.0, 12.8))
        // 双耳之间的头顶
        path.line(to: point(11.0, 12.8))
        // 右耳内侧上坡
        path.line(to: point(14.1, 16.9))
        // 右耳外侧下坡
        path.curve(to: point(16.8, 10.5),
                   controlPoint1: point(15.6, 15.5),
                   controlPoint2: point(16.8, 12.4))
        path.line(to: point(16.8, 6.9))
        // 右下角
        path.curve(to: point(13.2, 2.9),
                   controlPoint1: point(16.8, 4.7),
                   controlPoint2: point(15.1, 2.9))
        path.line(to: point(4.8, 2.9))
        // 左下角
        path.curve(to: point(1.2, 6.9),
                   controlPoint1: point(2.9, 2.9),
                   controlPoint2: point(1.2, 4.7))
        path.close()
        return path
    }

    /// 额头闪电：与应用图标上的奶油色闪电同向，缩到 18pt 仍能读出来。
    private static func boltPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        let path = NSBezierPath()
        path.move(to: point(10.4, 12.0))
        path.line(to: point(7.9, 8.6))
        path.line(to: point(9.3, 8.6))
        path.line(to: point(8.4, 5.6))
        path.line(to: point(11.0, 9.3))
        path.line(to: point(9.5, 9.3))
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

    /// 取自应用图标的粉橙渐变，只出现在品牌光晕、接口图标和主按钮上。
    private static let brandPink = Console.accent
    private static let brandOrange = Color(console: 0xFF8A4F)
    private static let brandGradient = LinearGradient(
        colors: [brandPink, brandOrange],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var running: Bool { state.isRunning }
    private var busy: Bool { state.serverState == .starting || state.serverState == .stopping }

    /// 状态色使用控制台调色板，和主界面的状态胶囊保持一致。
    private var statusTint: Color {
        switch state.serverState {
        case .ready: return Console.ok
        case .starting, .stopping: return Console.warn
        case .failed: return Console.danger
        case .stopped: return Console.tertiary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider.padding(.top, 11)

            modelCard
                .padding(.top, 12)

            runtimeBlock
                .padding(.top, 10)

            actions
                .padding(.top, 12)
            divider.padding(.top, 12)

            footer
                .padding(.top, 9)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(width: 348)
        .background(alignment: .topLeading) {
            // 顶部一层极淡的粉橙光晕，呼应 app icon；不改变 popover 的系统材质。
            RadialGradient(colors: [Self.brandPink.opacity(0.14), .clear],
                           center: .topLeading,
                           startRadius: 0,
                           endRadius: 190)
                .frame(height: 150)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Console.insetStroke)
            .frame(height: 1)
    }

    // MARK: 顶部状态行

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Self.brandPink.opacity(0.18),
                                                  Self.brandOrange.opacity(0.10)],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                BrandMark(size: 29, glow: false)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Console.text)
                HStack(spacing: 4) {
                    Text(state.activeEngine.displayName)
                    Text("·")
                    Text(state.engineVersion)
                }
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Console.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)
            StatusPill(text: state.serverState.rawValue, tint: statusTint, pulsing: busy)
        }
    }

    // MARK: 当前模型

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("当前模型")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Console.tertiary)
                Spacer(minLength: 4)
                if let info = state.selectedModelInfo {
                    Text(verbatim: info.sizeText)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .lineLimit(1)
                }
            }

            Text(modelTitle)
                .font(.system(size: 16.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(state.selectedModel.isEmpty ? Console.tertiary : Console.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(modelTitle)

            endpointRow
        }
        .padding(12)
        .consoleCardSurface()
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
                    .foregroundStyle(Self.brandPink.opacity(state.isRunning ? 0.95 : 0.5))
                Text(state.endpointURL)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Console.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Console.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Console.insetStroke, lineWidth: 0.8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plainHit)
        .help("点击复制接口地址")
    }

    // MARK: 运行区

    @ViewBuilder
    private var runtimeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isModelBusy {
                // 进程在跑但权重还没就位（启动、切换、加载权重、预热）：给一条
                // 带转圈的生命周期行；下面的读数条保留，只是暂时没有数据。
                NoticeRow(symbol: nil,
                          text: stageText,
                          tint: Console.warn,
                          showsSpinner: true)
            } else {
                switch state.serverState {
                case .ready:
                    EmptyView()
                case .starting, .stopping:
                    NoticeRow(symbol: nil,
                              text: stageText,
                              tint: Console.warn,
                              showsSpinner: true)
                case .failed:
                    NoticeRow(symbol: "exclamationmark.triangle.fill",
                              text: state.failureMessage ?? "引擎异常，打开日志查看原因",
                              tint: Console.danger,
                              showsSpinner: false)
                case .stopped:
                    // 已停止且没选模型时才提示；正常停止态不再占一行横幅。
                    if state.selectedModel.isEmpty {
                        NoticeRow(symbol: "pause.circle",
                                  text: "还没有选择模型，在模型页选一个即可启动",
                                  tint: Console.secondary,
                                  showsSpinner: false)
                    }
                }
            }

            // 读数条常驻：没有实时数据时显示「—」，面板不会因为停止或加载而少一截。
            MetricStrip(stats: state.serverState == .ready ? state.stats : nil,
                        rate: currentRate)
            if state.serverState == .ready, let peak = sparklinePeak {
                Sparkline(values: state.recentThroughput(window: 300).map(\.value),
                          peak: peak,
                          tint: Self.brandPink)
            }
        }
    }

    /// "启动中 · 预热 · 已等待 3:20". 和灵动岛、概览共用 `engineStageText`：
    /// 三个地方的措辞和秒数以前是三份拷贝，改一处就漏两处（灵动岛的计时停下时，
    /// 菜单栏还在按另一套规则算）。
    private var stageText: String { state.engineStageText }

    /// 菜单栏没有角标位，所以只显示真正的当前速度；网关 linger 里的
    /// 上一请求均值只留在概览（那里有 LAST 角标）。
    private var currentRate: Double? {
        guard state.serverState == .ready else { return nil }
        switch state.speedOrigin {
        case .gatewayLive, .engineLive: return state.totalDecodeRate
        case .gatewayLast, .none: return nil
        }
    }

    private var sparklinePeak: Double? {
        let samples = state.recentThroughput(window: 300).map(\.value)
        guard samples.count > 2, let peak = samples.max(), peak > 0 else { return nil }
        return peak
    }

    // MARK: 操作

    private var actions: some View {
        HStack(spacing: 8) {
            if state.isSwitchingModel {
                // 切换中留一条退路：引擎继续在后台加载，界面不用只能死等。
                Button {
                    state.abortModelSwitch()
                } label: {
                    Label("取消等待", systemImage: "xmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Console.text)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Capsule().fill(Console.inset))
                        .overlay(Capsule().strokeBorder(Console.insetStroke, lineWidth: 0.8))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            } else {
                Button {
                    running ? state.stopService() : state.startService()
                } label: {
                    Label(L10n.t(running ? "停止服务" : "启动服务"),
                          systemImage: running ? "stop.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(running ? Console.danger : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if running {
                                Capsule()
                                    .fill(Console.danger.opacity(0.10))
                                    .overlay(Capsule().strokeBorder(Console.danger.opacity(0.24),
                                                                   lineWidth: 0.8))
                            } else {
                                Capsule()
                                    .fill(Self.brandGradient)
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.18),
                                                                   lineWidth: 0.8))
                                    .shadow(color: Self.brandPink.opacity(0.30), radius: 8, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plainHit)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let stats = state.stats {
                Text(Self.countersText(stats))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            footerButton("主窗口", symbol: "macwindow") { onOpenMainWindow() }
                .help("打开主窗口")
            footerButton("退出", symbol: "power") { NSApp.terminate(nil) }
                .help("退出 flashCat")
        }
    }

    private func footerButton(_ title: String,
                              symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.t(title), systemImage: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Console.secondary)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(Console.inset))
                .overlay(Capsule().strokeBorder(Console.insetStroke, lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plainHit)
    }

    private static func countersText(_ stats: ServerStats) -> String {
        var parts = [L10n.format("完成 %lld", stats.requestsCompleted), L10n.format("失败 %lld", stats.requestsFailed)]
        if stats.activeRequests > 0 { parts.append(L10n.format("并发 %lld", stats.activeRequests)) }
        if stats.queuedRequests > 0 { parts.append(L10n.format("排队 %lld", stats.queuedRequests)) }
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
            Text(L10n.t(text))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.8))
        .fixedSize()
    }
}

// MARK: - 指标条

/// 三列读数：解码速度 / 首字延迟 / 内存占用。值用等宽数字，列间发丝线分隔。
private struct MetricStrip: View {
    let stats: ServerStats?
    /// 与概览、吞吐曲线同源（网关按请求聚合）；没有当前速度时显示「—」。
    let rate: Double?

    var body: some View {
        HStack(spacing: 0) {
            cell("解码", value(rate.map { Format.compact($0) }), unit: "tok/s")
            divider
            cell("首字", value(stats?.ttftMilliseconds.map { "\(Int($0))" }), unit: "ms")
            divider
            cell("内存", value(stats?.memoryBytes.map { Format.bytes($0) }), unit: nil)
        }
        .background(Console.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Console.insetStroke, lineWidth: 0.8)
        )
        // 读数条高度锁死：窗口高度被撑开时它也不跟着变高。
        .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View {
        Rectangle()
            .fill(Console.insetStroke)
            .frame(width: 1)
    }

    private func cell(_ label: String, _ value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.t(label))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Console.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Console.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
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
                    .foregroundStyle(Console.tertiary)
                Spacer(minLength: 4)
                Text(L10n.format("峰值 %@ tok/s", Format.compact(peak)))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Console.tertiary)
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
    var tint: Color = Console.secondary
    var showsSpinner: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
                    .scaleEffect(0.68)
                    .frame(width: 12, height: 12)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 1)
            }
            Text(L10n.t(text))
                .font(.system(size: 11.5))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Console.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Console.insetStroke, lineWidth: 0.8)
        )
    }
}
