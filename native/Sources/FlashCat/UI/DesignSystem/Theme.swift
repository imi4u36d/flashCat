// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import AppKit
import FlashCatCore
import SwiftUI

// MARK: - Appearance
//
// 控制台有四档皮肤：浅色琉璃、深色液态、极简纯白与极简纯黑。前两副是 macOS
// Liquid Glass 语言——粉彩 / 极光壁纸、半透明玻璃卡片、1px 高光边；后两副关掉
// 折射，换成实色白 / 深灰分层。`AppAppearance` 是用户的选择，`GlassSkin` 是这次
// 渲染真正用的那一档（`.system` 在控制器里解析成 light / dark）。窗口本身仍恒定
// Aqua，理由见 `ThemeController.apply(to:)`。

/// 玻璃渲染模式。与 `AppAppearance` 分开：`system` 只存在于用户选择里，
/// 颜色解析永远拿到具体的一副。
enum GlassSkin: Int, CaseIterable, Identifiable {
    case light
    case dark
    case studio
    /// 极简纯白的夜间版本：与 studio 一样的实色分层，只是色阶翻到深色。
    case studioDark

    var id: Int { rawValue }

    var isDark: Bool {
        self == .dark || self == .studioDark
    }
}

/// 动态 `NSColor` provider 在绘制时读取的当前皮肤。写入只发生主线程的
/// `ThemeController.apply`，读取发生在 AppKit 解析颜色时；两边都在主线程，
/// 但 provider 没有 actor 信息，因此这里用 `nonisolated(unsafe)` 明确承诺。
enum GlassSkinState {
    nonisolated(unsafe) static var current: GlassSkin = .light
}

/// User-facing appearance choice. Persisted by `AppSettings`, applied to AppKit by
/// `ThemeController` so AppKit-backed controls (rounded text fields, menus,
/// switches) flip together with the SwiftUI canvas.

// MARK: - Controller

/// Owns the appearance choice: persists it, applies it to AppKit, and publishes the
/// change so the settings UI can highlight the selected option.
@MainActor
final class ThemeController: ObservableObject {
    @Published private(set) var mode: AppAppearance
    /// 系统当前是不是深色。跟随系统时皮肤由它决定；发布出来还有第二个用处：
    /// 换肤时 SwiftUI 能跟着重画，不必等窗口激活事件把整棵树叫醒。
    @Published private(set) var systemIsDark: Bool

