// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import Combine
import FlashCatCore
import FlashCatKit
import QuartzCore
import SwiftUI

// MARK: - 尺寸

/// 模型列表的固定几何：宽度固定、高度封顶，列表只在内部滚动。
/// 这些值同时被窗口定位、内容布局与滚动条使用，必须保持单一来源。
enum ModelPickerMetrics {
    static let width: CGFloat = 480
    static let maxHeight: CGFloat = 320
    static let emptyHeight: CGFloat = 96

    static let floatingHorizontalPadding: CGFloat = 8
    static let inlineHorizontalPadding: CGFloat = 10
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 10
    static let groupHeaderHeight: CGFloat = 24
    static let groupGap: CGFloat = 4
    static let rowHeight: CGFloat = 30
    static let rowRadius: CGFloat = 8

    static let cardRadius: CGFloat = 22
    static let panelRadius: CGFloat = 16
    static let panelTopTrailingRadius: CGFloat = 10

    static let scrollBarWidth: CGFloat = 12
    static let scrollBarInset: CGFloat = 8
}

// MARK: - 分组

struct ModelPickerGroup: Identifiable {
    let engine: EngineID
    let models: [EngineModel]

    var id: EngineID { engine }
}

@MainActor
enum ModelPickerCatalog {
    /// 已安装引擎下可切换的模型：隐藏项、helper 和下载占位都不进浮层。
    static func groups(state: AppState) -> [ModelPickerGroup] {
        EngineCatalog.allIDs
            .filter { state.engineIsInstalled($0) }
            .compactMap { id in
                let models = state.engineModels(for: id)
                    .filter { !$0.hidden && !$0.helper && !ModelLibraryEntry.isDraftModel($0.id) }
                return models.isEmpty ? nil : ModelPickerGroup(engine: id, models: models)
            }
    }

    /// 内容自然高度：列表不满一屏时贴合内容，超过封顶才开始滚动。
    static func contentHeight(groups: [ModelPickerGroup]) -> CGFloat {
        guard !groups.isEmpty else { return ModelPickerMetrics.emptyHeight }
        var height = ModelPickerMetrics.topPadding + ModelPickerMetrics.bottomPadding
        for (index, group) in groups.enumerated() {
            if index > 0 { height += ModelPickerMetrics.groupGap }
            height += ModelPickerMetrics.groupHeaderHeight
            height += CGFloat(group.models.count) * ModelPickerMetrics.rowHeight
        }
        return height
    }

    static func panelHeight(groups: [ModelPickerGroup]) -> CGFloat {
        guard !groups.isEmpty else { return ModelPickerMetrics.emptyHeight }
        return min(ModelPickerMetrics.maxHeight, contentHeight(groups: groups))
    }

    /// 选中行在滚动内容里的顶部 y；用于打开时把它滚进视口。
    static func selectionOffset(
        groups: [ModelPickerGroup],
        selected: String,
        activeEngine: EngineID
    ) -> CGFloat? {
        var y = ModelPickerMetrics.topPadding
        for (index, group) in groups.enumerated() {
            if index > 0 { y += ModelPickerMetrics.groupGap }
            y += ModelPickerMetrics.groupHeaderHeight
            for model in group.models {
                if model.id == selected, group.engine == activeEngine {
                    return y
                }
                y += ModelPickerMetrics.rowHeight
            }
        }
        return nil
    }
}

// MARK: - 列表内容（浮层与输入卡共用）

