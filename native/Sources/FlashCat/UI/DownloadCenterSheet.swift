// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 下载中心：正在跑的任务、暂停/失败的行，以及断点续传入口。
struct DownloadCenterSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            DSDivider()
            ScrollView {
                VStack(spacing: 10) {
                    if let model = state.downloadingModel {
                        activeRow(model)
                    }
                    if pendingTasks.isEmpty && state.downloadingModel == nil {
                        EmptyHint(
                            icon: "arrow.down.circle",
                            title: "没有下载任务",
                            detail: "在模型页或模型广场点「下载」，任务会出现在这里；暂停后可以断点续传。"
                        )
                        .padding(.vertical, 30)
                    } else {
                        ForEach(pendingTasks) { task in
                            taskRow(task)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.never)
            DSDivider()
            footer
        }
        .frame(width: 620, height: 460)
        .sheetCanvas()
    }

    /// 正在跑的任务由上面的 `activeRow` 负责，列表里不再重复一份：
    /// 两者都来自同一行任务记录，重复显示会让人以为有两个下载。
    private var pendingTasks: [ModelDownloadTask] {
        state.downloadTasks.filter { task in
            !(task.model == state.downloadingModel && task.engine == state.downloadingEngine)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "arrow.down.circle", color: DS.accent, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("下载中心")
                    .font(DS.Font.lg.weight(.semibold))
                    .foregroundStyle(DS.text)
                Text("进度按已下载字节计算；暂停后继续会从断点接着走")
                    .font(DS.Font.xs)
                    .foregroundStyle(DS.text3)
            }
            Spacer(minLength: 8)
            DSIconButton(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func activeRow(_ model: String) -> some View {
        let fraction = state.downloadFraction ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model)
                    .font(DS.Font.sm.weight(.semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Tag(text: "下载中", tone: .accent)
                Spacer(minLength: 4)
                Text(Format.rate(state.downloadSpeed))
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                Button("暂停") { state.pauseDownload() }
                    .buttonStyle(.ds(.secondary, size: .small))
            }
            Meter(fraction: fraction, tint: DS.accent)
            Text(verbatim: fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(DS.Font.mono(10.5))
                .foregroundStyle(DS.text3)
                .monospacedDigit()
        }
        .padding(12)
        .dsSurface(radius: DS.Radius.md, tint: DS.accent.opacity(0.12), stroke: DS.accent.opacity(0.35))
    }

    private func taskRow(_ task: ModelDownloadTask) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.model)
                        .font(DS.Font.sm.weight(.semibold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Tag(text: statusLabel(task), tone: statusTone(task))
                    if let shared = task.shared, !shared.isEmpty {
                        Tag(text: "共享给 \(shared.map(\.displayName).joined(separator: "/"))", tone: .neutral)
                    }
                }
                Text(detailText(task))
                    .font(DS.Font.mono(10.5))
                    .foregroundStyle(DS.text3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("继续") { state.resumeDownload(task) }
                .buttonStyle(.ds(.secondary, size: .small))
            Button {
                state.removeTask(task)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.ds(.danger, size: .small))
            .help("移除任务并清理半成品")
        }
        .padding(12)
        .dsSurface(radius: DS.Radius.md)
    }

    private func statusLabel(_ task: ModelDownloadTask) -> String {
        switch task.status {
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .failed: return "失败"
        }
    }

    private func statusTone(_ task: ModelDownloadTask) -> TagTone {
        switch task.status {
        case .downloading: return .accent
        case .paused: return .neutral
        case .failed: return .danger
        }
    }

    private func detailText(_ task: ModelDownloadTask) -> String {
        var parts = [task.engine.displayName]
        if task.downloadedBytes > 0 { parts.append(L10n.format("已下载 %@", Format.size(task.downloadedBytes))) }
        if task.totalBytes > 0 { parts.append(L10n.format("共 %@", Format.size(task.totalBytes))) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("半成品目录带 .flashcat-incomplete 标记，不会混进模型库")
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("打开模型总目录") {
                        Paths.ensureDirectory(EnginePaths.modelsRoot)
                        NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
                    }
                    .buttonStyle(.ds(.secondary, size: .regular))
                    Button("完成") { dismiss() }
                        .buttonStyle(.ds(.primary, size: .regular))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
