import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 背景参数的纯数学映射。
///
/// 从视图里抽出来是因为「滑杆的值 → 实际画出来什么」这条链没有别的验证手段，
/// 而它恰好是最容易出错的地方：透明度和模糊互相牵连的那个 bug 就出在这里。
enum BackgroundMath {
    /// 背景模糊滑杆（0…40pt）→ 桌面毛玻璃层的强度 0…1。
    static func blurAlpha(_ blur: Double) -> Double {
        min(max(blur / 40, 0), 1)
    }

    /// APP 透明度 → 图片上那层画布保底渐变的不透明度。
    ///
    /// 保底值保证图片再清晰、文字也还有足够对比度；透明度 100% 时正好落在
    /// 保底值上，0 时完全遮住图片。以前直接写 `max(1 - opacity, floor)`，
    /// 透明度超过 `1 - floor`（深色约 58%）之后滑杆就再也没有可见变化——
    /// 一半行程是空的，看起来就像「拖了没反应」。这里把剩余行程线性映射到
    /// 「保底值 → 全遮」，两端仍然落在原来的值上，不留死区。
    static func veilOpacity(_ opacity: Double, dark: Bool) -> Double {
        let floor = dark ? 0.42 : 0.36
        let reveal = min(max(opacity, 0), 1)
        return floor + (1 - floor) * (1 - reveal)
    }

    /// 桌面上那层毛玻璃的强度。有自定义图片时桌面不参与，恒为 0。
    static func desktopFrost(blur: Double, hasImage: Bool) -> Double {
        hasImage ? 0 : blurAlpha(blur)
    }
}

/// 自定义背景：图片会被复制到应用支持目录，原图移动或删除后仍然可用。
/// 「APP 透明度」控制画布色盖在图片上的强度：数值越高，图片越清晰。
/// 「背景模糊」控制图片的柔化程度，数值越高越柔和、越不干扰文字。
///
/// 两个值都在 `didSet` 里直接调用 `BackgroundSurface.refresh()`：窗口表面
/// （不透明与否、毛玻璃强度）必须随参数立刻更新，不能等某个视图碰巧重建。
/// 细节见 `BackgroundSurface`。
@MainActor
final class BackgroundSettings: ObservableObject {
    static let shared = BackgroundSettings()

    /// 当前自定义背景图；nil 表示使用默认纯色画布。
    @Published private(set) var image: NSImage? {
        didSet { BackgroundSurface.shared.refresh() }
    }
    /// 0…1 的透明度：0 = 完全遮住图片，1 = 图片完全露出。
    @Published var opacity: Double {
        didSet {
            defaults.set(opacity, forKey: Keys.opacity)
            BackgroundSurface.shared.refresh()
        }
    }
    /// 背景图的模糊半径（pt）；没有图片时也允许预设。
    @Published var blur: Double {
        didSet {
            defaults.set(blur, forKey: Keys.blur)
            BackgroundSurface.shared.refresh()
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let path = "background.imagePath"
        static let opacity = "background.opacity"
        static let blur = "background.blur"
    }

    private init() {
        let stored = defaults.string(forKey: Keys.path) ?? ""
        if !stored.isEmpty, FileManager.default.fileExists(atPath: stored) {
            image = NSImage(contentsOfFile: stored)
        } else {
            image = nil
        }
        let storedOpacity = defaults.object(forKey: Keys.opacity) as? Double
        opacity = min(max(storedOpacity ?? 0.35, 0), 1)
        let storedBlur = defaults.object(forKey: Keys.blur) as? Double
        blur = min(max(storedBlur ?? 18, 0), 40)
    }

    var isEnabled: Bool { image != nil }

    /// 没有自定义图片时，透明度滑杆改为控制「透出桌面」的程度。
    var revealsDesktop: Bool { image == nil && opacity > 0.001 }

    /// 桌面透出强度 0…1；有图片时固定为 0，避免桌面和图片叠加。
    var desktopReveal: Double { image == nil ? opacity : 0 }

    /// 毛玻璃层当前应有的强度，供视图首次搭建时对齐（之后由 `BackgroundSurface` 驱动）。
    var blurAlpha: CGFloat {
        CGFloat(BackgroundMath.desktopFrost(blur: blur, hasImage: image != nil))
    }

    /// 弹出系统文件选择器，选中的图片会被复制到应用支持目录。
    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一张图片作为应用背景"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(from: url)
    }

    func clear() {
        if let path = defaults.string(forKey: Keys.path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        defaults.removeObject(forKey: Keys.path)
        image = nil
    }

    private func importImage(from url: URL) {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: Paths.supportDirectory, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("background." + ext)

        if let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil) {
            for file in contents where file.lastPathComponent.hasPrefix("background.") {
                try? fileManager.removeItem(at: file)
            }
        }

        do {
            try fileManager.copyItem(at: url, to: destination)
            defaults.set(destination.path, forKey: Keys.path)
            image = NSImage(contentsOf: destination)
        } catch {
            // 复制失败时退回直接引用原图，至少本次仍然可用。
            defaults.set(url.path, forKey: Keys.path)
            image = NSImage(contentsOf: url)
        }
    }
}
