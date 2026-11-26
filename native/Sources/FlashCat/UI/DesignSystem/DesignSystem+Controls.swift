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
    /// 展开态的入口：保持同一颗按钮，只把底与边换成强调色的软底。
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, size: size, isActive: isActive)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let size: DSButtonStyle.Size
    let isActive: Bool

    @Environment(\.isEnabled) private var isEnabled

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
        if isActive, kind == .secondary { return DS.accent }
        switch kind {
        case .primary: return DS.inkText
        case .secondary: return DS.text
        case .ghost: return DS.text2
        case .danger: return DS.dangerText
        }
    }

    private var background: Color {
        if isActive, kind == .secondary { return DS.accentSoft }
        switch kind {
        case .primary: return DS.ink
        case .secondary: return DS.surface
        case .ghost: return .clear
        case .danger: return DS.dangerFill
        }
    }

    private var borderColor: Color {
        if isActive, kind == .secondary { return DS.accent.opacity(0.45) }
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary: return DS.line2
        case .danger: return DS.dangerStroke
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: size == .large ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsGhost: DSButtonStyle { DSButtonStyle(kind: .ghost) }
    static var dsDanger: DSButtonStyle { DSButtonStyle(kind: .danger) }
    static func ds(
        _ kind: DSButtonStyle.Kind,
        size: DSButtonStyle.Size = .regular,
        active: Bool = false
    ) -> DSButtonStyle {
        DSButtonStyle(kind: kind, size: size, isActive: active)
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
    /// 动作结果的原位回执：短暂把图标换成对勾 / 感叹号，再自动还原。
    var flash: ActionFlash? = nil
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var shape: RoundedRectangle {
        DS.rect(size <= 24 ? DS.Radius.sm : DS.Radius.md)
    }

    private var foreground: Color {
        switch style {
        case .primary:
            return tint != nil ? .white : DS.inkText
        case .outlined:
            if active { return tint != nil ? .white : DS.inkText }
            return tint ?? (hovering ? DS.text : DS.text2)
        case .ghost:
            return tint ?? (active ? DS.accent : (hovering ? DS.text : DS.text2))
        }
    }

    private var background: Color {
        if let flash { return flash.tint.opacity(hovering ? 0.20 : 0.13) }
        switch style {
        case .primary:
            return tint ?? DS.ink
        case .outlined:
            return active ? (tint ?? DS.ink) : DS.surface
        case .ghost:
            return active ? DS.accentSoft : (hovering ? DS.hover : .clear)
        }
    }

    private var border: Color {
        if let flash { return flash.tint.opacity(0.34) }
        switch style {
        case .primary, .ghost: return .clear
        case .outlined: return active ? .clear : DS.line2
        }
    }

    var body: some View {
        Button(action: action) {
            ActionFlashIcon(
                systemName: systemName,
                flash: flash,
                size: size * 0.43,
                baseColor: foreground
            )
            .frame(width: size, height: size)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(isEnabled ? 1 : 0.4)
        .help(L10n.t(help))
        .accessibilityLabel(L10n.t(help))
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
/// 默认用填充橙 + 可可前景；错误角标由调用方传白字。
struct DSBadge: View {
    var count: Int
    var tint: Color = DS.accentFill
    var foreground: Color = DS.onAccent

    var body: some View {
        Text(verbatim: "\(count)")
            .font(DS.Font.mono(9.5, weight: .bold))
            .foregroundStyle(foreground)
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

/// 状态圆点；`live` 时加一层静态柔光环，避免常驻无限动画消耗 CPU/GPU。
struct DSStatusDot: View {
    var color: Color = DS.ok
    var live: Bool = false
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            if live {
                Circle()
                    .fill(color.opacity(0.22))
                    .frame(width: size * 1.9, height: size * 1.9)
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
        .background(Capsule().fill(tint?.opacity(0.12) ?? DS.pillFill))
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
