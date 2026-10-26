//
//  LogsView.swift
//  flashCat
//
//  Native macOS port of lib/features/logs/logs_page.dart.
//
//  Parity notes:
//  * `state.logs` is parsed incrementally into display entries; the cache is
//    keyed by the `LogLine.id` sequence, so a 20k-line tail is never re-parsed
//    on a stats tick.
//  * Timestamp: a leading `HH:mm:ss(.SSS)` in the line wins, otherwise the
//    LogStore timestamp for that line is shown.
//  * Level: the stored LogLevel is authoritative for error/warning; other
//    lines fall back to the Dart page's keyword classification.
//  * Pause freezes the visible snapshot, resume catches up to the live tail.
//  * Auto-scroll only follows while the reader is parked at the bottom, so
//    manual scrolling is never fought by incoming output.
//

import SwiftUI
import AppKit
import Foundation

// MARK: - Levels

/// Three display levels, matching the Flutter page's filter (全部/提示/警告/错误).
private enum LogsLevel: String, CaseIterable, Identifiable {
    case info, warning, error

    var id: String { rawValue }

    var tag: String {
        switch self {
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    var title: String {
        switch self {
        case .info: return "提示"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    var tagColor: Color {
        switch self {
        case .info: return Native.secondary
        case .warning: return Native.orange
        case .error: return Native.red
        }
    }

    var messageColor: Color {
        switch self {
        case .info: return Native.label.opacity(0.92)
        case .warning: return Native.orange
        case .error: return Native.red
        }
    }
}

// MARK: - Entries

private struct LogEntry: Identifiable, Equatable {
    /// `LogLine.id` — stable, monotonic, and what the row list scrolls by.
    let id: Int
    let number: Int
    let numberText: String
    let time: String
    let level: LogsLevel
    let message: String
    /// Original line, used for search (the Dart page searches `raw`).
    let raw: String

    var copyLine: String { message.isEmpty ? raw : "\(time) \(message)" }

    func matches(_ needle: String) -> Bool {
        if time.range(of: needle, options: .caseInsensitive) != nil { return true }
        return message.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

private enum LogLineParser {
    /// Same pattern as the Dart page: `^\[?(\d{1,2}:\d{2}:\d{2}(?:[.,]\d{1,3})?)\]?\s+`
    private static let stamp: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"^\[?(\d{1,2}:\d{2}:\d{2}(?:[.,]\d{1,3})?)\]?\s+"#)

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func parse(_ line: LogLine, number: Int) -> LogEntry {
        let text = line.text
        var time = clock.string(from: line.time)
        var message = text

        if let stamp {
            let range = NSRange(location: 0, length: text.utf16.count)
            if let match = stamp.firstMatch(in: text, options: [], range: range),
               let stampRange = Range(match.range(at: 1), in: text),
               let fullRange = Range(match.range(at: 0), in: text) {
                time = text[stampRange].replacingOccurrences(of: ",", with: ".")
                message = String(text[fullRange.upperBound...])
            }
        }
        if message.isEmpty { message = text }

        return LogEntry(id: line.id, number: number,
                        numberText: String(format: "%03d", number),
                        time: time, level: level(for: line),
                        message: message, raw: text)
    }

    static func level(for line: LogLine) -> LogsLevel {
        switch line.level {
        case .error: return .error
        case .warning: return .warning
        default: break
        }
        let lower = line.text.lowercased()
        if lower.contains("error") || lower.contains("fatal")
            || lower.contains("traceback") || line.text.contains("失败") {
            return .error
        }
        if lower.contains("warn") || lower.contains("deprecated") { return .warning }
        return .info
    }
}

// MARK: - Counts

private struct LogsCounts: Equatable {
    var total = 0
    var info = 0
    var warning = 0
    var error = 0
}

// MARK: - Incremental parse / filter cache

/// Memoises parsing and filtering so a streaming tail stays cheap: appends only
/// parse the new suffix and filtering re-runs only when the source identity,
/// the level filter, or the search needle actually change.
private final class LogCache {
    private(set) var entries: [LogEntry] = []
    /// Bumped whenever `entries` changes; doubles as the filter cache key.
    private(set) var identity = 0

    private var countsIdentity = -1
    private var counts = LogsCounts()

    private struct FilterKey: Equatable {
        var identity: Int
        var level: LogsLevel?
        var needle: String
    }
    private var filterKey: FilterKey?
    private var filtered: [LogEntry] = []

    func entries(for logs: [LogLine]) -> [LogEntry] {
        let target = logs.count
        guard target > 0 else {
            if !entries.isEmpty {
                entries.removeAll()
                identity &+= 1
            }
            return entries
        }

        let lastID = logs[target - 1].id
        if entries.isEmpty || entries.count > target {
            rebuild(logs)
            return entries
        }
        if entries.count == target, entries[entries.count - 1].id == lastID { return entries }
        guard let base = index(of: entries[entries.count - 1].id, in: logs) else {
            rebuild(logs)
            return entries
        }

        // Drop a stale head when the source trimmed older lines.
        let drop = entries.count - 1 - base
        guard drop >= 0 else {
            rebuild(logs)
            return entries
        }
        var changed = false
        if drop > 0 {
            entries.removeFirst(drop)
            changed = true
        }
        if base + 1 < target {
            entries.reserveCapacity(target)
            var number = entries.last?.number ?? 0
            for offset in (base + 1)..<target {
                number += 1
                entries.append(LogLineParser.parse(logs[offset], number: number))
            }
            changed = true
        }
        if changed { identity &+= 1 }
        return entries
    }

    func counts(for entries: [LogEntry]) -> LogsCounts {
        if countsIdentity == identity { return counts }
        var result = LogsCounts(total: entries.count)
        for entry in entries {
            switch entry.level {
            case .info: result.info += 1
            case .warning: result.warning += 1
            case .error: result.error += 1
            }
        }
        counts = result
        countsIdentity = identity
        return result
    }

    func filtered(_ source: [LogEntry], identity sourceIdentity: Int,
                  level: LogsLevel?, needle: String) -> [LogEntry] {
        let key = FilterKey(identity: sourceIdentity, level: level, needle: needle)
        if key == filterKey { return filtered }

        var result = source
        if level != nil || !needle.isEmpty {
            result = []
            result.reserveCapacity(source.count)
            for entry in source {
                if let level, entry.level != level { continue }
                if !needle.isEmpty, !entry.matches(needle) { continue }
                result.append(entry)
            }
        }
        filterKey = key
        filtered = result
        return result
    }

    private func rebuild(_ logs: [LogLine]) {
        var rebuilt: [LogEntry] = []
        rebuilt.reserveCapacity(logs.count)
        for (offset, line) in logs.enumerated() {
            rebuilt.append(LogLineParser.parse(line, number: offset + 1))
        }
        entries = rebuilt
        identity &+= 1
    }

    /// `LogLine.id` is assigned monotonically, so the snapshot is sorted.
    private func index(of id: Int, in logs: [LogLine]) -> Int? {
        var low = 0
        var high = logs.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let value = logs[middle].id
            if value == id { return middle }
            if value < id { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

// MARK: - Numbers

private enum LogsNumber {
    private static let fractional = make(digits: 1)
    private static let whole = make(digits: 0)

    private static func make(digits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter
    }

    static func text(_ value: Double?, digits: Int) -> String {
        guard let value, value.isFinite else { return "—" }
        return (digits > 0 ? fractional : whole).string(from: NSNumber(value: value)) ?? "—"
    }

    static func integer(_ value: Int) -> String {
        whole.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Page

struct LogsView: View {
    @ObservedObject var state: AppState

    /// Reference type: parsing memoisation, deliberately not observable.
    @State private var cache = LogCache()
    @State private var level: LogsLevel?
    @State private var query = ""
    @State private var autoScroll = true
    @State private var paused = false
    @State private var snapshot: LogSnapshot?
    @State private var snapshotSeq = 0
    @State private var pinned = true
    @State private var scrollRequest = 0
    @State private var confirmingClear = false

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var currentModel: String {
        (state.stats?.model ?? state.selectedModel).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filter change follows the tail only when auto-scroll is on.
    private var levelSelection: Binding<LogsLevel?> {
        Binding(get: { level }, set: { value in
            level = value
            if autoScroll { scrollRequest &+= 1 }
        })
    }

    private var autoScrollSelection: Binding<Bool> {
        Binding(get: { autoScroll }, set: { value in
            autoScroll = value
            if value {
                pinned = true
                scrollRequest &+= 1
            }
        })
    }

    var body: some View {
        let live = cache.entries(for: state.logs)
        let counts = cache.counts(for: live)
        let source = paused ? (snapshot?.entries ?? []) : live
        let sourceIdentity = paused ? (snapshot?.identity ?? 0) : cache.identity
        let visible = cache.filtered(source, identity: sourceIdentity, level: level, needle: needle)

        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "日志", subtitle: "引擎与控制台的实时输出")

                LogsStatsStrip(stats: state.stats, model: currentModel,
                               showsModel: proxy.size.width >= 840)

                LogsPanel(state: state, visible: visible, counts: counts,
                          hasLogs: !live.isEmpty, needle: needle,
                          level: levelSelection, query: $query,
                          autoScroll: autoScrollSelection,
                          paused: paused, pinned: $pinned,
                          width: proxy.size.width, scrollRequest: scrollRequest,
                          onClearSearch: { if autoScroll { scrollRequest &+= 1 } },
                          onTogglePause: togglePause,
                          onClear: { confirmingClear = true })
                    .frame(maxHeight: .infinity)
            }
            .padding(Native.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("清空日志？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { clearLogs() }
        } message: {
            Text("将移除内存中的全部日志行，日志文件中的历史记录不受影响。")
        }
    }

    private func togglePause() {
        if paused {
            paused = false
            snapshot = nil
            pinned = true
            scrollRequest &+= 1
        } else {
            snapshotSeq &+= 1
            snapshot = LogSnapshot(entries: cache.entries(for: state.logs),
                                   identity: -snapshotSeq)
            paused = true
        }
    }

    private func clearLogs() {
        state.clearLogs()
        paused = false
        snapshot = nil
        pinned = true
        scrollRequest &+= 1
        state.toast("已清空日志")
    }
}

private struct LogSnapshot {
    let entries: [LogEntry]
    let identity: Int
}

// MARK: - Stats strip

private struct LogsStatsStrip: View {
    let stats: ServerStats?
    let model: String
    let showsModel: Bool

    private var failedColor: Color {
        guard let stats else { return Native.tertiary }
        return stats.requestsFailed > 0 ? Native.red : Native.green
    }

    var body: some View {
        Card(padded: false) {
            HStack(spacing: 0) {
                LogsStatCell(label: "解码速度",
                             value: LogsNumber.text(stats?.decodeTokensPerSecond, digits: 1),
                             unit: stats?.decodeTokensPerSecond == nil ? nil : "tok/s")
                divider
                LogsStatCell(label: "预填充",
                             value: LogsNumber.text(stats?.prefillTokensPerSecond, digits: 0),
                             unit: stats?.prefillTokensPerSecond == nil ? nil : "tok/s")
                divider
                LogsStatCell(label: "完成请求",
                             value: stats.map { LogsNumber.integer($0.requestsCompleted) } ?? "—")
                divider
                LogsStatCell(label: "失败 / 取消",
                             value: stats.map { "\($0.requestsFailed)" } ?? "—",
                             valueColor: failedColor)
                if showsModel {
                    divider
                    LogsStatCell(label: "当前模型",
                                 value: model.isEmpty ? "—" : model,
                                 mono: true)
                        .help(model.isEmpty ? "未选择模型" : model)
                }
            }
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        }
    }

    private var divider: some View { VHairline().frame(maxHeight: .infinity) }
}

private struct LogsStatCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var valueColor: Color = Native.label
    var mono: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(mono ? Native.monoSmall
                               : .system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.8)
                if let unit {
                    Text(unit).font(.system(size: 9.5)).foregroundStyle(Native.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Panel

private struct LogsPanel: View {
    @ObservedObject var state: AppState
    let visible: [LogEntry]
    let counts: LogsCounts
    let hasLogs: Bool
    let needle: String
    @Binding var level: LogsLevel?
    @Binding var query: String
    @Binding var autoScroll: Bool
    let paused: Bool
    @Binding var pinned: Bool
    let width: CGFloat
    let scrollRequest: Int
    let onClearSearch: () -> Void
    let onTogglePause: () -> Void
    let onClear: () -> Void

    var body: some View {
        Card(padded: false) {
            VStack(spacing: 0) {
                LogsToolbar(serverState: state.serverState,
                            visibleCount: visible.count, counts: counts,
                            hasLogs: hasLogs, level: $level, query: $query,
                            autoScroll: $autoScroll, paused: paused, width: width,
                            onClearSearch: onClearSearch, onCopy: copyVisible,
                            onClear: onClear, onOpen: openLogFile,
                            onReveal: revealLogFile, onTogglePause: onTogglePause)
                Hairline()
                LogsBody(entries: visible, needle: needle, hasLogs: hasLogs,
                         autoScroll: autoScroll, paused: paused,
                         compact: width < 560, pinned: $pinned,
                         scrollRequest: scrollRequest)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Hairline()
                LogsFooter(paused: paused, pinned: pinned,
                           autoScroll: autoScroll, version: state.runtimeVersion)
            }
            .clipShape(RoundedRectangle(cornerRadius: Native.radiusPanel, style: .continuous))
        }
        .frame(maxHeight: .infinity)
    }

    private func copyVisible() {
        guard !visible.isEmpty else { return }
        state.copy(visible.map(\.copyLine).joined(separator: "\n"),
                   label: "已复制 \(visible.count) 行日志")
    }

    private func openLogFile() {
        guard Paths.fileExists(Paths.logFile) else {
            state.toast("日志文件尚未创建")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.logFile))
    }

    private func revealLogFile() {
        guard Paths.fileExists(Paths.logFile) else {
            state.toast("日志文件尚未创建")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.logFile)])
    }
}

// MARK: - Toolbar

private struct LogsToolbar: View {
    let serverState: ServerState
    let visibleCount: Int
    let counts: LogsCounts
    let hasLogs: Bool
    @Binding var level: LogsLevel?
    @Binding var query: String
    @Binding var autoScroll: Bool
    let paused: Bool
    let width: CGFloat
    let onClearSearch: () -> Void
    let onCopy: () -> Void
    let onClear: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onTogglePause: () -> Void

    private var stacked: Bool { width < 1000 }
    private var dense: Bool { width < 780 }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        statusTag
                        countLabel
                        Spacer(minLength: 6)
                        iconActions
                    }
                    HStack(spacing: 9) {
                        LogsSearchField(text: $query, onClear: onClearSearch)
                        filterPicker
                        Spacer(minLength: 6)
                        liveActions
                    }
                }
            } else {
                HStack(spacing: 9) {
                    statusTag
                    countLabel
                    LogsSearchField(text: $query, onClear: onClearSearch).frame(width: 210)
                    filterPicker
                    Spacer(minLength: 6)
                    iconActions
                    VHairline().frame(height: 16)
                    liveActions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Native.panel)
    }

    private var statusTag: some View {
        Tag(text: serverState.rawValue, tone: statusTone, icon: "circle.fill")
    }

    private var statusTone: TagTone {
        switch serverState {
        case .ready: return .success
        case .starting, .stopping: return .warning
        case .failed: return .danger
        case .stopped: return .neutral
        }
    }

    private var countLabel: some View {
        Text(verbatim: visibleCount == counts.total ? "\(visibleCount) 行"
                                                    : "\(visibleCount) / \(counts.total) 行")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Native.tertiary)
            .lineLimit(1)
            .fixedSize()
    }

    private var filterPicker: some View {
        Picker("级别", selection: $level) {
            Text(dense ? "全部" : "全部 \(counts.total)").tag(LogsLevel?.none)
            Text(dense ? "提示" : "提示 \(counts.info)").tag(LogsLevel.info as LogsLevel?)
            Text(dense ? "警告" : "警告 \(counts.warning)").tag(LogsLevel.warning as LogsLevel?)
            Text(dense ? "错误" : "错误 \(counts.error)").tag(LogsLevel.error as LogsLevel?)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("按级别筛选日志")
    }

    private var iconActions: some View {
        HStack(spacing: 7) {
            IconAction(systemName: "folder", help: "打开日志文件（右键在 Finder 中显示）") {
                onOpen()
            }
            .contextMenu { Button("在 Finder 中显示") { onReveal() } }

            IconAction(systemName: "doc.on.doc", help: "复制当前筛选结果") { onCopy() }
                .disabled(visibleCount == 0)
                .opacity(visibleCount == 0 ? 0.4 : 1)

            IconAction(systemName: "trash", help: "清空日志") { onClear() }
                .disabled(!hasLogs && !paused)
                .opacity(hasLogs || paused ? 1 : 0.4)
        }
    }

    private var liveActions: some View {
        HStack(spacing: 7) {
            Toggle("自动滚动", isOn: $autoScroll)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 11))
                .foregroundStyle(Native.secondary)
                .fixedSize()

            Button(action: onTogglePause) {
                Label(paused ? "继续" : "暂停",
                      systemImage: paused ? "play.fill" : "pause.fill")
            }
            .controlSize(.small)
            .help(paused ? "继续实时输出" : "暂停实时输出")
        }
    }
}

private struct LogsSearchField: View {
    @Binding var text: String
    let onClear: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Native.tertiary)

            TextField("搜索日志", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)

            if !text.isEmpty {
                Button {
                    text = ""
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Native.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(Native.raised,
                    in: RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Native.radiusSmall, style: .continuous)
                .stroke(focused ? Native.accent.opacity(0.8) : Native.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

// MARK: - Body

private struct LogContentMetrics: Equatable {
    var top: CGFloat = 0
    var height: CGFloat = 0
}

private struct LogMetricsKey: PreferenceKey {
    static var defaultValue = LogContentMetrics()
    static func reduce(value: inout LogContentMetrics, nextValue: () -> LogContentMetrics) {
        value = nextValue()
    }
}

private struct LogsBody: View {
    let entries: [LogEntry]
    let needle: String
    let hasLogs: Bool
    let autoScroll: Bool
    let paused: Bool
    let compact: Bool
    @Binding var pinned: Bool
    let scrollRequest: Int

    @State private var metrics: LogContentMetrics?

    private static let coordinateSpace = "logs.scroll"
    private static let bottomAnchor = "logs.bottom"

    var body: some View {
        ZStack {
            Native.raised

            if entries.isEmpty {
                EmptyHint(icon: "terminal",
                          title: hasLogs ? "没有匹配的日志" : "还没有日志输出",
                          detail: hasLogs ? "调整搜索关键词或级别筛选后再试。"
                                          : "启动服务后，引擎日志会实时出现在这里。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(entries) { entry in
                                    LogsRow(entry: entry, needle: needle, compact: compact)
                                        .equatable()
                                }
                                Color.clear.frame(height: 1).id(Self.bottomAnchor)
                            }
                            .padding(.vertical, 6)
                            .background(metricsReader)
                        }
                        .defaultScrollAnchor(.bottom)
                        .coordinateSpace(name: Self.coordinateSpace)
                        .onPreferenceChange(LogMetricsKey.self) { value in
                            updatePinned(value, viewportHeight: viewport.size.height)
                        }
                        .onChange(of: entries.last?.id) { _, _ in
                            // Follow only while the reader has not scrolled away.
                            guard autoScroll, !paused, pinned else { return }
                            follow(proxy)
                        }
                        .onChange(of: scrollRequest) { _, _ in follow(proxy) }
                        .onAppear { if autoScroll { follow(proxy) } }
                    }
                }
            }
        }
    }

    private var metricsReader: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .named(Self.coordinateSpace))
            Color.clear.preference(key: LogMetricsKey.self,
                                   value: LogContentMetrics(top: frame.minY, height: frame.height))
        }
    }

    /// The content origin only moves when the reader scrolls — appending rows
    /// changes the height, not the origin — so growth never unpins the tail.
    /// Only an upward move can detach; landing near the bottom re-attaches.
    private func updatePinned(_ value: LogContentMetrics, viewportHeight: CGFloat) {
        let previous = metrics
        metrics = value
        // First pass runs before `onAppear` parks the view at the bottom.
        guard let previous else { return }
        let delta = value.top - previous.top
        guard abs(delta) >= 0.5 else { return }

        let atBottom = value.height + value.top - viewportHeight < 28
        if delta > 0 {
            if pinned, !atBottom { pinned = false }
        } else if atBottom, !pinned {
            pinned = true
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        // Second pass lands on the true bottom once lazy row heights settle.
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

// MARK: - Row

private struct LogsRow: View, Equatable {
    let entry: LogEntry
    let needle: String
    let compact: Bool

    @State private var hovering = false

    static func == (lhs: LogsRow, rhs: LogsRow) -> Bool {
        lhs.entry == rhs.entry && lhs.needle == rhs.needle && lhs.compact == rhs.compact
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(entry.numberText)
                .foregroundStyle(Native.tertiary)
                .frame(width: compact ? 34 : 42, alignment: .trailing)
                .padding(.trailing, 8)

            if !compact {
                Text(entry.time)
                    .foregroundStyle(Native.tertiary)
                    .frame(width: 62, alignment: .leading)
                    .padding(.trailing, 10)
            }

            Text(entry.level.tag)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(entry.level.tagColor)
                .frame(width: 42, alignment: .leading)
                .padding(.top, 1.5)
                .padding(.trailing, 10)

            Text(message)
                .foregroundStyle(entry.level.messageColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(2)
        .padding(.vertical, 2)
        .padding(.trailing, 12)
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Highlighting is built per visible row; rows are equatable, so this only
    /// runs when the entry or the needle changes.
    private var message: AttributedString {
        let text = entry.message
        guard !needle.isEmpty else {
            var plain = AttributedString(text)
            plain.foregroundColor = entry.level.messageColor
            return plain
        }

        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let hit = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: cursor..<text.endIndex) {
            if hit.lowerBound > cursor {
                result += plain(String(text[cursor..<hit.lowerBound]))
            }
            result += marked(String(text[hit]))
            cursor = hit.upperBound
        }
        if cursor < text.endIndex { result += plain(String(text[cursor...])) }
        if result.characters.isEmpty { result += plain(text) }
        return result
    }

    private func plain(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = entry.level.messageColor
        return piece
    }

    private func marked(_ text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = Native.label
        piece.backgroundColor = Native.yellow.opacity(0.32)
        return piece
    }
}

// MARK: - Footer

private struct LogsFooter: View {
    let paused: Bool
    let pinned: Bool
    let autoScroll: Bool
    let version: String

    private var text: String {
        if paused { return "已暂停 · 显示快照" }
        if !autoScroll { return "自动滚动已关闭" }
        if !pinned { return "已暂停跟随 · 滚回底部恢复" }
        return "实时跟随 · 最新输出"
    }

    private var dotColor: Color {
        if paused { return Native.orange }
        if !autoScroll || !pinned { return Native.gray }
        return Native.green
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dotColor).frame(width: 5, height: 5)
            Text(text).lineLimit(1)
            Spacer(minLength: 8)
            Text("UTF-8")
            Text("·")
            Text("splash \(version)").lineLimit(1)
        }
        .font(.system(size: 10))
        .foregroundStyle(Native.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Native.panel)
    }
}
