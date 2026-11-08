import Foundation
import FlashCatKit

/// Finds the app bundle the CLI belongs to. When the command is symlinked into
/// `~/.local/bin` the executable resolves back into the bundle, so `app open`
/// and the bundled pack index still find the right installation.
public enum AppLocator {
    public static func resolve(environment: [String: String],
                               executable: String = CommandLine.arguments.first ?? "") -> URL? {
        if let explicit = environment["FLASHCAT_APP"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit)
            return url.pathExtension == "app" ? url : url.deletingLastPathComponent()
        }
        if let fromExecutable = bundleContaining(executable: executable) { return fromExecutable }
        if Bundle.main.bundlePath.hasSuffix(".app") { return Bundle.main.bundleURL }
        return installed(environment: environment)
    }

    public static func installed(environment: [String: String]) -> URL? {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "/Applications/flashCat.app",
            home + "/Applications/flashCat.app",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static func bundleContaining(executable: String) -> URL? {
        guard !executable.isEmpty else { return nil }
        var url = URL(fileURLWithPath: executable)
        // `argv[0]` can be a PATH-resolved name; Bundle.main knows the real
        // file when it exists.
        if !FileManager.default.fileExists(atPath: url.path),
           let resolved = Bundle.main.executableURL {
            url = resolved
        }
        url = url.resolvingSymlinksInPath()
        if url.pathExtension == "app" { return url }
        var cursor = url.deletingLastPathComponent()
        for _ in 0..<6 {
            if cursor.pathExtension == "app" { return cursor }
            // `.../flashCat.app/Contents/Helpers/flashcat`
            if cursor.lastPathComponent == "Contents" {
                let bundle = cursor.deletingLastPathComponent()
                if bundle.pathExtension == "app" { return bundle }
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return nil
    }

    public static func resourceRoot(_ app: URL?) -> URL? {
        guard let app else { return nil }
        return app.appendingPathComponent("Contents/Resources")
    }

    public static func engineResourceRoot(_ app: URL?) -> String? {
        resourceRoot(app)?.appendingPathComponent("engines").path
    }
}

/// Read-only view of the files the app writes, used when the control server is
/// not reachable. No command mutates files through this type except
/// `config set`, which goes through UserDefaults directly.
public struct LocalState {
    public let environment: [String: String]
    public let app: URL?
    private let defaults: UserDefaults?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        self.app = AppLocator.resolve(environment: environment)
        self.defaults = UserDefaults(suiteName: FlashCatPaths.preferencesDomain)
    }

    public var extraEngineRoots: [String] {
        AppLocator.engineResourceRoot(app).map { [$0] } ?? []
    }

    public func installed(_ id: EngineID) -> [EngineInstallation] {
        EngineInstallations.installed(id, extraRoots: extraEngineRoots)
    }

    public func newest(_ id: EngineID) -> EngineInstallation? {
        EngineInstallations.newest(id, version: nil, extraRoots: extraEngineRoots)
    }

    public var installedIDs: [EngineID] {
        EngineCatalog.allIDs.filter { newest($0) != nil }
    }

    public func string(_ key: String) -> String? {
        defaults?.string(forKey: key)
    }

    public func integer(_ key: String, fallback: Int) -> Int {
        guard let value = defaults?.object(forKey: key) as? NSNumber else { return fallback }
        return value.intValue
    }

    public func bool(_ key: String, fallback: Bool) -> Bool {
        guard defaults?.object(forKey: key) != nil else { return fallback }
        return defaults?.bool(forKey: key) ?? fallback
    }

    public func double(_ key: String, fallback: Double) -> Double {
        guard let value = defaults?.object(forKey: key) as? NSNumber else { return fallback }
        return value.doubleValue
    }

    public var gatewayPort: Int {
        let value = integer("gatewayPort", fallback: 9000)
        return (1024...65535).contains(value) ? value : 9000
    }

    public var gatewayEnabled: Bool { bool("gatewayEnabled", fallback: true) }
    public var controlPort: Int {
        let value = integer("controlPort", fallback: 9100)
        return (1024...65535).contains(value) ? value : 9100
    }
    public var controlEnabled: Bool { bool("controlAPIEnabled", fallback: true) }
    public var selectedModel: String { string("model") ?? "" }

    // MARK: engines.json

    public struct EngineConfiguration: Equatable {
        public var active: String?
        public var lastModel: [String: String] = [:]
        public var port: [String: Int] = [:]
    }

    public var engineConfiguration: EngineConfiguration {
        guard let data = FileManager.default.contents(atPath: FlashCatPaths.engineConfigurationFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return EngineConfiguration()
        }
        var configuration = EngineConfiguration()
        if let active = object["active"] as? [String: Any],
           let version = active["version"] as? String {
            configuration.active = version
        }
        for (key, raw) in object {
            guard key != "active", let value = raw as? [String: Any] else { continue }
            if let model = value["lastModel"] as? String, !model.isEmpty {
                configuration.lastModel[key] = model
            }
            if let port = value["port"] as? Int {
                configuration.port[key] = port
            }
        }
        return configuration
    }

    public var activeEngine: EngineID {
        let configuration = engineConfiguration
        if let active = configuration.active,
           let id = EngineID(rawValue: active),
           newest(id) != nil {
            return id
        }
        return installedIDs.first ?? .splash
    }

    public var enginePort: Int {
        let configuration = engineConfiguration
        return configuration.port[activeEngine.rawValue] ?? activeEngine.defaultPort
    }

    // MARK: Models

    public struct LocalModel: Equatable, Sendable {
        public var id: String
        public var engine: String
        public var path: String
        public var bytes: Int?
    }

    /// A deliberately simple directory scan for the offline case. The app's
    /// model library also merges the built-in catalog and shared-model grants;
    /// that logic needs the running app, so `models list` says "offline view"
    /// instead of pretending the two lists are identical.
    public func localModels(engine: EngineID) -> [LocalModel] {
        let root = FlashCatPaths.modelsDirectory(engine)
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root) else { return [] }
        var models: [LocalModel] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let path = root + "/" + entry
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if engine.descriptor.modelLayout == .nested {
                guard let children = try? manager.contentsOfDirectory(atPath: path) else { continue }
                for child in children.sorted() where !child.hasPrefix(".") {
                    let childPath = path + "/" + child
                    var childIsDirectory: ObjCBool = false
                    guard manager.fileExists(atPath: childPath, isDirectory: &childIsDirectory),
                          childIsDirectory.boolValue else { continue }
                    models.append(LocalModel(id: entry + "/" + child, engine: engine.rawValue,
                                             path: childPath, bytes: directoryBytes(childPath)))
                }
            } else {
                models.append(LocalModel(id: entry, engine: engine.rawValue,
                                         path: path, bytes: directoryBytes(path)))
            }
        }
        return models
    }

    public func directoryBytes(_ path: String) -> Int? {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return nil }
        var total = 0
        for case let item as String in enumerator {
            let full = path + "/" + item
            if let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size]) as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    public func logPath(source: String, engine: EngineID) -> String? {
        switch source {
        case "engine": return FlashCatPaths.logFile(engine)
        case "gateway": return FlashCatPaths.gatewayLogFile
        case "control": return FlashCatPaths.controlLogFile
        case "app": return FlashCatPaths.serverLogFile
        default: return nil
        }
    }
}

