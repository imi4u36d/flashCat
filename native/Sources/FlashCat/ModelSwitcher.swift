import SwiftUI
import AppKit
import FlashCatKit

/// Where a model switcher is drawn. Interaction is identical everywhere: the
/// whole name is clickable, long names stay on one line with an ellipsis, and
/// hovering reveals the full repository id.
enum ModelSwitcherVariant {
    /// Dense row inside the sidebar engine card.
    case engine
    /// Full-width row in the chat parameters panel.
    case panel
    /// Capsule beside the chat composer.
    case chip
}

struct ModelSwitcher: View {
    @ObservedObject var state: AppState
    var variant: ModelSwitcherVariant = .panel

    @State private var hovered = false
    @State private var anchorBox = MenuAnchorBox()

    private var switching: Bool { state.isSwitchingModel }

    private var label: String {
        if let info = state.selectedModelInfo { return info.shortName }
        let id = state.selectedModel
        if id.isEmpty { return "选择模型" }
        return state.shortModelName(id)
    }

    private var fullName: String {
        if let info = state.selectedModelInfo { return info.id }
        return state.selectedModel.isEmpty ? "选择模型" : state.selectedModel
    }

    private var helpText: String {
        if switching, let target = state.switchingModel {
            return state.switchStage.isEmpty
                ? "正在切换到 \(target)"
                : "正在切换到 \(target) · \(state.switchStage)"
        }
        return state.selectedModel.isEmpty ? "选择模型" : fullName
    }

    var body: some View {
        Button {
            presentMenu()
        } label: {
            labelContent
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(box: anchorBox))
        .allowsHitTesting(!switching)
        .help(helpText)
        .accessibilityLabel(switching ? "正在切换模型 \(fullName)" : "当前模型 \(fullName)，点击切换")
        .accessibilityHint("打开模型列表")
        .animation(.easeOut(duration: 0.18), value: switching)
        .animation(.easeOut(duration: 0.18), value: hovered)
        .animation(.easeOut(duration: 0.18), value: label)
    }

    // MARK: - Menu

    private func presentMenu() {
        guard !switching else { return }

        let target = ModelMenuTarget()
        target.onSelect = { [weak state] id, engine in
            state?.applyModelFromAnyEngine(id, engine: engine)
        }
        target.onManage = { [weak state] in state?.section = .models }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // One group per installed engine. A model belongs to the engine that
        // serves its format, so groups carry ids the active engine would
        // answer 404 to — picking one hops engines first, which the app does
        // silently (the menu only ever showed models, so the hop is the
        // switch the reader asked for).
        var listed = 0
        for engine in state.availableEngines {
            let models = state.engineModels(for: engine)
            if models.isEmpty { continue }

            let header = NSMenuItem(title: engine.displayName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for model in models {
                let item = NSMenuItem(title: model.id,
                                      action: #selector(ModelMenuTarget.select(_:)),
                                      keyEquivalent: "")
                item.target = target
                item.representedObject = [engine.rawValue, model.id]
                item.state = engine == state.activeEngine && model.id == state.selectedModel ? .on : .off
                menu.addItem(item)
                listed += 1
            }
            menu.addItem(.separator())
        }

        if listed == 0 {
            let empty = NSMenuItem(title: "没有已安装的模型", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        let manage = NSMenuItem(title: "管理模型…",
                                action: #selector(ModelMenuTarget.manage),
                                keyEquivalent: "")
        manage.target = target
        menu.addItem(manage)

        // Opening on the next runloop keeps the menu from being dismissed by the
        // mouse-up that activated the button. Anchor it under the control so the
        // list also opens correctly on secondary displays. `target` is captured
        // because NSMenuItem keeps a weak target, and must outlive the menu.
        DispatchQueue.main.async { [menu, target] in
            let location: NSPoint
            if let anchor = anchorBox.view, let window = anchor.window {
                let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                location = NSPoint(x: frame.minX, y: frame.minY - 4)
            } else {
                let pointer = NSEvent.mouseLocation
                location = NSPoint(x: pointer.x - 6, y: pointer.y - 8)
            }
            withExtendedLifetime(target) {
                menu.popUp(positioning: nil, at: location, in: nil)
            }
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var labelContent: some View {
        switch variant {
        case .engine:
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                    .layoutPriority(1)

                Spacer(minLength: 2)

                accessory
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Native.overlay(hovered && !switching ? 0.06 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hovered = hovering
            }

        case .panel:
            HStack(spacing: 7) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Native.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                    .layoutPriority(1)

                if switching {
                    Text(state.switchStage.isEmpty ? "切换中" : state.switchStage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Native.orange)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }

                Spacer(minLength: 2)

                accessory
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Native.overlay(switching ? 0.075 : (hovered ? 0.10 : 0.055)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(switching ? Native.orange.opacity(0.40) : Native.overlay(0.10),
                            lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering in
                hovered = hovering
            }

        case .chip:
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Native.tertiary)

                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Native.label.opacity(switching ? 1 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                    .frame(maxWidth: 120, alignment: .leading)

                accessory
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                Capsule().fill(Native.overlay(switching ? 0.10 : (hovered ? 0.12 : 0.07)))
            }
            .overlay {
                Capsule().stroke(switching ? Native.orange.opacity(0.35) : Native.overlay(0.12),
                                 lineWidth: 0.8)
            }
            .contentShape(Capsule())
            .onHover { hovering in
                hovered = hovering
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if switching {
            ProgressView()
                .controlSize(.mini)
                .tint(Native.orange)
                .scaleEffect(0.75)
                .frame(width: variant == .engine ? 14 : 16, height: 16)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
        } else {
            Image(systemName: variant == .chip ? "chevron.down" : "chevron.up.chevron.down")
                .font(.system(size: variant == .engine ? 8 : 8.5, weight: .bold))
                .foregroundStyle(Native.tertiary)
                .frame(width: variant == .engine ? 14 : 16, height: 16)
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// Retains the menu action target for the lifetime of one pop-up menu.
private final class ModelMenuTarget: NSObject {
    var onSelect: ((String, EngineID) -> Void)?
    var onManage: (() -> Void)?

    @objc func select(_ sender: NSMenuItem) {
        // The menu groups by engine, so each item carries the engine that
        // serves it next to the model id.
        guard let payload = sender.representedObject as? [String],
              payload.count == 2,
              let engine = EngineID(rawValue: payload[0]) else { return }
        onSelect?(payload[1], engine)
    }

    @objc func manage() {
        onManage?()
    }
}

/// Weakly hands the AppKit view under the switcher to the click handler so the
/// menu can be anchored precisely under the row.
private final class MenuAnchorBox {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