/// 组头 + 行。容器负责内边距、滚动与背景；这里只管内容。
struct ModelPickerListContent: View {
    @ObservedObject var state: AppState
    let groups: [ModelPickerGroup]
    var revealed: Bool = true
    let onPick: (EngineModel, EngineID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                if groupIndex > 0 {
                    Color.clear
                        .frame(height: ModelPickerMetrics.groupGap)
                }
                groupHeader(group)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 4)
                    .animation(revealAnimation(groupIndex: groupIndex, rowIndex: -1), value: revealed)
                ForEach(Array(group.models.enumerated()), id: \.element.id) { rowIndex, model in
                    row(model, engine: group.engine)
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed ? 0 : 6)
                        .animation(revealAnimation(groupIndex: groupIndex, rowIndex: rowIndex), value: revealed)
                }
            }
        }
    }

    private func revealAnimation(groupIndex: Int, rowIndex: Int) -> Animation? {
        guard !reduceMotion else { return nil }
        guard revealed else { return .easeOut(duration: 0.09) }
        let ordinal = max(0, groupIndex * 4 + rowIndex + 1)
        return .easeOut(duration: 0.14).delay(0.04 + Double(ordinal) * 0.01)
    }

    private func groupHeader(_ group: ModelPickerGroup) -> some View {
        HStack(spacing: 6) {
            EngineMark(id: group.engine, size: 14)
            Text(verbatim: group.engine.displayName.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(DS.text4)
            Text(verbatim: "\(group.models.count)")
                .font(.system(size: 10))
                .foregroundStyle(DS.text4.opacity(0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: ModelPickerMetrics.groupHeaderHeight)
    }

    private func row(_ model: EngineModel, engine: EngineID) -> some View {
        let selected = model.id == state.selectedModel && engine == state.activeEngine
        let switching = state.switchingModel == model.id && engine == state.activeEngine
        // 生成期间不能换模型：行直接灰掉，比点完再弹「先停止」更早说明。
        let locked = state.generating && !selected
        return ModelPickerRow(
            title: state.shortModelName(model.id),
            selected: selected,
            switching: switching,
            stage: state.switchStage,
            capability: capabilityBadge(for: model),
            locked: switching || locked,
            action: { onPick(model, engine) })
    }

    private func capabilityBadge(for model: EngineModel) -> (symbol: String, help: String)? {
        if model.supportsVideo { return ("film", "视频模型") }
        if model.supportsImage { return ("photo", "图像模型") }
        if model.supportsVision { return ("eye", "视觉模型") }
        return nil
    }
}

// MARK: - 列表行

private struct ModelPickerRow: View {
    let title: String
    let selected: Bool
    let switching: Bool
    let stage: String
    let capability: (symbol: String, help: String)?
    let locked: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? DS.accent : DS.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if switching {
                    Text(L10n.t(stage.isEmpty ? "加载中" : stage))
                        .font(.system(size: 10))
                        .foregroundStyle(DS.warn)
                        .lineLimit(1)
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    if let capability {
                        Image(systemName: capability.symbol)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(DS.text3)
                            .help(L10n.t(capability.help))
                    }
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.accent)
                        .frame(width: 12)
                        .opacity(selected ? 1 : 0)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: ModelPickerMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DS.rect(ModelPickerMetrics.rowRadius)
                    .fill(selected ? DS.accentSoft : (hovering ? DS.hover : Color.clear))
            )
            .contentShape(DS.rect(ModelPickerMetrics.rowRadius))
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(
            locked
                ? L10n.t("正在生成，先停止再切换模型")
                : L10n.t("切换到这个模型")
        )
        .onHover { inside in
            if reduceMotion {
                hovering = inside
            } else {
                withAnimation(DS.Motion.snappy) { hovering = inside }
            }
        }
    }
}

// MARK: - 滚动条

struct ModelPickerScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    var isScrollable: Bool { contentHeight > viewportHeight + 0.5 }
    var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }
}

/// 4pt 细胶囊：悬停或拖动时变 6pt，拖动转强调色；只有命中区域是 12pt。
struct ModelPickerScrollBar: View {
    let metrics: ModelPickerScrollMetrics
    let onScrollTo: (CGFloat) -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var dragOrigin: CGFloat?
    @State private var jumpDrag = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var thumbIdle: Color {
        Color.adaptive(dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.26, lightAlpha: 0.20)
    }

    private var thumbHover: Color {
        Color.adaptive(dark: 0xFFFFFF, light: 0x0F172A, darkAlpha: 0.46, lightAlpha: 0.42)
    }

