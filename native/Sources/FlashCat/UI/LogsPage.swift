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
    @State private var expanded: Set<Int> = []
    @State private var hoveredId: Int?

    /// 展开详情里的完整时间，和行首的 HH:mm:ss 互补。
    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

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
            GlassFilterBar(selection: $level,
                           options: LogsFilter.allCases.map { item in
                               (item, "\(item.label) \((paused ? frozen : state.logs).filter { item.matches($0.level) }.count)")
                           },
                           query: $query,
                           placeholder: "搜索")

            Spacer(minLength: 0)

            Button {
                state.copy(lines.map(\.text).joined(separator: "\n"), label: "已复制筛选后的日志")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        LiquidGlassSurface(shape: Circle(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)
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
                    .background {
                        LiquidGlassSurface(shape: Circle(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)
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
                Label(L10n.t(paused ? "继续" : "暂停"), systemImage: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Console.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background {
                        LiquidGlassSurface(shape: Capsule(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)

            Button {
                state.clearLogs()
                frozen = []
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        LiquidGlassSurface(shape: Circle(), interactive: true)
                    }
            }
            .buttonStyle(.plainHit)
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
        let tone = Console.levelColor(line.level)
        let isExpanded = expanded.contains(line.id)
        let isHovered = hoveredId == line.id
        let highlighted = isHovered || isExpanded

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.standard) {
                    if isExpanded { expanded.remove(line.id) } else { expanded.insert(line.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(Format.clock(line.time))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Console.tertiary)
                        .monospacedDigit()
                        .frame(width: 56, alignment: .leading)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(tone)
                            .frame(width: 5, height: 5)
                        Text(line.level.label)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(tone)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: 62, height: 17, alignment: .leading)
                    .background {
                        Capsule().fill(tone.opacity(line.level == .info ? 0.07 : 0.13))
                    }

                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.level == .error ? Console.danger : Console.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Console.tertiary)
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
                    .padding(.leading, 74)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlighted ? Console.inset : .clear)
        }
        .onHover { hovering in
            withAnimation(Motion.quick) {
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
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Console.text)
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Console.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background {
                            Capsule().fill(Console.inset)
                        }
                }
                .buttonStyle(.plainHit)
            }
            .font(.system(size: 10))
            .foregroundStyle(Console.tertiary)
            .labelStyle(.titleAndIcon)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Console.cardStrong.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Console.insetStroke, lineWidth: 1)
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
