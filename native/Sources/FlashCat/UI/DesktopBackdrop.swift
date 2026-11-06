import SwiftUI
import AppKit

/// 无自定义壁纸时，让窗口透出桌面。
///
/// 窗口本身由 `Theme.apply(to:)` 设为非不透明；这一层用系统
/// `NSVisualEffectView` 兜住桌面，避免透明窗口在切壁纸/外观后留下残影。
/// `blur` 越大，毛玻璃层越不透明，桌面越柔化；为 0 时桌面保持清晰。
struct DesktopBackdrop: NSViewRepresentable {
    var blur: Double

    func makeNSView(context: Context) -> BackdropContainerView {
        let container = BackdropContainerView()
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .underWindowBackground
        effect.autoresizingMask = [.width, .height]
        effect.alphaValue = blurAlpha
        container.addSubview(effect)
        context.coordinator.effect = effect
        container.onWindowChange = { window in
            AppState.shared.theme.apply(to: window)
        }
        return container
    }

    func updateNSView(_ nsView: BackdropContainerView, context: Context) {
        context.coordinator.effect?.alphaValue = blurAlpha
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppState.shared.theme.apply(to: window)
        }
    }

    private var blurAlpha: CGFloat {
        CGFloat(min(max(blur / 40, 0), 1))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var effect: NSVisualEffectView?
    }
}

/// 只在真正挂到窗口上时回调一次，避免 representable 创建阶段拿不到 window。
final class BackdropContainerView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        onWindowChange?(window)
    }
}
