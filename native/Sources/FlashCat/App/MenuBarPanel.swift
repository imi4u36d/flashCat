// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
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

/// 承载菜单栏卡片的浮层容器：负责玻璃底、1px 高光描边、状态光晕、投影与
/// 进出场弹簧动画，并将卡片实际高度同步回 `StatusBarController` 以便锁定顶部锚点。
///
/// 面板背后没有主窗口的极光壁纸，只有桌面，所以底色由「高不透明度面板色 +
/// 顶部高光 + 状态光晕」叠出来，而不是系统材质：应用内统一禁用材质模糊
/// （`NativeUITests` 有源码扫描守卫），玻璃感交给分层色、发丝边和投影，
/// 纯白 / 纯黑两副皮肤则换成实色。
struct MenuBarPanelContainer: View {
    @ObservedObject var state: AppState
    @ObservedObject var presenter: MenuBarPanelPresenter
    let cardWidth: CGFloat
    let shadowInsets: EdgeInsets
    var onOpenMainWindow: (Page?) -> Void
    var onDismiss: () -> Void
    var onCardHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardShape: RoundedRectangle { DS.rect(DS.Radius.window) }

    var body: some View {
        MenuBarPanel(
            state: state,
            isActive: presenter.isPresented,
            onOpenMainWindow: { page in onOpenMainWindow(page) },
            onDismiss: onDismiss
        )
        .frame(width: cardWidth)
        .background {
            ZStack(alignment: .top) {
                cardShape.fill(DS.panelFill)
                LinearGradient(
                    colors: [DS.glassSpecular.opacity(0.26), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 86)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                RadialGradient(
                    colors: [state.serverState.panelTint.opacity(0.16), .clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 132
                )
                .frame(height: 132)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        }
        .clipShape(cardShape)
        .overlay(
            cardShape.strokeBorder(
                LinearGradient(
                    colors: [DS.glassSpecular, DS.glassBorder],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 1)
        )
        .shadow(color: DS.glassShadow, radius: 24, x: 0, y: 12)
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

// MARK: - 状态色

private extension ServerState {
    /// 状态色只出现在状态胶囊、告警卡和顶部一层很淡的环境光里。
    var panelTint: Color {
        switch self {
        case .ready: return DS.ok
        case .starting, .stopping: return DS.accent
        case .failed: return DS.err
        case .stopped: return DS.text3
        }
    }
}

// MARK: - 菜单栏面板

/// 点击菜单栏图标弹出的面板：状态、当前模型、接口地址、实时指标与高频操作。
///
/// 布局按 Liquid Glass 高保真稿重排：顶部是应用图标 + 状态胶囊，中间一块凹槽
/// 模型卡（含内联模型选择器与接口地址），异常时插入诊断卡，下面是三格遥测与
/// 统一内存条，最后是主动作与底栏。所有表面都从 `DS` 取色，四副皮肤共用一套
/// 结构；数字保持等宽，状态色只表达状态，不做装饰。
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    /// 面板是否展开。收起时把内联选择器、日志和待确认切换清掉，
    /// 下次点开菜单栏图标回到干净的首屏。
    var isActive: Bool = true
    /// 打开主窗口的出口（可选指定跳转页面）。面板由独立 `NSPanel` 承载，
    /// 不依赖 `\.openWindow` 环境值。
    var onOpenMainWindow: (Page?) -> Void = { page in
        if let page { AppState.shared.section = page }
        MainWindow.show()
    }
    var onDismiss: () -> Void = {}

    @State private var copiedEndpoint = false
    @State private var copiedLog = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var logCopyResetTask: Task<Void, Never>?
    @State private var hoveringEndpoint = false
    @State private var modelPickerOpen = false
    @State private var logsOpen = false
    @State private var pendingSwitch: String?

    private var running: Bool { state.isRunning }
    private var busy: Bool { state.serverState == .starting || state.serverState == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            modelCard

            if state.serverState == .failed {
                failureCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if state.serverState == .stopped, state.selectedModel.isEmpty, !state.isModelBusy {
                emptyModelNotice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            telemetryCard

            if let pendingSwitch {
                switchConfirmCard(pendingSwitch)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            actionRow

            VStack(spacing: 9) {
                DSDivider()
                footer
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .animation(DS.Motion.smooth, value: state.serverState)
        .animation(DS.Motion.smooth, value: state.isModelBusy)
        .animation(DS.Motion.smooth, value: state.isSwitchingModel)
        .animation(DS.Motion.smooth, value: state.switchingModel)
        .animation(DS.Motion.smooth, value: state.selectedModel)
        .animation(DS.Motion.smooth, value: modelPickerOpen)
        .animation(DS.Motion.smooth, value: logsOpen)
        .animation(DS.Motion.smooth, value: pendingSwitch)
        .onChange(of: state.serverState) { _, newValue in
            // 异常卡消失后把展开的日志收回去；下次异常默认是收起状态。
            if newValue != .failed { logsOpen = false }
        }
        .onChange(of: isActive) { _, active in
            guard !active else { return }
            modelPickerOpen = false
            logsOpen = false
            pendingSwitch = nil
        }
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
            logCopyResetTask?.cancel()
            logCopyResetTask = nil
        }
    }

    // MARK: 顶部状态行

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 38, glow: false)
                .shadow(color: DS.glassShadow.opacity(0.55), radius: 3, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "flashCat")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.text)
                Text(verbatim: "\(state.activeEngine.displayName) · \(state.engineVersion)")
                    .font(DS.Font.mono(10.5, weight: .medium))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)
            PanelStatusPill(status: state.serverState, tint: state.serverState.panelTint)
        }
    }

    // MARK: 当前模型

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.t("当前模型"))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                Spacer(minLength: 4)
                PanelMiniPill(
                    title: "切换模型",
                    symbol: "chevron.down",
                    rotating: modelPickerOpen
                ) {
                    withAnimation(DS.Motion.smooth) { modelPickerOpen.toggle() }
                }
                PanelMiniPill(title: "模型", symbol: "arrow.up.right") {
                    onOpenMainWindow(.models)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: modelTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                    .help(modelTitle)

                if !modelBadges.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(modelBadges) { badge in
                            badgeView(badge)
                        }
                    }
                }
            }