    var body: some View {
        GeometryReader { proxy in
            let track = max(1, proxy.size.height)
            let thumbHeight = max(
                30,
                track * metrics.viewportHeight / max(1, metrics.contentHeight))
            let travel = max(1, track - thumbHeight)
            let progress = min(1, max(0, metrics.offset / max(1, metrics.maxOffset)))
            let width: CGFloat = (hovering || dragging) ? 6 : 4

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                Capsule()
                    .fill(dragging ? DS.accent : (hovering ? thumbHover : thumbIdle))
                    .frame(width: width, height: thumbHeight)
                    .offset(y: travel * progress)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.12),
                        value: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(name: "modelPickerScrollBar")
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("modelPickerScrollBar"))
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = metrics.offset
                            let thumbTop = travel * progress
                            let onThumb =
                                value.startLocation.y >= thumbTop
                                && value.startLocation.y <= thumbTop + thumbHeight
                            jumpDrag = !onThumb
                            if jumpDrag {
                                jump(to: value.startLocation.y, thumbHeight: thumbHeight, travel: travel)
                            }
                            dragging = true
                        }
                        if jumpDrag {
                            jump(to: value.location.y, thumbHeight: thumbHeight, travel: travel)
                        } else if let dragOrigin {
                            let delta =
                                (value.location.y - value.startLocation.y) / travel
                                * metrics.maxOffset
                            onScrollTo(min(max(dragOrigin + delta, 0), metrics.maxOffset))
                        }
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                        jumpDrag = false
                        dragging = false
                    })
        }
    }

    /// 点轨道：让拇指中心跟随指针，随后继续拖动。
    private func jump(to y: CGFloat, thumbHeight: CGFloat, travel: CGFloat) {
        let progress = min(1, max(0, (y - thumbHeight / 2) / travel))
        onScrollTo(progress * metrics.maxOffset)
    }
}

// MARK: - 输入卡内展开层

/// 对话页的模型列表：贴在输入卡上沿，宽度与输入卡一致，底部方角、顶部圆角，
/// 与输入卡共用一条缝和一个背景。
struct ModelPickerInlinePanel: View {
    @ObservedObject var state: AppState
    let groups: [ModelPickerGroup]
    let onPick: (EngineModel, EngineID) -> Void

    @State private var scroll = ScrollPosition()
    @State private var metrics = ModelPickerScrollMetrics()
    @State private var revealed = false
    @State private var positionedSelection = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ModelPickerMetrics.cardRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: ModelPickerMetrics.cardRadius,
            style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if groups.isEmpty {
                Text(L10n.t("暂无可用模型"))
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    ModelPickerListContent(
                        state: state,
                        groups: groups,
                        revealed: revealed,
                        onPick: onPick
                    )
                    .padding(.horizontal, ModelPickerMetrics.inlineHorizontalPadding)
                    .padding(.top, ModelPickerMetrics.topPadding)
                    .padding(.bottom, ModelPickerMetrics.bottomPadding)
                }
                .scrollIndicators(.never)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ModelPickerScrollMetrics.self) { geometry in
                    ModelPickerScrollMetrics(
                        offset: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height)
                } action: { _, newValue in
                    metrics = newValue
                    positionSelectionIfNeeded(groups: groups, metrics: newValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(DS.floating))
        .clipShape(shape)
        .overlay {
            // 底边不画：那条缝由输入卡自己的上边框承担。
            shape.strokeBorder(DS.line2, lineWidth: 1)
                .mask(alignment: .top) {
                    Rectangle()
                        .padding(.bottom, 1)
                }
        }
        .overlay(alignment: .trailing) {
            if metrics.isScrollable {
                ModelPickerScrollBar(metrics: metrics) { offset in
                    scroll.scrollTo(y: offset)
                }
                .frame(width: ModelPickerMetrics.scrollBarWidth)
                .padding(.vertical, ModelPickerMetrics.scrollBarInset)
                .padding(.trailing, 2)
                .opacity(revealed ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) {
                revealed = true
            }
        }
    }

    private func positionSelectionIfNeeded(
        groups: [ModelPickerGroup],
        metrics: ModelPickerScrollMetrics
    ) {
        guard !positionedSelection,
            let top = ModelPickerCatalog.selectionOffset(
                groups: groups,
                selected: state.selectedModel,
                activeEngine: state.activeEngine)
        else { return }
        positionedSelection = true
        guard top + ModelPickerMetrics.rowHeight > metrics.viewportHeight else { return }
        let centered = top - (metrics.viewportHeight - ModelPickerMetrics.rowHeight) / 2
        scroll.scrollTo(y: min(max(centered, 0), metrics.maxOffset))
    }
}

// MARK: - 概览浮层内容

/// 概览页的模型浮层：右缘对齐入口按钮，上沿贴住按钮下沿，右上角收成 8pt。
struct ModelPickerPanelContent: View {
    @ObservedObject var state: AppState
    let groups: [ModelPickerGroup]
    @ObservedObject var presenter: ModelPickerPanelPresenter
    let onPick: (EngineModel, EngineID) -> Void

