import SwiftUI
import AppKit

// MARK: - flashCat Design System (macOS 26 Native Liquid Glass)
//
// 唯一的设计源。颜色、字号、间距、圆角、动效全部从 `DS` 取；旧的 `Native` /
// `Console` token 只是指向这里的兼容别名，新代码不要再引用它们。
//
// 原则：
// - 导航层、顶栏、浮层与交互控件采用原生 macOS 26 Liquid Glass（`glassEffect` +
//   `GlassEffectContainer`）；内容卡片采用同心圆角与通透层级，保证正文极高可读性。
// - 中性冷灰阶 + 一个强调色（橙），状态色只用于状态。
// - 数字一律等宽对齐（`.monospacedDigit()`），地址 / 代码用等宽字体。
// - 同心圆角四档：sm 8 / md 12 / lg 16 / xl 22，按钮与胶囊控件使用 Capsule。
// - 动效只有四种曲线：snappy（反馈）、smooth（布局 / 页面）、bouncy（强调）、fade。

enum DS {
    // MARK: Color

    /// 侧栏、凹槽（输入框底、代码块）——半透明内嵌层，兼容背景透视。
    static let bg = Color.adaptive(dark: 0x0B0B0E, light: 0xE6E8EE, darkAlpha: 0.62, lightAlpha: 0.68)
    /// 主画布：浅色略微压暗成柔灰，让内容卡片与悬浮玻璃层不用重投影也能拉开层次。
    static let canvas = Color.adaptive(dark: 0x0E0E12, light: 0xECEEF3)
    /// 卡片 / 面板：通透卡片表面，允许底层画布与自定义背景微微透出。
    static let surface = Color.adaptive(dark: 0x18181E, light: 0xFFFFFF, darkAlpha: 0.84, lightAlpha: 0.88)
    /// 浮层、选中行、次级控件底。
    static let raised = Color.adaptive(dark: 0x222229, light: 0xFFFFFF, darkAlpha: 0.92, lightAlpha: 0.96)
    /// 凹槽（`DS.bg`）上的选中块、侧栏选中行。
    static let selected = Color.adaptive(dark: 0x2A2A34, light: 0xFFFFFF, darkAlpha: 0.92, lightAlpha: 0.96)
    /// 窗口级浮层（命令面板、弹出卡）。
    static let floating = Color.adaptive(dark: 0x1E1E25, light: 0xFFFFFF, darkAlpha: 0.86, lightAlpha: 0.90)
    /// 悬停底。
    static let hover = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.08, lightAlpha: 0.055)

    /// 描边三档：分隔线 / 控件边 / 强调边。
    static let line = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.08, lightAlpha: 0.07)
    static let line2 = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.13, lightAlpha: 0.11)
    static let line3 = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.22, lightAlpha: 0.18)

    /// 文字四档：正文 / 次要 / 说明 / 占位。
    static let text = Color(nsColor: .consoleText)
    static let text2 = Color.adaptive(dark: 0xA1A1AA, light: 0x52525B)
    static let text3 = Color.adaptive(dark: 0x6B6B74, light: 0x8A8A93)
    static let text4 = Color.adaptive(dark: 0x4A4A52, light: 0xB4B4BB)

    static let accent = Color(nsColor: .consoleAccent)
    static let accentSoft = Color.adaptive(dark: 0xFF7A3D, light: 0xE8590C, darkAlpha: 0.14, lightAlpha: 0.10)

    static let ok = Color.adaptive(dark: 0x3DD68C, light: 0x16A34A)
    static let warn = Color.adaptive(dark: 0xF5B642, light: 0xD97706)
    static let err = Color.adaptive(dark: 0xFF5C5C, light: 0xDC2626)
    static let info = Color.adaptive(dark: 0x6EA8FF, light: 0x2563EB)

    /// 唯一主动作的「墨色」按钮：深色皮肤是亮底黑字，浅色皮肤反过来。
    static let ink = Color.adaptive(dark: 0xECECEF, light: 0x18181B)
    static let inkText = Color.adaptive(dark: 0x0B0B0D, light: 0xFFFFFF)

    static let scrim = Color.adaptive(dark: 0x000000, light: 0x09090B, darkAlpha: 0.40, lightAlpha: 0.18)
    static let shadow = Color.adaptive(dark: 0x000000, light: 0x09090B, darkAlpha: 0.50, lightAlpha: 0.12)

    // MARK: Type — 11 / 12 / 13 / 15 / 22 / 30

    enum Font {
        static let xs = SwiftUI.Font.system(size: 11)
        static let sm = SwiftUI.Font.system(size: 12)
        static let md = SwiftUI.Font.system(size: 13)
        static let lg = SwiftUI.Font.system(size: 15)
        static let title = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let display = SwiftUI.Font.system(size: 30, weight: .semibold)

        static func mono(_ size: CGFloat, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// 读数：系统字体 + 等宽数字，比纯等宽字体更紧凑好读。
        static func number(_ size: CGFloat, weight: SwiftUI.Font.Weight = .medium) -> SwiftUI.Font {
            .system(size: size, weight: weight).monospacedDigit()
        }
    }

    // MARK: Space — 4pt grid

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Radius — 4 concentric levels

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 216
        static let titlebarHeight: CGFloat = 48
        static let rowHeight: CGFloat = 30
        static let controlHeight: CGFloat = 28
        static let pageMaxWidth: CGFloat = 1180
        static let chatColumn: CGFloat = 720
    }

    // MARK: Motion — 4 curves

    enum Motion {
        /// hover / press / toggle：短、利落，不过冲。
        static let snappy = Animation.snappy(duration: 0.18)
        /// 布局、页面、展开收起、选中块滑动。
        static let smooth = Animation.smooth(duration: 0.28)
        /// 需要被注意到的强调：灵动岛、命令面板、新条目。
        static let bouncy = Animation.bouncy(duration: 0.42, extraBounce: 0.06)
        /// 纯透明度变化（交叉淡入淡出）。
        static let fade = Animation.linear(duration: 0.15)
    }
}

