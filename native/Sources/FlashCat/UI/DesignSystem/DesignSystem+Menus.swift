// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

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
                    .foregroundStyle(imageTint ?? (kind == .primary ? DS.inkText : DS.text2))
            }
            if let title {
                Text(L10n.t(title))
                    .font(.system(size: size == .small ? 11.5 : 12.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? DS.inkText : DS.text)
                    .lineLimit(1)
            }
            if let badge {
                Text(L10n.t(badge))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.82) : DS.text2)
                    .lineLimit(1)
                    .fixedSize()
            }
            if trailingChevron && kind != .icon {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(kind == .primary ? DS.inkText.opacity(0.75) : DS.text3)
            }
        }
    }
}

/// 统一 Menu 包装：玻璃 / 描边 / 幽灵下拉按钮；触发器保持图标与文字原色。
struct DSMenu<Label: View, Content: View>: View {
    var kind: DSMenuTriggerLabel.Kind = .secondary
    var size: DSButtonStyle.Size = .regular
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var activeHover: Bool { hovering && isEnabled }

    private var height: CGFloat {
        switch size {
        case .small: return 24
        case .regular: return DS.Layout.controlHeight
        case .large: return 34
        }
    }

    private var horizontalPadding: CGFloat {
        if kind == .icon { return 0 }
        return size == .small ? 9 : 11
    }

    private var radius: CGFloat {
        size == .small ? DS.Radius.sm : DS.Radius.md
    }

    private var shape: RoundedRectangle { DS.rect(radius) }

    private var backgroundColor: Color {
        switch kind {
        case .primary: return activeHover ? DS.ink.opacity(0.88) : DS.ink
        case .secondary: return activeHover ? DS.raised : DS.surface
        case .icon: return activeHover ? DS.raised : DS.surface
        case .ghost: return activeHover ? DS.hover : .clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary, .ghost: return .clear
        case .secondary, .icon: return activeHover ? DS.line3 : DS.line2
        }
    }

    var body: some View {
        Menu {
            content()
        } label: {
            label()
                .padding(.horizontal, horizontalPadding)
                .frame(width: kind == .icon ? height : nil, height: height)
                .background {
                    ZStack {
                        shape.fill(backgroundColor)
                        if (kind == .secondary || kind == .icon) && activeHover {
                            shape.fill(DS.hover)
                        }
                    }
                }
                .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
                .contentShape(shape)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Motion.snappy, value: activeHover)
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

/// 统一 28pt 搜索框：ZCode 风格圆角输入框，实色底 + 1px 边框 + 聚焦微环。
struct DSSearchField: View {
    @Binding var query: String
    var placeholder: String = "搜索"
    var width: CGFloat? = nil

    @FocusState private var focused: Bool

    var body: some View {
        let shape = DS.rect(DS.Radius.md)
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
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("清除搜索"))
                .accessibilityLabel(L10n.t("清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: DS.Layout.controlHeight)
        .background(shape.fill(DS.surface))
        .overlay(shape.strokeBorder(focused ? DS.accent.opacity(0.70) : DS.line2, lineWidth: 1))
        .overlay(
            DS.rect(DS.Radius.md + 1)
                .strokeBorder(focused ? DS.accent.opacity(0.16) : .clear, lineWidth: 2)
                .padding(-1)
        )
        .contentShape(shape)
        .onTapGesture { focused = true }
        .animation(DS.Motion.snappy, value: focused)
    }
}

/// 一行筛选栏：ZCode 分段控件 + 搜索框。
struct DSFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 8) {
            DSSegmented(selection: $selection, options: options)
            DSSearchField(query: $query, placeholder: placeholder, width: maxSearchWidth)
        }
    }
}

// MARK: - Transitions