    @State private var scroll = ScrollPosition()
    @State private var metrics = ModelPickerScrollMetrics()
    @State private var positionedSelection = false

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: ModelPickerMetrics.panelRadius,
            bottomLeadingRadius: ModelPickerMetrics.panelRadius,
            bottomTrailingRadius: ModelPickerMetrics.panelRadius,
            topTrailingRadius: ModelPickerMetrics.panelTopTrailingRadius,
            style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if groups.isEmpty {
                Text(L10n.t("暂无可用模型"))
                    .font(DS.Font.sm)
                    .foregroundStyle(DS.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    ModelPickerListContent(
                        state: state,
                        groups: groups,
                        onPick: onPick
                    )
                    .padding(.horizontal, ModelPickerMetrics.floatingHorizontalPadding)
                    .padding(.top, ModelPickerMetrics.topPadding)
                    .padding(.bottom, ModelPickerMetrics.bottomPadding)
                }
                .scrollIndicators(.never)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: ModelPickerScrollMetrics.self) { geometry in
                    ModelPickerScrollMetrics(
                        offset: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        viewportHeight: geometry.containerSize.height)
                } action: { _, newValue in
                    metrics = newValue
                    positionSelectionIfNeeded(groups: groups, metrics: newValue)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.floating)
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.line2, lineWidth: 1))
        .overlay(alignment: .trailing) {
            if metrics.isScrollable {
                ModelPickerScrollBar(metrics: metrics) { offset in
                    scroll.scrollTo(y: offset)
                }
                .frame(width: ModelPickerMetrics.scrollBarWidth)
                .padding(.vertical, ModelPickerMetrics.scrollBarInset)
                .padding(.trailing, 2)
            }
        }
        .opacity(presenter.isPresented ? 1 : 0)
    }

    private func positionSelectionIfNeeded(
        groups: [ModelPickerGroup],
        metrics: ModelPickerScrollMetrics
    ) {
        guard !positionedSelection,
            let top = ModelPickerCatalog.selectionOffset(
                groups: groups,
                selected: state.selectedModel,
                activeEngine: state.activeEngine)
        else { return }
        positionedSelection = true
        guard top + ModelPickerMetrics.rowHeight > metrics.viewportHeight else { return }
        let centered = top - (metrics.viewportHeight - ModelPickerMetrics.rowHeight) / 2
        scroll.scrollTo(y: min(max(centered, 0), metrics.maxOffset))
    }
}

// MARK: - 浮层控制器

@MainActor
final class ModelPickerPanelPresenter: ObservableObject {
    @Published var isPresented = false
}

/// 概览页模型浮层的窗口控制器。
///
/// 用无边框 `NSPanel` 而不是 `NSPopover`：没有系统箭头、磨砂底和滚动条。
/// 面板右缘对齐入口按钮、上沿贴住按钮下沿；出现时窗口从按钮的右下角
/// 向外长到固定尺寸，内容始终按最终尺寸排好，只被窗口裁开。
@MainActor
final class ModelPickerPanelController: NSObject, NSWindowDelegate {
    static let shared = ModelPickerPanelController()

    private final class Panel: NSPanel {
        var onCancel: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private var panel: Panel?
    private var hostingView: NSHostingView<ModelPickerPanelContent>?
    private var presenter: ModelPickerPanelPresenter?
    private var ownerView: NSView?
    private var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastResignUptime: TimeInterval = 0
    private var themeCancellables: Set<AnyCancellable> = []

    var isPresented: Bool { panel?.isVisible == true }

    /// 点同一个入口收起；点别的入口则把浮层挪过去。
    func toggle(
        state: AppState,
        from anchor: NSView?,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        if isPresented, ownerView === anchor {
            dismiss()
            return
        }
        // 点击入口本身会让浮层先失焦收起；同一次点击不要立刻又把它开回来。
        if ProcessInfo.processInfo.systemUptime - lastResignUptime < 0.22 { return }
        present(state: state, from: anchor, onPresent: onPresent, onDismiss: onDismiss)
    }

