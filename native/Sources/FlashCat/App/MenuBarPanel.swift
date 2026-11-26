// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

// MARK: - 菜单栏图标

/// 系统菜单栏里的状态图标：单色猫头轮廓 + 闪电镂空，由系统按菜单栏明暗自动着色。
enum MenuBarIcon {
    static let pointSize: CGFloat = 18

    @MainActor private static var cache: [ServerState: NSImage] = [:]

    @MainActor
    static func statusImage(state: ServerState) -> NSImage {
        if let cached = cache[state] { return cached }

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for scale in [2.0, 3.0] {
            let pixel = Int(pointSize * scale)
            guard
                let rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixel, pixelsHigh: pixel,
                    bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = NSSize(width: pointSize, height: pointSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(state: state, in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }

    @MainActor
    private static func draw(state: ServerState, in rect: NSRect) {
        let glyphRect = rect.offsetBy(dx: 0, dy: -rect.width * 0.05)
        let glyph = glyphPath(in: glyphRect)
        let strokeWidth = rect.width * 0.075

        switch state {
        case .ready:
            NSColor.black.setFill()
            glyph.fill()

        case .starting, .stopping:
            NSColor.black.withAlphaComponent(0.40).setFill()
            glyph.fill()

        case .stopped:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            glyph.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.92).setStroke()
            glyph.stroke()

        case .failed:
            glyph.lineWidth = strokeWidth
            glyph.lineJoinStyle = .round
            glyph.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.50).setStroke()
            glyph.stroke()

            let dot = rect.width * 0.27
            let dotRect = NSRect(
                x: rect.width - dot - rect.width * 0.03,
                y: rect.height * 0.03,
                width: dot, height: dot)
            let gap = dotRect.insetBy(dx: -rect.width * 0.075, dy: -rect.width * 0.075)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: gap).fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    private static func glyphPath(in rect: NSRect) -> NSBezierPath {
        let path = headPath(in: rect)
        path.append(boltPath(in: rect))
        path.windingRule = .evenOdd
        return path
    }

    private static func headPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        let path = NSBezierPath()
        path.move(to: point(1.2, 6.9))
        path.line(to: point(1.2, 10.5))
        path.curve(
            to: point(3.9, 16.9),
            controlPoint1: point(1.2, 12.4),
            controlPoint2: point(2.4, 15.5))
        path.line(to: point(7.0, 12.8))
        path.line(to: point(11.0, 12.8))
        path.line(to: point(14.1, 16.9))
        path.curve(
            to: point(16.8, 10.5),
            controlPoint1: point(15.6, 15.5),
            controlPoint2: point(16.8, 12.4))
        path.line(to: point(16.8, 6.9))
        path.curve(
            to: point(13.2, 2.9),
            controlPoint1: point(16.8, 4.7),
            controlPoint2: point(15.1, 2.9))
        path.line(to: point(4.8, 2.9))
        path.curve(
            to: point(1.2, 6.9),
            controlPoint1: point(2.9, 2.9),
            controlPoint2: point(1.2, 4.7))
        path.close()
        return path
    }

    private static func boltPath(in rect: NSRect) -> NSBezierPath {
        let scale = rect.width / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }

        let path = NSBezierPath()
        path.move(to: point(10.4, 12.0))
        path.line(to: point(7.9, 8.6))
        path.line(to: point(9.3, 8.6))
        path.line(to: point(8.4, 5.6))
        path.line(to: point(11.0, 9.3))
        path.line(to: point(9.5, 9.3))
        path.close()
        return path
    }
}

// MARK: - 菜单栏浮层容器

/// 仅在面板展开时挂载 `MenuBarPanel`，收起期间不订阅高频指标更新。
struct MenuBarPanelContainer: View {
    @ObservedObject var state: AppState
    @ObservedObject var presenter: MenuBarPanelPresenter
    let cardWidth: CGFloat
    let shadowInsets: EdgeInsets
    var onOpenMainWindow: (Page?) -> Void
    var onDismiss: () -> Void
    var onCardHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardShape: RoundedRectangle { DS.rect(DS.Radius.window) }

