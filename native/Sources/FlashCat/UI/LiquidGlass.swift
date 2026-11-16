// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI

/// macOS 26 Liquid Glass 的统一入口。
///
/// 所有需要原生玻璃材质的自定义控件都通过这里取材质，避免每个视图各写一份
/// `glassEffect` 参数。玻璃只用于导航层、浮层与控件；正文卡片仍然靠层级排版，
/// 不把内容本身也做成玻璃。
struct LiquidGlassSurface<S: Shape>: View {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false

    // Direction B：分层靠描边而不是玻璃。API 保持不变，
    // 所有旧调用点自动变成「raised 底 + 1px 描边」的平面控件。
    var body: some View {
        ZStack {
            shape.fill(DS.raised)
            if let tint { shape.fill(tint) }
        }
        .overlay(shape.stroke(DS.line2, lineWidth: 1))
    }
}

extension View {
    /// 在视图背后加一层原生 Liquid Glass。
    func liquidGlassSurface<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        background {
            LiquidGlassSurface(shape: shape, tint: tint, interactive: interactive)
        }
    }
}

/// 悬浮玻璃面板：导航列这类「浮在画布上」的整块容器使用。
///
/// 使用温润的半透明侧栏底色 + 极细单层描边与柔和阴影，避免强高光反光边。
struct LiquidGlassPanel<Content: View>: View {
    var radius: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(DS.bg)
    }
}

/// 弹层画布：DS 画布底色。
struct SheetCanvas: View {
    var body: some View {
        DS.canvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

extension View {
    /// 给弹层铺纯色画布，替代系统默认窗口底色。
    func sheetCanvas() -> some View {
        background { SheetCanvas() }
    }
}

/// 兼容别名：转发到 `DSSegmented`。
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var embedded: Bool = false

    var body: some View {
        DSSegmented(selection: $selection, options: options)
    }
}

/// 兼容别名：转发到 `DSFilterBar`。
struct GlassFilterBar<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    @Binding var query: String
    var placeholder: String
    var maxSearchWidth: CGFloat = 200

    var body: some View {
        DSFilterBar(
            selection: $selection,
            options: options,
            query: $query,
            placeholder: placeholder,
            maxSearchWidth: maxSearchWidth)
    }
}