    private let settings: AppSettings
    /// Observation tokens are written on the main actor and read once in
    /// `deinit`, where no other reference exists. `nonisolated(unsafe)` is the
    /// narrow promise that lets the nonisolated deinit unregister them without
    /// a Swift 6 data-race diagnostic.
    ///
    /// macOS posts this when the reader flips the system appearance.
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    /// sheet / 提示框是独立窗口，出现那一刻还没有外观（`appearance == nil`），
    /// 会按主窗口的浅色外观画成浅色。AppKit 没有"子窗口已挂上"的公开通知
    /// （`willBeginSheetNotification` 发得太早，`attachedSheet` 还是 nil），
    /// 所以在每个 update 循环末尾补一次：只挑真正没皮肤的 sheet 窗口。
    nonisolated(unsafe) private var sheetObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        self.mode = settings.appearance
        self.systemIsDark = AppAppearance.systemIsDark
        AppAppearance.current = mode
        GlassSkinState.current = Self.skin(for: mode, systemIsDark: systemIsDark)
        observeSystemAppearance()
    }

    deinit {
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    }

    func set(_ value: AppAppearance) {
        guard value != mode else { return }
        mode = value
        AppAppearance.current = value
        GlassSkinState.current = Self.skin(for: value, systemIsDark: systemIsDark)
        settings.appearance = value
        apply()
    }

    /// 当前渲染的玻璃皮肤。`.system` 已经解析成具体的一副，视图不需要再分支。
    var skin: GlassSkin {
        Self.skin(for: mode, systemIsDark: systemIsDark)
    }

    private static func skin(for mode: AppAppearance, systemIsDark: Bool) -> GlassSkin {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .studio: return .studio
        case .studioDark: return .studioDark
        case .system: return systemIsDark ? .dark : .light
        }
    }

    /// 当前皮肤是不是深色。跟随系统时读的是发布出来的 `systemIsDark`，
    /// 而不是现场去翻系统默认值——换肤时要的是"这次通知里的系统状态"。
    var isDark: Bool {
        switch mode {
        case .light, .studio: return false
        case .dark, .studioDark: return true
        case .system: return systemIsDark
        }
    }

    /// 复用的外观实例。每次切换都新建 `NSAppearance(name:)` 会迫使窗口
    /// 重新解析整棵树，窗口从后台回到前台时甚至会让 SwiftUI 重排一次，
    /// 表现为界面整体上移。这里固定两个实例，只在真正换皮肤时赋值。
    private static let aquaAppearance = NSAppearance(named: .aqua)
    /// 极简纯白用的第二个 Aqua 实例。浅色琉璃换到纯白时外观仍是浅色，
    /// 只有换一个实例身份才能让 AppKit 重新解析所有动态颜色（否则页面不会重绘）。
    private static let studioAppearance = NSAppearance(named: .aqua)
    private static let darkAppearance = NSAppearance(named: .darkAqua)

    /// 皮肤本身的外观。它落在 contentView 上，而不是窗口上：窗口外观决定的是
    /// 系统画的那层 chrome（红绿灯、投影），见 `apply(to:)`。
    var skinAppearance: NSAppearance? {
        switch skin {
        case .light: return Self.aquaAppearance
        case .dark, .studioDark: return Self.darkAppearance
        case .studio: return Self.studioAppearance
        }
    }

    /// Applies the choice to the app's windows: AppKit-backed controls, the
    /// SwiftUI canvas (whose `colorScheme` derives from the content view's
    /// appearance) and the canvas colour behind the hidden title bar.
    ///
    /// 刻意**不设** `NSApp.appearance`：全局外观会把菜单栏常驻项也染成皮肤色，
    /// 浅色菜单栏项落在深色菜单栏上时，系统会给它补一块浅色底板（图标因此带
    /// 白底）。菜单栏图标应当始终跟随系统菜单栏着色，所以皮肤只作用到窗口。
    func apply() {
        AppAppearance.current = mode
        GlassSkinState.current = skin
        for window in NSApp.windows where window.canBecomeMain || window.sheetParent != nil {
            apply(to: window)
        }
    }

    /// 当前皮肤对应的具体外观，供 popover 这类不在窗口列表里的界面使用。
    var resolvedAppearance: NSAppearance? { skinAppearance }

    func apply(to window: NSWindow) {
        if window.canBecomeMain, window is NSPanel == false {
            // 窗口自己恒定用浅色外观。WindowServer 是按窗口外观画投影的：同一个
            // 窗口切成 darkAqua 后，投影贴边处几乎全黑、扩散距离也翻倍（实测
            // 边缘 alpha 247 对 121），铺在浅色桌面上就是用户看到的那圈黑影。
            // 窗口外观回到浅色后投影恢复正常，而皮肤照旧由 contentView 承担——
            // 深色皮肤下 AppKit / SwiftUI 的颜色仍然按深色解析。
            if window.appearance !== Self.aquaAppearance {
                window.appearance = Self.aquaAppearance
            }
            let skin = skinAppearance
            if window.contentView?.appearance !== skin {
                window.contentView?.appearance = skin
            }
            // 主窗口保持不透明，底色是壁纸的外圈画布；玻璃层由 SwiftUI 画在
            // 窗口内部，窗口本身不需要透明度。
            BackgroundSurface.shared.applyWindowSurface(to: window)
        } else if window.appearance !== skinAppearance {
            // sheet / 提示框这类独立窗口没有承载皮肤的层级，也不跟主窗口共享
            // 外观：只换它自己的外观，画布色留给系统——把窗口背景染成主窗口的
            // 颜色会把系统给 sheet 的圆角和材质盖掉。
            window.appearance = skinAppearance
        }
        // 纯白与浅色共用 Aqua，SwiftUI 树可能整棵复用；显式标脏一次，
        // 让 `GlassSkinState` 里的新皮肤在下一帧就被解析。
        window.contentView?.needsDisplay = true
    }

    /// Keeps "跟随系统" honest: re-resolve when macOS flips, and (as a backstop
    /// for a missed notification) whenever the app comes back to the front.
    private func observeSystemAppearance() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAppearance() }
        }
        sheetObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.skinUnstyledSheets() }
        }
    }

    /// 给刚出现、还没套皮肤的 sheet 窗口补上外观。判断条件只有两个属性，
    /// 主窗口每帧扫一遍可以忽略不计；套过一次之后 `appearance` 就不再是
    /// nil，不会重复进入。
    private func skinUnstyledSheets() {
        for window in NSApp.windows where window.sheetParent != nil && window.appearance == nil {
            apply(to: window)
        }
    }

    private func refreshSystemAppearance() {
        // 系统状态变了就先记下来：既让跟随系统这一档立刻换肤，也让之后切回
        // 「跟随系统」时手上已经是最新的系统状态，不必再等一次通知。
        let dark = AppAppearance.systemIsDark
        if dark != systemIsDark {
            systemIsDark = dark
        }
        guard mode == .system else { return }
        apply()
    }
}

