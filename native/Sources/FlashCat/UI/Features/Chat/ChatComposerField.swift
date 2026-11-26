// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

/// 对话输入框。
///
/// SwiftUI 的 `TextField(axis: .vertical)` 只能用回车换行，没办法把回车改成发送、
/// 再留一个组合键写换行，所以这里换成 `NSTextView`：**回车发送，⇧回车换行，
/// Escape 停止生成**，输入法组字期间的回车一律交回 AppKit（那是候选确认，不是发送）。
///
/// 这是应用里唯一一处按键判定，见 UI-SPEC「键盘策略」和
/// `LocalizationTests.testReturnKeyIsOnlyHandledByComposer`。它属于文本编辑动作，
/// 不是全局快捷键：判定只在输入框拿到焦点时发生，不会和用户的快捷键管理器抢键。
struct ChatComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled: Bool
    var isActive: Bool = true
    /// 当前草稿属于哪段会话。切会话时即使两段草稿文字相同，也把视图里的
    /// 编辑历史与选区重置，避免一段会话的撤销改到另一段。
    var conversation: String = ""
    var onSend: () -> Void
    /// Escape：生成中返回 true 表示已经停止；否则返回 false，什么都不做。
    var onCancel: (() -> Bool)? = nil
    /// 图片文件拖进输入框：返回 true 表示已接手，AppKit 不再按文本拖放处理。
    var onDropImage: ((URL) -> Bool)?
    /// 剪贴板里的图片（截图 / 复制图像）粘贴进输入框：返回 true 表示已接手。
    var onPasteImage: ((NSImage) -> Bool)?
    /// 剪贴板里是本地文件（Finder 复制 / 截图文件）时：返回 true 表示已接手。
    var onPasteFiles: (([URL]) -> Bool)?
    /// 拖拽悬停状态，交给外层画投放高亮。
    var onDragTargetChange: ((Bool) -> Void)?
    /// 当前模型能不能收图；不能时把文件拖放原样还给 NSTextView。
    var acceptsImageDrop: Bool = false
    /// 当前模型能不能收参考视频。
    var acceptsVideoDrop: Bool = false

    /// 竖排上限：Splash 的输入框长到 220pt 后内部滚动，不再继续长高。
    static let maxHeight: CGFloat = 220
    static let fontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerContainer {
        let container = ComposerContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.font = DS.Font.proseNS(Self.fontSize)
        textView.textColor = .consoleText
        textView.insertionPointColor = .consoleAccent
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        // 15pt 正文、3pt 行距，和消息里读到的回答一致（Splash 的 15/22）。
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        // 提示词里经常是代码或反引号，不要被智能标点改写。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        // NSTextView 默认只会把拖进来的东西当文本插入。显式注册文件 URL，
        // 由 `ComposerTextView` 判断是不是图片，再交给 SwiftUI 记成底图。
        textView.registerForDraggedTypes([.fileURL])

        context.coordinator.container = container
        textView.onDropImage = { [weak coordinator = context.coordinator] url in
            coordinator?.parent.onDropImage?(url) ?? false
        }
        textView.onPasteImage = { [weak coordinator = context.coordinator] image in
            coordinator?.parent.onPasteImage?(image) ?? false
        }
        textView.onPasteFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.parent.onPasteFiles?(urls) ?? false
        }
        textView.onDragTargetChange = { [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.onDragTargetChange?(targeted)
        }
        textView.acceptsImageDrop = acceptsImageDrop
        textView.acceptsVideoDrop = acceptsVideoDrop
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSend()
        }
        textView.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onCancel?() ?? false
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            // 事件回调里直接写 Binding 会在视图更新中途触发状态变更，挪到下一个循环。
            DispatchQueue.main.async { coordinator.parent.isFocused = focused }
        }
        textView.string = text
        context.coordinator.lastReportedText = text
        context.coordinator.syncHeight()
        container.isHidden = !isActive
        return container
    }

    func updateNSView(_ nsView: ComposerContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        nsView.isHidden = !isActive

        let textView = nsView.textView
        textView.isEditable = isEnabled
        textView.insertionPointColor = .consoleAccent
        textView.acceptsImageDrop = acceptsImageDrop
        textView.acceptsVideoDrop = acceptsVideoDrop
        let switched = conversation != coordinator.conversation
        if switched { coordinator.conversation = conversation }
        // 只有「草稿被外部改写」时才写回视图。不能拿 `textView.string` 直接跟
        // Binding 比：输入法组字中的 marked text 已经在文本存储里，却还没进
        // Binding，比一下就会把没确认的拼音清掉——旧实现正是这么丢掉输入的。
        // 视图手里的内容比回报过的新、草稿跟回报过的一致、正在组字，都不碰。
        if switched
            || (textView.string == coordinator.lastReportedText
                && text != coordinator.lastReportedText
                && !textView.hasMarkedText())
        {
            let caret = min(textView.selectedRange().location, text.count)
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            // 外部改写（发送后清空、切会话）不是一次编辑，撤销栈里不该再
            // 把上一段会话或已发送的文字翻回来。
            textView.undoManager?.removeAllActions()
            coordinator.lastReportedText = text
            coordinator.syncHeight()
        }

        // 只负责把「要聚焦」这件事落地。反向（草稿不再聚焦就辞职第一响应者）
        // 不接管：焦点只由用户和 AppKit 决定，免得组字中途被抢走。
        // 但页面隐藏时必须交出第一响应者，避免不可见的 NSTextView 抢走其他页面的键盘输入。
        guard let window = nsView.window else { return }
        if !isActive {
            if window.firstResponder === textView {
                DispatchQueue.main.async {
                    if textView.window?.firstResponder === textView {
                        textView.window?.makeFirstResponder(nil)
                    }
                }
            }
            return
        }
        if isFocused, window.firstResponder !== textView {
            // 不在更新过程中改第一响应者，等这一步结束。
            DispatchQueue.main.async {
                guard textView.window != nil, coordinator.parent.isActive else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    /// 文本视图的代理回调都在主线程，整类挂到 MainActor 上，
    /// 省得在 AppKit 回调里来回 assumeIsolated。
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposerField
        weak var container: ComposerContainer?

        init(_ parent: ChatComposerField) {
            self.parent = parent
        }

        /// 文本视图最后一次交给 SwiftUI 的内容，用来区分「输入框自己的编辑」
        /// 和「外部改写了草稿」。组字中的 marked text 不会进 Binding，所以两边
        /// 本来就可能暂时不一致，不能拿文本存储直接对 Binding 做比较。
        var lastReportedText: String = ""
        /// 视图当前承载的会话草稿。切会话时即使文字相同也要重置视图。
        var conversation: String = ""

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastReportedText = textView.string
            if parent.text != textView.string { parent.text = textView.string }
            syncHeight()
        }

        /// 输入框按内容长高，封顶 `maxLines` 行；超出后交给滚动。
        func syncHeight() {
            container?.syncHeight()
        }
    }
}

