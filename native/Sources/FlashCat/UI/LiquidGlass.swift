// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI

/// macOS 26 Liquid Glass 的统一入口。
///
/// 所有需要原生玻璃材质的控件与浮层都通过这里取材质，避免每个视图各写一份
/// `glassEffect` 参数。玻璃只用于导航层、浮层、标题栏与交互控件；正文阅读区
/// 保持清晰对比，不在内容文字上叠玻璃模糊。
struct LiquidGlassSurface<S: Shape>: View {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false
    var clear: Bool = false

    var body: some View {
        shape
            .fill(.clear)
            .glassEffect(glass, in: shape)
    }

    private var glass: Glass {
        var glass: Glass = clear ? .clear : .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }
}

extension View {
    /// 在视图上应用一层原生 Liquid Glass。
    func liquidGlassSurface<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        clear: Bool = false
    ) -> some View {
        var glass: Glass = clear ? .clear : .regular
        if let tint {
            glass = glass.tint(tint)
        }
        if interactive {
            glass = glass.interactive()
        }
        return glassEffect(glass, in: shape)
    }
}

/// 悬浮玻璃面板：侧栏这类「浮在画布上」的整块容器使用。
///
/// 底层使用 macOS 26 原生 `.glassEffect(.regular, in: shape)` 折射画布与桌面壁纸，
/// 外围配 0.8pt 极细高光折射边与柔和环境投影，与右侧主视口拉开层次。
struct LiquidGlassPanel<Content: View>: View {
    var radius: CGFloat = 22
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var rim: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(scheme == .dark ? 0.24 : 0.72),
                Color.white.opacity(scheme == .dark ? 0.04 : 0.14),
                Color.white.opacity(scheme == .dark ? 0.14 : 0.42),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        content()
            .glassEffect(.regular, in: shape)
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.24 : 0.04),
                radius: 10, x: 0, y: 4)
    }
}

/// 弹层画布：macOS 26 原生半透明毛玻璃材质 + 轻微画布底色，保持透气与文本可读性。
struct SheetCanvas: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            DS.canvas.opacity(0.42)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// 给弹层铺原生半透明材质画布。
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
