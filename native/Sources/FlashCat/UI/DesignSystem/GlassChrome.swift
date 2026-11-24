// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI

// MARK: - Wallpaper
//
// 设计稿的桌面底：浅色琉璃是粉彩 mesh，深色液态是极光 mesh，极简纯白是
// 一段接近无色的灰阶。它铺满整个 AppKit 窗口；玻璃窗口以 10pt 的留白浮在上面，
// 半透明层再把壁纸透回来。这里不使用系统桌面，避免换壁纸就换掉品牌色。

struct GlassWallpaper: View {
    var skin: GlassSkin

    var body: some View {
        ZStack {
            switch skin {
            case .light: lightMesh
            case .dark: darkMesh
            case .studio: studioMesh
            case .studioDark: studioDarkMesh
            }
            sheen
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var lightMesh: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                Color(red: 0.66, green: 0.82, blue: 0.99),
                Color(red: 0.85, green: 0.79, blue: 1.00),
                Color(red: 0.89, green: 0.86, blue: 1.00),
                Color(red: 0.63, green: 0.80, blue: 0.99),
                Color(red: 0.88, green: 0.91, blue: 1.00),
                Color(red: 0.72, green: 0.93, blue: 0.85),
                Color(red: 0.99, green: 0.80, blue: 0.62),
                Color(red: 0.79, green: 0.91, blue: 1.00),
                Color(red: 0.72, green: 0.94, blue: 0.89),
            ]
        )
        .overlay(Color.white.opacity(0.10))
    }

    private var darkMesh: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: [
                Color(red: 0.04, green: 0.15, blue: 0.25),
                Color(red: 0.10, green: 0.16, blue: 0.38),
                Color(red: 0.20, green: 0.08, blue: 0.33),
                Color(red: 0.03, green: 0.22, blue: 0.33),
                Color(red: 0.05, green: 0.07, blue: 0.16),
                Color(red: 0.24, green: 0.10, blue: 0.42),
                Color(red: 0.05, green: 0.09, blue: 0.22),
                Color(red: 0.03, green: 0.05, blue: 0.13),
                Color(red: 0.02, green: 0.20, blue: 0.15),
            ]
        )
        .overlay(
            LinearGradient(
                colors: [Color.black.opacity(0.05), Color.black.opacity(0.28)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    private var studioMesh: some View {
        MeshGradient(
            width: 2,
            height: 2,
            points: [[0, 0], [1, 0], [0, 1], [1, 1]],
            colors: [
                Color(red: 0.957, green: 0.965, blue: 0.976),
                Color(red: 0.933, green: 0.945, blue: 0.960),
                Color(red: 0.918, green: 0.933, blue: 0.952),
                Color(red: 0.902, green: 0.918, blue: 0.941),
            ]
        )
    }

    private var studioDarkMesh: some View {
        MeshGradient(
            width: 2,
            height: 2,
            points: [[0, 0], [1, 0], [0, 1], [1, 1]],
            colors: [
                Color(red: 0.086, green: 0.094, blue: 0.110),
                Color(red: 0.071, green: 0.078, blue: 0.094),
                Color(red: 0.059, green: 0.065, blue: 0.078),
                Color(red: 0.098, green: 0.106, blue: 0.125),
            ]
        )
    }

    /// 左上角的一层极淡高光，给壁纸一点方向感。
    private var sheen: some View {
        let strength: Double =
            switch skin {
            case .light: 0.30
            case .dark: 0.05
            case .studio: 0
            case .studioDark: 0.03
            }
        return RadialGradient(
            colors: [
                Color.white.opacity(strength),
                Color.white.opacity(0),
            ],
            center: .topLeading, startRadius: 0, endRadius: 820)
    }
}

// MARK: - Chrome

/// 浮起的玻璃窗口底：真实材质模糊（纯白皮肤关闭）+ 设计稿的半透明窗口色。
struct GlassWindowBackground: View {
    var skin: GlassSkin
    var radius: CGFloat = DS.Radius.window

    var body: some View {
        // 壁纸本身就是一张连续的 mesh，模糊看不出差别；真正的玻璃感来自
        // 半透明窗口色、高光边和投影。省掉材质也让粉彩颜色透得回来。
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(DS.windowFill)
    }
}

