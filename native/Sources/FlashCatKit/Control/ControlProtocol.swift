import Foundation
import Darwin

// MARK: - Runtime handshake

public enum ControlRuntimeError: LocalizedError, Equatable {
    case cannotCreate(String, code: Int32)
    case cannotWrite(String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .cannotCreate(let path, let code):
            return "无法创建 \(path)（errno \(code)）"
        case .cannotWrite(let path, let code):
            return "无法写入 \(path)（errno \(code)）"
        }
    }
}

/// The file `flashCat.app` leaves behind while its control server is up.
///
/// The CLI cannot guess the port: the user can change it, and the app falls
/// forward to the next free port when the configured one is taken. The runtime
/// file is the single discovery record; the token in it is required by every
/// control request, so another local process cannot drive the app by accident.
public struct ControlRuntime: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var pid: Int32
    public var port: UInt16
    public var token: String
    public var appVersion: String
    public var appPath: String?
    public var startedAt: Date

    public init(schemaVersion: Int = 1,
                pid: Int32,
                port: UInt16,
                token: String,
                appVersion: String,
                appPath: String?,
                startedAt: Date) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.port = port
        self.token = token
        self.appVersion = appVersion
        self.appPath = appPath
        self.startedAt = startedAt
    }

    public static func load(from path: String = FlashCatPaths.controlRuntimeFile) -> ControlRuntime? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? ControlJSON.decoder().decode(ControlRuntime.self, from: data)
    }

    public func write(to path: String = FlashCatPaths.controlRuntimeFile) throws {
        let directory = (path as NSString).deletingLastPathComponent
        FlashCatPaths.ensureDirectory(directory)
        let data = try ControlJSON.encoder().encode(self)
        // The token is a credential: create the file with 0600 from the first
        // byte instead of an `.atomic` write (whose temporary file follows the
        // process umask, usually 0644) followed by a best-effort chmod. fchmod
        // also tightens a stale file left by an older build.
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw ControlRuntimeError.cannotCreate(path, code: errno)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ControlRuntimeError.cannotCreate(path, code: errno)
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ControlRuntimeError.cannotWrite(path, code: errno)
                }
                offset += written
            }
        }
    }

    /// A stale file from a crashed launch must not make the CLI wait on a port
    /// nobody is listening on.
    public var processIsAlive: Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// Coders are created per call instead of stored in a global: `JSONEncoder` is
/// a mutable reference type, and a shared instance is the kind of cross-thread
/// state the concurrency checker rightly refuses to bless.
public enum ControlJSON {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Documents

public struct ControlAppInfo: Codable, Sendable, Equatable {
    public var version: String
    public var build: String?
    public var pid: Int32
    public var startedAt: Date
    public var appPath: String?
    public var controlPort: UInt16

    public init(version: String, build: String? = nil, pid: Int32, startedAt: Date,
                appPath: String? = nil, controlPort: UInt16) {
        self.version = version
        self.build = build
        self.pid = pid
        self.startedAt = startedAt
        self.appPath = appPath
        self.controlPort = controlPort
    }
}

public struct ControlEngineState: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var installedVersions: [String]
    public var isActive: Bool
    public var isInstalled: Bool
    /// `EngineRunState.rawValue`: stopped / starting / loading / ready / stopping / failed.
    public var state: String
    public var port: Int
    public var model: String
    public var stage: String
    public var uptimeSeconds: Int?
    public var pid: Int?
    public var capabilities: [String]

    public init(id: String, name: String, version: String, installedVersions: [String],
                isActive: Bool, isInstalled: Bool, state: String, port: Int, model: String,
                stage: String, uptimeSeconds: Int? = nil, pid: Int? = nil,
                capabilities: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.installedVersions = installedVersions
        self.isActive = isActive
        self.isInstalled = isInstalled
        self.state = state
        self.port = port
        self.model = model
        self.stage = stage
        self.uptimeSeconds = uptimeSeconds
        self.pid = pid
        self.capabilities = capabilities
    }

    public var isRunning: Bool {
        state == "starting" || state == "loading" || state == "ready" || state == "stopping"
    }
}

public struct ControlGatewayState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var running: Bool
    public var port: Int
    public var baseURL: String
    public var failure: String?

    public init(enabled: Bool, running: Bool, port: Int, baseURL: String, failure: String? = nil) {
        self.enabled = enabled
        self.running = running
        self.port = port
        self.baseURL = baseURL
        self.failure = failure
    }
}