// MARK: - Shapes

extension DS {
    static func rect(_ radius: CGFloat = Radius.md) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Surface

private struct DSSurfaceModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var tint: Color?
    var stroke: Color?
    var hoverable: Bool
    var active: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = DS.rect(radius)
        let baseFill = (hoverable && hovering) ? DS.raised : fill
        let resolvedTint: Color? = tint ?? (active ? DS.accent.opacity(0.08) : nil)
        let resolvedStroke: Color = stroke ?? (active ? DS.accent.opacity(0.40) : ((hoverable && hovering) ? DS.line2 : DS.line))
        content
            .background {
                ZStack {
                    shape.fill(baseFill)
                    if let resolvedTint {
                        shape.fill(resolvedTint)
                    }
                }
            }
            .overlay(shape.strokeBorder(resolvedStroke, lineWidth: 1))
            .onHover { value in
                guard hoverable else { return }
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
    }
}

extension View {
    /// 内容卡片表面：轻量通透底色 + 1px 发丝描边（不与浮层/按钮的 Liquid Glass 冲突）。
    func dsSurface(radius: CGFloat = DS.Radius.lg,
                   fill: Color = DS.surface,
                   tint: Color? = nil,
                   stroke: Color? = nil,
                   hoverable: Bool = false,
                   active: Bool = false) -> some View {
        modifier(DSSurfaceModifier(radius: radius,
                                   fill: fill,
                                   tint: tint,
                                   stroke: stroke,
                                   hoverable: hoverable,
                                   active: active))
    }

    /// 窗口级浮层（弹出菜单、命令面板）：原生 Liquid Glass 浮层 + 柔和投影。
    func dsFloating(radius: CGFloat = DS.Radius.xl) -> some View {
        let shape = DS.rect(radius)
        return glassEffect(.regular, in: shape)
            .shadow(color: DS.shadow, radius: 28, y: 12)
    }

    /// 弹出框表面：保留 macOS 26 `.popover` 原生 Liquid Glass 材质，不再铺不透明底色盖住玻璃。
    func dsPopoverSurface() -> some View {
        self
    }