    func present(
        state: AppState,
        from anchor: NSView?,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        guard let anchor, let parent = anchor.window else { return }
        if isPresented { dismiss(animated: false) }
        onPresent?()

        let groups = ModelPickerCatalog.groups(state: state)
        let size = NSSize(
            width: ModelPickerMetrics.width,
            height: ModelPickerCatalog.panelHeight(groups: groups))
        let finalFrame = Self.frame(anchor: anchor, in: parent, size: size)
        let presenter = ModelPickerPanelPresenter()

        let content = ModelPickerPanelContent(
            state: state,
            groups: groups,
            presenter: presenter,
            onPick: { [weak self] model, engine in
                self?.dismiss(animated: false)
                state.applyModelFromAnyEngine(model.id, engine: engine)
            })
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.autoresizingMask = [.minXMargin, .minYMargin]

        let initialSize = NSSize(width: 1, height: 1)
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = NSRect(
            x: initialSize.width - size.width,
            y: initialSize.height - size.height,
            width: size.width,
            height: size.height)
        container.addSubview(host)

        let initialFrame = NSRect(
            x: finalFrame.maxX - initialSize.width,
            y: finalFrame.maxY - initialSize.height,
            width: initialSize.width,
            height: initialSize.height)

        let panel = Panel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.title = L10n.t("选择模型")
        panel.appearance = state.theme.resolvedAppearance
        panel.contentView = container
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.setFrame(initialFrame, display: true)

        self.panel = panel
        self.hostingView = host
        self.presenter = presenter
        self.ownerView = anchor
        self.parentWindow = parent
        self.onDismiss = onDismiss

        observeTheme(state.theme, panel: panel)
        observeParent(parent)

        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                presenter.isPresented = true
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.86, 0.24, 1)
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    func dismiss(animated: Bool = true) {
        removeObservers()
        themeCancellables.removeAll()

        guard let panel else {
            let callback = onDismiss
            onDismiss = nil
            callback?()
            return
        }

        let callback = onDismiss
        let presenter = presenter
        let parent = parentWindow
        onDismiss = nil
        self.presenter = nil
        self.panel = nil
        self.hostingView = nil
        self.ownerView = nil
        self.parentWindow = nil

        let finish = { [weak self] in
            panel.orderOut(nil)
            if NSApp.isActive, let parent, self?.panel == nil {
                parent.makeKey()
            }
            callback?()
            // 选模型时这条栈还在按钮 action 里：窗口立刻收，承载视图下一轮再拆。
            DispatchQueue.main.async { panel.contentView = nil }
        }

        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                presenter?.isPresented = false
            }
            let corner = NSRect(
                x: panel.frame.maxX - 1,
                y: panel.frame.maxY - 1,
                width: 1,
                height: 1)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
                panel.animator().setFrame(corner, display: true)
            } completionHandler: {
                finish()
            }
        } else {
            presenter?.isPresented = false
            finish()
        }
    }

    // MARK: 定位

    /// 面板右缘对齐触发按钮，上沿贴住按钮下沿（零间隙）；下方放不下才翻到上方。
    private static func frame(anchor: NSView, in window: NSWindow, size: NSSize) -> NSRect {
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorRect = window.convertToScreen(anchorInWindow)
        let windowFrame = window.frame
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? windowFrame
        let margin: CGFloat = 10

        let minX = max(windowFrame.minX + margin, screenFrame.minX + margin)
        let maxX = min(windowFrame.maxX - margin, screenFrame.maxX - margin) - size.width
        var x = anchorRect.maxX - size.width
        x = min(max(x, minX), max(minX, maxX))

        let minY = max(windowFrame.minY + margin, screenFrame.minY + margin)
        let maxY = min(windowFrame.maxY - margin, screenFrame.maxY - margin) - size.height
        var y = anchorRect.minY - size.height
        if y < minY {
            y = anchorRect.maxY
        }
        y = min(max(y, minY), max(minY, maxY))

        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: 观察者

    private func observeTheme(_ theme: ThemeController, panel: Panel) {
        theme.$mode
            .receive(on: RunLoop.main)
            .sink { [weak panel, weak theme] _ in
                guard let theme else { return }
                panel?.appearance = theme.resolvedAppearance
            }
            .store(in: &themeCancellables)
        theme.$systemIsDark
            .receive(on: RunLoop.main)
            .sink { [weak panel, weak theme] _ in
                guard let theme else { return }
                panel?.appearance = theme.resolvedAppearance
            }
            .store(in: &themeCancellables)
    }

    private func observeParent(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.dismiss() }
                })
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        lastResignUptime = ProcessInfo.processInfo.systemUptime
        dismiss()
    }
}

// MARK: - 输入卡内列表窗口

/// 对话页的模型列表窗口：宽度跟输入卡一致，底边贴在输入卡上沿，从卡片
/// 上沿向上长到列表高度。用一个无边框 key panel 接管键盘与失焦收起，
/// 不挂 NSEvent 监听。
@MainActor
final class ModelPickerInlinePanelController: NSObject, NSWindowDelegate {
    static let shared = ModelPickerInlinePanelController()

