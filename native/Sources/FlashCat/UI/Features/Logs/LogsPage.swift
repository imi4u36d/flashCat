// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 日志页：顶部过滤条 + ZCode 风格实色日志控制台。
///
/// 默认看的是「全部日志」——每台已装引擎的尾巴按时间并成一份；只想盯一台时
/// 从 LIVE 旁的菜单里挑。以前这里默认就是当前引擎，别台引擎的报错要切过去才
/// 看得见，出问题时反而先多一步。
struct LogsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var logFeed: LogFeedService
    @State private var source: LogFeedSource = .all
    @State private var level: LogsFilter = .all
    @State private var query = ""
    /// 输入框里的搜索词停顿后再用于过滤，避免每次按键都扫一遍几千行日志。
    @State private var appliedQuery = ""
    @State private var paused = false
    @State private var frozen: [LogFeedEntry] = []
    @State private var expanded: Set<String> = []
    @State private var confirmingClear = false
    @State private var cachedDigest: LogsDigest?
    @State private var isWide = true

    private struct DigestTrigger: Equatable {
        let lastID: Int?
        let count: Int
        let revision: Int
        let source: LogFeedSource
        let level: LogsFilter
        let query: String
        let paused: Bool
    }

    private var digestTrigger: DigestTrigger {
        DigestTrigger(
            lastID: logFeed.logs.last?.id,
            count: logFeed.logs.count,
            revision: logFeed.logsRevision,
            source: effectiveSource,
            level: level,
            query: appliedQuery,
            paused: paused)
    }

    /// 选中的引擎被卸载后回落到「全部日志」：菜单里已经没有这一项了。
    private var effectiveSource: LogFeedSource {
        if case .engine(let id) = source, !state.availableEngines.contains(id) { return .all }
        return source
    }

    private func display() -> LogsDigest {
        LogsDigest.make(
            from: paused ? frozen : logFeed.logEntries(for: effectiveSource),
            level: level,
            query: appliedQuery)
    }

    var body: some View {
        let data = cachedDigest ?? display()
        let horizontal = Console.pageHorizontalPadding(compact: !isWide)
        VStack(alignment: .leading, spacing: Console.pageSectionGap) {
            DSPageHeader(
                title: "日志",
                subtitle: L10n.t(effectiveSource.title),
                status: DSPageStatus(
                    paused ? "PAUSED" : "LIVE",
                    color: paused ? DS.warn : DS.ok,
                    live: !paused)
            ) {
                actionButtons(data)
            }
            .padding(.horizontal, horizontal)
            .padding(.top, Console.scrollTopInset(sidebarShown: state.showsSidebar))
            .background(WindowDragArea())

            filterRow(data)
                .padding(.horizontal, horizontal)

            console(data)
                .padding(.horizontal, horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= Console.compactContentWidth
        } action: { wide in
            isWide = wide
        }
        .dsPageColumn()
        .padding(.bottom, Console.contentBottomInset)
        .onAppear {
            cachedDigest = display()
        }
        .onChange(of: digestTrigger) { _, _ in
            cachedDigest = display()
        }
        .task(id: query) {
            if query == appliedQuery { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
        .alert(L10n.t("清空当前日志？"), isPresented: $confirmingClear) {
            Button(L10n.t("清空"), role: .destructive) {
                state.clearLogs(for: effectiveSource)
                frozen = []
                expanded = []
                cachedDigest = display()
            }
            Button(L10n.t("取消"), role: .cancel) {}
        } message: {
            Text(L10n.format("将清空 %@ 中的内存日志视图，不影响磁盘上的历史记录。", effectiveSource.title))
        }
    }

    /// 过滤只有一套：来源、级别、搜索同在一行，右端不再重复一份来源下拉。
    private func filterRow(_ data: LogsDigest) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                levelControl(data)
                logSourceMenu
                DSSearchField(query: $query, placeholder: "搜索", width: 200)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    levelControl(data)
                    logSourceMenu
                }
                DSSearchField(query: $query, placeholder: "搜索", width: 200)
            }
        }
    }

    private func levelControl(_ data: LogsDigest) -> some View {
        DSSegmented(
            selection: $level,
            options: LogsFilter.allCases.map { item in
                (item, "\(L10n.t(item.label)) (\(data.counts[item] ?? 0))")
            },
            size: .regular)
    }

    @ViewBuilder
    private func actionButtons(_ data: LogsDigest) -> some View {
        HStack(spacing: 8) {
            DSIconButton(systemName: "doc.on.doc", help: "复制筛选后的日志", size: 28, style: .outlined) {
                let text = LogFeed.clipboardText(data.lines, tagged: effectiveSource == .all)
                state.copy(text, label: L10n.t("已复制筛选后的日志"))
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
                    frozen = logFeed.logEntries(for: effectiveSource)
                    paused = true
                }
            } label: {
                Label(L10n.t(paused ? "继续" : "暂停"), systemImage: paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.ds(.secondary, size: .regular))

            DSIconButton(systemName: "trash", help: "清空日志", size: 28, style: .outlined) {
                confirmingClear = true
            }
            .disabled((data.counts[.all] ?? 0) == 0)
        }
    }

    /// 合并视图没有单一文件，带读者去日志目录；单引擎则选中它的 `.log`。
    private func openLogsLocation() {
        if let path = effectiveSource.filePath {
            guard Paths.fileExists(path) else {
                state.toast(L10n.t("日志文件尚未创建"))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        let directory = Paths.logsDirectory
        guard Paths.fileExists(directory) else {
            state.toast(L10n.t("日志目录尚未创建"))
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory, isDirectory: true))
    }

    private var logSourceMenu: some View {
        DSMenu(size: .regular) {
            DSMenuTriggerLabel(
                title: effectiveSource.title,
                systemImage: "text.alignleft",
                kind: .secondary,
                size: .regular)
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

    /// 换来源等于换一份日志：暂停、展开都从零开始，免得带着上一份的 id。
    private func select(_ next: LogFeedSource) {
        guard next != effectiveSource else { return }
        source = next
        paused = false
        frozen = []
        expanded = []
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
                    Spacer(minLength: 0)
                    Text(L10n.format("%lld 行", Int64(data.lines.count)))
                        .font(DS.Font.mono(11))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .frame(height: 38)

                DSDivider()

                if data.lines.isEmpty {
                    if (data.counts[.all] ?? 0) > 0 {
                        VStack(spacing: 12) {
                            EmptyHint(
                                icon: "line.3.horizontal.decrease.circle",
                                title: "没有匹配的日志",
                                detail: "当前级别或搜索词下没有日志记录。"
                            )
                            Button(L10n.t("重置筛选")) {
                                level = .all
                                query = ""
                                appliedQuery = ""
                            }
                            .buttonStyle(.ds(.secondary, size: .regular))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(DS.text4)
                            Text(L10n.t("启动引擎后，日志会实时出现在这里"))
                                .font(DS.Font.sm)
                                .foregroundStyle(DS.text3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            // 新行从顶上插入，跟随「最新」的方式就是回到顶部。
                            Color.clear.frame(height: 1).id("logTop")
                            ForEach(data.lines) { line in
                                LogRowView(
                                    entry: line,
                                    highlightQuery: appliedQuery,
                                    isExpanded: expanded.contains(line.id),
                                    onToggle: {
                                        if expanded.contains(line.id) {
                                            expanded.remove(line.id)
                                        } else {
                                            expanded.insert(line.id)
                                        }
                                    },
                                    onCopyLine: {
                                        state.copy(line.text, label: L10n.t("已复制该行日志"))
                                    },
                                    onCopyFormatted: {
                                        let prefix = line.tag.map { "[\($0)] " } ?? ""
                                        let formatted = "\(line.clockText) \(prefix)[\(line.level.label)] \(line.text)"
                                        state.copy(formatted, label: L10n.t("已复制该行日志"))
                                    }
                                )
                                .id(line.id)
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
            }
            .dsSurface(radius: DS.Radius.card)
            .clipShape(DS.rect(DS.Radius.card))
            .frame(maxHeight: .infinity)
        }
    }
}

/// 单行日志及其局部悬停/展开详情：把 `hovering` 留在行内，避免鼠标移动触发整个 `LogsPage` 重新过滤。
private struct LogRowView: View {
    let entry: LogFeedEntry
    let highlightQuery: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCopyLine: () -> Void
    let onCopyFormatted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private var highlighted: Bool { hovering || isExpanded }

    var body: some View {
        let tone = Console.levelColor(entry.level)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.smooth, onToggle)
            } label: {
                HStack(spacing: 10) {
                    Text(entry.clockText)
                        .font(DS.Font.mono(10.5))
                        .foregroundStyle(DS.text3)
                        .monospacedDigit()
                        .frame(width: 58, alignment: .leading)

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

                    Text(highlighted(entry.text))
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
                detail
                    .padding(.leading, detailIndent)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                    )
            }
        }
        .background {
            DS.rect(DS.Radius.sm)
                .fill(highlighted ? DS.hover : .clear)
        }
        .onHover { inside in
            withAnimation(reduceMotion ? nil : DS.Motion.snappy) {
                hovering = inside
            }
        }
        .contextMenu {
            Button(L10n.t("复制该行"), action: onCopyLine)
            Button(L10n.t("复制带时间与来源"), action: onCopyFormatted)
        }
    }

    private var detailIndent: CGFloat {
        76 + (entry.tag == nil ? 0 : 64)
    }

    /// 搜索只过滤列表还不够：命中处要在行内亮起来，否则长日志里仍要靠眼睛找。
    private func highlighted(_ text: String) -> AttributedString {
        let base = entry.level == .error ? NSColor(DS.err) : NSColor(DS.text)
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.foregroundColor: base])
        let query = highlightQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AttributedString(attributed) }

        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length > 0 {
            let found = source.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: searchRange)
            if found.location == NSNotFound { break }
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor(DS.warn).withAlphaComponent(0.28),
                range: found)
            let next = found.location + found.length
            if next >= source.length { break }
            searchRange = NSRange(location: next, length: source.length - next)
        }
        return AttributedString(attributed)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(highlighted(entry.text))
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
                Label(L10n.format("%lld 字符", Int64(entry.text.count)), systemImage: "textformat.size")
                Spacer(minLength: 0)
                Button(action: onCopyLine) {
                    Label(L10n.t("复制"), systemImage: "doc.on.doc")
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
