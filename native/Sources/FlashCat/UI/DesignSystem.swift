import SwiftUI
import AppKit

// MARK: - flashCat Design System (Direction B · pro tool)
//
// 唯一的设计源。颜色、字号、间距、圆角、动效全部从 `DS` 取；旧的 `Native` /
// `Console` token 只是指向这里的兼容别名，新代码不要再引用它们。
//
// 原则：
// - 画布退后、数据向前：中性冷灰阶 + 一个强调色（橙），状态色只用于状态。
// - 分层靠 1px 描边，不靠阴影和玻璃；阴影只留给窗口级浮层。
// - 数字一律等宽对齐（`.monospacedDigit()`），地址 / 代码用等宽字体。
// - 圆角只有三档：sm 5 / md 8 / lg 12。
// - 动效只有四种曲线：snappy（反馈）、smooth（布局 / 页面）、bouncy（强调）、fade。

enum DS {
    // MARK: Color

    /// 侧栏、凹槽（输入框底、代码块）——最深的一层。
    static let bg = Color.adaptive(dark: 0x0B0B0D, light: 0xF4F4F5)
    /// 主画布。
    static let canvas = Color.adaptive(dark: 0x101013, light: 0xFAFAFA)
    /// 卡片 / 面板。
    static let surface = Color.adaptive(dark: 0x16161A, light: 0xFFFFFF)
    /// 浮层、选中行、次级按钮底。
    static let raised = Color.adaptive(dark: 0x1C1C21, light: 0xF4F4F6)
    /// 凹槽（`DS.bg`）上的选中块、侧栏选中行：浅色下用纯白才能从 `#F4F4F5` 里跳出来。
    static let selected = Color.adaptive(dark: 0x1C1C21, light: 0xFFFFFF)
    /// 窗口级浮层（命令面板、弹出卡）：浅色下用纯白配描边与投影。
    static let floating = Color.adaptive(dark: 0x1C1C21, light: 0xFFFFFF)
    /// 悬停底。
    static let hover = Color.adaptive(dark: 0x24242A, light: 0xECECEF)

    /// 1px 描边三档：分隔线 / 控件边 / 强调边。
    static let line = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.065, lightAlpha: 0.075)
    static let line2 = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.10, lightAlpha: 0.11)
    static let line3 = Color.adaptive(dark: 0xFFFFFF, light: 0x09090B, darkAlpha: 0.17, lightAlpha: 0.18)

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

    // MARK: Radius — 3 levels

    enum Radius {
        static let sm: CGFloat = 5
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }

    // MARK: Layout

    enum Layout {
        static let sidebarWidth: CGFloat = 216
        static let titlebarHeight: CGFloat = 44
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
    var stroke: Color
    var hoverable: Bool
    var active: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = DS.rect(radius)
        let resolvedFill = (hoverable && hovering) ? DS.raised : fill
        let resolvedStroke = active ? DS.line3 : ((hoverable && hovering) ? DS.line2 : stroke)
        content
            .background(shape.fill(resolvedFill))
            .overlay(shape.strokeBorder(resolvedStroke, lineWidth: 1))
            .onHover { value in
                guard hoverable else { return }
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
    }
}

extension View {
    /// 面板表面：纯色 + 1px 描边。全应用卡片唯一写法。
    func dsSurface(radius: CGFloat = DS.Radius.lg,
                   fill: Color = DS.surface,
                   stroke: Color = DS.line,
                   hoverable: Bool = false,
                   active: Bool = false) -> some View {
        modifier(DSSurfaceModifier(radius: radius, fill: fill, stroke: stroke, hoverable: hoverable, active: active))
    }

    /// 窗口级浮层（弹出菜单、命令面板）：raised 底 + 强描边 + 唯一允许的投影。
    func dsFloating(radius: CGFloat = DS.Radius.lg) -> some View {
        background(DS.rect(radius).fill(DS.floating))
            .overlay(DS.rect(radius).strokeBorder(DS.line2, lineWidth: 1))
            .shadow(color: DS.shadow, radius: 24, y: 12)
    }

    /// 弹出框表面（`.popover` 内容器统一底色）。
    func dsPopoverSurface() -> some View {
        background(DS.floating)
    }

