import SwiftUI
import AppKit

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
        target.onSelect = { [weak state] id in state?.applyModel(id) }
        target.onManage = { [weak state] in state?.section = .models }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Only the active engine's models: the catalog also carries Splash
        // packages (`owner/repo`) and the packs serve their own `owner--repo`
        // link names, so listing everything offers ids the running engine
        // answers 404 to.
        let models = state.engineModels()

        if models.isEmpty {
            let empty = NSMenuItem(title: "\(state.activeEngine.displayName) 没有本地模型",
                                   action: nil,
                                   keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for model in models {
                let item = NSMenuItem(title: model.id,
                                      action: #selector(ModelMenuTarget.select(_:)),
                                      keyEquivalent: "")
                item.target = target
                item.representedObject = model.id
                item.state = model.id == state.selectedModel ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
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
                    .fill(.white.opacity(hovered && !switching ? 0.06 : 0))
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
                    .fill(.white.opacity(switching ? 0.075 : (hovered ? 0.10 : 0.055)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(switching ? Native.orange.opacity(0.40) : .white.opacity(0.10),
                            lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering in
                hovered = hovering
            }

        case .chip:
            HStack(spacing: 4) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))

                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(switching ? 0.9 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
                    .frame(maxWidth: 180, alignment: .leading)

                Spacer(minLength: 2)

                accessory
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                Capsule().fill(.white.opacity(switching ? 0.10 : (hovered ? 0.12 : 0.065)))
            }
            .overlay {
                Capsule().stroke(switching ? Native.orange.opacity(0.35) : .white.opacity(0.10),
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
                .foregroundStyle(.white.opacity(variant == .engine ? 0.4 : 0.34))
                .frame(width: variant == .engine ? 14 : 16, height: 16)
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// Retains the menu action target for the lifetime of one pop-up menu.
private final class ModelMenuTarget: NSObject {
    var onSelect: ((String) -> Void)?
    var onManage: (() -> Void)?

    @objc func select(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect?(id)
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
