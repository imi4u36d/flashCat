import SwiftUI
import AppKit
import FlashCatKit

/// 日志页：引擎与网关的实时输出，按级别过滤、搜索、暂停、清空。
struct LogsPage: View {
    @ObservedObject var state: AppState
    @State private var level: LogsFilter = .all
    @State private var query = ""
    @State private var paused = false

    private var lines: [LogLine] {
        let source = paused ? frozen : state.logs
        return source.filter { line in
            guard level.matches(line.level) else { return false }
            guard !query.isEmpty else { return true }
            return line.text.localizedCaseInsensitiveContains(query)
        }
    }

    @State private var frozen: [LogLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "日志",
                       subtitle: "当前引擎与网关的实时输出",
                       eyebrow: "实时输出") {
                Button {
                    let path = Paths.logFile
                    guard Paths.fileExists(path) else {
                        state.toast("日志文件尚未创建")
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("打开日志文件", systemImage: "doc.text")
                }
                .buttonStyle(.arcadeGlass)

                Button {
                    state.clearLogs()
                    frozen = []
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(ArcadePillStyle(tone: .quietDanger))
            }
            .padding(.horizontal, Native.pagePadding)
            .padding(.top, 30)
            .padding(.bottom, 14)

            toolbar
                .padding(.horizontal, Native.pagePadding)
                .padding(.bottom, 10)

            console
                .padding(.horizontal, Native.pagePadding)
                .padding(.bottom, Native.pagePadding)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
                TextField("搜索日志", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .frame(width: 180)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Native.recess))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Native.hairline, lineWidth: 1))

            Picker("", selection: $level) {
                ForEach(LogsFilter.allCases) { item in
                    Text("\(item.label) \(count(item))").tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer(minLength: 4)

            Toggle(isOn: $paused) {
                Text(paused ? "已暂停" : "自动滚动")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                state.copy(lines.map(\.text).joined(separator: "\n"), label: "已复制筛选后的日志")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(ArcadePillStyle(tone: .glass, compact: true))
            .disabled(lines.isEmpty)
            .help("复制筛选后的日志")
        }
        .onChange(of: paused) { _, isPaused in
            if isPaused { frozen = state.logs } else { frozen = [] }
        }
    }

    private func count(_ item: LogsFilter) -> Int {
        (paused ? frozen : state.logs).filter { item.matches($0.level) }.count
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        EmptyHint(icon: "terminal",
                                  title: "还没有日志输出",
                                  detail: "启动服务后，引擎日志会实时出现在这里。")
                            .padding(.vertical, 50)
                    } else {
                        ForEach(lines) { line in
                            row(line).id(line.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("logBottom")
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .background { GlassSurface(radius: Native.radiusTile, tint: Native.recess) }
            .onChange(of: lines.count) { _, _ in
                guard !paused else { return }
                proxy.scrollTo("logBottom", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Format.clock(line.time))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Native.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(line.level.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(line.level))
                .frame(width: 34, alignment: .leading)
            Text(line.text)
                .font(Native.monoFont)
                .foregroundStyle(Native.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 4)
        .background(line.level == .error ? Native.red.opacity(0.07) : Color.clear)
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