// MARK: - AppKit host

/// 承载输入框的容器：`NSScrollView` + `NSTextView`，高度跟着文字走。
final class ComposerContainer: NSView {
    let scrollView = NSScrollView()
    let textView = ComposerTextView()

    private var heightConstraint: NSLayoutConstraint?
    private var currentHeight: CGFloat?

    init() {
        super.init(frame: .zero)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let height = heightAnchor.constraint(equalToConstant: 24)
        height.isActive = true
        heightConstraint = height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        syncHeight()
    }

    /// 空白处点一下也应该聚焦，和点正文里的任意位置一样。
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
        super.mouseDown(with: event)
    }

    func syncHeight() {
        guard let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)

        let font = textView.font ?? NSFont.systemFont(ofSize: ChatComposerField.fontSize)
        let line = ceil(layoutManager.defaultLineHeight(for: font))
        let inset = textView.textContainerInset.height * 2
        let content = max(ceil(layoutManager.usedRect(for: container).height) + inset, line + inset)
        let height = min(content, ChatComposerField.maxHeight)

        if currentHeight.map({ abs($0 - height) > 0.5 }) ?? true {
            currentHeight = height
            heightConstraint?.constant = height
            invalidateIntrinsicContentSize()
        }

        // 文字比可视区矮时，把文档视图撑满可视高度：这样点空白也算点进输入框；
        // 比上限高时文档视图保持内容高度，交给滚动。
        var frame = textView.frame
        let visible = max(height, scrollView.contentSize.height)
        if abs(frame.height - max(content, visible)) > 0.5 {
            frame.size.height = max(content, visible)
            textView.frame = frame
        }
    }
}

