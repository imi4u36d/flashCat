// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Settings chrome

/// 设置页的分区。每一区只回答一类问题，不再把外观、端口、token 和关于
/// 排成同一张两列长表。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case models
    case api
    case chat
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .models: return "模型来源"
        case .api: return "接口"
        case .chat: return "对话"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "square.stack.3d.up"
        case .api: return "network"
        case .chat: return "bubble.left.and.bubble.right"
        case .about: return "info.circle"
        }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String? = nil
    var trailingTop: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: trailingTop ? .top : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t(title))
                    .font(DS.Font.md.weight(.medium))
                    .foregroundStyle(DS.text)
                if let detail {
                    Text(L10n.t(detail))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
    }
}

extension View {
    /// 只在宽版式里把分段控件按标签宽度钉住；窄版式允许它压缩。
    @ViewBuilder
    func fixedSizeWhen(_ condition: Bool) -> some View {
        if condition { fixedSize() } else { self }
    }
}

// MARK: - Appearance picker

/// 设置页的外观四选一：浅色琉璃 / 深色液态 / 极简纯白 / 极简纯黑。
/// 跟随系统是下面单独一行；这里只负责固定的那四套。
struct AppearanceSkinControl: View {
    @ObservedObject var theme: ThemeController

    private let modes: [AppAppearance] = [.light, .dark, .studio, .studioDark]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(modes, id: \.self) { mode in
                let active = theme.mode == mode
                Button {
                    withAnimation(DS.Motion.smooth) {
                        theme.set(mode)
                    }
                } label: {
                    Text(L10n.t(mode.label))
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? DS.text : DS.text3)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background {
                            if active {
                                Capsule()
                                    .fill(DS.pillActive)
                                    .overlay(Capsule().strokeBorder(DS.pillBorder, lineWidth: 1))
                                    .shadow(color: DS.glassShadow.opacity(0.65), radius: 4, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(DSPressStyle(scale: 0.97))
                .help(L10n.t(mode.detail))
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(2)
        .dsGlassPill()
        .fixedSize()
    }
}