public struct ControlModelSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var engine: String
    public var path: String?
    public var bytes: Int?
    public var installed: Bool
    public var loaded: Bool
    public var loading: Bool
    public var hidden: Bool
    public var helper: Bool
    public var recommended: Bool
    /// `catalog` (built-in recommendation), `local` (weights on disk) or
    /// `shared` (downloaded into the shared folder).
    public var source: String
    public var contextTokens: Int?

    public init(id: String, engine: String, path: String? = nil, bytes: Int? = nil,
                installed: Bool, loaded: Bool = false, loading: Bool = false,
                hidden: Bool = false, helper: Bool = false, recommended: Bool = false,
                source: String, contextTokens: Int? = nil) {
        self.id = id
        self.engine = engine
        self.path = path
        self.bytes = bytes
        self.installed = installed
        self.loaded = loaded
        self.loading = loading
        self.hidden = hidden
        self.helper = helper
        self.recommended = recommended
        self.source = source
        self.contextTokens = contextTokens
    }
}

public struct ControlDownloadSummary: Codable, Sendable, Equatable, Identifiable {
    public var engine: String
    public var model: String
    public var status: String
    public var downloadedBytes: Int
    public var totalBytes: Int
    public var fraction: Double?
    public var shared: [String]?
    public var speed: Double?

    public init(engine: String, model: String, status: String, downloadedBytes: Int,
                totalBytes: Int, fraction: Double? = nil, shared: [String]? = nil,
                speed: Double? = nil) {
        self.engine = engine
        self.model = model
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.fraction = fraction
        self.shared = shared
        self.speed = speed
    }

    public var id: String { engine + "/" + model }
}

public struct ControlStatus: Codable, Sendable, Equatable {
    public var app: ControlAppInfo
    public var engine: ControlEngineState?
    public var engines: [ControlEngineState]
    public var gateway: ControlGatewayState
    public var downloads: [ControlDownloadSummary]

    public init(app: ControlAppInfo, engine: ControlEngineState?, engines: [ControlEngineState],
                gateway: ControlGatewayState, downloads: [ControlDownloadSummary]) {
        self.app = app
        self.engine = engine
        self.engines = engines
        self.gateway = gateway
        self.downloads = downloads
    }
}

public struct ControlLogLine: Codable, Sendable, Equatable {
    public var date: Date
    public var level: String
    public var text: String
    public var engine: String?

    public init(date: Date, level: String, text: String, engine: String? = nil) {
        self.date = date
        self.level = level
        self.text = text
        self.engine = engine
    }
}

public struct ControlLogDocument: Codable, Sendable, Equatable {
    public var source: String
    public var path: String
    public var lines: [ControlLogLine]

    public init(source: String, path: String, lines: [ControlLogLine]) {
        self.source = source
        self.path = path
        self.lines = lines
    }
}

public struct ControlConfigEntry: Codable, Sendable, Equatable, Identifiable {
    /// `string` / `int` / `double` / `bool` / `enum`.
    public var kind: String
    public var key: String
    public var title: String
    public var value: String
    public var mutable: Bool

    public init(kind: String, key: String, title: String, value: String, mutable: Bool = true) {
        self.kind = kind
        self.key = key
        self.title = title
        self.value = value
        self.mutable = mutable
    }

    public var id: String { key }
}

public struct ControlConfigDocument: Codable, Sendable, Equatable {
    public var entries: [ControlConfigEntry]
    public init(entries: [ControlConfigEntry]) { self.entries = entries }
}

public struct ControlDoctorCheck: Codable, Sendable, Equatable, Identifiable {
    /// `ok` / `warn` / `fail`.
    public var status: String
    public var id: String
    public var title: String
    public var detail: String

    public init(status: String, id: String, title: String, detail: String) {
        self.status = status
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct ControlDoctorReport: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var checks: [ControlDoctorCheck]

    public init(generatedAt: Date = Date(), checks: [ControlDoctorCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }

    public var failed: Bool { checks.contains { $0.status == "fail" } }
}

public struct ControlSimpleResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool = true, message: String) {
        self.ok = ok
        self.message = message
    }
}

public struct ControlErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlErrorDocument: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: ControlErrorBody

    public init(code: String, message: String) {
        self.ok = false
        self.error = ControlErrorBody(code: code, message: message)
    }
}

public enum ControlErrorCode {
    public static let unauthorized = "unauthorized"
    public static let notFound = "not_found"
    public static let badRequest = "bad_request"
    public static let conflict = "conflict"
    public static let unavailable = "unavailable"
    public static let failed = "failed"
    public static let timeout = "timeout"
    public static let unsupported = "unsupported"
}

// MARK: - Request bodies

public struct ControlEngineAction: Codable, Sendable, Equatable {
    /// Only the path-less fallback uses this; path routes carry the id.
    public var engine: String?
    public var start: Bool?

