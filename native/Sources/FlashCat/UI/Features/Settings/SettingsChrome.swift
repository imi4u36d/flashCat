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
            .dsSurface(radius: DS.Radius.card)
            .clipShape(DS.rect(DS.Radius.card))
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

/// 原生分段选择器：用于「外观」（玻璃 / 纯净）与「色彩模式」（跟随系统 / 日间 / 夜间）。
struct AppearanceSegmentedControl<Option: Identifiable & Hashable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    let detail: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        Picker(
            "",
            selection: Binding(
                get: { selection },
                set: { onSelect($0) }
            )
        ) {
            ForEach(options) { option in
                Text(L10n.t(label(option))).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(L10n.t(detail(selection)))
    }
}
