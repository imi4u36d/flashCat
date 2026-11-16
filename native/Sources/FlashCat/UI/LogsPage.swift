// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatKit
import SwiftUI

/// 日志页：顶部过滤条 + 一块玻璃控制台，版式对齐 WebUI。
///
/// 默认看的是「全部日志」——每台已装引擎的尾巴按时间并成一份；只想盯一台时
/// 从 LIVE 旁的菜单里挑。以前这里默认就是当前引擎，别台引擎的报错要切过去才
/// 看得见，出问题时反而先多一步。
struct LogsPage: View {
    @ObservedObject var state: AppState
    @State private var source: LogFeedSource = .all
    @State private var level: LogsFilter = .all
    @State private var query = ""
    /// 输入框里的搜索词停顿后再用于过滤，避免每次按键都扫一遍几千行日志。
    @State private var appliedQuery = ""
    @State private var paused = false
    @State private var frozen: [LogFeedEntry] = []
    @State private var expanded: Set<String> = []
    @State private var hoveredId: String?

    /// 选中的引擎被卸载后回落到「全部日志」：菜单里已经没有这一项了。
    private var effectiveSource: LogFeedSource {
        if case .engine(let id) = source, !state.availableEngines.contains(id) { return .all }
        return source
    }

    /// 展开详情里的完整时间，和行首的 HH:mm:ss 互补。
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func display() -> LogsDigest {
        LogsDigest.make(
            from: paused ? frozen : state.logEntries(for: effectiveSource),
            level: level,
            query: appliedQuery)
    }

