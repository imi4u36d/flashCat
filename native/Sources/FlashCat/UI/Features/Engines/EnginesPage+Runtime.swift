// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Active runtime strip

/// 运行中引擎的紧凑状态条：监听端点、当前模型与日志入口。
/// 引擎身份、版本、启停与配置都由下方活动卡承担，这里不再重复。
struct EngineRuntimeStrip: View {
    struct Actions {
        var logs: () -> Void
        var copyEndpoint: () -> Void
    }

    let engine: EngineID
    let port: Int
    let modelName: String
    /// 复制监听端点的原位回执。
    let copyFlash: ActionFlash?
    let actions: Actions

    private var accent: Color { engineAccent(engine) }
    private var shape: RoundedRectangle { DS.rect(DS.Radius.card) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 8)
                logButton
            }
            VStack(alignment: .leading, spacing: 8) {
                identity
                logButton
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 2)
        }
        .clipShape(shape)
    }

    private var identity: some View {
        HStack(spacing: 8) {
            EngineGlyph(id: engine, color: accent, size: 28)

            Button(action: actions.copyEndpoint) {
                HStack(spacing: 4) {
                    Text(verbatim: "127.0.0.1:\(port)")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(copyFlash == nil ? DS.text2 : DS.ok)
                    ActionFlashIcon(
                        systemName: "doc.on.doc",
                        flash: copyFlash,
                        size: 9.5,
                        baseColor: DS.text4
                    )
                    .frame(width: 11, height: 11)
                }
            }
            .buttonStyle(.plain)
            .help(copyFlash == .success ? L10n.t("监听端点已复制") : L10n.t("点击复制监听端点"))

            if !modelName.isEmpty {
                Text(verbatim: "·")
                    .foregroundStyle(DS.text4)
                Text(modelName)
                    .font(DS.Font.prose(11.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var logButton: some View {
        Button(action: actions.logs) {
            Label(L10n.t("日志"), systemImage: "doc.plaintext")
        }
        .buttonStyle(.dsGhost)
        .fixedSize()
    }
}
