import Foundation

/// Launch-at-login is implemented with a LaunchAgent plist, the same mechanism
/// the previous client used and the one macOS exposes to third-party apps.
enum LoginItem {
    static let label = "com.zhuo.flashCat"
    static var file: String { Paths.home + "/Library/LaunchAgents/\(label).plist" }

    static func set(enabled: Bool) {
        if !enabled {
            try? FileManager.default.removeItem(atPath: file)
            return
        }
        let executable = Bundle.main.executablePath ?? ""
        if executable.isEmpty { return }
        let escaped = executable
            .replacing("&", with: "&amp;")
            .replacing("<", with: "&lt;")
        Paths.ensureDirectory(Paths.home + "/Library/LaunchAgents")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(escaped)</string></array>
          <key>RunAtLoad</key><true/>
          <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        try? plist.write(toFile: file, atomically: true, encoding: .utf8)
    }

    static var enabled: Bool { Paths.fileExists(file) }
}
