// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import FlashCatKit
import SwiftUI

/// 模型选择入口：按钮只负责开合，浮层内容与定位都在 `ModelPickerPanelController`。
/// 触发控件背后的这个 `NSView` 用来取窗口坐标，本身不参与命中测试。
struct ModelPickerButton<Label: View>: View {
    @ObservedObject var state: AppState
    var kind: DSButtonStyle.Kind = .primary
    /// 浮层是否由这颗按钮打开；标签用它换颜色与箭头方向。
    @ViewBuilder var label: (Bool) -> Label

    @State private var anchor: NSView?
    @State private var isOpen = false

    var body: some View {
        Button {
            ModelPickerPanelController.shared.toggle(
                state: state,
                from: anchor,
                onPresent: { isOpen = true },
                onDismiss: { isOpen = false })
        } label: {
            label(isOpen)
        }
        .buttonStyle(.ds(kind, active: isOpen))
        .background(ModelPickerAnchorReader { anchor = $0 })
        .onDisappear {
            // 入口跟着页面一起消失时，浮层不能留在屏幕上。
            ModelPickerPanelController.shared.dismiss(animated: false)
        }
    }
}

struct ModelPickerAnchorReader: NSViewRepresentable {
    var onChange: (NSView?) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        // 布局完成前拿不到窗口；下一轮 runloop 再把坐标源交给浮层。
        DispatchQueue.main.async { onChange(view) }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