    public init(engine: String? = nil, start: Bool? = nil) {
        self.engine = engine
        self.start = start
    }
}

public struct ControlModelUse: Codable, Sendable, Equatable {
    public var model: String
    public var engine: String?

    public init(model: String, engine: String? = nil) {
        self.model = model
        self.engine = engine
    }
}

public struct ControlModelDownload: Codable, Sendable, Equatable {
    public var model: String
    public var engine: String?
    /// `shared` writes one copy into `shared-models` and grants it to
    /// `engines`; `engine` downloads into that engine's own model folder.
    public var mode: String?
    public var engines: [String]?

    public init(model: String, engine: String? = nil, mode: String? = nil, engines: [String]? = nil) {
        self.model = model
        self.engine = engine
        self.mode = mode
        self.engines = engines
    }
}

public struct ControlModelDelete: Codable, Sendable, Equatable {
    public var model: String
    public var engine: String?
    public var shared: Bool?

    public init(model: String, engine: String? = nil, shared: Bool? = nil) {
        self.model = model
        self.engine = engine
        self.shared = shared
    }
}

public struct ControlDownloadAction: Codable, Sendable, Equatable {
    public var engine: String
    public var model: String

    public init(engine: String, model: String) {
        self.engine = engine
        self.model = model
    }
}

public struct ControlGatewayAction: Codable, Sendable, Equatable {
    public var port: Int?

    public init(port: Int? = nil) { self.port = port }
}

public struct ControlConfigSet: Codable, Sendable, Equatable {
    public var key: String
    public var value: String
    /// `true` when the value should be treated as a JSON literal; the CLI
    /// always sends a string, so this is for other clients.
    public var json: Bool?

    public init(key: String, value: String, json: Bool? = nil) {
        self.key = key
        self.value = value
        self.json = json
    }
}

// MARK: - Routes

public enum ControlRoute: Equatable, Sendable {
    case health
    case status
    case engines
    case engineStart(String)
    case engineStop(String)
    case engineRestart(String)
    case engineUse(String)
    case enginesReload
    case models
    case modelUse
    case modelDownload
    case modelDelete
    case downloads
    case downloadPause
    case downloadResume
    case downloadCancel
    case logs
    case gatewayStart
    case gatewayStop
    case config
    case configSet
    case appQuit
    case appOpen
    case doctor

    /// Parse the method + path into a command. `nil` means "no such route";
    /// the caller answers 404 instead of silently succeeding.
    public static func parse(method: String, path: String) -> ControlRoute? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "v1" else { return nil }
        let verb = method.uppercased()

        switch (verb, parts[1]) {
        case ("GET", "health") where parts.count == 2: return .health
        case ("GET", "status") where parts.count == 2: return .status
        case ("GET", "doctor") where parts.count == 2: return .doctor
        case ("GET", "config") where parts.count == 2: return .config
        case ("POST", "config") where parts.count == 2: return .configSet
        case ("GET", "downloads") where parts.count == 2: return .downloads
        case ("GET", "logs") where parts.count == 2: return .logs
        case ("GET", "models") where parts.count == 2: return .models
        case ("POST", "models") where parts.count == 3:
            switch parts[2] {
            case "use": return .modelUse
            case "download": return .modelDownload
            case "delete": return .modelDelete
            default: return nil
            }
        case ("POST", "downloads") where parts.count == 3:
            switch parts[2] {
            case "pause": return .downloadPause
            case "resume": return .downloadResume
            case "cancel": return .downloadCancel
            default: return nil
            }
        case ("POST", "gateway") where parts.count == 3:
            switch parts[2] {
            case "start": return .gatewayStart
            case "stop": return .gatewayStop
            default: return nil
            }
        case ("POST", "app") where parts.count == 3:
            switch parts[2] {
            case "quit": return .appQuit
            case "open": return .appOpen
            default: return nil
            }
        case ("GET", "engines") where parts.count == 2: return .engines
        case ("POST", "engines") where parts.count == 3 && parts[2] == "reload": return .enginesReload
        case ("POST", "engines") where parts.count == 4:
            let id = parts[2].removingPercentEncoding ?? parts[2]
            guard !id.isEmpty else { return nil }
            switch parts[3] {
            case "start": return .engineStart(id)
            case "stop": return .engineStop(id)
            case "restart": return .engineRestart(id)
            case "use": return .engineUse(id)
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Log sources

public enum ControlLogSource: String, Sendable {
    case engine
    case gateway
    case control
    case app

    public static func resolve(_ raw: String?) -> ControlLogSource? {
        guard let raw, !raw.isEmpty else { return .engine }
        return ControlLogSource(rawValue: raw)
    }
}