    /// 输入框 / 文本域表面：半透明内嵌凹槽 + 细描边（聚焦时亮起强调色描边）。
    func dsInputSurface(radius: CGFloat = DS.Radius.md, focused: Bool = false) -> some View {
        background(DS.rect(radius).fill(Color.adaptiveOverlay(0.05)))
            .overlay(DS.rect(radius).strokeBorder(focused ? DS.accent.opacity(0.55) : DS.line2, lineWidth: 1))
            .animation(DS.Motion.snappy, value: focused)
    }
}

// MARK: - Panel

/// 带标题行的面板：40pt 标题 + 1px 分隔 + 内容。
struct DSPanel<Accessory: View, Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text(L10n.t(title))
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                if let subtitle {
                    Text(L10n.t(subtitle))
                        .font(DS.Font.sm)
                        .foregroundStyle(DS.text3)
                }
                Spacer(minLength: DS.Space.sm)
                accessory()
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Rectangle().fill(DS.line).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .dsSurface()
        .clipShape(DS.rect(DS.Radius.lg))
    }
}

extension DSPanel where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = { EmptyView() }
        self.content = content
    }
}

// MARK: - Buttons

/// 统一按钮样式：直接委托给系统原生 `.glass` / `.glassProminent` Liquid Glass 按钮。
struct DSButtonStyle: PrimitiveButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    private var controlSize: ControlSize {
        switch size {
        case .small: return .small
        case .regular: return .regular
        case .large: return .large
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 12
        case .regular: return 13
        case .large: return 13.5
        }
    }

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.system(size: fontSize, weight: size == .large ? .semibold : .medium))
            .lineLimit(1)

        switch kind {
        case .primary:
            Button(role: configuration.role, action: configuration.trigger) {
                label
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(controlSize)
            .tint(DS.accent)

        case .secondary:
            Button(role: configuration.role, action: configuration.trigger) {
                label
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(controlSize)

        case .danger:
            Button(role: .destructive, action: configuration.trigger) {
                label.foregroundStyle(DS.err)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(controlSize)

        case .ghost:
            Button(role: configuration.role, action: configuration.trigger) {
                label
            }
            .buttonStyle(DSGhostButtonStyle(size: size))
        }
    }
}

private struct DSGhostButtonStyle: ButtonStyle {
    let size: DSButtonStyle.Size
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var height: CGFloat {
        switch size {
        case .small: return 22
        case .regular: return 26
        case .large: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 9
        case .regular: return 12
        case .large: return 18
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? DS.text : DS.text2)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(hovering ? DS.hover : .clear))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
            .animation(DS.Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension PrimitiveButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDanger: DSButtonStyle { DSButtonStyle(kind: .danger) }
    static func ds(_ kind: DSButtonStyle.Kind, size: DSButtonStyle.Size = .regular) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size)
    }
}

/// 圆形图标按钮：支持幽灵、系统原生 `.glass` 与 `.glassProminent` 三种形态。
struct DSIconButton: View {
    enum Style { case ghost, outlined, primary }

    var systemName: String
    var help: String
    var size: CGFloat = 28
    var style: Style = .ghost
    var active: Bool = false
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var controlSize: ControlSize {
        size <= 24 ? .small : .regular
    }

    private var glyph: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .medium))
            .frame(width: size * 0.62, height: size * 0.62)
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .primary:
            Button(action: action) {
                glyph
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(controlSize)
            .tint(tint ?? DS.accent)
            .help(L10n.t(help))
            .accessibilityLabel(L10n.t(help))

        case .outlined:
            if active {
                Button(action: action) {
                    glyph
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(controlSize)
                .tint(tint ?? DS.accent)
                .help(L10n.t(help))
                .accessibilityLabel(L10n.t(help))
            } else {
                Button(action: action) {
                    glyph
                        .foregroundStyle(tint ?? DS.text)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(controlSize)
                .help(L10n.t(help))
                .accessibilityLabel(L10n.t(help))
            }

        case .ghost:
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(tint ?? (active ? DS.accent : (hovering ? DS.text : DS.text2)))
                    .frame(width: size, height: size)
                    .background(Circle().fill(active ? DS.accentSoft : (hovering ? DS.hover : .clear)))
                    .contentShape(Circle())
            }
            .buttonStyle(DSPressStyle())
            .opacity(isEnabled ? 1 : 0.4)
            .help(L10n.t(help))
            .accessibilityLabel(L10n.t(help))
            .onHover { value in withAnimation(DS.Motion.snappy) { hovering = value } }
        }
    }
}

