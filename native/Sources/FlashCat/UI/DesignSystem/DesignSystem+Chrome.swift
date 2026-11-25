// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

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

// MARK: - Page header
/// 页头里的一枚状态：颜色 + 文案，需要时可以呼吸。
struct DSPageStatus {
    var text: String
    var color: Color
    var live: Bool = false

    init(_ text: String, color: Color, live: Bool = false) {
        self.text = text
        self.color = color
        self.live = live
    }
}

/// 控制台页面共用的页头语法：与概览页统一为单行 `34pt` 布局——
/// `20pt` 粗体页名 + 同行 `24pt` 玻璃状态胶囊 + 右侧页面级动作；
/// 窄窗口下自动把动作折到第二行，不挤压标题。
struct DSPageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    var status: DSPageStatus?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 12)
                actionRow
            }
            .frame(height: Console.pageHeaderHeight)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Console.pageHeaderHeight)
                if Actions.self != EmptyView.self {
                    HStack(spacing: DS.Space.sm) {
                        Spacer(minLength: 0)
                        actionRow
                    }
                }
            }
        }
    }

    private var identity: some View {
        HStack(spacing: 10) {
            Text(L10n.t(title))
                .font(DS.Font.prose(20, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(DS.text)
                .fixedSize()

            if subtitle != nil || status != nil {
                HStack(spacing: 6) {
                    if let status {
                        DSStatusDot(color: status.color, live: status.live, size: 6)
                    }
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let status {
                        if subtitle != nil {
                            Text(verbatim: "·")
                                .font(DS.Font.prose(11))
                                .foregroundStyle(DS.text4)
                        }
                        Text(verbatim: status.text)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .dsGlassPill()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: DS.Space.sm) {
            actions()
        }
        .fixedSize()
    }
}

extension DSPageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, status: DSPageStatus? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.actions = { EmptyView() }
    }
}

// MARK: - Buttons

/// ZCode 风格按钮：直角小圆角（`Radius.sm` / `Radius.md`）、1px 发丝边与单色高对比主按钮。
