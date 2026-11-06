import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 自定义背景：图片会被复制到应用支持目录，原图移动或删除后仍然可用。
/// 「APP 透明度」控制画布色盖在图片上的强度：数值越高，图片越清晰。
/// 「背景模糊」控制图片的柔化程度，数值越高越柔和、越不干扰文字。
@MainActor
final class BackgroundSettings: ObservableObject {
    static let shared = BackgroundSettings()

    /// 当前自定义背景图；nil 表示使用默认纯色画布。
    @Published private(set) var image: NSImage?
    /// 0…1 的透明度：0 = 完全遮住图片，1 = 图片完全露出。
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    /// 背景图的模糊半径（pt）；没有图片时也允许预设。
    @Published var blur: Double {
        didSet { defaults.set(blur, forKey: Keys.blur) }
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