    /// 输入框 / 文本域表面：凹槽底 + 1px 描边（聚焦时加亮）。
    func dsInputSurface(radius: CGFloat = DS.Radius.md, focused: Bool = false) -> some View {
        background(DS.rect(radius).fill(DS.bg))
            .overlay(DS.rect(radius).strokeBorder(focused ? DS.line3 : DS.line2, lineWidth: 1))
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

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size, isEnabled: isEnabled)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let size: DSButtonStyle.Size
    let isEnabled: Bool
    @State private var hovering = false

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return DS.Layout.controlHeight
        case .large: return 36
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 9
        case .regular: return 12
        case .large: return 24
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 12
        case .regular: return 13
        case .large: return 13.5
        }
    }

    private var radius: CGFloat {
        size == .small ? DS.Radius.sm + 1 : DS.Radius.md
    }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.inkText
        case .danger: return hovering ? DS.err : DS.text
        case .secondary: return DS.text
        case .ghost: return hovering ? DS.text : DS.text2
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return DS.ink.opacity(hovering ? 1 : 0.92)
        case .secondary: return hovering ? DS.raised : DS.surface
        case .danger: return hovering ? DS.err.opacity(0.10) : DS.surface
        case .ghost: return hovering ? DS.hover : .clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary: return hovering ? DS.line3 : DS.line2
        case .danger: return hovering ? DS.err.opacity(0.45) : DS.line2
        }
    }

    var body: some View {
        let shape = DS.rect(radius)
        configuration.label
            .font(.system(size: fontSize, weight: size == .large ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
            .animation(DS.Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDanger: DSButtonStyle { DSButtonStyle(kind: .danger) }
    static func ds(_ kind: DSButtonStyle.Kind, size: DSButtonStyle.Size = .regular) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size)
    }
}

/// 方形图标按钮：统一支持透明幽灵、描边、激活/着色三种形态。
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

    private var radius: CGFloat { size <= 24 ? DS.Radius.sm : DS.Radius.md }

    private var foreground: Color {
        if let tint { return tint }
        if active { return DS.accent }
        switch style {
        case .primary: return DS.inkText
        case .ghost, .outlined: return hovering ? DS.text : DS.text2
        }
    }

    private var fill: Color {
        if active { return DS.accentSoft }
        switch style {
        case .primary: return DS.ink.opacity(hovering ? 1 : 0.92)
        case .outlined: return hovering ? DS.hover : DS.raised
        case .ghost: return hovering ? DS.hover : .clear
        }
    }

    private var stroke: Color {
        if active { return DS.accent.opacity(0.35) }
        switch style {
        case .primary, .ghost: return .clear
        case .outlined: return hovering ? DS.line3 : DS.line2
        }
    }

    var body: some View {
        let shape = DS.rect(radius)
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(stroke, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(DSPressStyle())
        .opacity(isEnabled ? 1 : 0.4)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
        .onHover { value in withAnimation(DS.Motion.snappy) { hovering = value } }
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
            .font(DS.Font.mono(10, weight: .medium))
            .foregroundStyle(onInk ? DS.inkText.opacity(0.55) : DS.text3)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(DS.rect(4).strokeBorder(onInk ? DS.inkText.opacity(0.18) : DS.line2, lineWidth: 1))
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

/// 小标签：圆点 + 文字，`raised` 底。
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
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(DS.rect(DS.Radius.sm).fill(tint?.opacity(0.12) ?? DS.bg))
        .overlay(DS.rect(DS.Radius.sm).strokeBorder(tint?.opacity(0.25) ?? DS.line, lineWidth: 1))
        .fixedSize()
    }
}

/// 3pt 细进度条。
struct DSMeter: View {
    var value: Double
    var tint: Color = DS.text2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.line2)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * min(max(value, 0), 1)))
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

