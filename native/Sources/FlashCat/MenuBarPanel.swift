import SwiftUI
import AppKit
import FlashCatKit

// MARK: - 菜单栏图标

/// 生成非模板的着色 SF Symbol。MenuBarExtra 的标签会被系统按模板图处理，
/// SwiftUI 直接画的颜色会被菜单栏抹掉，所以这里手工合成 NSImage 并关闭
/// `isTemplate`，让图标的颜色跟着服务状态走。
enum MenuBarIcon {
    static func tintedSymbol(_ name: String, color: NSColor, pointSize: CGFloat = 14) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "flashCat")?
            .withSymbolConfiguration(config) else { return NSImage() }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// 系统菜单栏里的常驻图标。颜色即状态：绿=运行中，黄=启动/停止中，
/// 红=异常，灰=已停止。
struct MenuBarStatusLabel: View {
    @ObservedObject var state: AppState

    private var tint: NSColor {
        NSColor(statusColor(state.serverState))
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.tintedSymbol("cat.fill", color: tint))
            .accessibilityLabel("flashCat 菜单栏")
    }
}

// MARK: - 菜单栏面板

/// 点击菜单栏图标弹出的信息面板：当前模型、引擎版本、服务状态与实时指标，
/// 外加启动/停止、复制地址、打开主窗口几个高频操作。
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    private var running: Bool { state.isRunning }

    private var statusTone: TagTone {
        switch state.serverState {
        case .ready: return .success
        case .starting, .stopping: return .warning
        case .failed: return .danger
        case .stopped: return .neutral
        }
    }

    /// 面板大标题优先显示引擎实际在跑的权重，其次才是选中的模型。
    private var modelTitle: String {
        if let served = state.stats?.model, !served.isEmpty {
            return state.shortModelName(served)
        }
        if let info = state.selectedModelInfo { return info.shortName }
        return state.selectedModel.isEmpty ? "未选择模型" : state.shortModelName(state.selectedModel)
    }

    private var modelSubtitle: String {
        if state.selectedModel.isEmpty { return "\(state.activeEngine.displayName) \(state.engineVersion)" }
        return "\(state.selectedModel) · \(state.activeEngine.displayName) \(state.engineVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modelSection
            Hairline()
            runtimeSection
            actions
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 28, glow: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("flashCat")
                    .font(.system(size: 13, weight: .bold))
                Text("本地推理控制台")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Native.tertiary)
            }
            Spacer()
            Tag(text: state.serverState.rawValue, tone: statusTone)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Eyebrow(text: "当前模型")
            Text(modelTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Native.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(modelTitle)
            Text(modelSubtitle)
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var runtimeSection: some View {
        switch state.serverState {
        case .ready:
            if let stats = state.stats {
                VStack(spacing: 0) {
                    row("解码速度", metricsValue(stats.decodeTokensPerSecond.map { "\(Format.compact($0)) tok/s" }))
                    divider
                    row("首字延迟", metricsValue(stats.ttftMilliseconds.map { "\(Int($0)) ms" }))
                    divider
                    row("内存占用", metricsValue(stats.memoryBytes.map { Format.bytes($0) }))
                    divider
                    row("热状态", stats.thermalText)
                    divider
                    row("请求", "完成 \(stats.requestsCompleted) · 活跃 \(stats.activeRequests)")
                }
            } else {
                hint("引擎已就绪，正在同步实时指标…")
            }
        case .starting, .stopping:
            let stage = state.isSwitchingModel
                ? (state.switchStage.isEmpty ? "切换模型" : state.switchStage)
                : state.startupStage
            hint("\(state.serverState.rawValue)：\(stage)")
        case .failed:
            hint(state.failureMessage ?? "引擎异常，可在日志页查看原因")
        case .stopped:
            hint(state.selectedModel.isEmpty
                 ? "还没有选择模型，在模型页选一个即可启动"
                 : "服务未运行，启动后对外提供 OpenAI 兼容接口")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                running ? state.stopService() : state.startService()
            } label: {
                Text(running ? "停止服务" : "启动服务")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(running ? .arcadeGlass : .arcadeAccent)
            .disabled(state.isSwitchingModel)

            IconAction(systemName: "doc.on.doc", help: "复制网关地址（OpenAI / Claude）") {
                state.copy(state.gatewayURL)
            }
            IconAction(systemName: "macwindow", help: "打开主窗口") {
                openMainWindow()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(state.gatewayURL)
                .font(Native.monoSmall)
                .foregroundStyle(Native.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("退出 flashCat") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Native.secondary)
        }
    }

    // MARK: pieces

    private func row(_ label: String, _ value: String) -> some View {
        KeyValueRow(label: label, value: value)
    }

    private var divider: some View {
        Hairline()
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Native.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func metricsValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