            if modelPickerOpen {
                modelPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            endpointBar
        }
        .padding(11)
        .background(DS.rect(DS.Radius.card).fill(Color.adaptiveOverlay(0.05)))
        .overlay(
            DS.rect(DS.Radius.card)
                .strokeBorder(DS.line, lineWidth: 1)
        )
    }

    private func badgeView(_ badge: PanelBadge) -> some View {
        Text(verbatim: badge.text)
            .font(DS.Font.mono(9.5, weight: badge.tinted ? .semibold : .medium))
            .foregroundStyle(badge.tinted ? DS.accent : DS.text2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(
                DS.rect(5)
                    .fill(badge.tinted ? DS.accentSoft : DS.bg)
            )
            .overlay(
                DS.rect(5)
                    .strokeBorder(
                        badge.tinted ? DS.accent.opacity(0.22) : DS.line,
                        lineWidth: 1)
            )
    }

    private var modelTitle: String {
        if state.isRunning, !state.isSwitchingModel,
            let served = state.stats?.model, !served.isEmpty
        {
            return state.shortModelName(served)
        }
        if !state.selectedModel.isEmpty {
            return state.shortModelName(state.selectedModel)
        }
        return L10n.t("未选择模型")
    }

    /// 模型卡上的两个小角标：量化（或来源）+ 上下文窗口。
    /// 没装引擎、也没选模型时返回空数组，卡面只留一行「未选择模型」。
    private var modelBadges: [PanelBadge] {
        var badges: [PanelBadge] = []
        if !state.selectedModel.isEmpty {
            if let quantization =
                state.selectedModelInfo?.quantization
                ?? ModelQuantization.detect(in: state.selectedModel)
            {
                badges.append(PanelBadge(text: quantization, tinted: true))
            } else if let origin = state.selectedModelInfo?.origin {
                badges.append(PanelBadge(text: L10n.t(origin.rawValue), tinted: true))
            }
        }
        if let tokens = contextTokens {
            badges.append(PanelBadge(text: Format.tokensShort(tokens), tinted: false))
        }
        return badges
    }

    private var contextTokens: Int? {
        if let value = state.stats?.maximumContextTokens, value > 0 { return value }
        if let value = state.engineModels()
            .first(where: { $0.id == state.selectedModel })?
            .maximumContextTokens,
            value > 0
        {
            return value
        }
        if let value = state.contextWindowTokens, value > 0 { return value }
        return nil
    }

    // MARK: 内联模型选择器

    private struct PanelModelOption: Identifiable {
        let id: String
        let model: EngineModel
        let engine: EngineID
        let engineTag: String?
    }

    private var modelOptions: [PanelModelOption] {
        let engines = ([state.activeEngine] + EngineCatalog.allIDs.filter { $0 != state.activeEngine })
            .filter { state.engineIsInstalled($0) }
        let showsEngineTags = engines.count > 1
        return engines.flatMap { engine in
            state.engineModels(for: engine)
                .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                .map { model in
                    PanelModelOption(
                        id: "\(engine.rawValue)|\(model.id)",
                        model: model,
                        engine: engine,
                        engineTag: showsEngineTags && engine != state.activeEngine
                            ? engine.displayName
                            : nil)
                }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSDivider()

            if modelOptions.isEmpty {
                Text(L10n.t("暂无可用模型"))
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else if modelOptions.count <= 6 {
                // 六行以内直接铺开，不套滚动视图：面板高度随内容长，少一层
                // 量高度的布局。超过六行才收进 204pt 的滚动区。
                modelOptionList
            } else {
                ScrollView { modelOptionList }
                    .frame(height: 204)
            }
        }
    }

    private var modelOptionList: some View {
        VStack(spacing: 2) {
            ForEach(modelOptions) { option in
                PanelModelRow(
                    name: state.shortModelName(option.model.id),
                    engineTag: option.engineTag,
                    sizeText: option.model.bytes.map { Format.size($0) },
                    selected: option.model.id == state.selectedModel
                        && option.engine == state.activeEngine,
                    switching: option.model.id == state.switchingModel
                        && option.engine == state.activeEngine,
                    stage: option.model.id == state.switchingModel
                        ? state.switchStage
                        : "",
                    disabled: state.generating
                ) {
                    choose(option)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func choose(_ option: PanelModelOption) {
        let target = option.model.id
        if option.engine != state.activeEngine {
            state.applyModelFromAnyEngine(target, engine: option.engine)
            withAnimation(DS.Motion.smooth) { modelPickerOpen = false }
            return
        }
        guard target != state.selectedModel else {
            withAnimation(DS.Motion.smooth) { modelPickerOpen = false }
            return
        }
        if EngineModelSelection.needsConfirmation(
            isRunning: state.isRunning,
            current: state.selectedModel,
            target: target)
        {
            withAnimation(DS.Motion.smooth) {
                modelPickerOpen = false
                pendingSwitch = target
            }
        } else {
            state.applyModel(target)
            withAnimation(DS.Motion.smooth) { modelPickerOpen = false }
        }
    }

    private func switchConfirmCard(_ target: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.warn)
                    .padding(.top, 0.5)
                Text(
                    L10n.format(
                        "将停止 %@ 并加载 %@，切换期间引擎暂时无法应答。",
                        state.shortModelName(state.selectedModel),
                        state.shortModelName(target))
                )
                .font(DS.Font.xs)
                .foregroundStyle(DS.text2)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 7) {
                Spacer(minLength: 0)
                PanelButton(title: "取消", kind: .glass, height: 30) {
                    withAnimation(DS.Motion.smooth) { pendingSwitch = nil }
                }
                PanelButton(title: "停止并切换", kind: .danger, height: 30) {
                    state.applyModelConfirmed(target)
                    withAnimation(DS.Motion.smooth) { pendingSwitch = nil }
                }
            }
        }
        .padding(10)
        .background(DS.rect(DS.Radius.lg).fill(DS.warn.opacity(0.08)))
        .overlay(DS.rect(DS.Radius.lg).strokeBorder(DS.warn.opacity(0.22), lineWidth: 1))
    }

    // MARK: 接口地址

    private var endpointBar: some View {
        Button {
            triggerCopyEndpoint()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        copiedEndpoint
                            ? DS.ok
                            : DS.accent.opacity(running ? 0.95 : 0.45)
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
                            : (hoveringEndpoint ? DS.line2 : DS.line),
                        lineWidth: 1)
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
        withAnimation(DS.Motion.snappy) { copiedEndpoint = true }
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) { copiedEndpoint = false }
        }
    }

    // MARK: 异常诊断

    private var failureTitle: String {
        L10n.t(state.failureMessage ?? "引擎异常，打开日志查看原因")
    }

    /// `SIGKILL · 被系统强制终止…`。退出码 / 信号是 Core 在进程退出那一刻
    /// 留下的结构化诊断，不是从失败文案里抠出来的。
    private var failureDetail: String? {
        guard let diagnostic = state.engineExitDiagnostic,
            let name = diagnostic.signalName
        else { return nil }
        guard let summary = signalSummary(diagnostic.code) else { return name }
        return "\(name) · \(summary)"
    }

    private func signalSummary(_ code: Int32) -> String? {
        switch code {
        case 2, 15: return L10n.t("收到终止信号")
        case 9: return L10n.t("被系统强制终止，通常是统一内存不足")
        case 11: return L10n.t("访问了非法内存地址")
        case 6: return L10n.t("进程自行中止，可能触发了断言")
        case 10: return L10n.t("内存访问异常")
        case 4: return L10n.t("执行了非法指令")
        default: return nil
        }
    }

    private var failureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.err)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: failureTitle)
                        .font(DS.Font.sm.weight(.semibold))
                        .foregroundStyle(DS.dangerText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = failureDetail {
                        Text(verbatim: detail)
                            .font(DS.Font.mono(9.5, weight: .medium))
                            .foregroundStyle(DS.dangerText.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                PanelMiniPill(title: logsOpen ? "收起" : "日志") {
                    withAnimation(DS.Motion.smooth) { logsOpen.toggle() }
                }
            }

            if logsOpen {
                logViewer
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(DS.rect(DS.Radius.lg).fill(DS.err.opacity(0.075)))
        .overlay(DS.rect(DS.Radius.lg).strokeBorder(DS.err.opacity(0.22), lineWidth: 1))
    }

    private var logTail: [LogLine] {
        Array(state.logs.suffix(4))
    }

    /// 复制的范围比可见的 4 行宽一些：异常卡里只放得下最关键的尾巴，
    /// 粘到问题单里时读者通常还想带上前面几行上下文。
    private var logCopyText: String {
        state.logs.suffix(20)
            .map { "\($0.clockText) \($0.text)" }
            .joined(separator: "\n")
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if logTail.isEmpty {
                        Text(verbatim: "—")
                            .font(DS.Font.mono(9))
                            .foregroundStyle(DS.text3)
                    } else {
                        ForEach(logTail) { line in
                            Text(verbatim: "\(line.clockText) \(line.text)")
                                .font(DS.Font.mono(9))
                                .foregroundStyle(
                                    line.level == .error
                                        ? DS.err.opacity(0.90)
                                        : DS.text2
                                )
                                .fixedSize()
                        }
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
            }
            .frame(height: 60, alignment: .leading)
            .background(DS.rect(DS.Radius.sm).fill(Color.adaptiveOverlay(0.06)))
            .overlay(
                DS.rect(DS.Radius.sm)
                    .strokeBorder(DS.err.opacity(0.12), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button {
                    triggerCopyLog()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedLog ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L10n.t(copiedLog ? "已复制" : "复制日志"))
                            .font(DS.Font.xs.weight(.medium))
                    }
                    .foregroundStyle(copiedLog ? DS.ok : DS.text2)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Button {
                    onOpenMainWindow(.logs)
                } label: {
                    HStack(spacing: 2) {
                        Text(L10n.t("查看日志"))
                            .font(DS.Font.xs.weight(.medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(DS.text2)
                }
                .buttonStyle(.plain)
                .help(L10n.t("打开主窗口"))
            }
            .padding(.horizontal, 2)
        }
    }

    private func triggerCopyLog() {
        let text = logCopyText
        state.copy(
            text.isEmpty ? (state.failureMessage ?? "—") : text,
            label: "已复制")
        logCopyResetTask?.cancel()
        withAnimation(DS.Motion.snappy) { copiedLog = true }
        logCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(DS.Motion.snappy) { copiedLog = false }
        }
    }

    private var emptyModelNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "pause.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.text3)
            Text(L10n.t("还没有选择模型，在模型库选一个即可启动"))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DS.rect(DS.Radius.lg).fill(Color.adaptiveOverlay(0.04)))
        .overlay(DS.rect(DS.Radius.lg).strokeBorder(DS.line, lineWidth: 1))
    }

    // MARK: 三格遥测

    private var telemetryCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                metricCell(
                    "解码",
                    value: number(state.menuBarDecodeReading.value),
                    unit: "tok/s",
                    tag: decodeTag,
                    tagTint: decodeTagTint,
                    sparkline: sparkValues)
                DSDivider(vertical: true)
                    .frame(maxHeight: .infinity)
                metricCell(
                    "首字",
                    value: milliseconds(state.ttftReading.milliseconds),
                    unit: "ms")
                DSDivider(vertical: true)
                    .frame(maxHeight: .infinity)
                metricCell(
                    "预填充",
                    value: number(state.prefillReading.value),
                    unit: "tok/s",
                    tag: prefillTag,
                    tagTint: prefillTagTint)
            }

            if showsMemoryStrip {
                DSDivider()
                memoryStrip
            }
        }
        .background(DS.rect(DS.Radius.card).fill(Color.adaptiveOverlay(0.05)))
        .overlay(
            DS.rect(DS.Radius.card)
                .strokeBorder(DS.line, lineWidth: 1)
        )
        .clipShape(DS.rect(DS.Radius.card))
    }

    private func metricCell(
        _ label: String,
        value: String,
        unit: String,
        tag: String? = nil,
        tagTint: Color = DS.text3,
        sparkline: [Double] = []
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(L10n.t(label))
                    .font(DS.Font.xs.weight(.medium))
                    .foregroundStyle(DS.text3)
                if let tag, value != "—" {
                    Text(verbatim: tag)
                        .font(DS.Font.mono(8.5, weight: .semibold))
                        .tracking(0.4)
                        .foregroundStyle(tagTint)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .font(DS.Font.number(16, weight: .semibold))
                    .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(verbatim: unit)
                    .font(DS.Font.mono(9.5, weight: .medium))
                    .foregroundStyle(DS.text3)
            }

            if sparkline.count > 1 {
                PanelSparkline(values: sparkline, tint: DS.ok)
                    .frame(height: 11)
                    .padding(.top, 1)
                    .help(sparklineHelp)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private var sparkValues: [Double] {
        guard state.serverState == .ready else { return [] }
        return state.recentThroughput(window: 300).map(\.value)
    }

    private var sparklineHelp: String {
        let peak = sparkValues.max() ?? 0
        return L10n.t("近 5 分钟吞吐") + " · " + L10n.format("峰值 %@ tok/s", Format.compact(peak))
    }

    private var showsMemoryStrip: Bool {
        running && state.stats != nil
    }

    private var memoryStrip: some View {
        HStack(spacing: 6) {
            Text(L10n.t("统一内存"))
                .font(DS.Font.prose(10.5))
                .foregroundStyle(DS.text3)
                .fixedSize()
            Text(verbatim: memoryText)
                .font(DS.Font.mono(10, weight: .semibold))
                .foregroundStyle(DS.text)
                .monospacedDigit()
                .fixedSize()

            if let fraction = memoryFraction {
                DSMeter(value: fraction, tint: memoryTint)
                    .frame(minWidth: 30, maxWidth: .infinity)
            } else {
                Spacer(minLength: 4)
            }

            Text(L10n.t("上下文"))
                .font(DS.Font.prose(10.5))
                .foregroundStyle(DS.text3)
                .fixedSize()
            Text(verbatim: contextText)
                .font(DS.Font.mono(10, weight: .semibold))
                .foregroundStyle(DS.text)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var memoryText: String {
        guard let bytes = state.stats?.memoryBytes, bytes > 0 else { return "—" }
        return Format.memory(bytes)
    }

    private var memoryFraction: Double? {
        guard let used = state.stats?.memoryBytes, used > 0,
            let total = state.stats?.physicalMemoryBytes, total > 0
        else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    private var memoryTint: Color {
        guard let fraction = memoryFraction else { return DS.ok }
        if fraction > 0.90 { return DS.err }
        if fraction > 0.75 { return DS.warn }
        return DS.ok
    }

    private var contextText: String {
        let used = state.overviewContextUsedTokens
        guard used > 0 else { return "—" }
        let usedText = Format.tokens(used)
        if let ceiling = state.stats?.maximumContextTokens ?? state.contextWindowTokens,
            ceiling > 0
        {
            return "\(usedText)/\(Format.tokensShort(ceiling))"
        }
        return usedText
    }

    /// 解码格的角标：实时读数标 `LIVE`，退回模型平均时标 `AVG`。
    /// 解码的实时值只来自网关（`.gatewayLive`），没有引擎实时这一档。
    private var decodeTag: String? {
        switch state.menuBarDecodeReading.origin {
        case .gatewayLive: return "LIVE"
        case .gatewayMean: return "AVG"
        default: return nil
        }
    }

    private var decodeTagTint: Color {
        state.menuBarDecodeReading.origin == .gatewayLive ? DS.ok : DS.text3
    }

    /// 预填充格的角标：做完的实测值标 `LAST`，累计均值标 `AVG`。
    private var prefillTag: String? {
        switch state.prefillReading.origin {
        case .gatewayLast: return "LAST"
        case .gatewayMean: return "AVG"
        default: return nil
        }
    }

    private var prefillTagTint: Color {
        DS.text3
    }

    private func number(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return Format.compact(value)
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return "\(Int(value.rounded()))"
    }

    // MARK: 操作

    @ViewBuilder
    private var actionRow: some View {
        if state.isSwitchingModel || state.isModelBusy {
            HStack(spacing: 8) {
                PanelStageBar(text: stageText)
                PanelButton(title: "取消", kind: .glass, minWidth: 66) {
                    cancelBusy()
                }
            }
        } else if running {
            HStack(spacing: 8) {
                PanelButton(
                    title: "停止服务",
                    symbol: "stop.fill",
                    kind: .danger,
                    fillsWidth: true
                ) {
                    state.stopService()
                }
                .disabled(busy)

                PanelButton(title: "重启服务", symbol: "arrow.clockwise", kind: .glass) {
                    state.restartService()
                }
                .disabled(busy)
            }
        } else {
            PanelButton(
                title: "启动服务",
                symbol: "play.fill",
                kind: .primary,
                fillsWidth: true
            ) {
                state.startService()
            }
            .disabled(state.selectedModel.isEmpty || state.runtimeMissing != nil || busy)
        }
    }

    private var stageText: String {
        let text = state.engineStageText
        if !text.isEmpty { return text }
        if state.isSwitchingModel { return L10n.t("切换中") }
        return L10n.t(state.serverState.rawValue)
    }

    private func cancelBusy() {
        if state.isSwitchingModel {
            state.abortModelSwitch()
        } else {
            state.stopService()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(DS.accent.opacity(0.80))
                    .frame(width: 5, height: 5)
                Text(verbatim: hardwareLabel)
                    .font(DS.Font.prose(10.5, weight: .medium))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            footerButton("主窗口", symbol: "macwindow") { onOpenMainWindow(nil) }
                .help(L10n.t("打开主窗口"))
            footerButton("退出", symbol: "power") {
                onDismiss()
                NSApp.terminate(nil)
            }
            .help(L10n.t("退出 flashCat"))
        }
    }

    private var hardwareLabel: String {
        if let device = state.stats?.deviceName, !device.isEmpty {
            return "\(device) · Metal"
        }
        return "Apple Silicon · Metal"
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
        .fixedSize()
    }
}

// MARK: - 状态胶囊

private struct PanelStatusPill: View {
    let status: ServerState
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            if status == .starting || status == .stopping {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.62)
                    .tint(tint)
                    .frame(width: 10, height: 10)
            } else {
                DSStatusDot(color: tint, live: status == .ready, size: 6)
            }
            Text(L10n.t(status.rawValue))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.26), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 模型选择行

private struct PanelModelRow: View {
    let name: String
    let engineTag: String?
    let sizeText: String?
    let selected: Bool
    let switching: Bool
    let stage: String
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if switching {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.62)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? DS.accent : DS.text4)
                }

                Text(verbatim: name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.accent : DS.text2)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if switching, !stage.isEmpty {
                    Text(verbatim: stage)
                        .font(DS.Font.mono(9))
                        .foregroundStyle(DS.warn)
                        .lineLimit(1)
                } else if let engineTag {
                    Text(verbatim: engineTag)
                        .font(DS.Font.mono(9))
                        .foregroundStyle(DS.text3)
                        .lineLimit(1)
                } else if let sizeText {
                    Text(verbatim: sizeText)
                        .font(DS.Font.mono(9))
                        .foregroundStyle(DS.text4)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(
                DS.rect(DS.Radius.sm)
                    .fill(selected ? DS.accentSoft : (hovering ? DS.hover : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
    }
}

// MARK: - 小胶囊按钮

/// 卡面微操作（切换模型、模型库、日志）：22pt 胶囊，悬停只抬底色，不抢主动作。
private struct PanelMiniPill: View {
    let title: String
    var symbol: String? = nil
    var rotating: Bool = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(L10n.t(title))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(rotating ? 180 : 0))
                        .animation(DS.Motion.snappy, value: rotating)
                }
            }
            .foregroundStyle(hovering ? DS.text : DS.text2)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                Capsule().fill(hovering ? DS.raised : DS.pillFill)
            )
            .overlay(
                Capsule().strokeBorder(
                    hovering ? DS.line2 : DS.pillBorder,
                    lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { value in
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
    }
}

// MARK: - 主动作按钮

/// 面板里的 40pt 高对比动作键。主色沿用 `DS.ink`（浅色皮肤是墨黑、深色皮肤是
/// 近白），危险键是淡红底 + 红字，玻璃键与卡面同族的胶囊。
private struct PanelButton: View {
    enum Kind { case primary, danger, glass }

    let title: String
    var symbol: String? = nil
    var kind: Kind = .glass
    var fillsWidth: Bool = false
    var height: CGFloat = 40
    var minWidth: CGFloat = 0
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var radius: CGFloat { height >= 36 ? 13 : 9 }
    private var shape: RoundedRectangle { DS.rect(radius) }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.inkText
        case .danger: return DS.dangerText
        case .glass: return DS.text
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: height >= 36 ? 11 : 9.5, weight: .semibold))
                }
                Text(L10n.t(title))
                    .font(.system(size: height >= 36 ? 12.5 : 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, height >= 36 ? 12 : 9)
            .frame(minWidth: minWidth)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .background(background)
            .overlay(border)
            .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.985))
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { value in
            guard !reduceMotion else {
                hovering = value
                return
            }
            withAnimation(DS.Motion.snappy) { hovering = value }
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary:
            shape.fill(
                LinearGradient(
                    colors: [DS.ink, DS.ink.opacity(hovering ? 0.92 : 0.84)],
                    startPoint: .top,
                    endPoint: .bottom)
            )
        case .danger:
            shape.fill(hovering ? DS.err.opacity(0.16) : DS.dangerFill)
        case .glass:
            shape.fill(hovering ? DS.raised : DS.pillFill)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch kind {
        case .primary:
            shape.strokeBorder(
                LinearGradient(
                    colors: [DS.glassSpecular.opacity(0.38), .clear],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 1)
        case .danger:
            shape.strokeBorder(DS.dangerStroke, lineWidth: 1)
        case .glass:
            shape.strokeBorder(hovering ? DS.line2 : DS.line, lineWidth: 1)
        }
    }
}