/// 唯一一处按键判定所在：回车发送、⇧回车换行、Escape 停止生成。
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onCancel: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onDropImage: ((URL) -> Bool)?
    var onPasteImage: ((NSImage) -> Bool)?
    var onPasteFiles: (([URL]) -> Bool)?
    var onDragTargetChange: ((Bool) -> Void)?
    var acceptsImageDrop = false
    var acceptsVideoDrop = false

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
    ]

    /// 只认受支持的本地媒体文件；其它文件继续走 NSTextView 原来的拖放逻辑。
    private func mediaURL(from info: NSDraggingInfo) -> URL? {
        guard acceptsImageDrop || acceptsVideoDrop else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls =
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options) as? [URL]
        return urls?.first { url in
            let ext = url.pathExtension.lowercased()
            return (acceptsImageDrop && Self.imageExtensions.contains(ext))
                || (acceptsVideoDrop && Self.videoExtensions.contains(ext))
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if mediaURL(from: sender) != nil {
            onDragTargetChange?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if mediaURL(from: sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetChange?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if mediaURL(from: sender) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = mediaURL(from: sender) {
            onDragTargetChange?(false)
            return onDropImage?(url) ?? false
        }
        onDragTargetChange?(false)
        return super.performDragOperation(sender)
    }

    /// Return（主键盘）与 Enter（小键盘）。
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// 截图 / 复制图像后 ⌘V：剪贴板里没有正文、只有位图时，当成附件而不是
    /// 让 NSTextView 插一张不可见的 NSTextAttachment。Finder 里复制的文件
    /// 优先交给 `onPasteFiles`，由外层判断当前模型收不收。
    ///
    /// 有些截图工具会顺便在剪贴板里留一段文件名 / 文件路径；这段文字不该
    /// 抢在图片前面被插进输入框，看起来就像「粘贴没反应」。
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let fileURLs = Self.clipboardFileURLs(from: pasteboard)
        if !fileURLs.isEmpty, onPasteFiles?(fileURLs) == true {
            return
        }

        let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let image = Self.clipboardImage()
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-"
        AppLog.info(
            .chat,
            "composer paste: types=\(types) text=\(text?.count ?? 0) "
                + "image=\(image != nil) files=\(fileURLs.count)")
        if let image, text?.isEmpty != false || Self.looksLikeImageReference(text) {
            if onPasteImage?(image) == true { return }
        }
        super.paste(sender)
    }

    /// 剪贴板里只有位图时，AppKit 的默认校验会把「粘贴」判成不可用：
    /// `NSTextView` 只按自己能读的文本类型验证，而微信 / QQ 截图写进剪贴板的是
    /// `public.png` / `public.tiff`。菜单项一灰，⌘V 的按键等价物就不会派发到
    /// `paste(_:)`，看起来就是「截图粘不进去」。这里把附件分支也算进可粘贴，
    /// 事件才进得来；文字仍由 `NSTextView` 自己判断。
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)), hasPasteableAttachment() {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// 剪贴板里有没有能接手的附件：本地文件交给外层，位图当图片附件。
    private func hasPasteableAttachment() -> Bool {
        let pasteboard = NSPasteboard.general
        if !Self.clipboardFileURLs(from: pasteboard).isEmpty, onPasteFiles != nil {
            return true
        }
        return onPasteImage != nil && Self.clipboardImage() != nil
    }

    private static func clipboardFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 剪贴板里的文字像不像一张图片的路径 / 文件名。只在同时存在位图时才用，
    /// 普通整句文本仍然走原生粘贴。
    private static func looksLikeImageReference(_ text: String?) -> Bool {
        guard let text, !text.isEmpty, !text.contains("\n"), text.count < 260 else {
            return false
        }
        if text.lowercased().hasPrefix("file://") { return true }
        let ext = (text as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    private static func clipboardImage() -> NSImage? {
        let pasteboard = NSPasteboard.general
        // 微信 / QQ 这类截图工具常用自己的 UTI，但通常仍暴露一个 NSImage。
        if let image = NSImage(pasteboard: pasteboard) { return image }
        let types: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
        ]
        for type in types {
            if let data = pasteboard.data(forType: type), let image = NSImage(data: data) {
                return image
            }
        }
        return pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
    }

    override func keyDown(with event: NSEvent) {
        // 组字中：回车是候选确认，不发送。
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }

        // Escape 停掉正在生成的回答；没有生成时什么也不做，不再交给文本视图
        // 弹补全菜单（Splash 的 `cancelOperation` 也是这样）。
        if event.keyCode == 53 {
            _ = onCancel?()
            return
        }

        guard Self.returnKeyCodes.contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            insertNewline(nil)
            return
        }
        // 回车发送；⇧回车在 AppKit 里就是换行。⌥/⌃ 回车留给输入法和系统默认行为。
        if flags.intersection([.shift, .option, .control]).isEmpty {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    /// Tab 继续用来在控件之间移动焦点，不往提示词里插制表符：
    /// 输入框不把键盘困在自己身上（上一版 `TextField` 也是这个行为）。
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }
}
