// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - Active runtime hero
//
// 参考稿的第一屏：左侧引擎身份 + 状态，右侧配置 / 日志 / 重启 / 停止；
// 下面四格读数分别是监听端点、当前加载模型、统一内存与投机解码。
// 它是整页唯一的强调卡片，颜色跟着当前引擎走。

struct EngineRuntimeCard: View {
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
    let modelID: String
    let stats: ServerStats?
    let decodeRate: Double
    let busy: Bool
    let actions: Actions

    private var accent: Color { engineAccent(engine) }
    private var shape: RoundedRectangle { DS.rect(DS.Radius.card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    identity
                    Spacer(minLength: 12)
                    controls
                }
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    controls
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    endpointTile
                    modelTile
                    memoryTile
                    speculationTile
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    endpointTile
                    modelTile
                    memoryTile
                    speculationTile
                }
            }
        }
        .padding(16)
        .background {
            ZStack {
                shape.fill(DS.raised)
                shape.fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.14),
                            accent.opacity(0.04),
                            DS.ok.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
            }
        }
        .overlay {
            shape.strokeBorder(accent.opacity(0.34), lineWidth: 1)
        }
        .shadow(color: accent.opacity(0.10), radius: 14, y: 4)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(alignment: .center, spacing: 12) {
            EngineGlyph(id: engine, color: accent, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(engine.displayName)
                        .font(DS.Font.prose(16, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(DS.text)
                        .lineLimit(1)

                    DSChip(
                        text: statusText,
                        dot: statusTint,
                        live: status == .ready,
                        tint: statusTint)

                    if let version {
                        Text(version)
                            .font(DS.Font.mono(10.5))
                            .foregroundStyle(DS.text3)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(DS.rect(6).fill(DS.pillFill))
                            .overlay(DS.rect(6).strokeBorder(DS.line, lineWidth: 1))
                            .fixedSize()
                    }
                }

                Text(L10n.t(engine.descriptor.summary))
                    .font(DS.Font.prose(12.5))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(L10n.t(engine.descriptor.summary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var lifecycleBusy: Bool {
        status == .starting || status == .stopping
    }

    // MARK: Metrics

    private var endpointTile: some View {
        Button(action: actions.copyEndpoint) {
            metricTile(label: "监听端点") {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(DS.text4)
            } content: {
                Text(verbatim: "127.0.0.1:\(port)")
                    .font(DS.Font.mono(12.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .help(L10n.t("点击复制监听端点"))
    }

    private var modelTile: some View {
        metricTile(label: "当前加载模型") {
            Image(systemName: "cube.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(DS.text4)
        } content: {
            Text(modelName.isEmpty ? L10n.t("未选择模型") : modelName)
                .font(DS.Font.prose(12.5, weight: .semibold))
                .foregroundStyle(modelName.isEmpty ? DS.text4 : DS.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(modelID.isEmpty ? L10n.t("未选择模型") : modelID)
        }
    }

    private var memoryTile: some View {
        metricTile(label: "显存 / 统一内存占用") {
            Text(verbatim: memoryAccessory)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(DS.text4)
                .lineLimit(1)
        } content: {
            HStack(spacing: 6) {
                Text(verbatim: memoryText)
                    .font(DS.Font.number(13, weight: .bold))
                    .foregroundStyle(memoryText == "—" ? DS.text4 : DS.text)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                OverviewMiniBar(
                    value: memoryFraction,
                    tint: DS.accentBlue,
                    gradientTo: DS.accent)
            }
        }
    }

    private var speculationTile: some View {
        metricTile(label: "投机解码") {
            DSStatusDot(color: speculationTint, size: 5)
        } content: {
            Text(verbatim: speculationText)
                .font(DS.Font.prose(12.5, weight: .semibold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .truncationMode(.tail)
        }
    }

    private func metricTile<Accessory: View, Content: View>(
        label: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(L10n.t(label))
                    .font(.system(size: 11))
                    .foregroundStyle(DS.text3)
                    .lineLimit(1)
                Spacer(minLength: 2)
                accessory()
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        .dsSubcard(radius: 10)
    }

    // MARK: Readings

    private var statusText: String {
        switch status {
        case .ready: return L10n.t("运行中")
        case .starting: return L10n.t("启动中")
        case .stopping: return L10n.t("停止中")
        case .failed: return L10n.t("异常")
        case .stopped: return L10n.t("已停止")
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

    private var memoryText: String {
        guard let bytes = stats?.memoryBytes, bytes > 0 else { return "—" }
        return Format.memory(bytes)
    }

    private var memoryAccessory: String {
        if let format = stats?.kvFormat, !format.isEmpty {
            return format.uppercased()
        }
        return L10n.t("统一内存")
    }

    private var memoryFraction: Double {
        if let used = stats?.memoryBytes, let total = stats?.physicalMemoryBytes, total > 0 {
            return min(1, max(0, Double(used) / Double(total)))
        }
        switch stats?.memoryPressure {
        case .some("critical"): return 0.94
        case .some("warning"): return 0.72
        case .some: return 0.45
        case .none: return 0
        }
    }

    private var speculationText: String {
        guard decodeRate > 0 else { return engine.speculationLabel }
        return "\(engine.speculationLabel) · \(Format.compact(decodeRate)) tok/s"
    }

    private var speculationTint: Color {
        engine.capabilities.contains(.mtp) || engine.capabilities.contains(.draft)
            ? DS.ok : DS.text4
    }
}

// MARK: - Idle state

/// 没有运行中引擎时的紧凑空态：已安装引擎直接给一键启动，未安装则指向下方目录。
struct EngineIdleRuntimeCard: View {
    let installed: [EngineID]
    let active: EngineID
    let hasSelection: Bool
    let switching: Bool
    let failureMessage: String?
    let start: (EngineID) -> Void

    private var shape: RoundedRectangle { DS.rect(DS.Radius.card) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 12)
                quickStart
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                quickStart
            }
        }
        .padding(16)
        .background(shape.fill(DS.surface))
        .overlay {
            shape.strokeBorder(
                DS.line2,
                style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .shadow(color: DS.glassShadow.opacity(0.6), radius: 10, y: 3)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                DS.rect(12).fill(DS.bg)
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DS.text3)
            }
            .frame(width: 40, height: 40)
            .overlay(DS.rect(12).strokeBorder(DS.line, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("当前无运行中引擎"))
                    .font(DS.Font.prose(13.5, weight: .semibold))
                    .foregroundStyle(DS.text)

                Text(
                    installed.isEmpty
                        ? L10n.t("请先从下方引擎目录下载并安装至少一款本地推理引擎。")
                        : L10n.t("从已安装引擎中一键启动，即可恢复本地推理服务与 API 监听。")
                )
                .font(DS.Font.prose(12))
                .foregroundStyle(DS.text3)
                .fixedSize(horizontal: false, vertical: true)

                if let failureMessage {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5))
                            .padding(.top, 1)
                        Text(failureMessage)
                            .font(DS.Font.prose(11))
                            .lineLimit(2)
                    }
                    .foregroundStyle(DS.warn)
                    .help(failureMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickStart: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(installed, id: \.self) { id in
                Button {
                    start(id)
                } label: {
                    Label(
                        L10n.format("启动 %@", id.displayName),
                        systemImage: "play.fill")
                }
                .buttonStyle(OverviewTintActionStyle(tint: DS.ok))
                .disabled(switching || (id == active && !hasSelection))
                .help(startHelp(id))
            }
        }
    }

    private func startHelp(_ id: EngineID) -> String {
        if switching { return L10n.t("正在切换模型…") }
        if id == active, !hasSelection { return L10n.t("请先选择模型") }
        return L10n.format("启动 %@", id.displayName)
    }
}
