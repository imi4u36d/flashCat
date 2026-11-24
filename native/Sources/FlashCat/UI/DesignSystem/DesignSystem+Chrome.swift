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

/// 七个页面共用的页头语法：页名 + 一行状态 + 页面级动作。
///
/// 之前每页开头都不一样——概览把模型名当标题、引擎页写「运行时」、模型/日志/
/// 实验只有筛选条、设置直接是卡片。切页时第一眼没有锚点，用户只能靠侧栏高亮
/// 判断自己在哪。这里把「页名回到导航、状态说一句现场」固定成一套版式。
struct DSPageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    var status: DSPageStatus?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(DS.Font.title)
                    .tracking(-0.3)
                    .foregroundStyle(DS.text)
                    .lineLimit(1)

                if subtitle != nil || status != nil {
                    HStack(spacing: 6) {
                        if let status {
                            DSStatusDot(color: status.color, live: status.live, size: 6)
                        }
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(DS.Font.prose(12))
                                .foregroundStyle(DS.text3)
                                .lineLimit(1)
                        }
                        if let status {
                            if subtitle != nil {
                                Text(verbatim: "·")
                                    .font(DS.Font.prose(12))
                                    .foregroundStyle(DS.text4)
                            }
                            Text(verbatim: status.text)
                                .font(DS.Font.prose(12))
                                .foregroundStyle(status.color)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: DS.Space.md)

            HStack(spacing: DS.Space.sm) {
                actions()
            }
            .fixedSize()
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
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
