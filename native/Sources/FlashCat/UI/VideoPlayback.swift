import AppKit

/// 显式用 QuickTime 打开本地视频。
/// 直接 `NSWorkspace.open` 会走用户给 .mp4 设的默认应用，有些机器上会落到音频软件；
/// 这里指定系统播放器，打不开时再退回默认行为。
enum VideoPlayback {
    static func openInQuickTime(_ path: String) {
        let file = URL(fileURLWithPath: path)
        let quickTime = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([file], withApplicationAt: quickTime,
                                configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(file)
            }
        }
    }
}
