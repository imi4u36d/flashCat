import Foundation

/// One source of truth for every path the app, the CLI and the gateway need.
///
/// Both `flashCat.app` and the `flashcat` command run against the same data
/// root. Duplicating "support directory + /engines" on either side is how a
/// CLI ends up reporting an engine the app cannot see, so the rules live here
/// and the app's `Paths` / `EnginePaths` simply forward to them.
public enum FlashCatPaths {
    /// One home directory for every lookup. `HOME` is read directly because a
    /// launch agent can start the app with a different environment than the
    /// shell that ran the CLI.
    public static var home: String {
        let value = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return value.isEmpty ? NSHomeDirectory() : value
    }

    public static var supportDirectory: String {
        if let override = environment("FLASHCAT_SUPPORT_DIR") { return override }
        return home + "/Library/Application Support/flashCat"
    }

    public static var logsDirectory: String {
        if let override = environment("FLASHCAT_LOGS_DIR") { return override }
        return home + "/Library/Logs/flashCat"
    }

    /// User-owned runtime packs. The app bundle and a checkout's
    /// `vendor/engines` are search locations, not install targets.
    public static var enginesDirectory: String { supportDirectory + "/engines" }

    public static var modelsRoot: String { supportDirectory + "/models" }
    public static var sharedModelsDirectory: String { supportDirectory + "/shared-models" }

    public static var controlRuntimeFile: String { supportDirectory + "/control.json" }
    public static var conversationFile: String { supportDirectory + "/conversation.json" }
    public static var historyFile: String { supportDirectory + "/chat-history.json" }
    public static var engineConfigurationFile: String { supportDirectory + "/engines.json" }
    public static var downloadTasksFile: String { supportDirectory + "/model-downloads.json" }
    public static var pidFile: String { supportDirectory + "/server.pid" }

    public static var gatewayLogFile: String { logsDirectory + "/gateway.log" }
    public static var controlLogFile: String { logsDirectory + "/control.log" }
    public static var serverLogFile: String { logsDirectory + "/server.log" }

    /// The UserDefaults domain the app writes. The CLI reads and edits the same
    /// domain so `flashcat config` works while the app is closed.
    public static let preferencesDomain = "com.zhuo.flashCat"

    public static func modelsDirectory(_ id: EngineID) -> String {
        modelsRoot + "/" + id.rawValue
    }

    public static func engineDirectory(_ id: EngineID) -> String {
        enginesDirectory + "/" + id.rawValue
    }

    /// Resolve a model selection to its on-disk directory. Most pack engines
    /// use flat `owner--repo` names; Hugging Face-native engines preserve the
    /// nested repository path.
    public static func modelPath(for engine: EngineID, model: String) -> String {
        let root = modelsDirectory(engine)
        let base = model.split(separator: ":", maxSplits: 1).first.map(String.init) ?? model
        switch engine.descriptor.modelLayout {
        case .nested:
            return root + "/" + base
        case .flat, .external:
            return root + "/" + modelFolderName(for: base)
        }
    }

    /// Weight folders are flat: `owner--repo` is the id every engine serves, and
    /// the same shape a download lands in.
    public static func modelFolderName(for repo: String) -> String {
        let flat = repo.replacingOccurrences(of: "/", with: "--")
        return flat.replacingOccurrences(of: ":", with: "-")
    }

    public static func logFile(_ id: EngineID) -> String {
        logsDirectory + "/" + id.rawValue + ".log"
    }

    public static func pidFile(_ id: EngineID) -> String {
        supportDirectory + "/" + id.rawValue + ".pid"
    }

    public static func ensureDirectory(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private static func environment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }
}
