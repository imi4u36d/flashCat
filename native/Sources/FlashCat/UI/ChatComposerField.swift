import AppKit
import SwiftUI

/// 对话输入框。
///
/// SwiftUI 的 `TextField(axis: .vertical)` 只能用回车换行，没办法把回车改成发送、
/// 再留一个组合键写换行，所以这里换成 `NSTextView`：**回车发送，⌘回车换行**，
/// 输入法组字期间的回车一律交回 AppKit（那是候选确认，不是发送）。
///
/// 这是应用里唯一一处按键判定，见 UI-SPEC「键盘策略」和
/// `LocalizationTests.testReturnKeyIsOnlyHandledByComposer`。它属于文本编辑动作，
/// 不是全局快捷键：判定只在输入框拿到焦点时发生，不会和用户的快捷键管理器抢键。
struct ChatComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var isEnabled: Bool
    var onSend: () -> Void
    /// 图片文件拖进输入框：返回 true 表示已接手，AppKit 不再按文本拖放处理。
    var onDropImage: ((URL) -> Bool)?
    /// 拖拽悬停状态，交给外层画投放高亮。
    var onDragTargetChange: ((Bool) -> Void)?
    /// 当前模型能不能收图；不能时把文件拖放原样还给 NSTextView。
    var acceptsImageDrop: Bool = false

    /// 竖排上限：超过之后输入框内部滚动，不再继续长高。
    static let maxLines = 6
    static let fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ComposerContainer {
        let container = ComposerContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textColor = .consoleText
        textView.insertionPointColor = .consoleAccent
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0,
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
        textView.onDragTargetChange = { [weak coordinator = context.coordinator] targeted in
            coordinator?.parent.onDragTargetChange?(targeted)
        }
        textView.acceptsImageDrop = acceptsImageDrop
        textView.onSend = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onSend()
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            guard let coordinator, coordinator.parent.isFocused != focused else { return }
            // 事件回调里直接写 Binding 会在视图更新中途触发状态变更，挪到下一个循环。
            DispatchQueue.main.async { coordinator.parent.isFocused = focused }
        }
        textView.string = text
        context.coordinator.lastReportedText = text
        context.coordinator.syncHeight()
        return container
    }

    func updateNSView(_ nsView: ComposerContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let textView = nsView.textView
        textView.isEditable = isEnabled
        textView.acceptsImageDrop = acceptsImageDrop
        // 只有「草稿被外部改写」时才写回视图。不能拿 `textView.string` 直接跟
        // Binding 比：输入法组字中的 marked text 已经在文本存储里，却还没进
        // Binding，比一下就会把没确认的拼音清掉——旧实现正是这么丢掉输入的。
        // 视图手里的内容比回报过的新、草稿跟回报过的一致、正在组字，都不碰。
        if textView.string == coordinator.lastReportedText,
           text != coordinator.lastReportedText,
           !textView.hasMarkedText() {
            let caret = min(textView.selectedRange().location, text.count)
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            coordinator.lastReportedText = text
            coordinator.syncHeight()
        }

        // 只负责把「要聚焦」这件事落地。反向（草稿不再聚焦就辞职第一响应者）
        // 不接管：焦点只由用户和 AppKit 决定，免得组字中途被抢走。
        guard let window = nsView.window else { return }
        if isFocused, window.firstResponder !== textView {
            // 不在更新过程中改第一响应者，等这一步结束。
            DispatchQueue.main.async {
                guard textView.window != nil else { return }
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
        scrollView.hasVerticalScroller = false
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

        let height = heightAnchor.constraint(equalToConstant: 18)
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
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)

        let font = textView.font ?? NSFont.systemFont(ofSize: ChatComposerField.fontSize)
        let line = ceil(layoutManager.defaultLineHeight(for: font))
        let content = max(ceil(layoutManager.usedRect(for: container).height), line)
        let cap = ceil(line * CGFloat(ChatComposerField.maxLines))
        let height = min(content, cap)

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

/// 唯一一处按键判定所在：回车发送、⌘回车换行。
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onDropImage: ((URL) -> Bool)?
    var onDragTargetChange: ((Bool) -> Void)?
    var acceptsImageDrop = false

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "bmp", "gif",
    ]

    /// 只认本地图片文件；其它文件继续走 NSTextView 原来的拖放逻辑。
    private func imageURL(from info: NSDraggingInfo) -> URL? {
        guard acceptsImageDrop else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: options) as? [URL]
        return urls?.first {
            Self.imageExtensions.contains($0.pathExtension.lowercased())
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if imageURL(from: sender) != nil {
            onDragTargetChange?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if imageURL(from: sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargetChange?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if imageURL(from: sender) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let url = imageURL(from: sender) {
            onDragTargetChange?(false)
            return onDropImage?(url) ?? false
        }
        onDragTargetChange?(false)
        return super.performDragOperation(sender)
    }

    /// Return（主键盘）与 Enter（小键盘）。
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    override func keyDown(with event: NSEvent) {
        // 组字中：回车是候选确认，不发送。
        guard !hasMarkedText() else {
            super.keyDown(with: event)
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
        // 回车发送；⇧/⌥/⌃ 回车留给输入法和 AppKit 的默认行为。
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
