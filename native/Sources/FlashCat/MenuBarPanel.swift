import SwiftUI
import AppKit
import FlashCatKit

// MARK: - 菜单栏图标

/// 系统菜单栏里的状态图标：flashCat 原画 + 右下角状态圆点。
///
/// 之前用 `NSImage(size:flipped:drawingHandler:)` 合成着色 SF Symbol，菜单栏
/// 把它当不透明位图渲染，出现"白底方块"；这里改为手工生成 2x/3x 位图表示，
/// 尺寸、清晰度、透明度都可控。
enum MenuBarIcon {
    static let pointSize: CGFloat = 18

    @MainActor
    static func statusImage(state: ServerState) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [2.0, 3.0] {
            let pixel = Int(pointSize * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: pixel, pixelsHigh: pixel,
                                             bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: pointSize, height: pointSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(state: state, in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }

    @MainActor
    private static func draw(state: ServerState, in rect: NSRect) {
        if let artwork = BrandMark.artwork {
            // 原画自带图标网格留白，放大一点让猫脸占满菜单栏高度。
            let scale: CGFloat = 1.18
            let size = rect.width * scale
            let frame = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2,
                               width: size, height: size)
            artwork.draw(in: frame)
        } else {
            // 兜底：着色猫形符号，同样画进位图上下文保证透明背景。
            let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.72, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "flashCat")?
                .withSymbolConfiguration(config) {
                symbol.draw(in: rect)
                NSColor(Color.adaptive(dark: 0xEDEDF2, light: 0x2A2A32)).setFill()
                rect.fill(using: .sourceAtop)
            }
        }

        // 右下角状态圆点：一圈低透明度深色描边在浅色/深色菜单栏上都能托住。
        let status = NSColor(statusColor(state))
        let dot = rect.width * 0.34
        let ring = NSBezierPath(ovalIn: NSRect(x: rect.width - dot - 0.5, y: -0.5,
                                               width: dot + 1, height: dot + 1))
        NSColor.black.withAlphaComponent(0.32).setFill()
        ring.fill()
        let core = NSBezierPath(ovalIn: NSRect(x: rect.width - dot, y: 0, width: dot, height: dot))
        status.setFill()
        core.fill()
    }
}

/// MenuBarExtra 的标签视图。状态变化时重新合成图标（负载极低， artwork 已缓存）。
struct MenuBarStatusLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(nsImage: MenuBarIcon.statusImage(state: state.serverState))
            .accessibilityLabel("flashCat 菜单栏")
    }
}

// MARK: - 菜单栏面板

/// 点击菜单栏图标弹出的信息面板：品牌头部、当前模型卡片、实时指标网格
/// 和高频操作。结构对齐概览页的设计语言，但按 340pt 窄面板重新排布。
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var running: Bool { state.isRunning }
    private var accent: Color { statusColor(state.serverState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ModelHero(state: state, accent: accent)
            runtimeArea
            actionRow
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            BrandMark(size: 30, glow: false)
            VStack(alignment: .leading, spacing: 1) {
                Text("flashCat")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("本地推理控制台")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: accent, diameter: 7,
                          pulsing: state.serverState == .starting || state.serverState == .stopping)
                Text(state.serverState.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Native.secondary)
            }
        }
    }

    // MARK: runtime

    @ViewBuilder
    private var runtimeArea: some View {
        switch state.serverState {
        case .ready:
            if let stats = state.stats {
                MetricGrid(stats: stats)
            } else {
                statusStrip(systemImage: "sparkles",
                            text: "引擎就绪，正在同步实时指标…")
            }
        case .starting, .stopping:
            let stage = state.isSwitchingModel
                ? (state.switchStage.isEmpty ? "切换模型" : state.switchStage)
                : state.startupStage
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("\(state.serverState.rawValue)：\(stage)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Native.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(Native.overlay(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .failed:
            statusStrip(systemImage: "exclamationmark.triangle.fill",
                        text: state.failureMessage ?? "引擎异常，可在日志页查看原因",
                        color: Native.red)
        case .stopped:
            statusStrip(systemImage: "pause.circle",
                        text: state.selectedModel.isEmpty
                            ? "还没有选择模型，在模型页选一个即可启动"
                            : "服务未运行，启动后对外提供 OpenAI 兼容接口")
        }
    }

    private func statusStrip(systemImage: String, text: String, color: Color = Native.secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Native.overlay(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                running ? state.stopService() : state.startService()
            } label: {
                Label(running ? "停止服务" : "启动服务",
                      systemImage: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(running ? .arcadeGlass : .arcadeAccent)
            .disabled(state.isSwitchingModel)

            IconAction(systemName: "doc.plaintext", help: "查看日志") {
                state.section = .logs
                openMainWindow()
            }
            IconAction(systemName: "macwindow", help: "打开主窗口") {
                openMainWindow()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let stats = state.stats {
                Text("完成 \(stats.requestsCompleted) · 失败 \(stats.requestsFailed)")
                    .font(.system(size: 10))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer()
            Button("退出 flashCat") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Native.tertiary)
        }
        .padding(.horizontal, 2)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 模型卡片

/// 面板主角：当前模型 + 引擎版本 + 可复制的接口地址，底色随服务状态着色。
private struct ModelHero: View {
    @ObservedObject var state: AppState
    let accent: Color

    private var title: String {
        if let served = state.stats?.model, !served.isEmpty {
            return state.shortModelName(served)
        }
        if let info = state.selectedModelInfo { return info.shortName }
        return state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel)
    }

    private var subtitle: String {
        let engine = "\(state.activeEngine.displayName) \(state.engineVersion)"
        return state.selectedModel.isEmpty ? engine : "\(state.selectedModel) · \(engine)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("当前模型")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(accent.opacity(0.95))
                Spacer()
                Text("\(state.activeEngine.displayName) \(state.engineVersion)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
            }
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Native.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Text(subtitle)
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            endpointPill
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.18),
                                              accent.opacity(0.06),
                                              Native.overlay(0.04)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 0.8)
        )
    }

    private var endpointPill: some View {
        Button {
            state.copy(state.endpointURL)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
                Text(state.endpointURL)
                    .font(Native.monoSmall)
                    .foregroundStyle(Native.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Native.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Native.overlay(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点击复制接口地址")
    }
}

// MARK: - 指标网格

/// 2×2 实时指标：值在上、标签在下，中缝与行间用发丝线分隔。
private struct MetricGrid: View {
    let stats: ServerStats

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cell("解码速度", metricsValue(stats.decodeTokensPerSecond.map { "\(Format.compact($0)) tok/s" }))
                VHairline()
                cell("首字延迟", metricsValue(stats.ttftMilliseconds.map { "\(Int($0)) ms" }))
            }
            Hairline()
            HStack(spacing: 0) {
                cell("内存占用", metricsValue(stats.memoryBytes.map { Format.bytes($0) }))
                VHairline()
                cell("热状态", stats.thermalText, valueColor: thermalColor)
            }
        }
        .background(Native.overlay(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Native.hairline, lineWidth: 0.8)
        )
    }

    private var thermalColor: Color {
        switch stats.thermal {
        case "nominal": return Native.green
        case "fair": return Native.orange
        case "serious", "critical": return Native.red
        default: return Native.label
        }
    }

    private func cell(_ label: String, _ value: String, valueColor: Color = Native.label) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Native.tertiary)
            Text(value)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metricsValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}
