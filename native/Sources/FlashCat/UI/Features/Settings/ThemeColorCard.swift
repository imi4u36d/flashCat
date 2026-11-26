// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

/// 设置 → 通用 → 主题色：预设色点 + 系统取色器 + 三件套预览。
/// 默认图标橙；基底白、状态色和引擎色都不参与换色。
struct ThemeColorCard: View {
    @ObservedObject var theme: ThemeController
    /// ColorPicker 自己拿一份稳定的本地颜色。直接绑 `theme.seedColor` 会让
    /// 系统取色器在初次挂载时把默认色当成一次用户选择写回去，默认主题就被
    /// 意外改成 custom 了。
    @State private var pickerColor = ThemeColorHex.color(hex: ThemePalette.pickerSeed)
    @State private var pickerReady = false

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.t("主题色"))
                            .font(DS.Font.md.weight(.medium))
                            .foregroundStyle(DS.text)
                        Text(L10n.t("默认图标橙；只影响强调色，状态色与引擎色不跟随"))
                            .font(DS.Font.xs)
                            .foregroundStyle(DS.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if theme.preset != .iconOrange {
                        Button(L10n.t("恢复默认")) {
                            theme.resetThemeColor()
                        }
                        .buttonStyle(.ds(.secondary, size: .small))
                        .help(L10n.t("恢复默认"))
                    }
                }

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(ThemePreset.swatches) { preset in
                        ThemeSwatchButton(
                            preset: preset,
                            selected: theme.preset == preset
                        ) {
                            theme.selectPreset(preset)
                        }
                    }
                }

                customPicker

                ThemeColorPreview(palette: theme.palette)
            }
            .padding(16)
            .onAppear {
                pickerColor = theme.seedColor
                pickerReady = true
            }
            .onChange(of: theme.preset) { _, _ in
                pickerColor = theme.seedColor
            }
            .onChange(of: theme.customSeed) { _, _ in
                pickerColor = theme.seedColor
            }
        }
    }

    private var customPicker: some View {
        HStack(spacing: 8) {
            ColorPicker(
                L10n.t("自定义"),
                selection: Binding(
                    get: { pickerColor },
                    set: { newValue in
                        pickerColor = newValue
                        guard pickerReady else { return }
                        theme.setCustomColor(newValue)
                    }
                ),
                supportsOpacity: false
            )
            .controlSize(.small)
            .fixedSize()

            if theme.preset == .custom {
                Text(L10n.t("使用中"))
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.accent)
            }

            Spacer(minLength: 0)
        }
        .help(L10n.t("自定义主题色"))
        .accessibilityLabel(Text(L10n.t("自定义主题色")))
    }
}

private struct ThemeSwatchButton: View {
    let preset: ThemePreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(ThemeColorHex.color(hex: preset.displayHex))
                    .frame(width: 22, height: 22)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ThemeRGBA(hex: preset.displayHex).contrastingText.color)
                }
            }
            .frame(width: 28, height: 28)
            .overlay {
                Circle()
                    .strokeBorder(selected ? DS.text : DS.line2, lineWidth: selected ? 2 : 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(preset.title))
        .accessibilityLabel(Text(L10n.t(preset.title)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 主题色预览：选中行、图表线、发送钮。只用 palette 的 color，保证切主题即时变化。
private struct ThemeColorPreview: View {
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "gauge")
                    .font(.system(size: 10, weight: .medium))
                Text(L10n.t("概览"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(palette.accent.color)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(palette.accentSoft.color))

            Spacer(minLength: 4)

            ThemeMiniChart(palette: palette)

            ZStack {
                Circle()
                    .fill(palette.accentFill.color)
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.onAccent.color)
            }
        }
        .padding(10)
        .background(DS.rect(DS.Radius.md).fill(DS.bg))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("主题色预览")))
    }
}

private struct ThemeMiniChart: View {
    let palette: ThemePalette

    var body: some View {
        GeometryReader { proxy in
            let values: [CGFloat] = [0.72, 0.58, 0.64, 0.38, 0.46, 0.24, 0.30, 0.12]
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height * value
                    let point = CGPoint(x: x, y: y)
                    if index == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(
                palette.chartLine.color,
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 68, height: 24)
        .accessibilityHidden(true)
    }
}
