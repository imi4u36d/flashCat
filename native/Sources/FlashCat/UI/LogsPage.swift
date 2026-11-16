// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import SwiftUI
import AppKit
import FlashCatKit

/// 日志页：顶部过滤条 + 一块玻璃控制台，版式对齐 WebUI。
struct LogsPage: View {
    @ObservedObject var state: AppState
    @State private var selectedEngine: EngineID?
    @State private var level: LogsFilter = .all
    @State private var query = ""
    /// 输入框里的搜索词停顿后再用于过滤，避免每次按键都扫一遍几千行日志。
    @State private var appliedQuery = ""
    @State private var paused = false
    @State private var frozen: [LogLine] = []
    @State private var expanded: Set<Int> = []
    @State private var hoveredId: Int?

    private var effectiveEngine: EngineID {
        selectedEngine ?? state.activeEngine
    }

    /// 展开详情里的完整时间，和行首的 HH:mm:ss 互补。
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func display() -> LogsDigest {
        LogsDigest.make(from: paused ? frozen : state.logs(for: effectiveEngine),
                        level: level,
                        query: appliedQuery)
    }

    var body: some View {
        let data = display()
        VStack(alignment: .leading, spacing: 14) {
            topBar(data)
            console(data)
        }
        .padding(.horizontal, Console.contentPadding)
        .padding(.top, Console.contentTopInset)
        .padding(.bottom, Console.contentBottomInset)
        .task(id: query) {
            if query == appliedQuery { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
    }

    private func topBar(_ data: LogsDigest) -> some View {
        // 窄窗口下过滤条和右侧动作放不进一行，自动折成上下两行。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                filterBar(data)
                Spacer(minLength: 0)
                actionButtons(data)
            }
            VStack(alignment: .leading, spacing: 10) {
                filterBar(data)
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    actionButtons(data)
                }
            }
        }
    }

    private func filterBar(_ data: LogsDigest) -> some View {
        DSFilterBar(selection: $level,
                    options: LogsFilter.allCases.map { item in
                        (item, "\(item.label) (\(data.counts[item] ?? 0))")
                    },
                    query: $query,
                    placeholder: "搜索")
    }

    @ViewBuilder
    private func actionButtons(_ data: LogsDigest) -> some View {
        DSIconButton(systemName: "doc.on.doc", help: "复制筛选后的日志", size: 28) {
            state.copy(data.lines.map(\.text).joined(separator: "\n"), label: "已复制筛选后的日志")
        }
        .disabled(data.lines.isEmpty)

        DSIconButton(systemName: "doc.text", help: "打开日志文件", size: 28) {
            let path = EnginePaths.logFile(effectiveEngine)
            guard Paths.fileExists(path) else {
                state.toast("日志文件尚未创建")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }

        Button {
            if paused {
                paused = false
                frozen = []
            } else {
                frozen = state.logs(for: effectiveEngine)
                paused = true
            }
        } label: {
            Label(L10n.t(paused ? "继续" : "暂停"), systemImage: paused ? "play.fill" : "pause.fill")
        }
        .buttonStyle(.ds(.secondary, size: .regular))

        DSIconButton(systemName: "trash", help: "清空日志", size: 28) {
            state.clearLogs(for: effectiveEngine)
            frozen = []
        }
    }

    private var engineLogMenu: some View {
        DSMenu {
            DSMenuTriggerLabel(title: "\(effectiveEngine.rawValue).log", size: .small)
        } content: {
            ForEach(EngineCatalog.allIDs, id: \.self) { id in
                Button {
                    selectedEngine = id
                    paused = false
                    frozen = []
                    expanded = []
                } label: {
                    let suffix = id == state.activeEngine ? " · \(L10n.t("当前"))" : ""
                    if id == effectiveEngine {
                        Label("\(id.rawValue).log\(suffix)", systemImage: "checkmark")
                    } else {
                        Text("\(id.rawValue).log\(suffix)")
                    }
                }
            }
        }
        .help(L10n.t("切换查看不同引擎的日志"))
    }

    private func console(_ data: LogsDigest) -> some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    DSStatusDot(color: paused ? DS.warn : DS.ok, live: !paused, size: 6)
                    Text(verbatim: paused ? "PAUSED" : "LIVE")
                        .font(DS.Font.mono(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(paused ? DS.warn : DS.ok)
                    engineLogMenu
                    Spacer(minLength: 0)
                    Text("\(data.lines.count) 行")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 38)

                DSDivider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        // 新行从顶上插入，跟随「最新」的方式就是回到顶部。
                        Color.clear.frame(height: 1).id("logTop")
                        if data.lines.isEmpty {
                            Text("启动引擎后，日志会实时出现在这里")
                                .font(DS.Font.sm)
                                .foregroundStyle(DS.text3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(data.lines) { line in
                                row(line).id(line.id)
                            }
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.top)
                .onChange(of: data.lines.count) { _, _ in
                    guard !paused else { return }
                    proxy.scrollTo("logTop", anchor: .top)
                }
            }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ line: LogLine) -> some View {
        let tone = Console.levelColor(line.level)
        let isExpanded = expanded.contains(line.id)
        let isHovered = hoveredId == line.id
        let highlighted = isHovered || isExpanded

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.smooth) {
                    if isExpanded { expanded.remove(line.id) } else { expanded.insert(line.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(line.clockText)
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .leading)

                    HStack(spacing: 5) {
                        DSStatusDot(color: tone, live: false, size: 5)
                        Text(line.level.label)
                            .font(DS.Font.mono(9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(tone)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: 62, height: 18, alignment: .leading)
                    .background {
                        DS.rect(4).fill(tone.opacity(0.12))
                    }
                    .overlay {
                        DS.rect(4).strokeBorder(tone.opacity(0.25), lineWidth: 1)
                    }

                    Text(line.text)
                        .font(DS.Font.mono(11.5))
                        .foregroundStyle(line.level == .error ? DS.err : DS.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(DS.text3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(highlighted ? 1 : 0.3)
                        .frame(width: 10)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit)
            .help(L10n.t(isExpanded ? "收起详情" : "展开详情"))

            if isExpanded {
                detail(line)
                    .padding(.leading, 76)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .background {
            DS.rect(DS.Radius.sm)
                .fill(highlighted ? DS.hover : .clear)
        }
        .onHover { hovering in
            withAnimation(DS.Motion.snappy) {
                if hovering {
                    hoveredId = line.id
                } else if hoveredId == line.id {
                    hoveredId = nil
                }
            }
        }
    }

    /// 展开后的详情：可换行的完整正文 + 元信息 + 单行复制。
    private func detail(_ line: LogLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line.text)
                .font(DS.Font.mono(11.5))
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Label(Self.fullDateFormatter.string(from: line.time), systemImage: "clock")
                Label("\(line.text.count) 字符", systemImage: "textformat.size")
                Spacer(minLength: 0)
                Button {
                    state.copy(line.text, label: "已复制该行日志")
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.ds(.secondary, size: .small))
            }
            .font(DS.Font.mono(10.5))
            .foregroundStyle(DS.text3)
            .labelStyle(.titleAndIcon)
        }
        .padding(10)
        .background {
            DS.rect(DS.Radius.md)
                .fill(DS.bg)
        }
        .overlay {
            DS.rect(DS.Radius.md)
                .strokeBorder(DS.line, lineWidth: 1)
        }
    }
}

/// 日志页要展示的行与计数。一次遍历同时得到「按级别计数」和「按级别 +
/// 搜索词过滤后的行」；以前 body 里会多次求值 `lines`，每求值一次就全表
/// 过滤一遍，还要为四个级别各扫一次日志。
///
/// 页面按「最新在最上面」阅读，所以这里把过滤后的行翻成倒序；`LogStore`
/// 仍是追加顺序——`AppState` 靠 `logs.last?.id` 判断有没有新行。
struct LogsDigest {
    var lines: [LogLine] = []
    var counts: [LogsFilter: Int] = [:]

    static func make(from source: [LogLine], level: LogsFilter, query: String) -> LogsDigest {
        var result = LogsDigest()
        result.lines.reserveCapacity(source.count)
        for line in source {
            result.counts[.all, default: 0] += 1
            switch line.level {
            case .warning: result.counts[.warning, default: 0] += 1
            case .error: result.counts[.error, default: 0] += 1
            default: result.counts[.info, default: 0] += 1
            }
            guard level.matches(line.level) else { continue }
            if !query.isEmpty, !line.text.localizedCaseInsensitiveContains(query) { continue }
            result.lines.append(line)
        }
        result.lines.reverse()
        return result
    }
}

enum LogsFilter: String, CaseIterable, Identifiable {
    case all, info, warning, error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "全部"
        case .info: return "提示"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    func matches(_ level: LogLevel) -> Bool {
        switch self {
        case .all: return true
        case .info: return level == .info || level == .system || level == .success
        case .warning: return level == .warning
        case .error: return level == .error
        }
    }
}