/// 只有按压缩放、没有任何底色的按钮样式。
struct DSPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
    }
}

/// 计数角标：全应用唯一的胶囊数字徽标（下载数量、未读通知）。
struct DSBadge: View {
    var count: Int
    var tint: Color = DS.accent

    var body: some View {
        Text(verbatim: "\(count)")
            .font(DS.Font.mono(9.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 15)
            .frame(height: 15)
            .background(Capsule().fill(tint))
            .fixedSize()
    }
}

// MARK: - Small parts

/// 键盘提示：⌘K。
struct DSKbd: View {
    var text: String
    var onInk = false

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.mono(10.5, weight: .medium))
            .foregroundStyle(onInk ? DS.inkText.opacity(0.65) : DS.text3)
            .padding(.horizontal, 4)
    }
}

/// 读数来源角标：LIVE / LAST / AVG / P50。只有 LIVE 着色。
struct DSSourceBadge: View {
    var text: String
    var live: Bool = false

    var body: some View {
        Text(verbatim: text)
            .font(DS.Font.mono(9, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(live ? DS.ok : DS.text3)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .overlay(DS.rect(3).strokeBorder(live ? DS.ok.opacity(0.35) : DS.line2, lineWidth: 1))
            .contentTransition(.opacity)
    }
}

/// 状态圆点；`live` 时外圈呼吸扩散。
struct DSStatusDot: View {
    var color: Color = DS.ok
    var live: Bool = false
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if live && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + phase * 1.4)
                        .opacity(0.45 * (1 - phase))
                }
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// 小标签：圆点 + 文字，柔和胶囊形态。
struct DSChip: View {
    var text: String
    var dot: Color? = nil
    var live: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot { DSStatusDot(color: dot, live: live, size: 6) }
            Text(L10n.t(text))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(tint ?? DS.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(tint?.opacity(0.12) ?? Color.adaptiveOverlay(0.05)))
        .overlay(Capsule().strokeBorder(tint?.opacity(0.25) ?? DS.line, lineWidth: 0.8))
        .fixedSize()
    }
}

/// 3pt 细进度条。值为 0 时保持空轨，不画多余的 2px 小点。
struct DSMeter: View {
    var value: Double
    var tint: Color = DS.text2

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                if clamped > 0 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(3, proxy.size.width * clamped))
                }
            }
        }
        .frame(height: 3)
        .animation(DS.Motion.smooth, value: value)
    }
}

/// 小节标题（侧栏分组、表单分组）。
struct DSSectionLabel: View {
    var text: String
    var body: some View {
        Text(L10n.t(text))
            .font(DS.Font.xs.weight(.medium))
            .foregroundStyle(DS.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DSDivider: View {
    var vertical = false
    var body: some View {
        if vertical {
            Rectangle().fill(DS.line).frame(width: 1)
        } else {
            Rectangle().fill(DS.line).frame(height: 1)
        }
    }
}

/// 迷你折线：最近若干个点，自动按峰值缩放。
struct DSSparkline: View {
    var values: [Double]
    var color: Color = DS.accent
    var floor: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let peak = max(values.max() ?? 0, floor)
            Path { path in
                guard values.count > 1 else { return }
                let step = proxy.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step,
                                        y: proxy.size.height - 1 - CGFloat(value / peak) * (proxy.size.height - 2))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Segmented & Button Groups

/// 原生 Liquid Glass 分段控件：在 macOS 27+ 走系统 `.tabs`（拖拽透镜玻璃胶囊），macOS 26 回退 `.segmented`。
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var size: DSButtonStyle.Size = .regular

    var body: some View {
        NativeSegmented(selection: $selection, options: options, size: size)
    }
}

/// 按钮组容器：用 `GlassEffectContainer` 把一组原生玻璃控件融合排布。
struct DSButtonGroup<Content: View>: View {
    var radius: CGFloat = DS.Radius.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                content()
            }
        }
    }
}

// MARK: - Menus & Popovers