/// 平面分段控件：选中块在选项间滑动（matchedGeometry）。全应用唯一的分段写法。
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var size: DSButtonStyle.Size = .regular

    @Environment(\.isEnabled) private var isEnabled
    @Namespace private var ns
    @State private var hoveredIndex: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.value == selection
                let hovering = hoveredIndex == index
                Button {
                    withAnimation(DS.Motion.smooth) { selection = option.value }
                } label: {
                    Text(L10n.t(option.label))
                        .font(.system(size: size == .small ? 11 : 12, weight: .medium))
                        .foregroundStyle(active ? DS.text : (hovering ? DS.text2 : DS.text3))
                        .padding(.horizontal, size == .small ? 8 : 10)
                        .frame(height: size == .small ? 20 : 24)
                        .background {
                            if active {
                                DS.rect(DS.Radius.sm)
                                    .fill(DS.selected)
                                    .overlay(DS.rect(DS.Radius.sm).strokeBorder(DS.line2, lineWidth: 1))
                                    .matchedGeometryEffect(id: "ds.segment", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    withAnimation(DS.Motion.snappy) {
                        if inside { hoveredIndex = index }
                        else if hoveredIndex == index { hoveredIndex = nil }
                    }
                }
            }
        }
        .padding(2)
        .background(DS.rect(DS.Radius.sm + 2).fill(DS.bg))
        .overlay(DS.rect(DS.Radius.sm + 2).strokeBorder(DS.line, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.45)
        .fixedSize()
    }
}

/// 按钮组容器：把一组相关的紧凑按钮收进同一个 1px 描边圆角框内，中间用 1px 竖线隔开。
struct DSButtonGroup<Content: View>: View {
    var radius: CGFloat = DS.Radius.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            content()
        }
        .background(DS.rect(radius).fill(DS.surface))
        .overlay(DS.rect(radius).strokeBorder(DS.line2, lineWidth: 1))
        .clipShape(DS.rect(radius))
    }
}

// MARK: - Menus & Popovers

/// 统一下拉菜单触发器外观（Menu 与 Popover 共用，保证两者视觉完全一致）。
struct DSMenuTriggerLabel: View {
    enum Kind { case primary, secondary, ghost, icon }

    var title: String? = nil
    var systemImage: String? = nil
    var imageTint: Color? = nil
    var badge: String? = nil
    var trailingChevron: Bool = true
    var kind: Kind = .secondary
    var size: DSButtonStyle.Size = .regular

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var height: CGFloat { size == .small ? 24 : DS.Layout.controlHeight }
    private var radius: CGFloat { size == .small ? DS.Radius.sm + 1 : DS.Radius.md }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.inkText
        case .secondary, .icon: return DS.text
        case .ghost: return hovering ? DS.text : DS.text2
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return DS.ink.opacity(hovering ? 1 : 0.92)
        case .secondary: return hovering ? DS.raised : DS.surface
        case .icon: return hovering ? DS.hover : DS.raised
        case .ghost: return hovering ? DS.hover : .clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary, .icon: return hovering ? DS.line3 : DS.line2
        }
    }

    var body: some View {
        let shape = DS.rect(radius)
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size == .small ? 10.5 : 11.5, weight: .semibold))
                    .foregroundStyle(imageTint ?? (kind == .primary ? DS.inkText : DS.text2))
            }
            if let title {
                Text(L10n.t(title))
                    .font(.system(size: size == .small ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
            }
            if let badge {
                Text(L10n.t(badge))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.75) : DS.text2)
                    .lineLimit(1)
            }
            if trailingChevron && kind != .icon {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.6) : DS.text3)
            }
        }
        .padding(.horizontal, kind == .icon ? 0 : (size == .small ? 9 : 11))
        .frame(width: kind == .icon ? height : nil, height: height)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(DS.Motion.snappy, value: hovering)
        .onHover { hovering = $0 }
    }
}

/// 统一 Menu 包装：自动收掉系统指示器与边距压平问题，全部菜单走同一套触发器样式。
struct DSMenu<Label: View, Content: View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content, label: label)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
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

/// 统一 28pt 搜索框：凹槽底、1px 描边（聚焦加亮）、清空按钮。
struct DSSearchField: View {
    @Binding var query: String
    var placeholder: String = "搜索"
    var width: CGFloat? = nil

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.text3)
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
        .padding(.horizontal, 9)
        .frame(width: width, height: DS.Layout.controlHeight)
        .dsInputSurface(radius: DS.Radius.md, focused: focused)
    }
}

/// 一行筛选栏：平面分段控件 + 常驻 28pt 紧凑搜索框。
struct DSFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 10) {
            DSSegmented(selection: $selection, options: options)
            DSSearchField(query: $query, placeholder: placeholder, width: maxSearchWidth)
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
