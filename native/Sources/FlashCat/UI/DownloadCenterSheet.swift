import SwiftUI
import AppKit
import FlashCatKit

/// 下载中心：正在跑的任务、暂停/失败的行，以及断点续传入口。
///
/// 视觉沿用控制台的 Liquid Glass 语言：标题栏图标与按钮用玻璃材质，
/// 任务行是内容卡片，只靠层级底色区分，不再使用旧的暖色 Native 调色板。
struct DownloadCenterSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(spacing: 10) {
                    if let model = state.downloadingModel {
                        activeRow(model)
                    }
                    if pendingTasks.isEmpty && state.downloadingModel == nil {
                        EmptyHint(icon: "arrow.down.circle",
                                  title: "没有下载任务",
                                  detail: "在模型页或模型广场点「下载」，任务会出现在这里；暂停后可以断点续传。")
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
            Hairline()
            footer
        }
        .frame(width: 620, height: 460)
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
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Console.accent)
                .frame(width: 34, height: 34)
                .background {
                    LiquidGlassSurface(shape: Circle())
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("下载中心")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Console.text)
                Text("进度按已下载字节计算；暂停后继续会从断点接着走")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Console.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    private func activeRow(_ model: String) -> some View {
        let fraction = state.downloadFraction ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Tag(text: "下载中", tone: .accent)
                Spacer(minLength: 4)
                Text(Format.rate(state.downloadSpeed))
                    .font(Native.monoSmall)
                    .foregroundStyle(Console.tertiary)
                Button("暂停") { state.pauseDownload() }
                    .buttonStyle(ConsolePillStyle(tone: .secondary, compact: true))
            }
            Meter(fraction: fraction, tint: Console.accent)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(Native.monoSmall)
                .foregroundStyle(Console.tertiary)
        }
        .padding(12)
        .background { rowBackground(tint: Console.accentSoft) }
    }

    private func taskRow(_ task: ModelDownloadTask) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.model)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Console.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Tag(text: statusLabel(task), tone: statusTone(task))
                    if let shared = task.shared, !shared.isEmpty {
                        Tag(text: "共享给 \(shared.map(\.displayName).joined(separator: "/"))", tone: .neutral)
                    }
                }
                Text(detailText(task))
                    .font(Native.monoSmall)
                    .foregroundStyle(Console.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("继续") { state.resumeDownload(task) }
                .buttonStyle(ConsolePillStyle(tone: .secondary, compact: true))
            Button {
                state.removeTask(task)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ConsolePillStyle(tone: .danger, compact: true))
            .help("移除任务并清理半成品")
        }
        .padding(12)
        .background { rowBackground(tint: Console.inset) }
    }

    private func rowBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Console.insetStroke, lineWidth: 0.8)
            }
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
        if task.downloadedBytes > 0 { parts.append("已下载 \(Format.bytes(task.downloadedBytes))") }
        if task.totalBytes > 0 { parts.append("共 \(Format.bytes(task.totalBytes))") }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("半成品目录带 .flashcat-incomplete 标记，不会混进模型库")
                .font(.system(size: 10))
                .foregroundStyle(Console.tertiary)
            Spacer(minLength: 0)
            Button("打开模型总目录") {
                Paths.ensureDirectory(EnginePaths.modelsRoot)
                NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
            }
            .buttonStyle(.consoleSecondary)
            Button("完成") { dismiss() }
                .buttonStyle(.consolePrimary)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }
}
