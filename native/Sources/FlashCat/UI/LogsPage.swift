import SwiftUI
import AppKit
import FlashCatKit

/// 日志页：顶部过滤条 + 一块玻璃控制台，版式对齐 WebUI。
struct LogsPage: View {
    @ObservedObject var state: AppState
    @State private var level: LogsFilter = .all
    @State private var query = ""
    @State private var paused = false
    @State private var frozen: [LogLine] = []

    private var lines: [LogLine] {
        let source = paused ? frozen : state.logs
        return source.filter { line in
            guard level.matches(line.level) else { return false }
            guard !query.isEmpty else { return true }
            return line.text.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            topBar
            console
        }
        .padding(.horizontal, Console.contentPadding)
        .padding(.top, 78)
        .padding(.bottom, 22)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            NativeSegmented(selection: $level, options: LogsFilter.allCases.map { item in
                (item, "\(item.label) \((paused ? frozen : state.logs).filter { item.matches($0.level) }.count)")
            })
            .frame(width: 330)
            .background(Capsule().fill(Console.card.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Console.tertiary)
                TextField("搜索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Console.card.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Console.cardStroke, lineWidth: 0.8))
            .frame(maxWidth: 380)

            Spacer(minLength: 0)

            Button {
                state.copy(lines.map(\.text).joined(separator: "\n"), label: "已复制筛选后的日志")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Console.card.opacity(0.7)))
                    .overlay(Circle().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .disabled(lines.isEmpty)
            .help("复制筛选后的日志")

            Button {
                let path = Paths.logFile
                guard Paths.fileExists(path) else {
                    state.toast("日志文件尚未创建")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Console.card.opacity(0.7)))
                    .overlay(Circle().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("打开日志文件")

            Button {
                if paused {
                    paused = false
                    frozen = []
                } else {
                    frozen = state.logs
                    paused = true
                }
            } label: {
                Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Console.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Console.card.opacity(0.72)))
                    .overlay(Capsule().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)

            Button {
                state.clearLogs()
                frozen = []
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Console.card.opacity(0.7)))
                    .overlay(Circle().strokeBorder(Console.cardStroke, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .help("清空日志")
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            GlassCard(padding: 0, content: {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Console.ok)
                            .frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(Console.ok)
                        Text("\(state.activeEngine.rawValue).log")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                        Spacer(minLength: 0)
                        Text("\(lines.count) 行")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Console.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 42)

                    Rectangle().fill(Console.insetStroke).frame(height: 1)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if lines.isEmpty {
                                Text("启动服务后，引擎日志会实时出现在这里")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Console.tertiary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                            } else {
                                ForEach(lines) { line in
                                    row(line).id(line.id)
                                }
                            }
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: lines.count) { _, _ in
                        guard !paused else { return }
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            })
            .frame(maxHeight: .infinity)
        }
    }

    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Format.clock(line.time))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Console.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(line.level.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(line.level))
                .frame(width: 32, alignment: .leading)
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Console.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(line.level == .error ? Console.danger.opacity(0.06) : .clear)
        }
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
