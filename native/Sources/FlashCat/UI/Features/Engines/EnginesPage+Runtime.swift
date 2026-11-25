// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Active runtime strip

/// 运行中引擎的紧凑状态条：引擎身份、端口、当前加载模型与配置/日志/重启/停止动作。
struct EngineRuntimeStrip: View {
    struct Actions {
        var configure: () -> Void
        var logs: () -> Void
        var restart: () -> Void
        var stop: () -> Void
        var copyEndpoint: () -> Void
    }

    let engine: EngineID
    let version: String?
    let status: ServerState
    let port: Int
    let modelName: String
    let busy: Bool
    let actions: Actions

    private var accent: Color { engineAccent(engine) }
    private var shape: RoundedRectangle { DS.rect(DS.Radius.card) }
    private var lifecycleBusy: Bool { status == .starting || status == .stopping }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identity
                Spacer(minLength: 12)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                controls
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(shape.fill(DS.raised))
        .overlay(shape.strokeBorder(accent.opacity(0.32), lineWidth: 1))
    }

    private var identity: some View {
        HStack(spacing: 11) {
            EngineGlyph(id: engine, color: accent, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(engine.displayName)
                        .font(DS.Font.prose(14.5, weight: .bold))
                        .foregroundStyle(DS.text)
                    DSChip(
                        text: statusText,
                        dot: statusTint,
                        live: status == .ready,
                        tint: statusTint)
                    if let version {
                        Text(version)
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                    }
                }

                HStack(spacing: 8) {
                    Button(action: actions.copyEndpoint) {
                        Text(verbatim: "127.0.0.1:\(port)")
                            .font(DS.Font.mono(11))
                            .foregroundStyle(DS.text2)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("点击复制监听端点"))

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
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Button(action: actions.configure) {
                Label(L10n.t("配置"), systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .disabled(busy)

            Button(action: actions.logs) {
                Label(L10n.t("日志"), systemImage: "doc.plaintext")
            }
            .buttonStyle(.ds(.secondary, size: .regular))

            Button(action: actions.restart) {
                Label(L10n.t("重启"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.ds(.secondary, size: .regular))
            .disabled(busy || lifecycleBusy)
            .help(L10n.t("平滑重启引擎"))

            Button(action: actions.stop) {
                Label(L10n.t("停止"), systemImage: "stop.fill")
            }
            .buttonStyle(.ds(.danger, size: .regular))
            .disabled(lifecycleBusy)
            .help(L10n.t("停止引擎"))
        }
        .fixedSize()
    }

    private var statusText: String {
        switch status {
        case .ready: return "运行中"
        case .starting: return "启动中"
        case .stopping: return "停止中"
        case .failed: return "异常"
        case .stopped: return "已停止"
        }
    }

    private var statusTint: Color {
        switch status {
        case .ready: return DS.ok
        case .starting, .stopping: return DS.warn
        case .failed: return DS.err
        case .stopped: return DS.text4
        }
    }
}
