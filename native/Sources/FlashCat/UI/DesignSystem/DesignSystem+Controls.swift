// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    enum Size { case small, regular, large }

    var kind: Kind = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let size: DSButtonStyle.Size

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return 28
        case .large: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .small: return 10
        case .regular: return 12
        case .large: return 16
        }
    }

    private var fontSize: CGFloat {
        switch size {
        case .small: return 11.5
        case .regular: return 12.5
        case .large: return 13
        }
    }

    private var radius: CGFloat {
        size == .small ? DS.Radius.sm : DS.Radius.md
    }

    private var shape: RoundedRectangle { DS.rect(radius) }

    private var foreground: Color {
        switch kind {
        case .primary: return DS.inkText
        case .secondary: return DS.text
        case .ghost: return activeHover ? DS.text : DS.text2
        case .danger: return DS.err
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return activeHover ? DS.ink.opacity(0.88) : DS.ink
        case .secondary:
            return activeHover ? DS.raised : DS.surface
        case .ghost:
            return activeHover ? DS.hover : .clear
        case .danger:
            return DS.err.opacity(activeHover ? 0.17 : 0.10)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return .clear
        case .secondary: return activeHover ? DS.line3 : DS.line2
        case .ghost: return .clear
        case .danger: return DS.err.opacity(activeHover ? 0.42 : 0.26)
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: size == .large ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                ZStack {
                    shape.fill(background)
                    if kind == .secondary && activeHover {
                        shape.fill(DS.hover)
                    }
                }
            }
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .contentShape(shape)
            .scaleEffect((!reduceMotion && configuration.isPressed && isEnabled) ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
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

/// ZCode 风格圆角矩形图标按钮：支持幽灵、描边与高对比主按钮三种形态。
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var shape: RoundedRectangle {
        DS.rect(size <= 24 ? DS.Radius.sm : DS.Radius.md)
    }

    private var foreground: Color {
        switch style {
        case .primary:
            return tint != nil ? .white : DS.inkText
        case .outlined:
            if active { return tint != nil ? .white : DS.inkText }
            return tint ?? (activeHover ? DS.text : DS.text2)
        case .ghost:
            return tint ?? (active ? DS.accent : (activeHover ? DS.text : DS.text2))
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            let base = tint ?? DS.ink
            return activeHover ? base.opacity(0.88) : base
        case .outlined:
            if active {
                let base = tint ?? DS.ink
                return activeHover ? base.opacity(0.90) : base
            }
            return activeHover ? DS.raised : DS.surface
        case .ghost:
            return active ? DS.accentSoft : (activeHover ? DS.hover : .clear)
        }
    }

    private var border: Color {
        switch style {
        case .primary:
            return .clear
        case .outlined:
            if active { return .clear }
            return activeHover ? DS.line3 : DS.line2
        case .ghost:
            return .clear
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.43, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background {
                    ZStack {
                        shape.fill(background)
                        if style == .outlined && !active && activeHover {
                            shape.fill(DS.hover)
                        }
                    }
                }
                .overlay(shape.strokeBorder(border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(DSPressStyle(scale: 0.96))
        .opacity(isEnabled ? 1 : 0.4)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
        .onHover { value in
            if reduceMotion {
                hovering = value
            } else {
                withAnimation(DS.Motion.snappy) { hovering = value }
            }
        }
    }
}

/// 只有按压缩放、没有任何底色的按钮样式。
struct DSPressStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect((!reduceMotion && configuration.isPressed) ? scale : 1)
            .animation(reduceMotion ? nil : DS.Motion.snappy, value: configuration.isPressed)
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

/// 小标签：圆点 + 文字，ZCode 圆角徽标形态。
struct DSChip: View {
    var text: String
    var dot: Color? = nil
    var live: Bool = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                DSStatusDot(color: dot, live: live, size: 6)
                    .accessibilityHidden(true)
            }
            Text(L10n.t(text))
                .font(DS.Font.xs.weight(.medium))
                .foregroundStyle(tint ?? DS.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(DS.rect(DS.Radius.sm).fill(tint?.opacity(0.12) ?? DS.hover))
        .overlay(DS.rect(DS.Radius.sm).strokeBorder(tint?.opacity(0.26) ?? DS.line, lineWidth: 1))
        .fixedSize()
    }
}

/// 3pt 细进度条。值为 0 时保持空轨，不画多余的 2px 小点。
struct DSMeter: View {
    var value: Double
    var tint: Color = DS.text2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
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
        .animation(reduceMotion ? nil : DS.Motion.smooth, value: clamped)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((clamped * 100).rounded()))%")
    }
}

/// 小节标题（侧栏分组、表单分组）。
struct DSSectionLabel: View {
    var text: String
    var body: some View {
        Text(L10n.t(text))
            .font(DS.Font.prose(11.5, weight: .medium))
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
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: proxy.size.height - 1 - CGFloat(value / peak) * (proxy.size.height - 2))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Segmented & Button Groups

/// ZCode 风格分段控件。
struct DSSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var size: DSButtonStyle.Size = .regular

    var body: some View {
        NativeSegmented(selection: $selection, options: options, size: size)
    }
}

/// 按钮组容器：紧凑间距排布一组按钮。
struct DSButtonGroup<Content: View>: View {
    var radius: CGFloat = DS.Radius.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
    }
}

// MARK: - Menus & Popovers

/// 统一下拉菜单触发器标签（纯内容排版，外层底色与边框由 `DSMenu` 提供）。
