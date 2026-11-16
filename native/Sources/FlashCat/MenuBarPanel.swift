// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

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
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixel, pixelsHigh: pixel,
                    bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
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
            let dotRect = NSRect(
                x: rect.width - dot - rect.width * 0.03,
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
        path.curve(
            to: point(3.9, 16.9),
            controlPoint1: point(1.2, 12.4),
            controlPoint2: point(2.4, 15.5))
        // 左耳内侧下坡（直线让耳尖保持锐利，和应用图标一致）
        path.line(to: point(7.0, 12.8))
        // 双耳之间的头顶
        path.line(to: point(11.0, 12.8))
        // 右耳内侧上坡
        path.line(to: point(14.1, 16.9))
        // 右耳外侧下坡
        path.curve(
            to: point(16.8, 10.5),
            controlPoint1: point(15.6, 15.5),
            controlPoint2: point(16.8, 12.4))
        path.line(to: point(16.8, 6.9))
        // 右下角
        path.curve(
            to: point(13.2, 2.9),
            controlPoint1: point(16.8, 4.7),
            controlPoint2: point(15.1, 2.9))
        path.line(to: point(4.8, 2.9))
        // 左下角
        path.curve(
            to: point(1.2, 6.9),
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

// MARK: - 菜单栏浮层容器

/// 承载菜单栏卡片的浮层容器：负责圆角、1px 描边、投影与进出场弹簧动画，
/// 并将卡片实际高度同步回 `StatusBarController` 以便锁定顶部锚点。
struct MenuBarPanelContainer: View {
    @ObservedObject var state: AppState
    @ObservedObject var presenter: MenuBarPanelPresenter
    let cardWidth: CGFloat
    let shadowInsets: EdgeInsets
    var onOpenMainWindow: (Page?) -> Void
    var onDismiss: () -> Void
    var onCardHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardShape: RoundedRectangle { DS.rect(14) }

    var body: some View {
        MenuBarPanel(
            state: state,
            onOpenMainWindow: { page in onOpenMainWindow(page) },
            onDismiss: onDismiss
        )
        .frame(width: cardWidth)
        .background(cardShape.fill(DS.canvas))
        .overlay(
            cardShape
                .strokeBorder(DS.line2, lineWidth: 1)
        )
        .clipShape(cardShape)
        .shadow(color: DS.shadow, radius: 18, x: 0, y: 10)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { _, newHeight in
            onCardHeightChange(newHeight)
        }
        .scaleEffect(reduceMotion ? 1 : (presenter.isPresented ? 1 : 0.95), anchor: .top)
        .offset(y: reduceMotion ? 0 : (presenter.isPresented ? 0 : -6))
        .opacity(presenter.isPresented ? 1 : 0)
        .animation(
            reduceMotion
                ? DS.Motion.fade
                : .spring(response: 0.24, dampingFraction: 0.86),
            value: presenter.isPresented
        )
        .padding(shadowInsets)
        .onExitCommand { onDismiss() }
    }
}

// MARK: - 菜单栏面板

/// 点击菜单栏图标弹出的面板：状态、当前模型、接口地址、实时指标与高频操作。
///
/// 设计取向与主界面「精密仪器」一致：面板里不放渐变卡片，改用排版层级 +
/// 发丝线分区，指标放在唯一一块凹槽面上，状态色只出现在状态胶囊和读数上。
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    /// 打开主窗口的出口（可选指定跳转页面）。面板由独立 `NSPanel` 承载，
    /// 不依赖 `\.openWindow` 环境值。
    var onOpenMainWindow: (Page?) -> Void = { page in
        if let page { AppState.shared.section = page }
        MainWindow.show()
    }
    var onDismiss: () -> Void = {}

    @State private var copiedEndpoint = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var hoveringModel = false
    @State private var hoveringEndpoint = false

    private var running: Bool { state.isRunning }
    private var busy: Bool { state.serverState == .starting || state.serverState == .stopping }

    /// 状态色使用控制台调色板，和主界面的状态标签保持一致。
    private var statusTint: Color {
        switch state.serverState {
        case .ready: return DS.ok
        case .starting, .stopping: return DS.warn
        case .failed: return DS.err
        case .stopped: return DS.text3
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
        .animation(DS.Motion.smooth, value: state.serverState)
        .animation(DS.Motion.smooth, value: state.isModelBusy)
        .animation(DS.Motion.smooth, value: state.isSwitchingModel)
        .animation(DS.Motion.smooth, value: sparklinePeak != nil)
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private var divider: some View {
        DSDivider()
    }

    // MARK: 顶部状态行

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                DS.rect(DS.Radius.md)
                    .fill(DS.raised)
                    .overlay(
                        DS.rect(DS.Radius.md)
                            .strokeBorder(DS.line, lineWidth: 1)
                    )
                BrandMark(size: 24, glow: false)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(DS.Font.md.weight(.semibold))
                    .foregroundStyle(DS.text)
                HStack(spacing: 4) {
                    Text(state.activeEngine.displayName)
                    Text("·")
                    Text(state.engineVersion)
                }
                .font(DS.Font.mono(10, weight: .medium))
                .foregroundStyle(DS.text3)
                .lineLimit(1)
            }

            Spacer(minLength: 6)
            DSChip(
                text: state.serverState.rawValue,
                dot: statusTint,
                live: running || busy,
                tint: statusTint
            )
            .contentTransition(.opacity)
        }
    }

    // MARK: 当前模型

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("当前模型")
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                if let info = state.selectedModelInfo {
                    Text(verbatim: info.sizeText)
                        .font(DS.Font.mono(10, weight: .medium))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Button {
                    onOpenMainWindow(.models)
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.t("模型"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(hoveringModel ? DS.text : DS.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        DS.rect(DS.Radius.sm)
                            .fill(hoveringModel ? DS.hover : DS.bg)
                    )
                    .overlay(
                        DS.rect(DS.Radius.sm)
                            .strokeBorder(hoveringModel ? DS.line2 : DS.line, lineWidth: 1)
                    )
                }
                .buttonStyle(DSPressStyle())
                .onHover { value in
                    withAnimation(DS.Motion.snappy) { hoveringModel = value }
                }
                .help(L10n.t("模型"))
            }

            Text(modelTitle)
                .font(DS.Font.lg.weight(.semibold))
                .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
                .help(modelTitle)

            endpointRow
        }
        .padding(12)
        .dsSurface(radius: DS.Radius.lg)
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
            triggerCopyEndpoint()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        copiedEndpoint
                            ? DS.ok
                            : DS.accent.opacity(state.isRunning ? 0.95 : 0.45)
                    )
                Text(state.endpointURL)
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(hoveringEndpoint ? DS.text : DS.text2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if copiedEndpoint {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(L10n.t("已复制"))
                            .font(DS.Font.xs.weight(.medium))
                    }
                    .foregroundStyle(DS.ok)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(hoveringEndpoint ? DS.text2 : DS.text3)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                DS.rect(DS.Radius.md)
                    .fill(hoveringEndpoint ? DS.hover : DS.bg)
            }
            .overlay(
                DS.rect(DS.Radius.md)
                    .strokeBorder(
                        copiedEndpoint
                            ? DS.ok.opacity(0.45)
                            : (hoveringEndpoint ? DS.line3 : DS.line),
                        lineWidth: 1
                    )
            )
            .contentShape(DS.rect(DS.Radius.md))
        }
        .buttonStyle(DSPressStyle(scale: 0.985))
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hoveringEndpoint = value }
        }
        .help(L10n.t("复制接口地址"))
    }

    private func triggerCopyEndpoint() {
        state.copy(state.endpointURL, label: "接口地址已复制")
        copyResetTask?.cancel()
        withAnimation(DS.Motion.snappy) {
            copiedEndpoint = true
        }
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) {
                copiedEndpoint = false
            }
        }
    }

    // MARK: 运行区

    @ViewBuilder
    private var runtimeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isModelBusy {
                // 进程在跑但权重还没就位（启动、切换、加载权重、预热）：给一条
                // 带转圈的生命周期行；下面的读数条保留，只是暂时没有数据。
                if !stageText.isEmpty {
                    NoticeRow(
                        symbol: nil,
                        text: stageText,
                        tint: DS.warn,
                        showsSpinner: true
                    )
                    .transition(.dsRowInsert)
                }
            } else {
                switch state.serverState {
                case .ready:
                    EmptyView()
                case .starting, .stopping:
                    NoticeRow(
                        symbol: nil,
                        text: stageText,
                        tint: DS.warn,
                        showsSpinner: true
                    )
                    .transition(.dsRowInsert)
                case .failed:
                    NoticeRow(
                        symbol: "exclamationmark.triangle.fill",
                        text: state.failureMessage ?? "引擎异常，打开日志查看原因",
                        tint: DS.err,
                        showsSpinner: false,
                        actionLabel: "日志",
                        action: { onOpenMainWindow(.logs) }
                    )
                    .transition(.dsRowInsert)
                case .stopped:
                    // 已停止且没选模型时才提示；正常停止态不再占一行横幅。
                    if state.selectedModel.isEmpty {
                        NoticeRow(
                            symbol: "pause.circle",
                            text: "还没有选择模型，在模型页选一个即可启动",
                            tint: DS.text2,
                            showsSpinner: false
                        )
                        .transition(.dsRowInsert)
                    }
                }
            }

            // 读数条常驻：没有实时数据时显示「—」，面板不会因为停止或加载而少一截。
            MetricStrip(
                decode: state.serverState == .ready ? state.menuBarDecodeReading : .none,
                ttft: state.serverState == .ready ? state.ttftReading : .none,
                prefill: state.serverState == .ready ? state.prefillReading : .none)

            if state.serverState == .ready, let peak = sparklinePeak {
                Sparkline(
                    values: state.recentThroughput(window: 300).map(\.value),
                    peak: peak,
                    tint: DS.accent
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// "启动中 · 预热 · 已等待 3:20". 和灵动岛、概览、命令面板共用 `engineStageText`。
    private var stageText: String { state.engineStageText }

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
                    Label(L10n.t("取消等待"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.secondary, size: .regular))
            } else if running {
                Button {
                    state.stopService()
                } label: {
                    Label(L10n.t("停止服务"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.danger, size: .regular))

                Button {
                    state.restartService()
                } label: {
                    Label(L10n.t("重启服务"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.ds(.secondary, size: .regular))
                .fixedSize()
            } else {
                Button {
                    state.startService()
                } label: {
                    Label(L10n.t("启动服务"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.ds(.primary, size: .regular))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let stats = state.stats {
                Text(Self.countersText(stats))
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            footerButton("主窗口", symbol: "macwindow") { onOpenMainWindow(nil) }
                .help("打开主窗口")
            footerButton("退出", symbol: "power") {
                onDismiss()
                NSApp.terminate(nil)
            }
            .help(L10n.t("退出 flashCat"))
        }
    }

    private func footerButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L10n.t(title), systemImage: symbol)
        }
        .buttonStyle(.ds(.secondary, size: .small))
    }

    private static func countersText(_ stats: ServerStats) -> String {
        var parts = [L10n.format("完成 %lld", stats.requestsCompleted), L10n.format("失败 %lld", stats.requestsFailed)]
        if stats.activeRequests > 0 { parts.append(L10n.format("并发 %lld", stats.activeRequests)) }
        if stats.queuedRequests > 0 { parts.append(L10n.format("排队 %lld", stats.queuedRequests)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 指标条

/// 三列读数：解码速度 / 首字延迟 / 预填充速度。值用等宽数字，列间发丝线分隔。
private struct MetricStrip: View {
    let decode: MetricReading
    let ttft: TTFTReading
    let prefill: MetricReading

    var body: some View {
        HStack(spacing: 0) {
            cell(
                "解码", value: number(decode.value), unit: "tok/s",
                tag: decodeTag, tagTint: decodeTagTint)
            DSDivider(vertical: true)
            cell("首字", value: milliseconds(ttft.milliseconds), unit: "ms")
            DSDivider(vertical: true)
            cell(
                "预填充", value: number(prefill.value), unit: "tok/s",
                tag: prefillTag, tagTint: prefillTagTint)
        }
        .background(DS.bg, in: DS.rect(DS.Radius.md))
        .overlay(
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        )
        // 读数条高度锁死：窗口高度被撑开时它也不跟着变高。
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(
        _ label: String,
        value: String,
        unit: String?,
        tag: String? = nil,
        tagTint: Color = DS.text3
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(L10n.t(label))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                if let tag, value != "—" {
                    Text(tag)
                        .font(DS.Font.mono(8.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(tagTint)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(DS.Font.mono(14.5, weight: .semibold))
                    .foregroundStyle(value == "—" ? DS.text3 : DS.text)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(DS.Motion.snappy, value: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit {
                    Text(unit)
                        .font(DS.Font.mono(9, weight: .medium))
                        .foregroundStyle(DS.text3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 解码格的角标：实时读数标 `LIVE`，退回模型平均时标 `AVG`。
    private var decodeTag: String? {
        switch decode.origin {
        case .gatewayLive, .engineLive: return "LIVE"
        case .gatewayMean, .engineMean: return "AVG"
        default: return nil
        }
    }

    private var decodeTagTint: Color {
        switch decode.origin {
        case .gatewayLive, .engineLive: return DS.accent
        default: return DS.text3
        }
    }

    /// 预填充格的角标：此刻在处理才 `LIVE`，做完的实测值标 `LAST`，累计均值标 `AVG`。
    private var prefillTag: String? {
        switch prefill.origin {
        case .engineLive: return "LIVE"
        case .gatewayLast, .engineLast: return "LAST"
        case .gatewayMean, .engineMean: return "AVG"
        default: return nil
        }
    }

    private var prefillTagTint: Color {
        prefill.origin == .engineLive ? DS.accent : DS.text3
    }

    private func number(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return "\(Int(value.rounded()))"
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
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                Text(L10n.format("峰值 %@ tok/s", Format.compact(peak)))
                    .font(DS.Font.mono(10))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
                            LinearGradient(
                                colors: [tint.opacity(0.22), tint.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom)
                        )
                    }
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(
                        tint.opacity(0.9),
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
            return CGPoint(
                x: CGFloat(index) * step,
                y: size.height * (1 - CGFloat(normalized)) * 0.92 + 1)
        }
    }
}

// MARK: - 单行提示

private struct NoticeRow: View {
    var symbol: String?
    let text: String
    var tint: Color = DS.text2
    var showsSpinner: Bool = false
    var actionLabel: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
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
            }
            Text(L10n.t(text))
                .font(DS.Font.xs)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionLabel, let action {
                Button(action: action) {
                    Text(L10n.t(actionLabel))
                        .font(DS.Font.xs.weight(.medium))
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DS.bg, in: DS.rect(DS.Radius.md))
        .overlay(
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        )
    }
}