/// 统一下拉菜单触发器标签（纯内容排版，外层玻璃由 `DSMenu` 或按钮样式提供）。
struct DSMenuTriggerLabel: View {
    enum Kind { case primary, secondary, ghost, icon }

    var title: String? = nil
    var systemImage: String? = nil
    var imageTint: Color? = nil
    var badge: String? = nil
    var trailingChevron: Bool = true
    var kind: Kind = .secondary
    var size: DSButtonStyle.Size = .regular

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .small ? 10.5 : 11.5, weight: .semibold))
                    .foregroundStyle(imageTint ?? (kind == .primary ? .white : DS.text2))
            }
            if let title {
                Text(L10n.t(title))
                    .font(.system(size: size == .small ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? .white : DS.text)
                    .lineLimit(1)
            }
            if let badge {
                Text(L10n.t(badge))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? Color.white.opacity(0.82) : DS.text2)
                    .lineLimit(1)
            }
            if trailingChevron && kind != .icon {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind == .primary ? Color.white.opacity(0.75) : DS.text3)
            }
        }
    }
}

/// 统一 Menu 包装：使用 macOS 26 原生 `.menuStyle(.button)` + `.buttonStyle(.glass)` / `.glassProminent`。
struct DSMenu<Label: View, Content: View>: View {
    var kind: DSMenuTriggerLabel.Kind = .secondary
    var size: DSButtonStyle.Size = .regular
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    private var controlSize: ControlSize {
        switch size {
        case .small: return .small
        case .regular: return .regular
        case .large: return .large
        }
    }

    @ViewBuilder
    var body: some View {
        let base = Menu(content: content, label: label)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(controlSize)
            .fixedSize()

        switch kind {
        case .primary:
            base
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(DS.accent)
        case .secondary:
            base
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        case .icon:
            base
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        case .ghost:
            base
                .buttonStyle(.borderless)
        }
    }
}

/// 弹出菜单单行：选中态用 `accentSoft`，悬停态用 `hover`，30pt 高度 + `Radius.sm`。
struct DSMenuRow<Content: View>: View {
    var selected: Bool = false
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .frame(height: DS.Layout.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    DS.rect(DS.Radius.sm)
                        .fill(selected ? DS.accentSoft : (hovering ? DS.hover : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(DS.Motion.snappy) { hovering = inside }
        }
    }
}

// MARK: - Search & Filter

/// 统一 28pt 搜索框：原生 Liquid Glass 胶囊，聚焦时亮起强调色微光。
struct DSSearchField: View {
    @Binding var query: String
    var placeholder: String = "搜索"
    var width: CGFloat? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? DS.accent : DS.text3)
            TextField(L10n.t(placeholder), text: $query)
                .textFieldStyle(.plain)
                .font(DS.Font.sm)
                .foregroundStyle(DS.text)
                .focused($focused)
                .onExitCommand {
                    query = ""
                    focused = false
                }
                .onSubmit {
                    focused = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: width, height: DS.Layout.controlHeight)
        .glassEffect(.regular.tint(focused ? DS.accent.opacity(0.08) : nil).interactive(),
                     in: Capsule())
        .overlay {
            if focused {
                Capsule()
                    .strokeBorder(DS.accent.opacity(0.42), lineWidth: 1)
            }
        }
        .animation(DS.Motion.snappy, value: focused)
    }
}

/// 一行筛选栏：原生 Liquid Glass 分段控件 + 胶囊玻璃搜索框（包在 `GlassEffectContainer` 中）。
struct DSFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                DSSegmented(selection: $selection, options: options)
                DSSearchField(query: $query, placeholder: placeholder, width: maxSearchWidth)
            }
        }
    }
}

// MARK: - Transitions

extension AnyTransition {
    /// 页面切换：淡入 + 4pt 上移；离开只淡出。
    static var dsPage: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                    removal: .opacity)
    }

    /// 新条目：从上方 6pt 滑入并淡入。
    static var dsRowInsert: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)),
                    removal: .opacity)
    }

    /// 浮层：轻微缩放 + 淡入。
    static var dsPopover: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
    }
}

// MARK: - Animated Grid

