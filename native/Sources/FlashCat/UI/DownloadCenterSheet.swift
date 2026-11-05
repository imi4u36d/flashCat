import SwiftUI
import AppKit
import FlashCatKit

/// 下载中心：正在跑的任务、暂停/失败的行，以及断点续传入口。
struct DownloadCenterSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ScrollView {
                VStack(spacing: 0) {
                    if let model = state.downloadingModel {
                        activeRow(model)
                        Hairline()
                    }
                    if state.downloadTasks.isEmpty && state.downloadingModel == nil {
                        EmptyHint(icon: "arrow.down.circle",
                                  title: "没有下载任务",
                                  detail: "在模型页或模型广场点「下载」，任务会出现在这里；暂停后可以断点续传。")
                            .padding(.vertical, 40)
                    } else {
                        ForEach(state.downloadTasks) { task in
                            taskRow(task)
                            Hairline()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            Hairline()
            footer
        }
        .frame(width: 620, height: 460)
        .background(Native.canvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArcadeIcon(symbol: "arrow.down.circle",
                       colors: [Native.blue, Native.cyan],
                       size: 28,
                       glyphScale: 0.48,
                       glow: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("下载中心")
                    .font(.system(size: 15, weight: .semibold))
                Text("进度按已下载字节计算；暂停后继续会从断点接着走")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer(minLength: 8)
            IconAction(systemName: "xmark", help: "关闭") { dismiss() }
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 14)
    }

    private func activeRow(_ model: String) -> some View {
        let fraction = state.downloadFraction ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Tag(text: "下载中", tone: .accent)
                Spacer(minLength: 4)
                Text(Format.rate(state.downloadSpeed))
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                Button("暂停") { state.pauseDownload() }
                    .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            }
            Meter(fraction: fraction, tint: Native.accent)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 11)
    }

    private func taskRow(_ task: ModelDownloadTask) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.model)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Native.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Tag(text: task.status == .paused ? "已暂停" : "失败",
                        tone: task.status == .paused ? .neutral : .danger)
                    if let shared = task.shared, !shared.isEmpty {
                        Tag(text: "共享给 \(shared.map(\.displayName).joined(separator: "/"))", tone: .neutral)
                    }
                }
                Text(detailText(task))
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("继续") { state.resumeDownload(task) }
                .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            Button {
                state.removeTask(task)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(ArcadePillStyle(tone: .quietDanger, compact: true))
            .help("移除任务并清理半成品")
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 11)
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
                .foregroundStyle(Native.tertiary)
            Spacer(minLength: 0)
            Button("打开模型总目录") {
                Paths.ensureDirectory(EnginePaths.modelsRoot)
                NSWorkspace.shared.open(URL(fileURLWithPath: EnginePaths.modelsRoot))
            }
            .buttonStyle(.arcadeGlass)
            Button("完成") { dismiss() }
                .buttonStyle(.arcadePill)
        }
        .padding(.horizontal, Native.pagePadding)
        .padding(.vertical, 12)
    }
}