// MARK: - 迷你吞吐曲线

/// 解码格里的 5 分钟走势：只有折线，不带坐标轴与说明。
private struct PanelSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let peak = max(values.max() ?? 1, 1)
            let points = points(in: size, peak: peak)

            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(
                tint.opacity(0.90),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize, peak: Double) -> [CGPoint] {
        guard values.count > 1, size.width > 1, size.height > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = min(max(value / peak, 0), 1)
            return CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat(normalized) * (size.height - 2) - 1)
        }
    }
}

// MARK: - 阶段进度条

/// 启动 / 切换 / 停止中的一行：转圈 + 阶段文案，底部一条不确定进度，
/// 让「点下去有反应」这件事在面板里也看得见。
private struct PanelStageBar: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .tint(DS.accent)
                .frame(width: 14, height: 14)
            Text(verbatim: text)
                .font(DS.Font.sm.weight(.medium))
                .foregroundStyle(DS.text2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(DS.rect(13).fill(DS.accentSoft))
        .overlay(DS.rect(13).strokeBorder(DS.accent.opacity(0.20), lineWidth: 1))
        .overlay(alignment: .bottom) {
            if !reduceMotion {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.accent.opacity(0.10))
                        Capsule()
                            .fill(DS.accent.opacity(0.55))
                            .frame(width: max(24, proxy.size.width * 0.28))
                            .offset(x: phase * max(0, proxy.size.width * 0.72))
                    }
                }
                .frame(height: 2)
                .padding(.horizontal, 1)
            }
        }
        .clipShape(DS.rect(13))
        .onAppear {
            guard !reduceMotion else { return }
            phase = 0
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 角标

private struct PanelBadge: Identifiable {
    let text: String
    let tinted: Bool

    var id: String { "\(tinted)|\(text)" }
}
