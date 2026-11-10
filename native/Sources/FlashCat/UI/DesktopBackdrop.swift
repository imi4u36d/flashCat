import SwiftUI
import AppKit

/// 无自定义壁纸时，让窗口透出桌面。
///
/// 窗口本身由 `Theme.apply(to:)` 设为非不透明；这一层用系统
/// `NSVisualEffectView` 兜住桌面，避免透明窗口在切壁纸/外观后留下残影。
/// 模糊滑杆越大，毛玻璃层越不透明，桌面越柔化；为 0 时桌面保持清晰。
///
/// 强度不由 SwiftUI 入参决定，而是登记到 `BackgroundSurface`：后者在背景参数
/// 一变化时就改这一层的 `alphaValue`。带 `blur` 入参的版本会踩到「入参没变就
/// 不回调 `updateNSView`」，只拖透明度时这一层根本收不到更新，桌面要等下一次
/// 拖模糊才跟着出现（见 `BackgroundSurface` 的说明）。
struct DesktopBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> BackdropContainerView {
        let container = BackdropContainerView()
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .underWindowBackground
        effect.autoresizingMask = [.width, .height]
        effect.alphaValue = BackgroundSettings.shared.blurAlpha
        container.addSubview(effect)
        context.coordinator.effect = effect
        BackgroundSurface.shared.attach(effectView: effect)
        container.onWindowChange = { window in
            // 只认主窗口：菜单栏面板、弹层里的窗口不该改窗口表面。
            guard window.canBecomeMain else { return }
            BackgroundSurface.shared.attach(window: window)
        }
        return container
    }

    func updateNSView(_ nsView: BackdropContainerView, context: Context) {
        // 重建或换窗口时再对齐一次；参数本身由 BackgroundSurface 驱动。
        BackgroundSurface.shared.refresh()
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