/// 支持列数切换平滑重排的原生网格 `Layout`：
/// 在 `columns` 变化时配合 `withAnimation(DS.Motion.smooth)` 为每张卡片插值位置与宽度，
/// 弥补 `LazyVGrid(.adaptive)` 在侧栏收放与窗口缩放时生硬跳变的不足。
struct DSAnimatedGrid: Layout {
    var columns: Int
    var minWidth: CGFloat
    var maxWidth: CGFloat? = nil
    var spacing: CGFloat = 12
    var maxColumns: Int? = nil

    static func columnCount(for width: CGFloat,
                            minWidth: CGFloat,
                            spacing: CGFloat,
                            maxColumns: Int? = nil) -> Int {
        let usable = max(1, width)
        let raw = max(1, Int((usable + spacing) / (minWidth + spacing)))
        if let maxColumns { return min(maxColumns, raw) }
        return raw
    }

    private func resolvedColumns(for width: CGFloat) -> Int {
        columns > 0
            ? columns
            : Self.columnCount(for: width, minWidth: minWidth, spacing: spacing, maxColumns: maxColumns)
    }

    private func cellWidth(totalWidth: CGFloat, cols: Int) -> CGFloat {
        let raw = max(1, (totalWidth - spacing * CGFloat(max(0, cols - 1))) / CGFloat(cols))
        return maxWidth.map { min(raw, $0) } ?? raw
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fallbackCols = max(1, columns)
        let totalWidth = proposal.width
            ?? (minWidth * CGFloat(fallbackCols) + spacing * CGFloat(max(0, fallbackCols - 1)))
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let itemProposal = ProposedViewSize(width: itemWidth, height: nil)

        var totalHeight: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<end {
                rowHeight = max(rowHeight, subviews[i].sizeThatFits(itemProposal).height)
            }
            if index > 0 { totalHeight += spacing }
            totalHeight += rowHeight
            index = end
        }
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let totalWidth = bounds.width
        let cols = max(1, resolvedColumns(for: totalWidth))
        let itemWidth = cellWidth(totalWidth: totalWidth, cols: cols)
        let measureProposal = ProposedViewSize(width: itemWidth, height: nil)

        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let end = min(index + cols, subviews.count)
            var rowHeight: CGFloat = 0
            var heights: [CGFloat] = []
            heights.reserveCapacity(end - index)
            for i in index..<end {
                let h = subviews[i].sizeThatFits(measureProposal).height
                heights.append(h)
                rowHeight = max(rowHeight, h)
            }
            for offset in 0..<(end - index) {
                let x = bounds.minX + CGFloat(offset) * (itemWidth + spacing)
                subviews[index + offset].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: heights[offset])
                )
            }
            y += rowHeight + spacing
            index = end
        }
    }
}

private struct DSTrackColumnsModifier: ViewModifier {
    @Binding var columns: Int
    let minWidth: CGFloat
    let spacing: CGFloat
    let maxColumns: Int?
    let horizontalPadding: CGFloat

    @State private var measuredWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(1, proxy.size.width - horizontalPadding * 2)
            } action: { width in
                measuredWidth = width
                updateColumns(for: width, animate: columns > 0)
            }
            .onChange(of: minWidth) { _, _ in
                guard measuredWidth > 1 else { return }
                updateColumns(for: measuredWidth, animate: columns > 0)
            }
    }

    private func updateColumns(for width: CGFloat, animate: Bool) {
        let next = DSAnimatedGrid.columnCount(for: width,
                                              minWidth: minWidth,
                                              spacing: spacing,
                                              maxColumns: maxColumns)
        guard next != columns else { return }
        if animate {
            withAnimation(DS.Motion.smooth) { columns = next }
        } else {
            columns = next
        }
    }
}

extension View {
    /// 监听容器可用宽度并在跨越列数断点时以平滑动画更新列数。
    func dsTrackColumns(_ columns: Binding<Int>,
                        minWidth: CGFloat,
                        spacing: CGFloat,
                        maxColumns: Int? = nil,
                        horizontalPadding: CGFloat = Console.contentPadding) -> some View {
        modifier(DSTrackColumnsModifier(columns: columns,
                                        minWidth: minWidth,
                                        spacing: spacing,
                                        maxColumns: maxColumns,
                                        horizontalPadding: horizontalPadding))
    }
}