    private final class Panel: NSPanel {
        var onCancel: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private var panel: Panel?
    private var hostingView: NSHostingView<ModelPickerInlinePanel>?
    private var ownerView: NSView?
    private var parentWindow: NSWindow?
    private var onDismiss: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var themeCancellables: Set<AnyCancellable> = []
    private var lastResignUptime: TimeInterval = 0

    var isPresented: Bool { panel?.isVisible == true }

    func toggle(
        state: AppState,
        from anchor: NSView?,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        if isPresented {
            dismiss()
            return
        }
        // 点击入口本身会让浮层先失焦收起；同一次点击不要立刻又把它开回来。
        if ProcessInfo.processInfo.systemUptime - lastResignUptime < 0.22 { return }
        present(state: state, from: anchor, onPresent: onPresent, onDismiss: onDismiss)
    }

    func present(
        state: AppState,
        from anchor: NSView?,
        onPresent: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        guard let anchor, let parent = anchor.window else { return }
        if isPresented { dismiss(animated: false) }
        onPresent?()

        let groups = ModelPickerCatalog.groups(state: state)
        let anchorRect = Self.screenRect(anchor)
        let width = max(240, anchorRect.width)
        let roomAbove = max(120, parent.frame.maxY - anchorRect.maxY - 10)
        let height = min(ModelPickerCatalog.panelHeight(groups: groups), roomAbove)
        let size = NSSize(width: width, height: height)
        let finalFrame = NSRect(
            x: anchorRect.minX,
            y: anchorRect.maxY,
            width: width,
            height: height)
        let initialFrame = NSRect(
            x: anchorRect.minX,
            y: anchorRect.maxY,
            width: width,
            height: 1)

        let content = ModelPickerInlinePanel(
            state: state,
            groups: groups,
            onPick: { [weak self] model, engine in
                self?.dismiss(animated: false)
                state.applyModelFromAnyEngine(model.id, engine: engine)
            })
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: initialFrame.height - size.height, width: size.width, height: size.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.autoresizingMask = [.maxXMargin, .minYMargin]

        let container = NSView(frame: NSRect(origin: .zero, size: initialFrame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(host)

        let panel = Panel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.title = L10n.t("选择模型")
        panel.appearance = state.theme.resolvedAppearance
        panel.contentView = container
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.setFrame(initialFrame, display: true)

        self.panel = panel
        self.hostingView = host
        self.ownerView = anchor
        self.parentWindow = parent
        self.onDismiss = onDismiss

        observeTheme(state.theme, panel: panel)
        observeParent(parent)

        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.86, 0.24, 1)
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    func dismiss(animated: Bool = true) {
        removeObservers()
        themeCancellables.removeAll()

        guard let panel else {
            let callback = onDismiss
            onDismiss = nil
            callback?()
            return
        }

        let callback = onDismiss
        let parent = parentWindow
        onDismiss = nil
        self.panel = nil
        self.hostingView = nil
        self.ownerView = nil
        self.parentWindow = nil

        let finish = { [weak self] in
            panel.orderOut(nil)
            if NSApp.isActive, let parent, self?.panel == nil {
                parent.makeKey()
            }
            callback?()
            DispatchQueue.main.async { panel.contentView = nil }
        }

        if animated {
            let collapsed = NSRect(
                x: panel.frame.minX,
                y: panel.frame.minY,
                width: panel.frame.width,
                height: 1)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 0.2)
                panel.animator().setFrame(collapsed, display: true)
            } completionHandler: {
                finish()
            }
        } else {
            finish()
        }
    }

    // MARK: 观察者

    private func observeTheme(_ theme: ThemeController, panel: Panel) {
        theme.$mode
            .receive(on: RunLoop.main)
            .sink { [weak panel, weak theme] _ in
                guard let theme else { return }
                panel?.appearance = theme.resolvedAppearance
            }
            .store(in: &themeCancellables)
        theme.$systemIsDark
            .receive(on: RunLoop.main)
            .sink { [weak panel, weak theme] _ in
                guard let theme else { return }
                panel?.appearance = theme.resolvedAppearance
            }
            .store(in: &themeCancellables)
    }

    private func observeParent(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.dismiss() }
                })
        }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            })
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private static func screenRect(_ view: NSView) -> CGRect {
        guard let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        lastResignUptime = ProcessInfo.processInfo.systemUptime
        dismiss()
    }
}