/// Process-wide facts shared by the command implementations.
public struct CLIContext {
    public var invocation: CLIInvocation
    public var environment: [String: String]
    public var output: CLIOutput
    public var local: LocalState
    /// stdout is a terminal. Drives colour and the "is this a person watching"
    /// notes; it must not decide whether stdin can be read.
    public var isTTY: Bool
    /// stdin is a terminal. Prompts and `chat -` read stdin only when it is
    /// *not* one (or when the user explicitly asked with `-`).
    public var stdinIsTTY: Bool
    public var executable: String

    public init(invocation: CLIInvocation,
                environment: [String: String],
                output: CLIOutput,
                local: LocalState,
                isTTY: Bool,
                stdinIsTTY: Bool,
                executable: String) {
        self.invocation = invocation
        self.environment = environment
        self.output = output
        self.local = local
        self.isTTY = isTTY
        self.stdinIsTTY = stdinIsTTY
        self.executable = executable
    }

    public var timeout: TimeInterval {
        guard let raw = invocation.option("timeout"), let value = Double(raw), value > 0 else { return 30 }
        return value
    }

    public var longTimeout: TimeInterval {
        guard let raw = invocation.option("timeout"), let value = Double(raw), value > 0 else { return 900 }
        return value
    }

    public var control: ControlLocation {
        get throws {
            let location = try ControlLocation.discover(invocation: invocation, environment: environment)
            if output.verbose { output.note("控制接口：\(location.baseURL.absoluteString)") }
            return location
        }
    }

    /// Ask before an irreversible action. `--yes` skips the question; a
    /// non-interactive stdin refuses instead of hanging forever on readLine.
    public func confirm(_ prompt: String) throws -> Bool {
        if invocation.flag("yes") { return true }
        guard !stdinIsTTY else {
            throw CLIError("这是一个不可逆操作，非交互环境需要加 --yes", exit: .conflict)
        }
        output.note(prompt + " [y/N]")
        let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    public func engineArgument(_ index: Int = 0) throws -> EngineID {
        guard invocation.arguments.indices.contains(index) else {
            throw CLIError("需要引擎 id（\(EngineCatalog.allIDs.map(\.rawValue).joined(separator: " / "))）",
                           exit: .usage)
        }
        let raw = invocation.arguments[index]
        guard let id = EngineID(rawValue: raw), EngineCatalog.allIDs.contains(id) else {
            throw CLIError("未知引擎：\(raw)", exit: .usage,
                           hint: "可用：" + EngineCatalog.allIDs.map(\.rawValue).joined(separator: ", "))
        }
        return id
    }
}