extension AppAppearance {
    /// Last applied choice, for the rare call site that needs to branch on the
    /// skin (key art keeps white type in both, but a few overlays differ).
    @MainActor static var current: AppAppearance = .system

    @MainActor static var isDark: Bool { current.resolvedIsDark }
}

// MARK: - Dynamic colour

extension NSColor {
    /// A colour that resolves against the *current* appearance every time AppKit
    /// asks for it, instead of freezing to whatever was active at creation time.
    static func adaptive(
        dark: UInt32,
        light: UInt32,
        darkAlpha: Double = 1,
        lightAlpha: Double = 1
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    /// Translucent overlay that flips with the skin: white over the night canvas,
    /// near-black over the daylight one. Keeps relative emphasis identical.
    static func adaptiveOverlay(_ opacity: Double) -> NSColor {
        adaptive(dark: 0xFFFFFF, light: 0x101014, darkAlpha: opacity, lightAlpha: opacity)
    }

    /// 三副皮肤各自取一个值。前两副是 Liquid Glass（浅色琉璃 / 深色液态），
    /// 第三副是极简纯白的实色版本；provider 在绘制时读 `GlassSkinState`。
    static func glass(
        light: UInt32,
        dark: UInt32,
        studio: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1,
        studioAlpha: CGFloat = 1,
        /// 极简纯黑是「深色液态的实色版」：同一个深色色相，但不透出壁纸。
        /// 只有窗口 / 卡片这类表面需要传 1，描边和光晕继续沿用 darkAlpha。
        studioDarkAlpha: CGFloat? = nil
    ) -> NSColor {
        NSColor(name: nil) { _ in
            let hex: UInt32
            let alpha: CGFloat
            switch GlassSkinState.current {
            case .light:
                hex = light
                alpha = lightAlpha
            case .dark:
                hex = dark
                alpha = darkAlpha
            case .studio:
                hex = studio
                alpha = studioAlpha
            case .studioDark:
                hex = dark
                alpha = studioDarkAlpha ?? darkAlpha
            }
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
        }
    }

    /// 控制台正文与强调色。SwiftUI 侧的 `DS.text` / `DS.accent`
    /// 就是这两个颜色的包装，因此 AppKit 文本宿主（对话输入框）和卡片是同一组值。
    /// 浅色琉璃与深色液态取自设计稿的 slate / indigo 色阶。
    static let consoleText = glass(light: 0x0F172A, dark: 0xF8FAFC, studio: 0x111827)
    static let consoleAccent = glass(light: 0x4F46E5, dark: 0x818CF8, studio: 0x4F46E5)
}

extension Color {
    static func adaptive(
        dark: UInt32,
        light: UInt32,
        darkAlpha: Double = 1,
        lightAlpha: Double = 1
    ) -> Color {
        Color(
            nsColor: NSColor.adaptive(
                dark: dark, light: light,
                darkAlpha: darkAlpha, lightAlpha: lightAlpha))
    }

    /// See `NSColor.adaptiveOverlay(_:)`.
    static func adaptiveOverlay(_ opacity: Double) -> Color {
        Color(nsColor: NSColor.adaptiveOverlay(opacity))
    }

    /// See `NSColor.glass(...)`.
    static func glass(
        light: UInt32,
        dark: UInt32,
        studio: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1,
        studioAlpha: CGFloat = 1,
        studioDarkAlpha: CGFloat? = nil
    ) -> Color {
        Color(
            nsColor: NSColor.glass(
                light: light, dark: dark, studio: studio,
                lightAlpha: lightAlpha, darkAlpha: darkAlpha, studioAlpha: studioAlpha,
                studioDarkAlpha: studioDarkAlpha))
    }
}