    var body: some View {
        let data = display()
        VStack(alignment: .leading, spacing: 10) {
            topBar(data)
                .padding(.top, Console.pageTopPadding)
                .background(WindowDragArea())
            console(data)
                .padding(.horizontal, Console.contentPadding)
        }
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
            .frame(height: DS.Layout.titlebarHeight)
            .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
            .padding(.trailing, Console.contentPadding)

            VStack(alignment: .leading, spacing: 10) {
                filterBar(data)
                    .frame(height: DS.Layout.titlebarHeight)
                    .padding(.leading, Console.topBarLeading(sidebarShown: state.showsSidebar))
                    .padding(.trailing, Console.contentPadding)
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    actionButtons(data)
                }
                .padding(.horizontal, Console.contentPadding)
            }
        }
    }

    private func filterBar(_ data: LogsDigest) -> some View {
        DSFilterBar(
            selection: $level,
            options: LogsFilter.allCases.map { item in
                (item, "\(item.label) (\(data.counts[item] ?? 0))")
            },
            query: $query,
            placeholder: "搜索")
    }

    @ViewBuilder
    private func actionButtons(_ data: LogsDigest) -> some View {
        HStack(spacing: 8) {
            DSIconButton(systemName: "doc.on.doc", help: "复制筛选后的日志", size: 28, style: .outlined) {
                let text = LogFeed.clipboardText(data.lines, tagged: effectiveSource == .all)
                state.copy(text, label: "已复制筛选后的日志")
            }
            .disabled(data.lines.isEmpty)

            DSIconButton(
                systemName: effectiveSource == .all ? "folder" : "doc.text",
                help: effectiveSource == .all ? "打开日志目录" : "打开日志文件",
                size: 28, style: .outlined
            ) {
                openLogsLocation()
            }

            Button {
                if paused {
                    paused = false
                    frozen = []
                } else {
                    frozen = state.logEntries(for: effectiveSource)
                    paused = true
                }
            } label: {
                Label(L10n.t(paused ? "继续" : "暂停"), systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.ds(.secondary, size: .regular))

            DSIconButton(systemName: "trash", help: "清空日志", size: 28, style: .outlined) {
                state.clearLogs(for: effectiveSource)
                frozen = []
                expanded = []
            }
        }
    }

    /// 合并视图没有单一文件，带读者去日志目录；单引擎则选中它的 `.log`。
    private func openLogsLocation() {
        if let path = effectiveSource.filePath {
            guard Paths.fileExists(path) else {
                state.toast("日志文件尚未创建")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let directory = Paths.logsDirectory
        guard Paths.fileExists(directory) else {
            state.toast("日志目录尚未创建")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    private var logSourceMenu: some View {
        DSMenu(size: .small) {
            DSMenuTriggerLabel(title: effectiveSource.title, size: .small)
        } content: {
            Button {
                select(.all)
            } label: {
                if effectiveSource == .all {
                    Label(L10n.t("全部日志"), systemImage: "checkmark")
                } else {
                    Text(L10n.t("全部日志"))
                }
            }

            if !state.availableEngines.isEmpty {
                Divider()
                ForEach(state.availableEngines, id: \.self) { id in
                    Button {
                        select(.engine(id))
                    } label: {
                        let suffix = id == state.activeEngine ? " · \(L10n.t("当前"))" : ""
                        let title = "\(id.rawValue).log\(suffix)"
                        if effectiveSource == .engine(id) {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        }
        .help(L10n.t("切换日志来源"))
    }

    /// 换来源等于换一份日志：暂停、展开、悬停都从零开始，免得带着上一份的 id。
    private func select(_ next: LogFeedSource) {
        guard next != effectiveSource else { return }
        source = next
        paused = false
        frozen = []
        expanded = []
        hoveredId = nil
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
                    logSourceMenu
                    Spacer(minLength: 0)
                    Text("\(data.lines.count) 行")
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 38)

                DSDivider()

                if data.lines.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(DS.text4)
                        Text("启动引擎后，日志会实时出现在这里")
                            .font(DS.Font.sm)
                            .foregroundStyle(DS.text3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            // 新行从顶上插入，跟随「最新」的方式就是回到顶部。
                            Color.clear.frame(height: 1).id("logTop")
                            ForEach(data.lines) { line in
                                row(line).id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .defaultScrollAnchor(.top)
                    .onChange(of: data.lines.count) { _, _ in
                        guard !paused else { return }
                        proxy.scrollTo("logTop", anchor: .top)
                    }
                }
            }
            .dsSurface(radius: DS.Radius.lg)
            .clipShape(DS.rect(DS.Radius.lg))
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ entry: LogFeedEntry) -> some View {
        let tone = Console.levelColor(entry.level)
        let isExpanded = expanded.contains(entry.id)
        let isHovered = hoveredId == entry.id
        let highlighted = isHovered || isExpanded

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DS.Motion.smooth) {
                    if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(entry.clockText)
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .leading)

                    // 合并视图里行首标出来源；单引擎视图不占这一列。
                    if let tag = entry.tag {
                        Text(tag)
                            .font(DS.Font.mono(9.5))
                            .foregroundStyle(DS.text3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 54, alignment: .leading)
                    }

                    HStack(spacing: 5) {
                        DSStatusDot(color: tone, live: false, size: 5)
                        Text(entry.level.label)
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

                    Text(entry.text)
                        .font(DS.Font.mono(11.5))
                        .foregroundStyle(entry.level == .error ? DS.err : DS.text)
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
                detail(entry)
                    .padding(.leading, detailIndent(entry))
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
                    hoveredId = entry.id
                } else if hoveredId == entry.id {
                    hoveredId = nil
                }
            }
        }
    }

    /// 详情正文与行内正文左对齐：时间列 58 + 间距 10 + 行内边距 8，合并视图
    /// 再让出来源列（54 + 间距 10）。
    private func detailIndent(_ entry: LogFeedEntry) -> CGFloat {
        76 + (entry.tag == nil ? 0 : 64)
    }

    /// 展开后的详情：可换行的完整正文 + 元信息 + 单行复制。
    private func detail(_ entry: LogFeedEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text)
                .font(DS.Font.mono(11.5))
                .foregroundStyle(DS.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Label(Self.fullDateFormatter.string(from: entry.time), systemImage: "clock")
                if let tag = entry.tag {
                    Label(tag, systemImage: "cpu")
                }
                Label("\(entry.text.count) 字符", systemImage: "textformat.size")
                Spacer(minLength: 0)
                Button {
                    state.copy(entry.text, label: "已复制该行日志")
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
/// 传进来的 `entries` 已经是最新在前（`LogFeed.entries` 合并出来的顺序，
/// 单引擎则是内存尾巴倒着读），所以过滤只做筛选、不再翻转。
struct LogsDigest {
    var lines: [LogFeedEntry] = []
    var counts: [LogsFilter: Int] = [:]

    static func make(from entries: [LogFeedEntry], level: LogsFilter, query: String) -> LogsDigest {
        var result = LogsDigest()
        result.lines.reserveCapacity(entries.count)
        for entry in entries {
            result.counts[.all, default: 0] += 1
            switch entry.level {
            case .warning: result.counts[.warning, default: 0] += 1
            case .error: result.counts[.error, default: 0] += 1
            default: result.counts[.info, default: 0] += 1
            }
            guard level.matches(entry.level) else { continue }
            if !query.isEmpty, !entry.text.localizedCaseInsensitiveContains(query) { continue }
            result.lines.append(entry)
        }
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