    var body: some View {
        Group {
            if presenter.isPresented {
                MenuBarPanel(
                    state: state,
                    metrics: state.metrics,
                    onOpenMainWindow: onOpenMainWindow,
                    onDismiss: onDismiss
                )
            } else {
                Color.clear
                    .frame(height: 220)
            }
        }
        .frame(width: cardWidth)
        .background(cardShape.fill(DS.floating))
        .clipShape(cardShape)
        .overlay(cardShape.strokeBorder(DS.line2, lineWidth: 1))
        .shadow(color: DS.glassShadow, radius: 20, x: 0, y: 10)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { _, newHeight in
            onCardHeightChange(newHeight)
        }
        .scaleEffect(reduceMotion ? 1 : (presenter.isPresented ? 1 : 0.96), anchor: .top)
        .offset(y: reduceMotion ? 0 : (presenter.isPresented ? 0 : -5))
        .opacity(presenter.isPresented ? 1 : 0)
        .animation(
            reduceMotion ? DS.Motion.fade : DS.Motion.snappy,
            value: presenter.isPresented
        )
        .padding(shadowInsets)
        .tint(DS.accent)
        .onExitCommand { onDismiss() }
    }
}

// MARK: - 轻量菜单栏面板

struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var metrics: MetricsStore
    var onOpenMainWindow: (Page?) -> Void = { page in
        if let page { AppState.shared.section = page }
        MainWindow.show()
    }
    var onDismiss: () -> Void = {}

    @State private var modelPickerOpen = false
    @State private var pendingSwitch: String?
    @State private var copiedEndpoint = false
    @State private var hoveringModelRow = false
    @State private var hoveringEndpoint = false
    @State private var copyResetTask: Task<Void, Never>?

    private var running: Bool { state.isRunning }
    private var busy: Bool { state.serverState == .starting || state.serverState == .stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            modelSection
            DSDivider()
            endpointRow
            DSDivider()

            if running {
                telemetryRow
            }

            if state.serverState == .failed {
                failureBanner
            }

            if let pendingSwitch {
                switchConfirmCard(pendingSwitch)
            }

            actionRow
            DSDivider()
            footer
        }
        .padding(14)
        .animation(DS.Motion.snappy, value: modelPickerOpen)
        .animation(DS.Motion.snappy, value: pendingSwitch)
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 22)
            Text("flashCat")
                .font(DS.Font.prose(13.5, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(state.activeEngine.displayName)
                .font(DS.Font.mono(10.5, weight: .medium))
                .foregroundStyle(DS.text3)
            Spacer(minLength: 4)
            DSChip(
                text: statusLabel,
                dot: statusTint,
                live: state.canChat,
                tint: statusTint)
        }
    }

    private var statusLabel: String {
        if state.serverState == .failed { return "异常" }
        if state.canChat { return "运行中" }
        if state.isModelBusy || busy {
            let stage = state.engineStageText
            return stage.isEmpty ? state.serverState.rawValue : stage
        }
        return "已停止"
    }

    private var statusTint: Color {
        if state.serverState == .failed { return DS.err }
        if state.canChat { return DS.ok }
        if state.isModelBusy || busy { return DS.warn }
        return DS.text3
    }

    // MARK: Model & inline switcher

    private var installedModels: [String] {
        let local = state.engineModels().filter { !$0.helper && !$0.hidden }.map(\.id)
        if !state.selectedModel.isEmpty, !local.contains(state.selectedModel) {
            return [state.selectedModel] + local
        }
        return local
    }

    private var modelDisplayName: String {
        if state.selectedModel.isEmpty { return L10n.t("尚未选择模型") }
        return state.selectedModelInfo?.shortName ?? state.shortModelName(state.selectedModel)
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                modelPickerOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    EngineMark(id: state.activeEngine, size: 18)
                    Text(modelDisplayName)
                        .font(DS.Font.prose(12.5, weight: .medium))
                        .foregroundStyle(state.selectedModel.isEmpty ? DS.text3 : DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: modelPickerOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.text3)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(DS.rect(DS.Radius.md).fill(hoveringModelRow ? DS.hover : .clear))
                .contentShape(DS.rect(DS.Radius.md))
            }
            .buttonStyle(.plain)
            .onHover { hoveringModelRow = $0 }
            .disabled(busy || state.isSwitchingModel)

            if modelPickerOpen {
                modelList
            }
        }
    }

    private var modelList: some View {
        ScrollView {
            VStack(spacing: 2) {
                if installedModels.isEmpty {
                    Text(L10n.t("没有可用模型"))
                        .font(DS.Font.xs)
                        .foregroundStyle(DS.text3)
                        .padding(.vertical, 8)
                } else {
                    ForEach(installedModels, id: \.self) { id in
                        let current = id == state.selectedModel
                        Button {
                            selectModel(id)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: current ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(current ? DS.accent : DS.text4)
                                Text(state.shortModelName(id))
                                    .font(DS.Font.prose(11.5, weight: current ? .semibold : .regular))
                                    .foregroundStyle(DS.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(DS.rect(6).fill(current ? DS.accentSoft : .clear))
                            .contentShape(DS.rect(6))
                        }
                        .buttonStyle(.plain)
                        // 生成期间换模型会被拒；行直接灰掉，避免点完再弹提示。
                        .disabled(state.generating && !current)
                        .help(
                            state.generating && !current
                                ? L10n.t("正在生成，先停止再切换模型")
                                : L10n.t("切换到这个模型"))
                    }
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 156)
        .dsWell(radius: DS.Radius.md)
    }

    private func selectModel(_ id: String) {
        modelPickerOpen = false
        guard id != state.selectedModel else { return }
        if EngineModelSelection.needsConfirmation(
            isRunning: state.isRunning,
            current: state.selectedModel,
            target: id
        ) {
            pendingSwitch = id
        } else {
            state.applyModel(id)
        }
    }

    private func switchConfirmCard(_ target: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.format("停止当前模型并切换到 %@？", state.shortModelName(target)))
                .font(DS.Font.prose(11.5))
                .foregroundStyle(DS.text2)
            HStack(spacing: 8) {
                Button(L10n.t("取消")) { pendingSwitch = nil }
                    .buttonStyle(.ds(.secondary, size: .small))
                Button(L10n.t("停止并切换")) {
                    pendingSwitch = nil
                    state.applyModelConfirmed(target)
                }
                .buttonStyle(.ds(.primary, size: .small))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsWell(radius: DS.Radius.md)
    }

    // MARK: Endpoint & telemetry

    private var endpointRow: some View {
        Button {
            state.copy(state.gatewayURL)
            copiedEndpoint = true
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                copiedEndpoint = false
            }
        } label: {
            HStack(spacing: 6) {
                Text("API")
                    .font(DS.Font.mono(10, weight: .semibold))
                    .foregroundStyle(DS.text3)
                Text(verbatim: state.gatewayURL)
                    .font(DS.Font.mono(11))
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: copiedEndpoint ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(copiedEndpoint ? DS.ok : DS.text3)
            }
            .frame(height: 28)
            .background(DS.rect(DS.Radius.sm).fill(hoveringEndpoint ? DS.hover : .clear))
            .contentShape(DS.rect(DS.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hoveringEndpoint = $0 }
        .help(L10n.t("复制接口地址"))
    }

    private var telemetryRow: some View {
        let decode = state.menuBarDecodeReading.value
        let ttft = state.ttftReading.milliseconds
        let decodeText = (decode ?? 0) > 0 ? "\(Format.compact(decode ?? 0)) tok/s" : "—"
        let ttftText = (ttft ?? 0) > 0 ? String(format: "%.0f ms", ttft ?? 0) : "—"
        return HStack(spacing: 0) {
            telemetryChip(label: "解码", value: decodeText)
            Rectangle()
                .fill(DS.line)
                .frame(width: 1)
                .frame(maxHeight: 20)
            telemetryChip(label: "首字延迟", value: ttftText)
        }
    }

    private func telemetryChip(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(L10n.t(label))
                .font(DS.Font.xs)
                .foregroundStyle(DS.text3)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(DS.Font.number(11.5, weight: .semibold))
                .foregroundStyle(value == "—" ? DS.text4 : DS.text)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
    }

    // MARK: Failure

    private var failureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.err)
            Text(state.failureMessage ?? L10n.t("引擎启动异常"))
                .font(DS.Font.xs)
                .foregroundStyle(DS.err)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L10n.t("查看日志")) {
                onOpenMainWindow(.logs)
            }
            .buttonStyle(.dsGhost)
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .background(DS.rect(DS.Radius.sm).fill(DS.dangerFill))
        .overlay(alignment: .leading) {
            Rectangle().fill(DS.err).frame(width: 2)
        }
        .clipShape(DS.rect(DS.Radius.sm))
    }

    // MARK: Actions & footer

    private var actionRow: some View {
        Button {
            if busy {
                state.stopService()
            } else {
                state.toggleService()
            }
        } label: {
            Label(
                L10n.t(busy ? "取消" : (running ? "停止引擎" : "启动引擎")),
                systemImage: running || busy ? "stop.fill" : "play.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.ds(running ? .danger : .primary, size: .regular))
        .disabled(!running && !busy && (state.selectedModel.isEmpty || state.runtimeMissing != nil))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(L10n.t("打开主窗口")) {
                onOpenMainWindow(nil)
            }
            .buttonStyle(.dsGhost)
            .font(DS.Font.xs)

            Button(L10n.t("对话")) {
                onOpenMainWindow(.chat)
            }
            .buttonStyle(.dsGhost)
            .font(DS.Font.xs)

            Spacer(minLength: 0)

            Button(L10n.t("退出")) {
                onDismiss()
                NSApp.terminate(nil)
            }
            .buttonStyle(.dsGhost)
            .font(DS.Font.xs)
        }
    }
}
